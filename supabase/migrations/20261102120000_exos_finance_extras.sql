-- ============================================================================
-- Migration 20261102120000 — Exos: tiered deal brackets, revenue-type ledger
-- codes with per-event overrides and backfills, imported ledger entries, the
-- reporting-row feed and the per-event cash summary.
-- docs/offers-settlements.md ("Tiered deals", "Ledger codes and reporting").
--
-- Touches:  C: TABLE exos_deal_brackets, exos_gl_revenue_codes,
--              exos_gl_code_assignments, exos_imported_ledger_entries,
--              exos_reporting_rows
--           C: FUNCTION _exos_bracket_amount, _exos_offer_brackets_json,
--              _exos_gl_resolve, _exos_gl_backfill, _exos_ledger_import,
--              _exos_cash_summary, _exos_settlement_extras (service_role:
--              exos-api passes the key's org), exos_gl_backfill /
--              exos_ledger_import / exos_cash_summary (signed-in staff),
--              trigger functions
--           W: FUNCTION _exos_settlement_inputs (patched in place: the
--              offers' brackets and the show's imported entries join the
--              inputs, so the settlement, its snapshot and the P&L see them)
--           R: exos_offers, exos_events, exos_gl_codes, exos_checkout_sessions,
--              exos_order_payments, exos_order_refunds, exos_order_fees,
--              exos_order_money, exos_tickets, exos_pos_orders,
--              exos_pos_payments, exos_paypal_order_owed
-- Pre-reqs: 20261031100000 (offers, GL codes), 20261031100500 (settlement
--           inputs), 20261031220000 (processor / payment_method),
--           20261030130000 (gift_card_cents / donation_cents)
--
--   * Brackets (Opendate's v3 deal brackets) change an offer's percentage
--     from a threshold upward, on one basis per offer: `amount` (the base
--     the percentage applies to, cents) or `tickets` (paid tickets sold).
--     Below the lowest threshold the offer's own percentage applies.
--     Thresholds are unique per offer, so in order they are strictly
--     increasing and never overlap. The pure maths is
--     supabase/functions/_shared/finance/dealBrackets.ts;
--     _exos_bracket_amount is its SQL twin (same exact integer rounding,
--     checked against the same fixtures). Brackets change only on a draft
--     offer (they are deal terms) and are frozen into a finalized
--     settlement's snapshot with everything else.
--   * Ledger codes: exos_gl_revenue_codes maps each revenue type (tickets,
--     fees, tax, donations, refunds, platform fees, POS, payouts and the
--     imported sources) to one of the org's GL codes; exos_gl_code_assignments
--     overrides that for one event. _exos_gl_backfill rebuilds the event's
--     reporting rows from its orders, refunds, POS sales and payouts and
--     re-tags every row (imported ones included) with the code in force:
--     idempotent (a second run changes nothing) and serialized per event.
--   * Imported ledger entries: accounting lines from outside Exos (an old box
--     office, a bar POS), at most 500 per call, deduped on
--     (source_system, source_line_id): the same line again is `exists`, a
--     different one under that id is an error naming the stored entry.
--     Amounts are signed integer cents. Each entry becomes a reporting row
--     at once (flagged imported), and entries on a show count in its
--     settlement and P&L as income (positive) or expense (negative), under
--     "Imported · <source>" lines that never merge with Exos lines.
--   * Cash summary: one show's money (gross, fees, tax, refunds, net), split
--     by payment method (card, Cash App, PayPal, Venmo, gift card, cash and
--     card at the POS, comps), with payouts. Read-only.
--
-- Who: owners, managers and finance read all of it; owners and managers
-- write brackets (as offers); owners, managers and finance write ledger
-- codes, overrides, imports and run backfills. Scanners and content staff
-- see nothing. Reporting rows have no client write path; imported entries
-- are created only through the import function and deleted by staff.
--
-- Errors: 22023 bad input, P0002 not found, 55000 wrong state, 54000 limit,
-- 42501 not allowed.
--
-- Additive only; re-run safe. Prod apply needs operator OK.
-- ROLLBACK: DROP the functions and tables above, then re-run
-- 20261031100500's _exos_settlement_inputs.
-- ============================================================================

-- ===========================================================================
-- 1. Deal brackets
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_deal_brackets (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  offer_id   uuid NOT NULL,
  basis      text NOT NULL DEFAULT 'amount' CHECK (basis IN ('amount', 'tickets')),
  -- Cents (amount) or paid tickets (tickets) from which `percentage` applies.
  threshold  bigint NOT NULL CHECK (threshold BETWEEN 0 AND 100000000000),
  percentage numeric(6, 3) NOT NULL CHECK (percentage BETWEEN 0 AND 100),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (offer_id, org_id) REFERENCES public.exos_offers (id, org_id) ON DELETE CASCADE,
  UNIQUE (offer_id, threshold)
);
CREATE INDEX IF NOT EXISTS exos_deal_brackets_org_idx ON public.exos_deal_brackets (org_id, created_at DESC);

-- A bracket takes its org from the offer, which must be a draft; every
-- bracket of an offer has one basis; 20 per offer. The offer row is locked,
-- so two writers on one offer serialize (no mixed bases, no 21st bracket).
CREATE OR REPLACE FUNCTION public._exos_tg_deal_bracket()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE o record; v_offer uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.offer_id ELSE NEW.offer_id END;
BEGIN
  SELECT id, org_id INTO o FROM public.exos_offers WHERE id = v_offer;
  IF o.id IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;   -- the offer is going (cascade)
    RAISE EXCEPTION 'offer not found' USING ERRCODE = 'P0002';
  END IF;
  -- A signed-in writer must be staff of the offer's org before anything
  -- about the offer is read or locked (the policy is checked after this).
  IF auth.uid() IS NOT NULL AND NOT (public.exos_is_admin() OR public.exos_has_org_role(o.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT id, org_id, status INTO o FROM public.exos_offers WHERE id = v_offer FOR UPDATE;
  IF o.status <> 'draft' THEN
    RAISE EXCEPTION 'brackets change only on a draft offer (edit its terms to take a sent offer back to draft)' USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' AND (NEW.offer_id IS DISTINCT FROM OLD.offer_id OR NEW.org_id IS DISTINCT FROM OLD.org_id) THEN
    RAISE EXCEPTION 'a bracket can''t move to another offer' USING ERRCODE = '22023';
  END IF;
  NEW.org_id := o.org_id;
  IF NEW.basis = 'tickets' AND NEW.threshold > 10000000 THEN
    RAISE EXCEPTION 'a ticket threshold is at most 10000000' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_deal_brackets b
              WHERE b.offer_id = NEW.offer_id AND b.id <> NEW.id AND b.basis <> NEW.basis) THEN
    RAISE EXCEPTION 'every bracket of an offer has the same basis' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_deal_brackets b
              WHERE b.offer_id = NEW.offer_id AND b.id <> NEW.id AND b.threshold = NEW.threshold) THEN
    RAISE EXCEPTION 'two brackets start at %: thresholds must be strictly increasing', NEW.threshold USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    IF (SELECT count(*) FROM public.exos_deal_brackets WHERE offer_id = NEW.offer_id) >= 20 THEN
      RAISE EXCEPTION 'at most 20 brackets per offer' USING ERRCODE = '54000';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_deal_bracket() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_deal_brackets_guard ON public.exos_deal_brackets;
CREATE TRIGGER exos_deal_brackets_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_deal_brackets
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_deal_bracket();

-- An offer's brackets as the maths reads them: { basis, tiers: [{ threshold,
-- percentage }] } in threshold order, or NULL.
CREATE OR REPLACE FUNCTION public._exos_offer_brackets_json(p_offer uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN count(*) = 0 THEN NULL ELSE jsonb_build_object(
           'basis', min(b.basis),
           'tiers', jsonb_agg(jsonb_build_object('threshold', b.threshold, 'percentage', b.percentage) ORDER BY b.threshold)) END
    FROM public.exos_deal_brackets b WHERE b.offer_id = p_offer;
$$;
REVOKE ALL ON FUNCTION public._exos_offer_brackets_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_offer_brackets_json(uuid) TO service_role;

-- The tiered amount of p_base (cents) with p_sold paid tickets: the SQL twin
-- of tieredAmount() in _shared/finance/dealBrackets.ts. Each tier is
-- half-up(n / d) with n, d exact: amount basis n = units × pct‰, d = 100000;
-- tickets basis n = base × tickets × pct‰, d = sold × 100000.
CREATE OR REPLACE FUNCTION public._exos_bracket_amount(p_base bigint, p_sold bigint, p_default_pct numeric, p_brackets jsonb)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  x numeric := greatest(coalesce(p_base, 0), 0);
  n numeric := greatest(coalesce(p_sold, 0), 0);
  v_basis text := coalesce(p_brackets ->> 'basis', 'amount');
  froms numeric[] := '{}';
  pcts numeric[] := '{}';
  t record;
  i int;
  v_to numeric;
  units numeric;
  pm numeric;
  num numeric;
  den numeric;
  total numeric := 0;
BEGIN
  FOR t IN SELECT floor((e ->> 'threshold')::numeric) AS th, (e ->> 'percentage')::numeric AS pct
             FROM jsonb_array_elements(coalesce(p_brackets -> 'tiers', '[]'::jsonb)) e
            WHERE (e ->> 'threshold')::numeric >= 0
            ORDER BY 1 LOOP
    IF array_length(froms, 1) IS NULL AND t.th > 0 THEN
      froms := froms || 0::numeric; pcts := pcts || coalesce(p_default_pct, 0);
    END IF;
    IF array_length(froms, 1) IS NOT NULL AND froms[array_length(froms, 1)] = t.th THEN
      pcts[array_length(pcts, 1)] := t.pct;
    ELSE
      froms := froms || t.th; pcts := pcts || t.pct;
    END IF;
  END LOOP;
  IF array_length(froms, 1) IS NULL THEN
    froms := ARRAY[0::numeric]; pcts := ARRAY[coalesce(p_default_pct, 0)];
  END IF;
  FOR i IN 1 .. array_length(froms, 1) LOOP
    v_to := CASE WHEN i < array_length(froms, 1) THEN froms[i + 1] END;
    pm := round(least(100, greatest(0, pcts[i])) * 1000);
    IF v_basis = 'tickets' THEN
      IF n = 0 THEN
        IF i = 1 THEN num := x * pm; den := 100000; ELSE CONTINUE; END IF;
      ELSE
        units := greatest(0, least(n, coalesce(v_to, n)) - froms[i]);
        num := x * units * pm; den := n * 100000;
      END IF;
    ELSE
      units := greatest(0, least(x, coalesce(v_to, x)) - froms[i]);
      num := units * pm; den := 100000;
    END IF;
    total := total + div(2 * num + den, 2 * den);
  END LOOP;
  RETURN total::bigint;
END $$;
REVOKE ALL ON FUNCTION public._exos_bracket_amount(bigint, bigint, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_bracket_amount(bigint, bigint, numeric, jsonb) TO service_role;

-- ===========================================================================
-- 2. Ledger codes per revenue type, per-event overrides
-- ===========================================================================
-- The revenue types a reporting row posts as. The imported sources are
-- revenue types too, so an org codes "bar" once for both.
CREATE OR REPLACE FUNCTION public.exos_gl_revenue_types()
RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT ARRAY['tickets', 'fees', 'tax', 'donations', 'refunds', 'platform_fees', 'pos', 'payouts',
               'box_office', 'bar', 'merchandise', 'membership', 'delivery', 'ticket_insurance', 'gift_cards', 'other'];
$$;
REVOKE ALL ON FUNCTION public.exos_gl_revenue_types() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_gl_revenue_types() TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.exos_gl_revenue_codes (
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  revenue_type text NOT NULL CHECK (revenue_type = ANY (public.exos_gl_revenue_types())),
  gl_code_id   uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, revenue_type),
  FOREIGN KEY (gl_code_id, org_id) REFERENCES public.exos_gl_codes (id, org_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.exos_gl_code_assignments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  revenue_type text NOT NULL CHECK (revenue_type = ANY (public.exos_gl_revenue_types())),
  gl_code_id   uuid NOT NULL,
  created_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, revenue_type),
  FOREIGN KEY (gl_code_id, org_id) REFERENCES public.exos_gl_codes (id, org_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS exos_gl_code_assignments_org_idx ON public.exos_gl_code_assignments (org_id);

-- Codes are the org's own and not discarded; an override takes its org from
-- the event and can't move to another event.
CREATE OR REPLACE FUNCTION public._exos_tg_gl_mapping()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF TG_TABLE_NAME = 'exos_gl_code_assignments' THEN
    SELECT org_id INTO v_org FROM public.exos_events WHERE id = NEW.event_id;
    IF v_org IS NULL THEN
      RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.event_id IS DISTINCT FROM OLD.event_id OR v_org IS DISTINCT FROM OLD.org_id
                              OR NEW.revenue_type IS DISTINCT FROM OLD.revenue_type) THEN
      RAISE EXCEPTION 'an override can only be repointed to another code' USING ERRCODE = '22023';
    END IF;
    NEW.org_id := v_org;
    IF TG_OP = 'INSERT' THEN NEW.created_by := coalesce(auth.uid(), NEW.created_by); END IF;
  ELSIF TG_OP = 'UPDATE' AND (NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.revenue_type IS DISTINCT FROM OLD.revenue_type) THEN
    RAISE EXCEPTION 'a revenue code can only be repointed' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_gl_codes g
                  WHERE g.id = NEW.gl_code_id AND g.org_id = NEW.org_id AND g.discarded_at IS NULL) THEN
    RAISE EXCEPTION 'gl_code_id is not one of this organization''s ledger codes' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_gl_mapping() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_gl_revenue_codes_guard ON public.exos_gl_revenue_codes;
CREATE TRIGGER exos_gl_revenue_codes_guard BEFORE INSERT OR UPDATE ON public.exos_gl_revenue_codes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_gl_mapping();
DROP TRIGGER IF EXISTS exos_gl_code_assignments_guard ON public.exos_gl_code_assignments;
CREATE TRIGGER exos_gl_code_assignments_guard BEFORE INSERT OR UPDATE ON public.exos_gl_code_assignments
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_gl_mapping();

-- The code in force for a revenue type on an event: the event's override,
-- else the org's code for the type; discarded codes don't count.
CREATE OR REPLACE FUNCTION public._exos_gl_resolve(p_org uuid, p_event uuid, p_revenue_type text)
RETURNS TABLE (gl_code_id uuid, gl_code text) LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT g.id, g.code FROM (
    SELECT a.gl_code_id, 1 AS rank FROM public.exos_gl_code_assignments a
     WHERE p_event IS NOT NULL AND a.event_id = p_event AND a.revenue_type = p_revenue_type
    UNION ALL
    SELECT r.gl_code_id, 2 FROM public.exos_gl_revenue_codes r
     WHERE r.org_id = p_org AND r.revenue_type = p_revenue_type) c
  JOIN public.exos_gl_codes g ON g.id = c.gl_code_id AND g.org_id = p_org AND g.discarded_at IS NULL
  ORDER BY c.rank LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public._exos_gl_resolve(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 3. Imported ledger entries and reporting rows
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_imported_ledger_entries (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id         uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  source           text NOT NULL CHECK (source IN ('box_office', 'bar', 'merchandise', 'donations', 'membership', 'delivery',
                                                   'ticket_insurance', 'gift_cards', 'other')),
  description      text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300),
  -- Signed: income positive, a cost or a gift-card spend negative.
  amount_cents     bigint NOT NULL CHECK (amount_cents BETWEEN -100000000000 AND 100000000000),
  tax_amount_cents bigint NOT NULL DEFAULT 0 CHECK (tax_amount_cents BETWEEN -100000000000 AND 100000000000),
  currency         text NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  gl_code          text CHECK (gl_code IS NULL OR gl_code ~ '^[A-Za-z0-9][A-Za-z0-9.-]{0,23}$'),
  tax_gl_code      text CHECK (tax_gl_code IS NULL OR tax_gl_code ~ '^[A-Za-z0-9][A-Za-z0-9.-]{0,23}$'),
  tax_name         text CHECK (tax_name IS NULL OR char_length(tax_name) <= 60),
  posted_at        timestamptz NOT NULL,
  source_system    text NOT NULL CHECK (source_system ~ '^[a-z0-9][a-z0-9_.-]{0,39}$'),
  source_line_id   text NOT NULL CHECK (char_length(source_line_id) BETWEEN 1 AND 200),
  source_order_id  text CHECK (source_order_id IS NULL OR char_length(source_order_id) <= 200),
  import_run_id    text CHECK (import_run_id IS NULL OR char_length(import_run_id) <= 100),
  created_via      text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api')),
  api_key_id       uuid,
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, source_system, source_line_id)
);
CREATE INDEX IF NOT EXISTS exos_imported_ledger_entries_org_idx ON public.exos_imported_ledger_entries (org_id, posted_at);
CREATE INDEX IF NOT EXISTS exos_imported_ledger_entries_event_idx ON public.exos_imported_ledger_entries (event_id) WHERE event_id IS NOT NULL;

