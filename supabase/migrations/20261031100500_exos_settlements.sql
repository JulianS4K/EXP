-- ============================================================================
-- Migration 20261031100500 — Exos: finance items, settlements, profit and
-- loss inputs, scheduled ticket-count emails. docs/offers-settlements.md.
--
-- Touches:  C: TABLE exos_finance_items, exos_settlements,
--              exos_ticket_count_schedules, exos_ticket_count_recipients
--           C: FUNCTION _exos_box_office, _exos_settlement_inputs,
--              _exos_settlement_ensure / _get / _update / _finalize /
--              _reopen, _exos_pnl_inputs, _exos_tc_* (service_role: exos-api
--              passes the key's org), exos_settlement_* / exos_pnl_inputs /
--              exos_ticket_counts_* (signed-in staff),
--              exos_settlement_public, exos_ticket_counts_optout (anon,
--              64-hex token), exos_ticket_counts_run (service_role, cron)
--           C: cron.schedule exos-ticket-counts-15min, created INACTIVE
--              (when pg_cron is present)
--           W: exos_mail template allowlist (+ settlement-finalized,
--              ticket-counts)
--           R: exos_events, exos_tickets, exos_ticket_tiers,
--              exos_checkout_sessions, exos_order_refunds, exos_order_fees,
--              exos_holds, exos_venues, exos_event_contacts, exos_offers,
--              exos_budgets, exos_budget_lines, exos_offer_pools,
--              exos_finance_categories, exos_gl_codes,
--              exos_sales_count_totals (PR #65, read only when it exists)
-- Pre-reqs: 20261031100000 (offers), 20261027100000 (exos_order_fees),
--           20260929131000 (session fee columns), 20261030100000 (booking)
--
-- The settlement is computed by the pure deal math
-- (supabase/functions/_shared/finance/dealMath.ts, the same file the
-- dashboard and exos-api run) from the inputs this migration gathers in one
-- place (_exos_settlement_inputs):
--   * Box office from Exos sales: tickets still active or used (voided and
--     transferred-away tickets don't count), paid ($ > 0) vs comps ($0:
--     attendance, not revenue), per ticket type; gross is what buyers paid
--     for them (price_paid, all-in), less refunds not already covered by
--     voided tickets. Deductions (tax, passed-on fees, absorbed fees, the
--     Exos and card fee) come from each order in proportion to the share of
--     it still held as valid tickets.
--   * Sold elsewhere: exos_sales_count_totals (PR #65) per currency, read
--     through to_regclass so this migration applies with or without it; in
--     the event's currency they count, others are listed only.
--   * Finance items (per show, each in a category with its GL code), the
--     accepted offers on the show (or on its hold, not yet linked), their
--     budget's pool, and the hold's rental terms.
--   * Promoter mode (the show's venue is rented / partner, or its hold has
--     rental terms): the venue is settled too (rental + its share of net box
--     office − the rental deposit paid), and the rental is a Venue rental
--     expense line created once (deleting it sticks).
-- Finalizing freezes the inputs (snapshot): later sales and edits no longer
-- move it. It mints a link for the show's settlement contacts
-- (exos_settlement_public, anon, 64-hex token; no promoter net on that page)
-- and emits settlement.finalized. Reopening (owner / manager) kills the link.
--
-- Ticket counts: a per-show schedule (daily at a local time, or weekly on a
-- weekday, in the show's time zone) mails each recipient (default: the show's
-- agent contacts) sold by ticket type, comps, gross, the last 24 hours,
-- attendance against capacity and sold elsewhere, through exos_mail. Each
-- recipient has an opt-out link. exos_ticket_counts_run (cron, created
-- inactive) claims due schedules with SKIP LOCKED and moves next_run_at
-- before sending; mails carry a dedupe key per recipient and run, so a retry
-- never doubles. Schedules switch off a day after the show or when it is
-- cancelled. "Send now" is at most once per 10 minutes.
--
-- Who: owners, managers and finance read settlements, items, P&L and
-- schedules; owners, managers and finance write items, adjustments and
-- finalize; owners and managers reopen and manage ticket-count emails.
-- Scanners and content staff see nothing.
--
-- Additive only; re-run safe. Prod apply needs operator OK.
-- ROLLBACK: SELECT cron.unschedule('exos-ticket-counts-15min'); DROP the
-- functions and tables above.
-- ============================================================================

-- ===========================================================================
-- 1. Finance items (per show)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_finance_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  category_id    uuid REFERENCES public.exos_finance_categories (id) ON DELETE SET NULL,
  kind           text NOT NULL DEFAULT 'expense' CHECK (kind IN ('income', 'expense')),
  label          text NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 120),
  -- What it is; forecast / estimate / actual override it in the P&L columns
  -- (the settlement uses actual, else amount).
  amount_cents   bigint NOT NULL DEFAULT 0 CHECK (amount_cents BETWEEN 0 AND 100000000000),
  forecast_cents bigint CHECK (forecast_cents IS NULL OR forecast_cents BETWEEN 0 AND 100000000000),
  estimate_cents bigint CHECK (estimate_cents IS NULL OR estimate_cents BETWEEN 0 AND 100000000000),
  actual_cents   bigint CHECK (actual_cents IS NULL OR actual_cents BETWEEN 0 AND 100000000000),
  notes          text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 1000),
  -- 'venue-rental': created from the hold's rental terms, once.
  auto           text CHECK (auto IS NULL OR auto IN ('venue-rental')),
  created_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, auto)
);
CREATE INDEX IF NOT EXISTS exos_finance_items_event_idx ON public.exos_finance_items (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_finance_items_org_idx ON public.exos_finance_items (org_id);

-- Items take their org from the event; the category is the org's own and of
-- a kind that fits; 200 per show.
CREATE OR REPLACE FUNCTION public._exos_tg_finance_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_kind text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.event_id IS DISTINCT FROM OLD.event_id OR v_org IS DISTINCT FROM OLD.org_id) THEN
    RAISE EXCEPTION 'a finance item can''t move to another show' USING ERRCODE = '22023';
  END IF;
  NEW.org_id := v_org;
  NEW.label := btrim(NEW.label);
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_finance_items WHERE event_id = NEW.event_id) >= 200 THEN
      RAISE EXCEPTION 'at most 200 finance items per show' USING ERRCODE = '54000';
    END IF;
  ELSIF NEW.auto IS DISTINCT FROM OLD.auto THEN
    RAISE EXCEPTION 'auto is set by Exos' USING ERRCODE = '22023';
  END IF;
  IF NEW.category_id IS NOT NULL THEN
    SELECT kind INTO v_kind FROM public.exos_finance_categories WHERE id = NEW.category_id AND org_id = v_org;
    IF v_kind IS NULL THEN
      RAISE EXCEPTION 'category_id is not one of this organization''s finance categories' USING ERRCODE = '22023';
    END IF;
    IF v_kind <> 'both' AND v_kind <> NEW.kind THEN
      RAISE EXCEPTION 'that category is for % lines', v_kind USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_finance_item() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_finance_items_guard ON public.exos_finance_items;