-- One row per money line, carrying the ledger code it posts to. Exos lines
-- are (re)built per event by _exos_gl_backfill; imported lines are written
-- when the entry is imported and go when it is deleted.
CREATE TABLE IF NOT EXISTS public.exos_reporting_rows (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id       uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  source_type    text NOT NULL CHECK (source_type IN ('order', 'refund', 'pos', 'payout', 'imported')),
  source_id      text NOT NULL CHECK (char_length(source_id) BETWEEN 1 AND 200),
  revenue_type   text NOT NULL CHECK (revenue_type = ANY (public.exos_gl_revenue_types())),
  occurred_at    timestamptz NOT NULL,
  currency       text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount_cents   bigint NOT NULL,
  payment_method text CHECK (payment_method IS NULL OR char_length(payment_method) <= 20),
  description    text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300),
  gl_code_id     uuid REFERENCES public.exos_gl_codes (id) ON DELETE SET NULL,
  gl_code        text,
  imported       boolean GENERATED ALWAYS AS (source_type = 'imported') STORED,
  tagged_at      timestamptz NOT NULL DEFAULT now(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_type, source_id, revenue_type)
);
CREATE INDEX IF NOT EXISTS exos_reporting_rows_org_idx ON public.exos_reporting_rows (org_id, occurred_at, id);
CREATE INDEX IF NOT EXISTS exos_reporting_rows_event_idx ON public.exos_reporting_rows (event_id) WHERE event_id IS NOT NULL;

-- An imported entry's lines: the amount under its source, the tax under
-- 'tax'. Its own code wins (matched to the org's chart when it is there),
-- else the code in force for the type.
CREATE OR REPLACE FUNCTION public._exos_tg_imported_entry()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_id uuid; v_code text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.exos_reporting_rows WHERE source_type = 'imported' AND source_id = OLD.id::text;
    RETURN OLD;
  END IF;
  FOR r IN SELECT * FROM (VALUES (NEW.source, NEW.amount_cents, NEW.gl_code),
                                 ('tax', NEW.tax_amount_cents, NEW.tax_gl_code)) v(rt, amt, code)
            WHERE v.amt <> 0 OR v.rt = NEW.source LOOP
    v_id := NULL; v_code := r.code;
    IF r.code IS NOT NULL THEN
      SELECT g.id INTO v_id FROM public.exos_gl_codes g
       WHERE g.org_id = NEW.org_id AND lower(g.code) = lower(r.code) AND g.discarded_at IS NULL;
    ELSE
      SELECT x.gl_code_id, x.gl_code INTO v_id, v_code FROM public._exos_gl_resolve(NEW.org_id, NEW.event_id, r.rt) x;
    END IF;
    INSERT INTO public.exos_reporting_rows (org_id, event_id, source_type, source_id, revenue_type, occurred_at, currency,
                                            amount_cents, description, gl_code_id, gl_code)
    VALUES (NEW.org_id, NEW.event_id, 'imported', NEW.id::text, r.rt, NEW.posted_at, NEW.currency, r.amt,
            left(NEW.source_system || ': ' || NEW.description, 300), v_id, v_code)
    ON CONFLICT (source_type, source_id, revenue_type) DO NOTHING;
  END LOOP;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_imported_entry() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_imported_ledger_entries_rows ON public.exos_imported_ledger_entries;
CREATE TRIGGER exos_imported_ledger_entries_rows AFTER INSERT OR DELETE ON public.exos_imported_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_imported_entry();
-- Entries are records of what happened elsewhere: no edits (delete and import again).
CREATE OR REPLACE FUNCTION public._exos_tg_imported_entry_frozen()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'an imported entry can''t be changed: delete it and import it again' USING ERRCODE = '55000';
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_imported_entry_frozen() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_imported_ledger_entries_frozen ON public.exos_imported_ledger_entries;
CREATE TRIGGER exos_imported_ledger_entries_frozen BEFORE UPDATE ON public.exos_imported_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_imported_entry_frozen();

-- ===========================================================================
-- 4. updated_at, RLS, grants
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_deal_brackets', 'exos_gl_revenue_codes', 'exos_gl_code_assignments',
                           'exos_imported_ledger_entries', 'exos_reporting_rows'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_sel', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_sel', t);
  END LOOP;
  -- Brackets are deal terms: owners and managers, as offers.
  GRANT INSERT, DELETE ON public.exos_deal_brackets TO authenticated;
  GRANT UPDATE (basis, threshold, percentage) ON public.exos_deal_brackets TO authenticated;
  DROP POLICY IF EXISTS exos_deal_brackets_write ON public.exos_deal_brackets;
  CREATE POLICY exos_deal_brackets_write ON public.exos_deal_brackets FOR ALL TO authenticated
    USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']))
    WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager']));
  -- Ledger codes are finance's too (as exos_gl_codes).
  FOREACH t IN ARRAY ARRAY['exos_gl_revenue_codes', 'exos_gl_code_assignments'] LOOP
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON public.%I TO authenticated;', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I;', t || '_write', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))
                      WITH CHECK (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']));',
                   t || '_write', t);
  END LOOP;
  -- Imported entries: created by the import function only; staff delete.
  GRANT DELETE ON public.exos_imported_ledger_entries TO authenticated;
  DROP POLICY IF EXISTS exos_imported_ledger_entries_del ON public.exos_imported_ledger_entries;
  CREATE POLICY exos_imported_ledger_entries_del ON public.exos_imported_ledger_entries FOR DELETE TO authenticated
    USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