CREATE TRIGGER exos_finance_items_guard BEFORE INSERT OR UPDATE ON public.exos_finance_items
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_finance_item();
-- A client can't make an auto line.
CREATE OR REPLACE FUNCTION public._exos_tg_finance_item_auto()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.auto IS NOT NULL AND current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'auto is set by Exos' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_finance_item_auto() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_finance_items_auto ON public.exos_finance_items;
CREATE TRIGGER exos_finance_items_auto BEFORE INSERT ON public.exos_finance_items
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_finance_item_auto();

-- ===========================================================================
-- 2. Settlements (one per show) and ticket-count schedules
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_settlements (
  event_id                 uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id                   uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status                   text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'finalized')),
  -- [{ id, offer_id | null, label, amount_cents (signed), reason, by, at }]
  adjustments              jsonb NOT NULL DEFAULT '[]'::jsonb
                           CHECK (jsonb_typeof(adjustments) = 'array' AND jsonb_array_length(adjustments) <= 50),
  -- { offer_id: true } for deposits already paid to the act.
  deposits_paid            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(deposits_paid) = 'object'),
  venue_share_percent      numeric(6, 3) NOT NULL DEFAULT 0 CHECK (venue_share_percent BETWEEN 0 AND 100),
  -- NULL: the hold's rental deposit.
  venue_deposit_paid_cents bigint CHECK (venue_deposit_paid_cents IS NULL OR venue_deposit_paid_cents BETWEEN 0 AND 100000000000),
  -- The inputs frozen when finalized.
  snapshot                 jsonb,
  finalized_at             timestamptz,
  finalized_by             uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  link_token_hash          text CHECK (link_token_hash IS NULL OR link_token_hash ~ '^[0-9a-f]{64}$'),
  emailed_to               text[] NOT NULL DEFAULT '{}',
  rental_seeded            boolean NOT NULL DEFAULT false,
  revision                 integer NOT NULL DEFAULT 0,
  history                  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(history) = 'array'),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'finalized') = (snapshot IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS exos_settlements_org_idx ON public.exos_settlements (org_id, status);

CREATE TABLE IF NOT EXISTS public.exos_ticket_count_schedules (
  event_id        uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  enabled         boolean NOT NULL DEFAULT false,
  frequency       text NOT NULL DEFAULT 'daily' CHECK (frequency IN ('daily', 'weekly')),
  send_time       time NOT NULL DEFAULT '10:00',
  weekday         integer NOT NULL DEFAULT 1 CHECK (weekday BETWEEN 0 AND 6),   -- 0 = Sunday
  timezone        text NOT NULL DEFAULT 'UTC' CHECK (char_length(timezone) <= 64),
  next_run_at     timestamptz,
  last_sent_at    timestamptz,
  last_sent_count integer NOT NULL DEFAULT 0,
  last_manual_at  timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_ticket_count_schedules_due_idx
  ON public.exos_ticket_count_schedules (next_run_at) WHERE enabled;

CREATE TABLE IF NOT EXISTS public.exos_ticket_count_recipients (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  event_id     uuid NOT NULL REFERENCES public.exos_ticket_count_schedules (event_id) ON DELETE CASCADE,
  name         text CHECK (name IS NULL OR char_length(name) <= 100),
  email        text NOT NULL CHECK (char_length(email) <= 200),
  role         text NOT NULL DEFAULT 'other' CHECK (role IN ('agent', 'promoter', 'settlement', 'other')),
  source       text NOT NULL DEFAULT 'manual' CHECK (source IN ('contact', 'manual')),
  optout_token text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex') CHECK (optout_token ~ '^[0-9a-f]{64}$'),
  opted_out_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, email),
  UNIQUE (optout_token)
);
CREATE INDEX IF NOT EXISTS exos_ticket_count_recipients_org_idx ON public.exos_ticket_count_recipients (org_id);

-- ===========================================================================
-- 3. updated_at, RLS, grants
--    Items: owner / manager / finance read and write.
--    Settlements, schedules, recipients: owner / manager / finance read;
--    written only by the functions below. Recipients' opt-out tokens have no
--    client column grant.
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_finance_items', 'exos_settlements', 'exos_ticket_count_schedules',
                           'exos_ticket_count_recipients'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_sel', t);
  END LOOP;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_finance_items TO authenticated;
DROP POLICY IF EXISTS exos_finance_items_write ON public.exos_finance_items;
CREATE POLICY exos_finance_items_write ON public.exos_finance_items FOR ALL TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']))
  WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
GRANT SELECT (event_id, org_id, status, adjustments, deposits_paid, venue_share_percent, venue_deposit_paid_cents,
              finalized_at, finalized_by, emailed_to, revision, history, created_at, updated_at)
  ON public.exos_settlements TO authenticated;
GRANT SELECT ON public.exos_ticket_count_schedules TO authenticated;
GRANT SELECT (id, org_id, event_id, name, email, role, source, opted_out_at, created_at, updated_at)
  ON public.exos_ticket_count_recipients TO authenticated;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_finance_items', 'exos_settlements', 'exos_ticket_count_schedules',
                               'exos_ticket_count_recipients'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 4. Box office and settlement inputs
-- ===========================================================================

-- Exos sales of one show (see the header for the rules). Minor units.
CREATE OR REPLACE FUNCTION public._exos_box_office(p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  WITH tk AS (
    SELECT t.tier_id, coalesce(t.tier_name, tt.name, 'Tickets') AS tier_name, t.order_ref, t.status, t.created_at,
           round(coalesce(t.price_paid, 0) * 100)::bigint AS cents
      FROM public.exos_tickets t
      LEFT JOIN public.exos_ticket_tiers tt ON tt.id = t.tier_id
     WHERE t.event_id = p_event
  ), counting AS (
    SELECT * FROM tk WHERE status IN ('active', 'used')
  ), ses AS (
    SELECT s.session_id, greatest(s.amount_cents, 0)::bigint AS amount,
           coalesce(s.tax_cents, 0)::bigint AS tax,
           coalesce(s.application_fee_cents, 0)::bigint AS platform,
           coalesce((SELECT sum(r.amount_cents) FROM public.exos_order_refunds r
                      WHERE r.session_id = s.session_id AND r.status = 'succeeded'), 0)::bigint AS refunded,
           coalesce((SELECT sum(f.amount_cents) FROM public.exos_order_fees f
                      WHERE f.session_id = s.session_id AND f.kind = 'passed_on'), 0)::bigint AS passed_on,
           coalesce((SELECT sum(f.amount_cents) FROM public.exos_order_fees f
                      WHERE f.session_id = s.session_id AND f.kind = 'absorbed'), 0)::bigint AS absorbed,
           coalesce((SELECT sum(c.cents) FROM counting c WHERE c.order_ref = s.session_id), 0)::bigint AS valid,
           coalesce((SELECT sum(x.cents) FROM tk x WHERE x.order_ref = s.session_id), 0)::bigint AS minted
      FROM public.exos_checkout_sessions s
     WHERE s.event_id = p_event AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')
  ), ses2 AS (
    -- Refunds not already covered by voided tickets come off the gross.
    SELECT *, least(valid, greatest(0, refunded - (minted - valid))) AS extra_refund FROM ses
  ), ses3 AS (
    SELECT *, CASE WHEN amount > 0 THEN (valid - extra_refund)::numeric / amount ELSE 0 END AS share FROM ses2
  ), tiers AS (
    SELECT tier_id, min(tier_name) AS tier_name,
           count(*) FILTER (WHERE cents > 0) AS paid, count(*) FILTER (WHERE cents = 0) AS comps,
           coalesce(sum(cents), 0) AS gross
      FROM counting GROUP BY tier_id
  )
  SELECT jsonb_build_object(
    'tiers', coalesce((SELECT jsonb_agg(jsonb_build_object('tier_id', tier_id, 'name', tier_name, 'paid', paid,
                                                           'comps', comps, 'gross_cents', gross)
                                        ORDER BY paid DESC, tier_name) FROM tiers), '[]'::jsonb),
    'paid_sold', (SELECT count(*) FROM counting WHERE cents > 0),
    'comps', (SELECT count(*) FROM counting WHERE cents = 0),
    'sold_last_24h', (SELECT count(*) FROM counting WHERE cents > 0 AND created_at >= now() - interval '24 hours'),
    'first_sale_at', (SELECT min(created_at) FROM counting),
    'gross_cents', (SELECT coalesce(sum(cents), 0) FROM counting) - (SELECT coalesce(sum(extra_refund), 0) FROM ses3),
    'refunded_cents', (SELECT coalesce(sum(refunded), 0) FROM ses3),
    'tax_cents', (SELECT coalesce(round(sum(tax * share)), 0) FROM ses3),
    'passed_on_fees_cents', (SELECT coalesce(round(sum(passed_on * share)), 0) FROM ses3),
    'absorbed_fees_cents', (SELECT coalesce(round(sum(absorbed * share)), 0) FROM ses3),
    'platform_fees_cents', (SELECT coalesce(round(sum(platform * share)), 0) FROM ses3));
$$;
REVOKE ALL ON FUNCTION public._exos_box_office(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_box_office(uuid) TO service_role;

-- Sold elsewhere (PR #65's exos_sales_count_totals), per currency. The view
-- may not be on this database yet: then available = false and no lines.
CREATE OR REPLACE FUNCTION public._exos_sold_elsewhere(p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v jsonb;
BEGIN
  IF to_regclass('public.exos_sales_count_totals') IS NULL THEN
    RETURN jsonb_build_object('available', false, 'lines', '[]'::jsonb);
  END IF;
  EXECUTE 'SELECT coalesce(jsonb_agg(jsonb_build_object(''currency'', upper(currency), ''sold'', sold,
                                                        ''gross_cents'', gross_cents, ''entries'', entries)
                                     ORDER BY currency), ''[]''::jsonb)
             FROM public.exos_sales_count_totals WHERE event_id = $1'
     INTO v USING p_event;
  RETURN jsonb_build_object('available', true, 'lines', v);
END $$;
REVOKE ALL ON FUNCTION public._exos_sold_elsewhere(uuid) FROM PUBLIC, anon, authenticated;

-- Everything the settlement, the P&L and the ticket counts read for one show.
CREATE OR REPLACE FUNCTION public._exos_settlement_inputs(p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  e       public.exos_events%ROWTYPE;
  h       public.exos_holds%ROWTYPE;
  v_rel   text;
  v_venue jsonb;
  v_cap   bigint;
  st      public.exos_settlements%ROWTYPE;
  v_budget uuid;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event;
  IF e.id IS NULL THEN RETURN NULL; END IF;
  IF e.hold_id IS NOT NULL THEN
    SELECT * INTO h FROM public.exos_holds WHERE id = e.hold_id;
  END IF;
  SELECT v.relationship, jsonb_build_object('id', v.id, 'name', v.name, 'relationship', v.relationship)
    INTO v_rel, v_venue FROM public.exos_venues v WHERE v.id = e.exos_venue_id;
  SELECT CASE WHEN e.total_tickets > 0 THEN e.total_tickets
              ELSE (SELECT coalesce(sum(t.capacity), 0) FROM public.exos_ticket_tiers t WHERE t.event_id = e.id) END
    INTO v_cap;
  SELECT * INTO st FROM public.exos_settlements WHERE event_id = e.id;
  -- The forecast budget: an accepted offer's, else the newest open offer's,
  -- else a budget linked to the show.
  SELECT o.budget_id INTO v_budget FROM public.exos_offers o
   WHERE o.org_id = e.org_id AND (o.event_id = e.id OR (o.event_id IS NULL AND e.hold_id IS NOT NULL AND o.hold_id = e.hold_id))
     AND o.status IN ('accepted', 'sent', 'draft')
   ORDER BY (o.status = 'accepted') DESC, o.created_at DESC LIMIT 1;
  IF v_budget IS NULL THEN
    SELECT id INTO v_budget FROM public.exos_budgets WHERE org_id = e.org_id AND event_id = e.id ORDER BY created_at DESC LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'version', 1,
    'computed_at', now(),
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at,
                                'timezone', e.timezone, 'currency', upper(coalesce(e.currency, 'USD')),
                                'capacity', v_cap, 'venue', v_venue, 'venue_name', e.venue_name, 'hold_id', e.hold_id),
    'box_office', public._exos_box_office(e.id),
    'sold_elsewhere', public._exos_sold_elsewhere(e.id),
    'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', i.id, 'kind', i.kind, 'label', i.label, 'category_id', i.category_id, 'category_key', c.key,
                'category_name', c.name, 'gl_code', g.code, 'amount_cents', i.amount_cents,
                'forecast_cents', i.forecast_cents, 'estimate_cents', i.estimate_cents, 'actual_cents', i.actual_cents,
                'auto', i.auto, 'notes', i.notes) ORDER BY i.kind DESC, c.position NULLS LAST, i.created_at)
              FROM public.exos_finance_items i
              LEFT JOIN public.exos_finance_categories c ON c.id = i.category_id
              LEFT JOIN public.exos_gl_codes g ON g.id = c.gl_code_id AND g.discarded_at IS NULL
             WHERE i.event_id = e.id), '[]'::jsonb),
    'offers', coalesce((SELECT jsonb_agg(jsonb_build_object(
                'id', o.id, 'budget_id', o.budget_id, 'artist_name', o.artist_name, 'act_type', o.act_type,
                'status', o.status, 'currency', o.currency, 'terms', o.terms,
                'pool_share_percent', o.pool_share_percent)
                ORDER BY CASE o.act_type WHEN 'headliner' THEN 0 WHEN 'co_headliner' THEN 1 WHEN 'support' THEN 2
                                         WHEN 'opener' THEN 3 ELSE 4 END, o.created_at)
              FROM public.exos_offers o
             WHERE o.org_id = e.org_id AND o.status = 'accepted'
               AND (o.event_id = e.id OR (o.event_id IS NULL AND e.hold_id IS NOT NULL AND o.hold_id = e.hold_id))),
              '[]'::jsonb),
    'pools', coalesce((SELECT jsonb_agg(jsonb_build_object('budget_id', p.budget_id, 'mode', p.mode, 'terms', p.terms))
              FROM public.exos_offer_pools p
             WHERE p.budget_id IN (SELECT o.budget_id FROM public.exos_offers o
                                    WHERE o.org_id = e.org_id AND o.status = 'accepted'
                                      AND (o.event_id = e.id OR (o.event_id IS NULL AND e.hold_id IS NOT NULL AND o.hold_id = e.hold_id)))),
              '[]'::jsonb),
    'budget', (SELECT jsonb_build_object('id', b.id, 'name', b.name, 'currency', b.currency, 'capacity', b.capacity,
                        'average_price_cents', b.average_price_cents, 'sell_through_percent', b.sell_through_percent,
                        'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', l.kind, 'label', l.label,
                                     'category_id', l.category_id, 'category_key', c.key, 'amount_cents', l.amount_cents)
                                     ORDER BY l.position, l.created_at)
                                   FROM public.exos_budget_lines l
                                   LEFT JOIN public.exos_finance_categories c ON c.id = l.category_id
                                  WHERE l.budget_id = b.id), '[]'::jsonb),
                        'offers', coalesce((SELECT jsonb_agg(jsonb_build_object('id', o.id, 'artist_name', o.artist_name,
                                     'status', o.status, 'terms', o.terms, 'pool_share_percent', o.pool_share_percent)
                                     ORDER BY o.created_at)
                                   FROM public.exos_offers o WHERE o.budget_id = b.id AND o.status IN ('draft', 'sent', 'accepted')),
                                   '[]'::jsonb),
                        'pool', (SELECT jsonb_build_object('mode', p.mode, 'terms', p.terms)
                                   FROM public.exos_offer_pools p WHERE p.budget_id = b.id))
                 FROM public.exos_budgets b WHERE b.id = v_budget),
    'rental', CASE WHEN h.id IS NOT NULL AND h.rental_status IN ('requested', 'confirmed') THEN jsonb_build_object(
                'status', h.rental_status, 'fee_cents', round(coalesce(h.rental_fee, 0) * 100)::bigint,
                'deposit_cents', round(coalesce(h.rental_deposit, 0) * 100)::bigint,
                'currency', coalesce(h.rental_currency, 'USD')) END,
    'promoter_mode', coalesce(v_rel IN ('rented', 'partner'), false)
                     OR (h.id IS NOT NULL AND h.rental_status IN ('requested', 'confirmed')),
    'settlement', jsonb_build_object(
      'adjustments', coalesce(st.adjustments, '[]'::jsonb),
      'deposits_paid', coalesce(st.deposits_paid, '{}'::jsonb),
      'venue_share_percent', coalesce(st.venue_share_percent, 0),
      'venue_deposit_paid_cents', coalesce(st.venue_deposit_paid_cents,
                                           CASE WHEN h.rental_status IN ('requested', 'confirmed')
                                                THEN round(coalesce(h.rental_deposit, 0) * 100)::bigint ELSE 0 END)));
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_inputs(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_settlement_inputs(uuid) TO service_role;

-- ===========================================================================
-- 5. Settlement logic (cores: service_role; exos-api passes the key's org)
-- ===========================================================================

-- The settlement row for a show of p_org (created on first use) with the
-- Venue rental line seeded once in promoter mode. P0002 for another org's.
CREATE OR REPLACE FUNCTION public._exos_settlement_ensure(p_org uuid, p_event uuid)
RETURNS public.exos_settlements LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE st public.exos_settlements%ROWTYPE; h public.exos_holds%ROWTYPE; v_rel text; e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO public.exos_settlements (event_id, org_id) VALUES (e.id, p_org) ON CONFLICT (event_id) DO NOTHING;
  SELECT * INTO st FROM public.exos_settlements WHERE event_id = e.id FOR UPDATE;
  IF NOT st.rental_seeded AND st.status = 'draft' THEN
    IF e.hold_id IS NOT NULL THEN
      SELECT * INTO h FROM public.exos_holds WHERE id = e.hold_id;
    END IF;
    SELECT relationship INTO v_rel FROM public.exos_venues WHERE id = e.exos_venue_id;
    IF h.id IS NOT NULL AND h.rental_status IN ('requested', 'confirmed') AND coalesce(h.rental_fee, 0) > 0 THEN
      PERFORM public._exos_fin_seed(p_org);
      INSERT INTO public.exos_finance_items (org_id, event_id, category_id, kind, label, amount_cents, notes, auto)
      VALUES (p_org, e.id, public._exos_fin_category(p_org, 'venue-rental'), 'expense', 'Venue rental',
              round(h.rental_fee * 100)::bigint,
              CASE WHEN coalesce(h.rental_deposit, 0) > 0 THEN 'Deposit ' || h.rental_deposit || ' ' || coalesce(h.rental_currency, 'USD') ELSE '' END,
              'venue-rental')
      ON CONFLICT (event_id, auto) DO NOTHING;
    END IF;
    UPDATE public.exos_settlements SET rental_seeded = true WHERE event_id = e.id RETURNING * INTO st;
  END IF;
  RETURN st;
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_ensure(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_settlement_view(st public.exos_settlements)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'event_id', st.event_id, 'status', st.status, 'adjustments', st.adjustments, 'deposits_paid', st.deposits_paid,
    'venue_share_percent', st.venue_share_percent, 'venue_deposit_paid_cents', st.venue_deposit_paid_cents,
    'finalized_at', st.finalized_at, 'finalized_by', st.finalized_by, 'emailed_to', to_jsonb(st.emailed_to),
    'revision', st.revision, 'history', st.history, 'updated_at', st.updated_at,
    'inputs', CASE WHEN st.status = 'finalized' THEN st.snapshot ELSE public._exos_settlement_inputs(st.event_id) END);
$$;
REVOKE ALL ON FUNCTION public._exos_settlement_view(public.exos_settlements) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_settlement_get(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_settlement_view(public._exos_settlement_ensure(p_org, p_event));
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_get(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_settlement_get(uuid, uuid) TO service_role;

-- Change adjustments (the full list; each needs a reason), deposits paid and
-- venue terms. Not while finalized. p_revision, when given, must match
-- (someone else saved in between: 55000).
CREATE OR REPLACE FUNCTION public._exos_settlement_update(p_org uuid, p_actor uuid, p_event uuid, p jsonb,
                                                          p_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  st  public.exos_settlements%ROWTYPE;
  b   jsonb := CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}'::jsonb END;
  a   jsonb;
  v_adj jsonb := '[]'::jsonb;
  v_dep jsonb := '{}'::jsonb;
  k   text;
  v_amount bigint;
  v_offer uuid;
  ven jsonb;
BEGIN
  st := public._exos_settlement_ensure(p_org, p_event);
  IF st.status = 'finalized' THEN
    RAISE EXCEPTION 'the settlement is finalized; reopen it to change it' USING ERRCODE = '55000';
  END IF;
  IF p_revision IS NOT NULL AND p_revision <> st.revision THEN
    RAISE EXCEPTION 'the settlement changed since you loaded it; reload and try again' USING ERRCODE = '55000';
  END IF;
  IF b ? 'adjustments' THEN
    IF jsonb_typeof(b -> 'adjustments') <> 'array' THEN
      RAISE EXCEPTION 'adjustments must be a list' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(b -> 'adjustments') > 50 THEN
      RAISE EXCEPTION 'at most 50 adjustments' USING ERRCODE = '54000';
    END IF;
    FOR a IN SELECT * FROM jsonb_array_elements(b -> 'adjustments') LOOP
      IF jsonb_typeof(a) <> 'object' THEN
        RAISE EXCEPTION 'each adjustment must be an object' USING ERRCODE = '22023';
      END IF;
      IF coalesce(a ->> 'amount_cents', '') !~ '^-?[0-9]{1,12}$' THEN
        RAISE EXCEPTION 'adjustments.amount_cents must be a whole number of cents (negative to deduct)' USING ERRCODE = '22023';
      END IF;
      v_amount := (a ->> 'amount_cents')::bigint;
      IF char_length(btrim(coalesce(a ->> 'label', ''))) NOT BETWEEN 1 AND 120 THEN
        RAISE EXCEPTION 'adjustments.label must be 1-120 characters' USING ERRCODE = '22023';
      END IF;
      IF char_length(btrim(coalesce(a ->> 'reason', ''))) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'every adjustment needs a reason (at most 500 characters)' USING ERRCODE = '22023';
      END IF;
      v_offer := public._exos_uuid(a ->> 'offer_id', 'adjustments.offer_id');
      IF v_offer IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_offers WHERE id = v_offer AND org_id = p_org) THEN
        RAISE EXCEPTION 'adjustments.offer_id is not one of this organization''s offers' USING ERRCODE = '22023';
      END IF;
      v_adj := v_adj || jsonb_build_array(jsonb_build_object(
        'id', coalesce(public._exos_uuid(a ->> 'id', 'adjustments.id'), gen_random_uuid()),
        'offer_id', v_offer, 'label', btrim(a ->> 'label'), 'amount_cents', v_amount,
        'reason', btrim(a ->> 'reason'),
        'by', coalesce(a -> 'by', to_jsonb(p_actor)), 'at', coalesce(a -> 'at', to_jsonb(now()))));
    END LOOP;
    st.adjustments := v_adj;
  END IF;
  IF b ? 'deposits_paid' THEN
    IF jsonb_typeof(b -> 'deposits_paid') <> 'object' THEN
      RAISE EXCEPTION 'deposits_paid must be an object of offer id → true / false' USING ERRCODE = '22023';
    END IF;
    FOR k IN SELECT jsonb_object_keys(b -> 'deposits_paid') LOOP
      v_offer := public._exos_uuid(k, 'deposits_paid');
      IF NOT EXISTS (SELECT 1 FROM public.exos_offers WHERE id = v_offer AND org_id = p_org) THEN
        RAISE EXCEPTION 'deposits_paid names an offer that isn''t this organization''s' USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(b -> 'deposits_paid' -> k) <> 'boolean' THEN
        RAISE EXCEPTION 'deposits_paid values must be true or false' USING ERRCODE = '22023';
      END IF;
      IF (b -> 'deposits_paid' ->> k)::boolean THEN v_dep := v_dep || jsonb_build_object(k, true); END IF;
    END LOOP;
    st.deposits_paid := v_dep;
  END IF;
  IF b ? 'venue' THEN
    ven := b -> 'venue';
    IF jsonb_typeof(ven) <> 'object' THEN
      RAISE EXCEPTION 'venue must be an object' USING ERRCODE = '22023';
    END IF;
    IF ven ? 'share_percent' THEN st.venue_share_percent := public._exos_fin_pct(ven, 'share_percent', 'venue.share_percent'); END IF;
    IF ven ? 'deposit_paid_cents' THEN
      st.venue_deposit_paid_cents := public._exos_fin_cents(ven, 'deposit_paid_cents', 'venue.deposit_paid_cents', true);
    END IF;
  END IF;
  UPDATE public.exos_settlements SET
    adjustments = st.adjustments, deposits_paid = st.deposits_paid, venue_share_percent = st.venue_share_percent,
    venue_deposit_paid_cents = st.venue_deposit_paid_cents, revision = revision + 1,
    history = (history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'edited', 'by', p_actor)))
  WHERE event_id = p_event
  RETURNING * INTO st;
  RETURN public._exos_settlement_view(st);
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_update(uuid, uuid, uuid, jsonb, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_settlement_update(uuid, uuid, uuid, jsonb, integer) TO service_role;

-- Freeze the inputs, mint the contacts' link, mail every settlement contact
-- of the show, emit settlement.finalized. Returns the view plus link_path.
CREATE OR REPLACE FUNCTION public._exos_settlement_finalize(p_org uuid, p_actor uuid, p_event uuid,
                                                            p_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  st      public.exos_settlements%ROWTYPE;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_to    text[] := '{}';
  r       record;
  v_pay   jsonb;
BEGIN
  st := public._exos_settlement_ensure(p_org, p_event);
  IF st.status = 'finalized' THEN
    RAISE EXCEPTION 'the settlement is already finalized' USING ERRCODE = '55000';
  END IF;
  IF p_revision IS NOT NULL AND p_revision <> st.revision THEN
    RAISE EXCEPTION 'the settlement changed since you loaded it; reload and try again' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_settlements SET
    status = 'finalized', snapshot = public._exos_settlement_inputs(p_event), finalized_at = now(), finalized_by = p_actor,
    link_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), revision = revision + 1,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'finalized', 'by', p_actor))
  WHERE event_id = p_event
  RETURNING * INTO st;
  v_pay := jsonb_build_object(
    'org', (SELECT jsonb_build_object('id', g.id, 'name', g.name) FROM public.exos_orgs g WHERE g.id = p_org),
    'event', (SELECT jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'timezone', e.timezone)
                FROM public.exos_events e WHERE e.id = p_event),
    'token', v_token);
  FOR r IN SELECT DISTINCT lower(c.email) AS email FROM public.exos_event_contacts c
            WHERE c.event_id = p_event AND c.role = 'settlement' AND c.email IS NOT NULL LOOP
    PERFORM public.exos_mail_enqueue('settlement-finalized', r.email, v_pay,
                                     'settlement:' || p_event || ':' || st.revision || ':' || r.email, NULL, false, p_actor);
    v_to := v_to || r.email;
  END LOOP;
  UPDATE public.exos_settlements SET emailed_to = v_to WHERE event_id = p_event RETURNING * INTO st;
  PERFORM public.exos_enqueue_webhook(p_org, 'settlement.finalized',
                                      jsonb_build_object('event_id', p_event, 'finalized_at', st.finalized_at));
  RETURN public._exos_settlement_view(st) || jsonb_build_object('link_path', '/settlement/' || p_event || '?t=' || v_token);
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_finalize(uuid, uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_settlement_finalize(uuid, uuid, uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_settlement_reopen(p_org uuid, p_actor uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE st public.exos_settlements%ROWTYPE;
BEGIN
  st := public._exos_settlement_ensure(p_org, p_event);
  IF st.status <> 'finalized' THEN
    RAISE EXCEPTION 'the settlement isn''t finalized' USING ERRCODE = '55000';
  END IF;
  UPDATE public.exos_settlements SET
    status = 'draft', snapshot = NULL, link_token_hash = NULL, revision = revision + 1,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'action', 'reopened', 'by', p_actor))
  WHERE event_id = p_event
  RETURNING * INTO st;
  RETURN public._exos_settlement_view(st);
END $$;
REVOKE ALL ON FUNCTION public._exos_settlement_reopen(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_settlement_reopen(uuid, uuid, uuid) TO service_role;

-- P&L inputs for the org's shows starting in [p_from, p_to] (at most 366
-- days, 100 shows): each show's settlement inputs (the snapshot when
-- finalized). Read-only: nothing is seeded.
CREATE OR REPLACE FUNCTION public._exos_pnl_inputs(p_org uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366 THEN
    RAISE EXCEPTION 'from and to must be dates at most 366 days apart' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('from', p_from, 'to', p_to, 'shows', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'event_id', x.id, 'finalized', s.status = 'finalized',
             'inputs', CASE WHEN s.status = 'finalized' THEN s.snapshot ELSE public._exos_settlement_inputs(x.id) END)
             ORDER BY x.starts_at, x.id)
      FROM (SELECT e.id, e.starts_at FROM public.exos_events e
             WHERE e.org_id = p_org AND e.starts_at >= p_from::timestamptz AND e.starts_at < (p_to + 1)::timestamptz
             ORDER BY e.starts_at, e.id LIMIT 100) x
      LEFT JOIN public.exos_settlements s ON s.event_id = x.id), '[]'::jsonb),
    'truncated', (SELECT count(*) > 100 FROM public.exos_events e
                   WHERE e.org_id = p_org AND e.starts_at >= p_from::timestamptz AND e.starts_at < (p_to + 1)::timestamptz));
END $$;
REVOKE ALL ON FUNCTION public._exos_pnl_inputs(uuid, date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_pnl_inputs(uuid, date, date) TO service_role;

-- ---- Signed-in wrappers ------------------------------------------------------
-- An unknown show and another org's show get the same 42501.
CREATE OR REPLACE FUNCTION public._exos_event_org_for(p_event uuid, p_roles text[])
RETURNS uuid LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, p_roles)) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_org_for(uuid, text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_settlement_get(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_settlement_get(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']), p_event_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_settlement_update(p_event_id uuid, p_patch jsonb, p_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_settlement_update(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']),
                                        auth.uid(), p_event_id, p_patch, p_revision);
END $$;

CREATE OR REPLACE FUNCTION public.exos_settlement_finalize(p_event_id uuid, p_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_settlement_finalize(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']),
                                          auth.uid(), p_event_id, p_revision);
END $$;

CREATE OR REPLACE FUNCTION public.exos_settlement_reopen(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_settlement_reopen(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager']),
                                        auth.uid(), p_event_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_pnl_inputs(p_org_id uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'finance']);
  RETURN public._exos_pnl_inputs(p_org_id, p_from, p_to);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_settlement_get(uuid)', 'exos_settlement_update(uuid, jsonb, integer)',
                           'exos_settlement_finalize(uuid, integer)', 'exos_settlement_reopen(uuid)',
                           'exos_pnl_inputs(uuid, date, date)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon;', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated;', f);
  END LOOP;
END $$;

-- ---- The settlement contacts' link (anon; 64-hex token) ----------------------
-- The frozen inputs without item notes; the page leaves out the promoter net.
CREATE OR REPLACE FUNCTION public.exos_settlement_public(p_event_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE st public.exos_settlements%ROWTYPE;
BEGIN
  IF p_event_id IS NULL OR p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'settlement not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO st FROM public.exos_settlements
   WHERE event_id = p_event_id AND status = 'finalized'
     AND link_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  IF st.event_id IS NULL THEN
    RAISE EXCEPTION 'settlement not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'org', (SELECT jsonb_build_object('name', g.name) FROM public.exos_orgs g WHERE g.id = st.org_id),
    'finalized_at', st.finalized_at,
    'inputs', jsonb_set(st.snapshot, '{items}', coalesce((
      SELECT jsonb_agg(x - 'notes' - 'id' - 'category_id') FROM jsonb_array_elements(st.snapshot -> 'items') x), '[]'::jsonb))
      - 'budget');
END $$;
REVOKE ALL ON FUNCTION public.exos_settlement_public(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_settlement_public(uuid, text) TO anon, authenticated;

-- ===========================================================================
-- 6. Ticket-count emails
-- ===========================================================================

-- The next send after p_after: daily at p_time, or weekly on p_weekday at
-- p_time, in p_tz (UTC when unknown).
CREATE OR REPLACE FUNCTION public._exos_tc_next_run(p_frequency text, p_time time, p_weekday int, p_tz text,
                                                    p_after timestamptz)
RETURNS timestamptz LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tz text := CASE WHEN EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_tz) THEN p_tz ELSE 'UTC' END;
  v_local timestamp := p_after AT TIME ZONE v_tz;
  v_day date := v_local::date;
  v_try timestamptz;
  i int;
BEGIN
  FOR i IN 0..8 LOOP
    IF p_frequency = 'daily' OR extract(dow FROM v_day + i)::int = p_weekday THEN
      v_try := ((v_day + i) + p_time) AT TIME ZONE v_tz;
      IF v_try > p_after THEN RETURN v_try; END IF;
    END IF;
  END LOOP;
  RETURN p_after + interval '1 day';
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_next_run(text, time, int, text, timestamptz) FROM PUBLIC, anon, authenticated;

-- The counts a ticket-count mail carries (no buyer data).
CREATE OR REPLACE FUNCTION public._exos_tc_counts(p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE e public.exos_events%ROWTYPE; bo jsonb; ext jsonb; v_cap bigint; v_cur text; v_paid bigint; v_ext_sold bigint;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event;
  IF e.id IS NULL THEN RETURN NULL; END IF;
  bo := public._exos_box_office(p_event);
  ext := public._exos_sold_elsewhere(p_event);
  v_cur := upper(coalesce(e.currency, 'USD'));
  v_cap := CASE WHEN e.total_tickets > 0 THEN e.total_tickets
                ELSE (SELECT coalesce(sum(t.capacity), 0) FROM public.exos_ticket_tiers t WHERE t.event_id = e.id) END;
  v_paid := (bo ->> 'paid_sold')::bigint;
  SELECT coalesce(sum((x ->> 'sold')::bigint), 0) INTO v_ext_sold
    FROM jsonb_array_elements(ext -> 'lines') x WHERE x ->> 'currency' = v_cur;
  RETURN jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'timezone', e.timezone),
    'currency', v_cur,
    'tiers', bo -> 'tiers', 'paid_sold', v_paid, 'comps', bo -> 'comps', 'sold_last_24h', bo -> 'sold_last_24h',
    'gross_cents', bo -> 'gross_cents', 'capacity', v_cap,
    'sold_elsewhere', ext -> 'lines',
    'attendance_percent', CASE WHEN v_cap > 0
      THEN round(100.0 * (v_paid + v_ext_sold + (bo ->> 'comps')::bigint) / v_cap, 1) END);
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_counts(uuid) FROM PUBLIC, anon, authenticated;

-- Queue one run's mails (one per active recipient, deduped per run).
CREATE OR REPLACE FUNCTION public._exos_tc_send(p_event uuid, p_run text)
RETURNS integer LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_counts jsonb := public._exos_tc_counts(p_event); v_org jsonb; n int := 0;
BEGIN
  SELECT jsonb_build_object('id', g.id, 'name', g.name) INTO v_org
    FROM public.exos_events e JOIN public.exos_orgs g ON g.id = e.org_id WHERE e.id = p_event;
  FOR r IN SELECT * FROM public.exos_ticket_count_recipients
            WHERE event_id = p_event AND opted_out_at IS NULL ORDER BY created_at LOOP
    IF public.exos_mail_enqueue('ticket-counts', r.email,
         jsonb_build_object('org', v_org, 'counts', v_counts, 'recipient_name', r.name, 'optout_token', r.optout_token),
         'tc:' || p_event || ':' || r.id || ':' || p_run, NULL, false, NULL) IS NOT NULL THEN
      n := n + 1;
    END IF;
  END LOOP;
  UPDATE public.exos_ticket_count_schedules SET last_sent_at = now(), last_sent_count = n WHERE event_id = p_event;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_send(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_tc_get(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_ticket_count_schedules%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO s FROM public.exos_ticket_count_schedules WHERE event_id = p_event;
  RETURN jsonb_build_object(
    'event_id', p_event, 'enabled', coalesce(s.enabled, false), 'frequency', coalesce(s.frequency, 'daily'),
    'send_time', to_char(coalesce(s.send_time, '10:00'::time), 'HH24:MI'), 'weekday', coalesce(s.weekday, 1),
    'timezone', s.timezone, 'next_run_at', s.next_run_at, 'last_sent_at', s.last_sent_at,
    'last_sent_count', coalesce(s.last_sent_count, 0),
    'recipients', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'email', r.email, 'role', r.role,
                                                                'source', r.source, 'opted_out_at', r.opted_out_at)
                                             ORDER BY r.created_at)
                              FROM public.exos_ticket_count_recipients r WHERE r.event_id = p_event), '[]'::jsonb),
    'suggested', coalesce((SELECT jsonb_agg(jsonb_build_object('name', c.name, 'email', lower(c.email), 'role', c.role)
                                            ORDER BY c.created_at)
                             FROM public.exos_event_contacts c
                            WHERE c.event_id = p_event AND c.role = 'agent' AND c.email IS NOT NULL), '[]'::jsonb),
    'preview', public._exos_tc_counts(p_event));
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_get(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tc_get(uuid, uuid) TO service_role;

-- Save the schedule: enabled, frequency, send_time 'HH:MM', weekday 0-6,
-- recipients [{ name, email, role }] (the full list; an address already on
-- it keeps its opt-out). Without a recipients key on a new schedule, the
-- show's agent contacts are added.
CREATE OR REPLACE FUNCTION public._exos_tc_save(p_org uuid, p_event uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  b jsonb := CASE WHEN jsonb_typeof(p) = 'object' THEN p ELSE '{}'::jsonb END;
  e public.exos_events%ROWTYPE;
  s public.exos_ticket_count_schedules%ROWTYPE;
  r jsonb;
  v_emails text[] := '{}';
  v_email text;
  v_new boolean := false;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO public.exos_ticket_count_schedules (event_id, org_id, timezone)
  VALUES (e.id, p_org, coalesce(nullif(e.timezone, ''), 'UTC'))
  ON CONFLICT (event_id) DO NOTHING;
  v_new := FOUND;
  SELECT * INTO s FROM public.exos_ticket_count_schedules WHERE event_id = e.id FOR UPDATE;
  IF b ? 'enabled' THEN
    IF jsonb_typeof(b -> 'enabled') <> 'boolean' THEN
      RAISE EXCEPTION 'enabled must be true or false' USING ERRCODE = '22023';
    END IF;
    s.enabled := (b ->> 'enabled')::boolean;
  END IF;
  IF b ? 'frequency' THEN
    IF coalesce(b ->> 'frequency', '') NOT IN ('daily', 'weekly') THEN
      RAISE EXCEPTION 'frequency must be daily or weekly' USING ERRCODE = '22023';
    END IF;
    s.frequency := b ->> 'frequency';
  END IF;
  IF b ? 'send_time' THEN s.send_time := coalesce(public._exos_hm(b ->> 'send_time', 'send_time'), '10:00'); END IF;
  IF b ? 'weekday' THEN
    IF coalesce(b ->> 'weekday', '') !~ '^[0-6]$' THEN
      RAISE EXCEPTION 'weekday must be 0 (Sunday) to 6' USING ERRCODE = '22023';
    END IF;
    s.weekday := (b ->> 'weekday')::int;
  END IF;
  s.timezone := coalesce(nullif(e.timezone, ''), 'UTC');

  IF b ? 'recipients' THEN
    IF jsonb_typeof(b -> 'recipients') <> 'array' THEN
      RAISE EXCEPTION 'recipients must be a list' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(b -> 'recipients') > 25 THEN
      RAISE EXCEPTION 'at most 25 recipients' USING ERRCODE = '54000';
    END IF;
    FOR r IN SELECT * FROM jsonb_array_elements(b -> 'recipients') LOOP
      IF jsonb_typeof(r) <> 'object' THEN
        RAISE EXCEPTION 'each recipient must be an object' USING ERRCODE = '22023';
      END IF;
      v_email := public._exos_fin_email(r ->> 'email', 'recipients.email');
      IF v_email IS NULL THEN
        RAISE EXCEPTION 'every recipient needs an email' USING ERRCODE = '22023';
      END IF;
      IF coalesce(r ->> 'role', 'other') NOT IN ('agent', 'promoter', 'settlement', 'other') THEN
        RAISE EXCEPTION 'recipients.role must be agent, promoter, settlement or other' USING ERRCODE = '22023';
      END IF;
      v_emails := v_emails || v_email;
      INSERT INTO public.exos_ticket_count_recipients (org_id, event_id, name, email, role, source)
      VALUES (p_org, e.id, left(nullif(btrim(coalesce(r ->> 'name', '')), ''), 100), v_email,
              coalesce(r ->> 'role', 'other'), 'manual')
      ON CONFLICT (event_id, email) DO UPDATE SET name = EXCLUDED.name, role = EXCLUDED.role;
    END LOOP;
    DELETE FROM public.exos_ticket_count_recipients WHERE event_id = e.id AND NOT (email = ANY (v_emails));
  ELSIF v_new THEN
    INSERT INTO public.exos_ticket_count_recipients (org_id, event_id, name, email, role, source)
    SELECT DISTINCT ON (lower(c.email)) p_org, e.id, c.name, lower(c.email), 'agent', 'contact'
      FROM public.exos_event_contacts c
     WHERE c.event_id = e.id AND c.role = 'agent' AND c.email IS NOT NULL
     ORDER BY lower(c.email), c.created_at
     LIMIT 25
    ON CONFLICT (event_id, email) DO NOTHING;
  END IF;

  UPDATE public.exos_ticket_count_schedules SET
    enabled = s.enabled, frequency = s.frequency, send_time = s.send_time, weekday = s.weekday, timezone = s.timezone,
    next_run_at = CASE WHEN s.enabled THEN public._exos_tc_next_run(s.frequency, s.send_time, s.weekday, s.timezone, now()) END
  WHERE event_id = e.id;
  RETURN public._exos_tc_get(p_org, e.id);
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_save(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tc_save(uuid, uuid, jsonb) TO service_role;

-- Send now (at most once per 10 minutes).
CREATE OR REPLACE FUNCTION public._exos_tc_send_now(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE s public.exos_ticket_count_schedules%ROWTYPE; n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO s FROM public.exos_ticket_count_schedules WHERE event_id = p_event FOR UPDATE;
  IF s.event_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_ticket_count_recipients
                                        WHERE event_id = p_event AND opted_out_at IS NULL) THEN
    RAISE EXCEPTION 'add a recipient first' USING ERRCODE = '55000';
  END IF;
  IF s.last_manual_at IS NOT NULL AND s.last_manual_at > now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'ticket counts were sent less than 10 minutes ago' USING ERRCODE = '54000';
  END IF;
  UPDATE public.exos_ticket_count_schedules SET last_manual_at = now() WHERE event_id = p_event;
  n := public._exos_tc_send(p_event, 'manual:' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS'));
  RETURN jsonb_build_object('queued', n);
END $$;
REVOKE ALL ON FUNCTION public._exos_tc_send_now(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_tc_send_now(uuid, uuid) TO service_role;

-- The cron's tick: due schedules, 25 at a time, claimed with SKIP LOCKED and
-- moved to their next run before anything is queued.
CREATE OR REPLACE FUNCTION public.exos_ticket_counts_run(p_limit integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE s record; v_sent int := 0; v_off int := 0; v_runs int := 0;
BEGIN
  FOR s IN SELECT c.*, e.status AS event_status, e.starts_at, e.ends_at
             FROM public.exos_ticket_count_schedules c JOIN public.exos_events e ON e.id = c.event_id
            WHERE c.enabled AND c.next_run_at <= now()
            ORDER BY c.next_run_at
            LIMIT greatest(1, least(coalesce(p_limit, 25), 100))
              FOR UPDATE OF c SKIP LOCKED LOOP
    IF s.event_status = 'cancelled' OR coalesce(s.ends_at, s.starts_at) < now() - interval '1 day' THEN
      UPDATE public.exos_ticket_count_schedules SET enabled = false, next_run_at = NULL WHERE event_id = s.event_id;
      v_off := v_off + 1;
      CONTINUE;
    END IF;
    UPDATE public.exos_ticket_count_schedules
       SET next_run_at = public._exos_tc_next_run(s.frequency, s.send_time, s.weekday, s.timezone, now())
     WHERE event_id = s.event_id;
    v_sent := v_sent + public._exos_tc_send(s.event_id, 'run:' || to_char(s.next_run_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'));
    v_runs := v_runs + 1;
  END LOOP;
  RETURN jsonb_build_object('runs', v_runs, 'queued', v_sent, 'switched_off', v_off);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_counts_run(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ticket_counts_run(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_ticket_counts_get(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_tc_get(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']), p_event_id);
END $$;

CREATE OR REPLACE FUNCTION public.exos_ticket_counts_save(p_event_id uuid, p_schedule jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_tc_save(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager']), p_event_id, p_schedule);
END $$;

CREATE OR REPLACE FUNCTION public.exos_ticket_counts_send_now(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_tc_send_now(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager']), p_event_id);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_ticket_counts_get(uuid)', 'exos_ticket_counts_save(uuid, jsonb)',
                           'exos_ticket_counts_send_now(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon;', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated;', f);
  END LOOP;
END $$;

-- The recipient's opt-out link (anon; 64-hex token). p_confirm false only
-- describes it (the GET page); true opts out. Unknown tokens: P0002.
CREATE OR REPLACE FUNCTION public.exos_ticket_counts_optout(p_token text, p_confirm boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_ticket_count_recipients%ROWTYPE;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'link not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO r FROM public.exos_ticket_count_recipients WHERE optout_token = p_token;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'link not found' USING ERRCODE = 'P0002';
  END IF;
  IF coalesce(p_confirm, false) AND r.opted_out_at IS NULL THEN
    UPDATE public.exos_ticket_count_recipients SET opted_out_at = now() WHERE id = r.id RETURNING * INTO r;
  END IF;
  RETURN jsonb_build_object(
    'event', (SELECT jsonb_build_object('name', e.name, 'starts_at', e.starts_at) FROM public.exos_events e WHERE e.id = r.event_id),
    'org', (SELECT jsonb_build_object('name', g.name) FROM public.exos_orgs g WHERE g.id = r.org_id),
    'email', regexp_replace(r.email, '^(.).*(@.*)$', '\1…\2'),
    'opted_out', r.opted_out_at IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_counts_optout(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_ticket_counts_optout(text, boolean) TO anon, authenticated;

-- ===========================================================================
-- 7. Mail templates and the cron (inactive)
-- ===========================================================================
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['settlement-finalized', 'ticket-counts'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF v_def IS NULL THEN RETURN; END IF;
  IF strpos(v_def, '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live FROM regexp_matches(v_def, '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN RETURN; END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION SELECT unnest(v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- Every 15 minutes, created INACTIVE: the operator turns it on with
--   SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-ticket-counts-15min'), active := true);
-- once the mail drain is live. A re-run leaves an existing job (and its
-- active flag) alone.
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1' INTO v_job USING 'exos-ticket-counts-15min';
  IF v_job IS NULL THEN
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job
      USING 'exos-ticket-counts-15min', '*/15 * * * *', 'SELECT public.exos_ticket_counts_run(25);';
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_job;
  END IF;
END $$;

COMMENT ON TABLE public.exos_settlements IS
  'mig 20261031100500: one per show (docs/offers-settlements.md). Written only by exos_settlement_* / _exos_settlement_*; snapshot = the inputs frozen at finalize; link_token_hash has no client column grant.';
COMMENT ON TABLE public.exos_finance_items IS
  'mig 20261031100500: income and expense lines per show, in the org''s finance categories. auto = venue-rental: from the hold''s rental terms, created once.';
COMMENT ON TABLE public.exos_ticket_count_schedules IS
  'mig 20261031100500: scheduled ticket-count emails per show; exos_ticket_counts_run (cron, created inactive) sends them through exos_mail.';