END $$;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_deal_brackets', 'exos_gl_revenue_codes', 'exos_gl_code_assignments',
                               'exos_imported_ledger_entries', 'exos_reporting_rows'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 5. Imports (cores: service_role; exos-api passes the key's org)
-- ===========================================================================

-- A jsonb value as signed whole cents.
CREATE OR REPLACE FUNCTION public._exos_fin_signed_cents(v jsonb, p_field text)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE t text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN RETURN NULL; END IF;
  t := CASE jsonb_typeof(v) WHEN 'number' THEN v::text WHEN 'string' THEN btrim(v #>> '{}') END;
  IF t IS NULL OR t !~ '^-?[0-9]{1,12}$' THEN
    RAISE EXCEPTION '% must be a whole number of cents', p_field USING ERRCODE = '22023';
  END IF;
  RETURN t::bigint;
END $$;
REVOKE ALL ON FUNCTION public._exos_fin_signed_cents(jsonb, text) FROM PUBLIC, anon, authenticated;

-- Import up to 500 entries; each row is applied on its own and reported:
-- created, exists (same line, same values: nothing written) or error.
CREATE OR REPLACE FUNCTION public._exos_ledger_import(p_org uuid, p_actor uuid, p_via text, p_api_key uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  r jsonb; i int := 0; v_out jsonb := '[]'::jsonb; e public.exos_imported_ledger_entries%ROWTYPE;
  old public.exos_imported_ledger_entries%ROWTYPE; v_id uuid; v_ev uuid; v_cur text; v_at timestamptz;
  n_created int := 0; n_exists int := 0; n_error int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org) THEN
    RAISE EXCEPTION 'organization not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'entries must be a list of 1 to 500 entries' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) > 500 THEN
    RAISE EXCEPTION 'at most 500 entries per import' USING ERRCODE = '54000';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    BEGIN
      IF jsonb_typeof(r) <> 'object' THEN
        RAISE EXCEPTION 'each entry must be an object' USING ERRCODE = '22023';
      END IF;
      v_ev := NULL;
      IF nullif(r ->> 'event_id', '') IS NOT NULL THEN
        IF (r ->> 'event_id') !~ '^[0-9a-fA-F-]{36}$' THEN
          RAISE EXCEPTION 'event_id must be an id' USING ERRCODE = '22023';
        END IF;
        SELECT id, upper(coalesce(currency, 'USD')) INTO v_ev, v_cur FROM public.exos_events
         WHERE id = (r ->> 'event_id')::uuid AND org_id = p_org;
        IF v_ev IS NULL THEN
          RAISE EXCEPTION 'event_id is not one of this organization''s events' USING ERRCODE = '22023';
        END IF;
      END IF;
      BEGIN
        v_at := (r ->> 'posted_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'posted_at must be a date and time' USING ERRCODE = '22023';
      END;
      IF v_at IS NULL THEN
        RAISE EXCEPTION 'posted_at is required' USING ERRCODE = '22023';
      END IF;
      e := NULL;
      e.org_id := p_org;
      e.event_id := v_ev;
      e.source := lower(btrim(coalesce(r ->> 'source', '')));
      IF e.source NOT IN ('box_office', 'bar', 'merchandise', 'donations', 'membership', 'delivery', 'ticket_insurance', 'gift_cards', 'other') THEN
        RAISE EXCEPTION 'source must be one of box_office, bar, merchandise, donations, membership, delivery, ticket_insurance, gift_cards, other'
          USING ERRCODE = '22023';
      END IF;
      e.description := public._exos_fin_text(r, 'description', 'description', 300);
      e.amount_cents := public._exos_fin_signed_cents(r -> 'amount_cents', 'amount_cents');
      IF e.amount_cents IS NULL THEN
        RAISE EXCEPTION 'amount_cents is required' USING ERRCODE = '22023';
      END IF;
      e.tax_amount_cents := coalesce(public._exos_fin_signed_cents(r -> 'tax_amount_cents', 'tax_amount_cents'), 0);
      e.currency := upper(coalesce(nullif(btrim(r ->> 'currency'), ''), v_cur, 'USD'));
      IF e.currency !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'currency must be a three-letter code' USING ERRCODE = '22023';
      END IF;
      e.gl_code := nullif(public._exos_fin_text(r, 'gl_code', 'gl_code', 24), '');
      e.tax_gl_code := nullif(public._exos_fin_text(r, 'tax_gl_code', 'tax_gl_code', 24), '');
      e.tax_name := nullif(public._exos_fin_text(r, 'tax_name', 'tax_name', 60), '');
      e.posted_at := v_at;
      e.source_system := lower(public._exos_fin_text(r, 'source_system', 'source_system', 40));
      e.source_line_id := public._exos_fin_text(r, 'source_line_id', 'source_line_id', 200);
      IF e.source_system = '' OR e.source_line_id = '' THEN
        RAISE EXCEPTION 'source_system and source_line_id are required (they identify the line)' USING ERRCODE = '22023';
      END IF;
      e.source_order_id := nullif(public._exos_fin_text(r, 'source_order_id', 'source_order_id', 200), '');
      e.import_run_id := nullif(public._exos_fin_text(r, 'import_run_id', 'import_run_id', 100), '');

      v_id := NULL;
      INSERT INTO public.exos_imported_ledger_entries (org_id, event_id, source, description, amount_cents, tax_amount_cents,
             currency, gl_code, tax_gl_code, tax_name, posted_at, source_system, source_line_id, source_order_id, import_run_id,
             created_via, api_key_id, created_by)
      VALUES (p_org, e.event_id, e.source, e.description, e.amount_cents, e.tax_amount_cents, e.currency, e.gl_code,
              e.tax_gl_code, e.tax_name, e.posted_at, e.source_system, e.source_line_id, e.source_order_id, e.import_run_id,
              CASE WHEN p_via = 'api' THEN 'api' ELSE 'dashboard' END, p_api_key, p_actor)
      ON CONFLICT (org_id, source_system, source_line_id) DO NOTHING
      RETURNING id INTO v_id;
      IF v_id IS NOT NULL THEN
        n_created := n_created + 1;
        v_out := v_out || jsonb_build_object('index', i, 'status', 'created', 'id', v_id);
      ELSE
        SELECT * INTO old FROM public.exos_imported_ledger_entries
         WHERE org_id = p_org AND source_system = e.source_system AND source_line_id = e.source_line_id;
        IF (old.event_id, old.source, old.description, old.amount_cents, old.tax_amount_cents, old.currency, old.gl_code,
            old.tax_gl_code, old.tax_name, old.posted_at, old.source_order_id)
           IS NOT DISTINCT FROM
           (e.event_id, e.source, e.description, e.amount_cents, e.tax_amount_cents, e.currency, e.gl_code,
            e.tax_gl_code, e.tax_name, e.posted_at, e.source_order_id) THEN
          n_exists := n_exists + 1;
          v_out := v_out || jsonb_build_object('index', i, 'status', 'exists', 'id', old.id);
        ELSE
          n_error := n_error + 1;
          v_out := v_out || jsonb_build_object('index', i, 'status', 'error', 'id', old.id,
            'error', 'this source_line_id is already imported with other values (entry ' || old.id || '); delete that entry first to change it');
        END IF;
      END IF;
    EXCEPTION WHEN data_exception OR integrity_constraint_violation THEN
      n_error := n_error + 1;
      v_out := v_out || jsonb_build_object('index', i, 'status', 'error', 'error', left(SQLERRM, 300));
    END;
  END LOOP;
  RETURN jsonb_build_object('created', n_created, 'exists', n_exists, 'errors', n_error, 'results', v_out);
END $$;
REVOKE ALL ON FUNCTION public._exos_ledger_import(uuid, uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_ledger_import(uuid, uuid, text, uuid, jsonb) TO service_role;

-- ===========================================================================
-- 6. Backfill: rebuild and re-tag one event's reporting rows
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_gl_backfill(p_org uuid, p_event uuid)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  e public.exos_events%ROWTYPE;
  n_created int := 0; n_retagged int := 0; n_removed int := 0; n_total int;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  -- One backfill per event at a time; a second waits and then finds nothing to do.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_gl_backfill:' || p_event::text, 0));

  IF to_regclass('pg_temp.exos_bf_rows') IS NULL THEN
  CREATE TEMP TABLE exos_bf_rows (
    source_type text, source_id text, revenue_type text, occurred_at timestamptz, currency text,
    amount_cents bigint, payment_method text, description text) ON COMMIT DROP;
  END IF;
  TRUNCATE pg_temp.exos_bf_rows;

  -- Orders: tickets (order value less tax, buyer fees and donations), tax,
  -- buyer fees, donations and the platform fee (negative).
  INSERT INTO pg_temp.exos_bf_rows
  SELECT 'order', s.session_id, x.rt, coalesce(s.fulfilled_at, s.created_at), upper(coalesce(s.currency, e.currency, 'USD')),
         x.amt, CASE WHEN coalesce(s.amount_cents, 0) = 0 AND coalesce(s.gift_card_cents, 0) > 0 THEN 'gift_card'
                     ELSE coalesce(s.payment_method, CASE s.processor WHEN 'paypal' THEN 'paypal' ELSE 'card' END) END,
         left('Order ' || s.session_id, 300)
    FROM public.exos_checkout_sessions s
    CROSS JOIN LATERAL (SELECT coalesce(sum(f.amount_cents), 0)::bigint AS passed_on FROM public.exos_order_fees f
                         WHERE f.session_id = s.session_id AND f.kind = 'passed_on') pf
    CROSS JOIN LATERAL (VALUES
      ('tickets', coalesce(s.amount_cents, 0) + coalesce(s.gift_card_cents, 0) - coalesce(s.tax_cents, 0) - pf.passed_on - coalesce(s.donation_cents, 0)),
      ('tax', coalesce(s.tax_cents, 0)::bigint),
      ('fees', pf.passed_on),
      ('donations', coalesce(s.donation_cents, 0)::bigint),
      ('platform_fees', -coalesce(s.application_fee_cents, 0)::bigint)) x(rt, amt)
   WHERE s.event_id = p_event AND s.org_id = p_org AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')
     AND (x.rt = 'tickets' OR x.amt <> 0);
  -- Refunds that went through (negative).
  INSERT INTO pg_temp.exos_bf_rows
  SELECT 'refund', rf.id::text, 'refunds', rf.created_at, upper(coalesce(rf.currency, s.currency, 'USD')), -rf.amount_cents::bigint,
         coalesce(s.payment_method, CASE s.processor WHEN 'paypal' THEN 'paypal' ELSE 'card' END),
         left('Refund of order ' || s.session_id, 300)
    FROM public.exos_order_refunds rf
    JOIN public.exos_checkout_sessions s ON s.session_id = rf.session_id
   WHERE s.event_id = p_event AND s.org_id = p_org AND rf.status = 'succeeded';
  -- Payouts: what Stripe transferred to the organizer for an order.
  INSERT INTO pg_temp.exos_bf_rows
  SELECT 'payout', m.session_id, 'payouts', coalesce(m.fulfilled_at, m.created_at), upper(coalesce(m.currency, 'USD')),
         m.organizer_net_cents::bigint, 'card', left('Transfer ' || m.transfer_id, 300)
    FROM public.exos_order_money m
   WHERE m.event_id = p_event AND m.org_id = p_org AND m.transfer_id IS NOT NULL
     AND m.status IN ('fulfilled', 'refunded', 'partially_refunded');
  -- POS sales at the show (paid; a refunded one nets to 0 with its refund line).
  INSERT INTO pg_temp.exos_bf_rows
  SELECT 'pos', o.id::text, x.rt, coalesce(o.paid_at, o.created_at), upper(coalesce(o.currency, e.currency, 'USD')), x.amt,
         o.payment_method, 'POS sale'
    FROM public.exos_pos_orders o
    CROSS JOIN LATERAL (VALUES ('pos', (o.total_cents - o.tax_cents)::bigint), ('tax', o.tax_cents::bigint),
                               ('refunds', CASE WHEN o.status = 'refunded' THEN -o.total_cents::bigint ELSE 0 END)) x(rt, amt)
   WHERE o.event_id = p_event AND o.org_id = p_org AND o.status IN ('paid', 'refunded') AND (x.rt = 'pos' OR x.amt <> 0);

  -- Remove Exos rows whose source is gone (a voided POS sale, a failed order).
  WITH gone AS (
    DELETE FROM public.exos_reporting_rows r
     WHERE r.event_id = p_event AND r.source_type <> 'imported'
       AND NOT EXISTS (SELECT 1 FROM pg_temp.exos_bf_rows b
                        WHERE b.source_type = r.source_type AND b.source_id = r.source_id AND b.revenue_type = r.revenue_type)
    RETURNING 1)
  SELECT count(*) INTO n_removed FROM gone;

  -- Insert new rows; re-tag (and re-amount) changed ones; leave the rest.
  WITH want AS (
    SELECT b.*, g.gl_code_id, g.gl_code
      FROM pg_temp.exos_bf_rows b
      LEFT JOIN LATERAL public._exos_gl_resolve(p_org, p_event, b.revenue_type) g ON true
  ), up AS (
    INSERT INTO public.exos_reporting_rows AS r (org_id, event_id, source_type, source_id, revenue_type, occurred_at, currency,
                                                 amount_cents, payment_method, description, gl_code_id, gl_code)
    SELECT p_org, p_event, w.source_type, w.source_id, w.revenue_type, w.occurred_at, w.currency, w.amount_cents,
           w.payment_method, w.description, w.gl_code_id, w.gl_code FROM want w
    ON CONFLICT (source_type, source_id, revenue_type) DO UPDATE
       SET amount_cents = EXCLUDED.amount_cents, occurred_at = EXCLUDED.occurred_at, currency = EXCLUDED.currency,
           payment_method = EXCLUDED.payment_method, description = EXCLUDED.description,
           gl_code_id = EXCLUDED.gl_code_id, gl_code = EXCLUDED.gl_code, tagged_at = now()
     WHERE r.org_id = p_org
       AND (r.amount_cents, r.occurred_at, r.currency, r.payment_method, r.description, r.gl_code_id, r.gl_code)
           IS DISTINCT FROM
           (EXCLUDED.amount_cents, EXCLUDED.occurred_at, EXCLUDED.currency, EXCLUDED.payment_method, EXCLUDED.description,
            EXCLUDED.gl_code_id, EXCLUDED.gl_code)
    RETURNING (xmax = 0) AS inserted)
  SELECT count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted) INTO n_created, n_retagged FROM up;

  -- Imported rows of the event: an entry's own code (linked to the chart
  -- when the org has it), else the code in force for its type.
  WITH want AS (
    SELECT r.id, g.gl_code_id, g.gl_code
      FROM public.exos_reporting_rows r
      JOIN public.exos_imported_ledger_entries ie ON ie.id::text = r.source_id AND ie.org_id = p_org
      CROSS JOIN LATERAL (SELECT CASE WHEN r.revenue_type = 'tax' THEN ie.tax_gl_code ELSE ie.gl_code END AS own) c
      LEFT JOIN LATERAL (
        SELECT x.id AS gl_code_id, c.own AS gl_code FROM public.exos_gl_codes x
         WHERE c.own IS NOT NULL AND x.org_id = p_org AND lower(x.code) = lower(c.own) AND x.discarded_at IS NULL
        UNION ALL
        SELECT NULL, c.own WHERE c.own IS NOT NULL
        UNION ALL
        SELECT y.gl_code_id, y.gl_code FROM public._exos_gl_resolve(p_org, p_event, r.revenue_type) y WHERE c.own IS NULL
        LIMIT 1) g ON true
     WHERE r.event_id = p_event AND r.source_type = 'imported'
  ), imp AS (
    UPDATE public.exos_reporting_rows r SET gl_code_id = w.gl_code_id, gl_code = w.gl_code, tagged_at = now()
      FROM want w
     WHERE r.id = w.id AND (r.gl_code_id, r.gl_code) IS DISTINCT FROM (w.gl_code_id, w.gl_code)
    RETURNING 1)
  SELECT n_retagged + count(*) INTO n_retagged FROM imp;

  SELECT count(*) INTO n_total FROM public.exos_reporting_rows WHERE event_id = p_event;
  RETURN jsonb_build_object('event_id', p_event, 'created', n_created, 'retagged', n_retagged, 'removed', n_removed,
                            'rows', n_total, 'backfilled_at', now());
END $$;
REVOKE ALL ON FUNCTION public._exos_gl_backfill(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_gl_backfill(uuid, uuid) TO service_role;

-- ===========================================================================
-- 7. Cash summary (read-only)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_cash_summary(p_org uuid, p_event uuid, p_from timestamptz DEFAULT NULL,
                                                     p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  e public.exos_events%ROWTYPE;
  v_online jsonb; v_methods jsonb; v_pos jsonb; v_payouts jsonb; v_comps int;
  v_gross bigint; v_tax bigint; v_refunds bigint; v_platform bigint; v_buyer_fees bigint; v_absorbed bigint;
  v_processor bigint; v_orders int; v_pos_gross bigint; v_pos_tax bigint; v_pos_refunds bigint; v_pos_tips bigint;
  v_paypal jsonb := jsonb_build_object('owed_cents', 0, 'held_cents', 0);
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
    RAISE EXCEPTION 'from must be before to' USING ERRCODE = '22023';
  END IF;

  IF to_regclass('pg_temp.exos_cs_orders') IS NULL THEN
  CREATE TEMP TABLE exos_cs_orders (
    session_id text, method text, card_cents bigint, gift_cents bigint, tax bigint, platform bigint, processor bigint,
    refunded bigint, buyer_fees bigint, absorbed bigint, transferred boolean, organizer_net bigint) ON COMMIT DROP;
  END IF;
  TRUNCATE pg_temp.exos_cs_orders;
  INSERT INTO pg_temp.exos_cs_orders
  SELECT s.session_id, coalesce(s.payment_method, CASE s.processor WHEN 'paypal' THEN 'paypal' ELSE 'card' END),
         coalesce(s.amount_cents, 0), coalesce(s.gift_card_cents, 0), coalesce(s.tax_cents, 0), coalesce(s.application_fee_cents, 0),
         coalesce(m.card_fee_actual_cents, 0), coalesce(m.refunded_cents, 0),
         coalesce((SELECT sum(f.amount_cents) FROM public.exos_order_fees f WHERE f.session_id = s.session_id AND f.kind = 'passed_on'), 0),
         coalesce((SELECT sum(f.amount_cents) FROM public.exos_order_fees f WHERE f.session_id = s.session_id AND f.kind = 'absorbed'), 0),
         m.transfer_id IS NOT NULL, coalesce(m.organizer_net_cents, 0)
    FROM public.exos_checkout_sessions s
    LEFT JOIN public.exos_order_money m ON m.session_id = s.session_id
   WHERE s.event_id = p_event AND s.org_id = p_org AND s.status IN ('fulfilled', 'refunded', 'partially_refunded')
     AND (p_from IS NULL OR s.created_at >= p_from) AND (p_to IS NULL OR s.created_at < p_to);

  SELECT count(*), coalesce(sum(card_cents + gift_cents), 0), coalesce(sum(tax), 0), coalesce(sum(refunded), 0),
         coalesce(sum(platform), 0), coalesce(sum(buyer_fees), 0), coalesce(sum(absorbed), 0), coalesce(sum(processor), 0)
    INTO v_orders, v_gross, v_tax, v_refunds, v_platform, v_buyer_fees, v_absorbed, v_processor
    FROM pg_temp.exos_cs_orders;

  -- POS at the show: payments by method (comps are value given, not money).
  SELECT coalesce(sum(p.amount_cents) FILTER (WHERE p.method <> 'comp'), 0),
         coalesce(sum(p.amount_cents) FILTER (WHERE p.method <> 'comp' AND p.status = 'refunded'), 0),
         coalesce(sum(p.tip_cents), 0)
    INTO v_pos_gross, v_pos_refunds, v_pos_tips
    FROM public.exos_pos_payments p
   WHERE p.event_id = p_event AND p.org_id = p_org
     AND (p_from IS NULL OR p.created_at >= p_from) AND (p_to IS NULL OR p.created_at < p_to);
  SELECT coalesce(sum(o.tax_cents), 0) INTO v_pos_tax FROM public.exos_pos_orders o
   WHERE o.event_id = p_event AND o.org_id = p_org AND o.status IN ('paid', 'refunded')
     AND (p_from IS NULL OR o.created_at >= p_from) AND (p_to IS NULL OR o.created_at < p_to);

  -- By payment method: online card / Cash App / PayPal / Venmo, gift cards, POS cash and card, comps.
  WITH m AS (
    SELECT method, count(*) AS orders, sum(card_cents) AS gross, sum(least(refunded, card_cents)) AS refunds
      FROM pg_temp.exos_cs_orders WHERE card_cents > 0 GROUP BY method
    UNION ALL
    SELECT 'gift_card', count(*), sum(gift_cents), 0 FROM pg_temp.exos_cs_orders WHERE gift_cents > 0
    UNION ALL
    SELECT CASE p.method WHEN 'cash' THEN 'cash' WHEN 'card' THEN 'pos_card' ELSE 'comp' END,
           count(DISTINCT p.order_id), sum(p.amount_cents), sum(p.amount_cents) FILTER (WHERE p.status = 'refunded')
      FROM public.exos_pos_payments p
     WHERE p.event_id = p_event AND p.org_id = p_org
       AND (p_from IS NULL OR p.created_at >= p_from) AND (p_to IS NULL OR p.created_at < p_to)
     GROUP BY 1
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('method', method, 'orders', orders, 'gross_cents', gross,
                                               'refunds_cents', coalesce(refunds, 0), 'net_cents', gross - coalesce(refunds, 0))
                            ORDER BY array_position(ARRAY['card', 'cashapp', 'paypal', 'venmo', 'gift_card', 'cash', 'pos_card', 'comp'], method)),
                  '[]'::jsonb)
    INTO v_methods FROM (SELECT method, sum(orders) AS orders, sum(gross) AS gross, sum(refunds) AS refunds FROM m GROUP BY method) x;

  SELECT count(*) INTO v_comps FROM public.exos_tickets t
   WHERE t.event_id = p_event AND t.status IN ('active', 'used') AND coalesce(t.price_paid, 0) = 0
     AND (p_from IS NULL OR t.created_at >= p_from) AND (p_to IS NULL OR t.created_at < p_to);

  IF to_regclass('public.exos_paypal_order_owed') IS NOT NULL THEN
    EXECUTE 'SELECT jsonb_build_object(''owed_cents'', coalesce(sum(owed_cents), 0), ''held_cents'', coalesce(sum(held_cents), 0))
               FROM public.exos_paypal_order_owed WHERE event_id = $1 AND org_id = $2' INTO v_paypal USING p_event, p_org;
  END IF;
  SELECT jsonb_build_object(
           'stripe_transferred_cents', coalesce(sum(organizer_net) FILTER (WHERE transferred AND method IN ('card', 'cashapp')), 0),
           'stripe_pending_cents', coalesce(sum(organizer_net) FILTER (WHERE NOT transferred AND method IN ('card', 'cashapp')), 0),
           'paypal_owed_cents', (v_paypal ->> 'owed_cents')::bigint,
           'paypal_held_cents', (v_paypal ->> 'held_cents')::bigint)
    INTO v_payouts FROM pg_temp.exos_cs_orders;

  RETURN jsonb_build_object(
    'event_id', e.id, 'currency', upper(coalesce(e.currency, 'USD')), 'from', p_from, 'to', p_to,
    'orders', v_orders,
    'gross_cents', v_gross + v_pos_gross,
    'fees', jsonb_build_object('buyer_fees_cents', v_buyer_fees, 'absorbed_fees_cents', v_absorbed,
                               'platform_fees_cents', v_platform, 'processor_fees_cents', v_processor),
    'fees_cents', v_platform,
    'tax_cents', v_tax + v_pos_tax,
    'refunds_cents', v_refunds + v_pos_refunds,
    'net_cents', v_gross + v_pos_gross - v_tax - v_pos_tax - v_refunds - v_pos_refunds - v_platform,
    'online', jsonb_build_object('gross_cents', v_gross, 'tax_cents', v_tax, 'refunds_cents', v_refunds),
    'pos', jsonb_build_object('gross_cents', v_pos_gross, 'tax_cents', v_pos_tax, 'refunds_cents', v_pos_refunds, 'tips_cents', v_pos_tips),
    'by_payment_method', v_methods,
    'comps', jsonb_build_object('tickets', v_comps,
                                'pos_cents', coalesce((SELECT (x ->> 'gross_cents')::bigint FROM jsonb_array_elements(v_methods) x
                                                        WHERE x ->> 'method' = 'comp'), 0)),
    'payouts', v_payouts,
    'computed_at', now());
END $$;
REVOKE ALL ON FUNCTION public._exos_cash_summary(uuid, uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_cash_summary(uuid, uuid, timestamptz, timestamptz) TO service_role;

-- ===========================================================================
-- 8. Settlement inputs: brackets and imported entries
-- ===========================================================================
-- { deal_brackets: { offer_id: { basis, tiers } }, imported_entries: [...] }
-- for a show: the brackets of its offers (on the show, its hold, or the
-- forecast budget) and its imported entries in the show's currency.
CREATE OR REPLACE FUNCTION public._exos_settlement_extras(p_event uuid, p_budget uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'deal_brackets', coalesce((
      SELECT jsonb_object_agg(o.id, public._exos_offer_brackets_json(o.id))
        FROM public.exos_offers o
       WHERE o.org_id = e.org_id
         AND (o.event_id = e.id OR (o.event_id IS NULL AND e.hold_id IS NOT NULL AND o.hold_id = e.hold_id)
              OR (p_budget IS NOT NULL AND o.budget_id = p_budget))
         AND EXISTS (SELECT 1 FROM public.exos_deal_brackets b WHERE b.offer_id = o.id)), '{}'::jsonb),
    'imported_entries', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', i.id, 'source', i.source, 'description', i.description,
                                          'amount_cents', i.amount_cents, 'tax_amount_cents', i.tax_amount_cents,
                                          'gl_code', i.gl_code, 'posted_at', i.posted_at, 'source_system', i.source_system)
                       ORDER BY i.posted_at, i.id)
        FROM public.exos_imported_ledger_entries i
       WHERE i.event_id = e.id AND i.org_id = e.org_id AND i.currency = upper(coalesce(e.currency, 'USD'))), '[]'::jsonb))
    FROM public.exos_events e WHERE e.id = p_event;
$$;
REVOKE ALL ON FUNCTION public._exos_settlement_extras(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

SELECT pg_temp.exos_patch_n('public._exos_settlement_inputs(uuid)',
  '_exos_settlement_extras',
  $o$  RETURN jsonb_build_object($o$,
  $n$  RETURN public._exos_settlement_extras(e.id, v_budget) || jsonb_build_object($n$, 1);

-- ===========================================================================
-- 9. Signed-in wrappers (the dashboard)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_gl_backfill(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_gl_backfill(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']), p_event_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_gl_backfill(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_gl_backfill(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_ledger_import(p_org_id uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public._exos_fin_staff(p_org_id, ARRAY['owner', 'manager', 'finance']);
  RETURN public._exos_ledger_import(p_org_id, auth.uid(), 'dashboard', NULL, p_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_ledger_import(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_ledger_import(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_cash_summary(p_event_id uuid, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_cash_summary(public._exos_event_org_for(p_event_id, ARRAY['owner', 'manager', 'finance']),
                                   p_event_id, p_from, p_to);
END $$;
REVOKE ALL ON FUNCTION public.exos_cash_summary(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_cash_summary(uuid, timestamptz, timestamptz) TO authenticated;
