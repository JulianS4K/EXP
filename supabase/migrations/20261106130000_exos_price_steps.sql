-- ============================================================================
-- Migration 20261106130000 — Exos: price steps (DICE PriceTier)
--
-- Branch:   claude/exos-capacity-pricing (KANBAN "DICE gaps" #4)
-- Touches:  exos_price_steps (new), exos_ticket_tiers (+door_price_cents),
--           exos_cart_holds / exos_checkout_sessions / exos_tickets
--           (+price_step_id; holds +unit_price_cents), exos_public_tiers
--           (view: price = the current step's price), exos_public_price_steps
--           (new view), new exos_tier_current_price /
--           exos_tier_price_now / exos_hold_lock_price / exos_set_price_steps
--           / exos_tier_price_steps + API cores; redefines exos_rr_tier_price
--           (body only); marker patches (pg_temp.exos_patch_n) on
--           _exos_api_public_tiers_json, _exos_api_event_json,
--           _exos_discovery_event_json, _exos_listing_feed_event,
--           exos_voucher_tier.
-- Pre-reqs: 20260703122000 (price_schedule), 20260702123000 (cart holds),
--           20261027100000 (fee rules), 20261106120000 (shared capacity).
--
-- One ticket type moves through prices on its own: "Early bird $20 for the
-- first 100 or until Dec 1, then $25, then $30", plus an optional door price.
--
-- ONE PRICING PATH (option (b) of the coordinator's note). The old
-- exos_ticket_tiers.price_schedule ([{startsAt, price}], mig 20260703122000:
-- base price, then overrides from a time on) is migrated into
-- exos_price_steps, and the current price is computed in ONE function,
-- exos_tier_current_price(tier, at, channel). Every price the buyer can see
-- comes from it:
--   * exos_public_tiers.price (the storefront, the Google and catalog feeds,
--     MCP, the hosted pages) is the current step's price;
--   * the public API's tiers JSON, the partner API's event JSON, public
--     discovery, the listing feed and voucher-unlocked tiers, by patches;
--   * partner sales and referral rewards, through exos_rr_tier_price (now a
--     wrapper);
--   * exos-checkout asks it for the price it charges and locks it on the hold.
-- The all-in price (fees + exclusive tax on top of that face price) is still
-- computed by allInCents (_shared/pricing.ts, mirrored in SQL by
-- exos_all_in_unit_cents); only its input changed. The readers' own
-- effectiveTierPrice(price, price_schedule) still runs, and is a no-op on
-- these rows: price is already the current price, and price_schedule is the
-- steps' time-only form (or [] for steps a schedule can't express).
--
-- price_schedule stays, kept in sync both ways so existing API clients and
-- the old editor don't break:
--   * a write of price / price_schedule (dashboard, API ticket type, event
--     template) rebuilds the type's TIME-ONLY steps from it, in place;
--   * steps written through exos_set_price_steps write price (the first
--     step's) and price_schedule (the time-only form, else []) back.
--   A type whose steps end on a count can't be expressed as a schedule: a
--   price_schedule write to it is refused (edit its steps instead); a price
--   write sets the first step's price.
--
-- RULES (also docs/price-steps.md):
--   * A step ends when its count is reached (tickets sold at it + live holds
--     on it) or at its time, whichever comes first. The last step has no end.
--   * Once a step's count has SOLD (not just held), it stays ended
--     (sold_out_at): a refund after that frees the ticket at the current
--     price, it doesn't bring the lower one back. Before that, a refund or an
--     expired hold frees the step's place again.
--   * Boundary rule: CAP. An order is priced at one step. If it asks for more
--     than the step has left, checkout refuses it with how many are left at
--     this price (409, reason price_step_remaining); the buyer takes those
--     and buys the rest at the next price. (pretix and DICE also cap; it
--     keeps one unit price per order, which fulfilment, refunds and the
--     price disclosure rely on.)
--   * The price seen is the price paid: exos-checkout reads the current step,
--     prices the order with it, creates the hold, then exos_hold_lock_price
--     re-checks the step under a lock on the type's steps and stamps it on
--     the hold (the hold now counts against the step). If the step moved in
--     between, the hold is released and the buyer is told the new price
--     (409, reason price_changed). The Stripe amount is fixed at that point;
--     the webhook mints at it even if the step advanced meanwhile.
--   * Comps (price 0) and door sales at the door price don't use a step's
--     places. The door channel ('door' / 'pos' / 'box_office') sells at
--     door_price_cents when it is set, else at the current step.
--
-- Additive, replay-safe. D4 authors; not applied.
-- ============================================================================

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

-- ===========================================================================
-- 1. Tables and columns.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_price_steps (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id         uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id          uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  sort_order       integer NOT NULL DEFAULT 0,
  name             text NOT NULL DEFAULT '' CHECK (length(name) <= 80),
  price_cents      integer NOT NULL CHECK (price_cents >= 0 AND price_cents <= 100000000),
  -- End conditions (either, both or, for the last step, neither).
  ends_after_count integer CHECK (ends_after_count IS NULL OR ends_after_count > 0),
  ends_at          timestamptz,
  -- Latched when ends_after_count tickets have SOLD at this step.
  sold_out_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_price_steps_tier_idx ON public.exos_price_steps (tier_id, sort_order, id);
CREATE INDEX IF NOT EXISTS exos_price_steps_event_idx ON public.exos_price_steps (event_id);

DROP TRIGGER IF EXISTS exos_price_steps_touch ON public.exos_price_steps;
CREATE TRIGGER exos_price_steps_touch BEFORE UPDATE ON public.exos_price_steps
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- A step's org and event come from its ticket type.
CREATE OR REPLACE FUNCTION public.exos_tg_price_step_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  SELECT t.event_id, e.org_id INTO NEW.event_id, NEW.org_id
    FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.id = NEW.tier_id;
  IF NEW.event_id IS NULL THEN
    RAISE EXCEPTION 'price step: ticket type not found' USING ERRCODE = '23503';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.tier_id IS DISTINCT FROM OLD.tier_id THEN
    RAISE EXCEPTION 'price step: a step can''t move to another ticket type' USING ERRCODE = '42501';
  END IF;
  NEW.name := left(btrim(coalesce(NEW.name, '')), 80);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_price_step_scope() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_price_steps_scope ON public.exos_price_steps;
CREATE TRIGGER exos_price_steps_scope BEFORE INSERT OR UPDATE ON public.exos_price_steps
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_price_step_scope();

ALTER TABLE public.exos_ticket_tiers
  ADD COLUMN IF NOT EXISTS door_price_cents integer
  CONSTRAINT exos_ticket_tiers_door_price_ck CHECK (door_price_cents IS NULL OR door_price_cents >= 0);
ALTER TABLE public.exos_cart_holds
  ADD COLUMN IF NOT EXISTS price_step_id uuid REFERENCES public.exos_price_steps (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS unit_price_cents integer;
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS price_step_id uuid REFERENCES public.exos_price_steps (id) ON DELETE SET NULL;
ALTER TABLE public.exos_tickets
  ADD COLUMN IF NOT EXISTS price_step_id uuid REFERENCES public.exos_price_steps (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_tickets_price_step_idx ON public.exos_tickets (price_step_id) WHERE price_step_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_cart_holds_price_step_idx ON public.exos_cart_holds (price_step_id)
  WHERE price_step_id IS NOT NULL AND status = 'active';

-- Buyers may see the door price ("$35 at the door"; exos_public_price_steps).

-- RLS: organizer config. Staff read; writes only through exos_set_price_steps
-- (validated, keeps price_schedule in sync) or the API cores.
ALTER TABLE public.exos_price_steps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_price_steps_sel ON public.exos_price_steps;
CREATE POLICY exos_price_steps_sel ON public.exos_price_steps FOR SELECT TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','content']));
REVOKE ALL ON public.exos_price_steps FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_price_steps TO authenticated;
GRANT ALL ON public.exos_price_steps TO service_role;

-- ===========================================================================
-- 2. The current price: exos_tier_current_price (the one computation).
-- ===========================================================================

-- Places a step has used: tickets sold at it + live holds on it.
CREATE OR REPLACE FUNCTION public._exos_price_step_used(p_step_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (SELECT count(*)::int FROM public.exos_tickets t
           WHERE t.price_step_id = p_step_id AND t.status IN ('active', 'used', 'transferred'))
       + (SELECT coalesce(sum(h.quantity * public.exos_tier_party_size(h.tier_id)), 0)::int
            FROM public.exos_cart_holds h
           WHERE h.price_step_id = p_step_id AND h.status = 'active' AND h.expires_at > now());
$$;
REVOKE ALL ON FUNCTION public._exos_price_step_used(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_price_step_used(uuid) TO service_role;

-- The price a ticket type sells at, at a time, on a channel. Mirrored by
-- currentPriceStep (supabase/functions/_shared/priceSteps.ts); the parity
-- cases in tests/exos/fixtures/price_steps_cases.json run against both.
--   { price_cents, source: 'base' | 'step' | 'door', step_id, step_name,
--     step_index (1-based), step_count, step_remaining (null: no count end),
--     step_ends_at, next_price_cents, next_step_name, door_price_cents }
-- Service role and definer functions only: buyers read it through
-- exos_public_tier_price (public, published types).
CREATE OR REPLACE FUNCTION public.exos_tier_current_price(p_tier_id uuid, p_at timestamptz DEFAULT now(), p_channel text DEFAULT 'online')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t        record;
  s        record;
  v_at     timestamptz := coalesce(p_at, now());
  v_door   boolean := lower(coalesce(p_channel, 'online')) IN ('door', 'pos', 'box_office');
  v_n      int;
  v_i      int := 0;
  v_cur    record;
  v_cur_i  int;
  v_used   int;
  v_rem    int;
  v_ended  boolean;
  v_next   record;
BEGIN
  SELECT tt.id, tt.price, tt.door_price_cents INTO t FROM public.exos_ticket_tiers tt WHERE tt.id = p_tier_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_door AND t.door_price_cents IS NOT NULL THEN
    RETURN jsonb_build_object('price_cents', t.door_price_cents, 'source', 'door', 'step_id', NULL, 'step_name', NULL,
      'step_index', NULL, 'step_count', NULL, 'step_remaining', NULL, 'step_ends_at', NULL,
      'next_price_cents', NULL, 'next_step_name', NULL, 'door_price_cents', t.door_price_cents);
  END IF;

  SELECT count(*) INTO v_n FROM public.exos_price_steps WHERE tier_id = p_tier_id;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('price_cents', greatest(round(coalesce(t.price, 0) * 100), 0)::int, 'source', 'base',
      'step_id', NULL, 'step_name', NULL, 'step_index', NULL, 'step_count', 0, 'step_remaining', NULL,
      'step_ends_at', NULL, 'next_price_cents', NULL, 'next_step_name', NULL, 'door_price_cents', t.door_price_cents);
  END IF;

  -- The first step that hasn't ended; the last one if they all have.
  FOR s IN SELECT * FROM public.exos_price_steps WHERE tier_id = p_tier_id ORDER BY sort_order, id LOOP
    v_i := v_i + 1;
    v_used := CASE WHEN s.ends_after_count IS NULL THEN 0 ELSE public._exos_price_step_used(s.id) END;
    v_ended := (s.ends_at IS NOT NULL AND v_at >= s.ends_at)
            OR (s.sold_out_at IS NOT NULL AND s.sold_out_at <= v_at)
            OR (s.ends_after_count IS NOT NULL AND v_used >= s.ends_after_count);
    v_cur := s; v_cur_i := v_i;
    v_rem := CASE WHEN s.ends_after_count IS NULL THEN NULL ELSE greatest(s.ends_after_count - v_used, 0) END;
    EXIT WHEN NOT v_ended;
  END LOOP;

  SELECT * INTO v_next FROM public.exos_price_steps
   WHERE tier_id = p_tier_id AND (sort_order, id) > (v_cur.sort_order, v_cur.id)
   ORDER BY sort_order, id LIMIT 1;

  RETURN jsonb_build_object('price_cents', v_cur.price_cents, 'source', 'step', 'step_id', v_cur.id,
    'step_name', nullif(v_cur.name, ''), 'step_index', v_cur_i, 'step_count', v_n, 'step_remaining', v_rem,
    'step_ends_at', v_cur.ends_at,
    'next_price_cents', v_next.price_cents, 'next_step_name', nullif(v_next.name, ''),
    'door_price_cents', t.door_price_cents);
END $$;
REVOKE ALL ON FUNCTION public.exos_tier_current_price(uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_tier_current_price(uuid, timestamptz, text) TO service_role;

-- The face price now, in major units: what the readers put in `price`.
CREATE OR REPLACE FUNCTION public.exos_tier_price_now(p_tier_id uuid, p_channel text DEFAULT 'online')
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT trim_scale(((public.exos_tier_current_price(p_tier_id, now(), p_channel) ->> 'price_cents')::numeric) / 100);
$$;
REVOKE ALL ON FUNCTION public.exos_tier_price_now(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_tier_price_now(uuid, text) TO service_role;

-- The buyer's read (anon): the current price of a public type of a published
-- event, else NULL (a hidden type's price stays behind its code). Used by
-- the exos_public_tiers view.
CREATE OR REPLACE FUNCTION public.exos_public_tier_price(p_tier_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                            WHERE t.id = p_tier_id AND t.visibility = 'public' AND e.status = 'published')
              THEN public.exos_tier_current_price(p_tier_id, now(), 'online') END;
$$;
REVOKE ALL ON FUNCTION public.exos_public_tier_price(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_public_tier_price(uuid) TO anon, authenticated, service_role;

-- ===========================================================================
-- 3. price_schedule <-> steps (option (b): steps are the truth, the schedule
--    stays readable and writable for the old clients).
-- ===========================================================================

-- Steps -> the tier's price + price_schedule (time-only form, else []).
CREATE OR REPLACE FUNCTION public._exos_price_steps_to_tier(p_tier_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_first int; v_counts boolean; v_sched jsonb;
BEGIN
  SELECT price_cents INTO v_first FROM public.exos_price_steps WHERE tier_id = p_tier_id ORDER BY sort_order, id LIMIT 1;
  IF v_first IS NULL THEN
    RETURN;
  END IF;
  SELECT bool_or(ends_after_count IS NOT NULL) INTO v_counts FROM public.exos_price_steps WHERE tier_id = p_tier_id;
  IF v_counts THEN
    v_sched := '[]'::jsonb;
  ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'startsAt', to_char(prev_end AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
             'price', trim_scale(price_cents::numeric / 100)) ORDER BY rn), '[]'::jsonb)
      INTO v_sched
      FROM (SELECT price_cents, row_number() OVER w AS rn, lag(ends_at) OVER w AS prev_end
              FROM public.exos_price_steps WHERE tier_id = p_tier_id
            WINDOW w AS (ORDER BY sort_order, id)) x
     WHERE rn > 1 AND prev_end IS NOT NULL;
  END IF;
  PERFORM set_config('exos.price_steps_sync', '1', true);
  UPDATE public.exos_ticket_tiers
     SET price = trim_scale(v_first::numeric / 100), price_schedule = v_sched
   WHERE id = p_tier_id
     AND (price IS DISTINCT FROM trim_scale(v_first::numeric / 100) OR price_schedule IS DISTINCT FROM v_sched);
  PERFORM set_config('exos.price_steps_sync', '', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_price_steps_to_tier(uuid) FROM PUBLIC, anon, authenticated;

-- The tier's price + price_schedule -> its time-only steps, in place (step
-- ids, and the holds and tickets on them, survive an edit). Malformed
-- schedule entries are skipped, as effectiveTierPrice skips them; entries
-- are taken in time order, ties in array order (its stable sort).
CREATE OR REPLACE FUNCTION public._exos_try_timestamptz(p text)
RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN p::timestamptz;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_try_timestamptz(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_price_steps_from_schedule(p_tier_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_price numeric; v_sched jsonb;
  v_want jsonb;   -- [{price_cents, ends_at}]
  v_have uuid[]; v_k int; v_n int;
BEGIN
  SELECT price, price_schedule INTO v_price, v_sched FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF NOT FOUND THEN RETURN; END IF;
  -- Valid entries (as effectiveTierPrice reads them), in time order, ties in
  -- array order; the opening price until the first, each until the next.
  WITH e AS (
    SELECT x.ord, public._exos_try_timestamptz(x.v ->> 'startsAt') AS at, (x.v ->> 'price')::numeric AS price
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_sched) = 'array' THEN v_sched ELSE '[]'::jsonb END)
           WITH ORDINALITY AS x(v, ord)
     WHERE jsonb_typeof(x.v) = 'object' AND jsonb_typeof(x.v -> 'price') = 'number'
       AND jsonb_typeof(x.v -> 'startsAt') = 'string' AND (x.v ->> 'price')::numeric >= 0
  ), ok AS (
    SELECT * FROM e WHERE at IS NOT NULL
  ), steps AS (
    SELECT 0::bigint AS rn, greatest(round(coalesce(v_price, 0) * 100), 0)::int AS pc, (SELECT min(at) FROM ok) AS ends
     WHERE EXISTS (SELECT 1 FROM ok)
    UNION ALL
    SELECT row_number() OVER (ORDER BY at, ord), greatest(round(price * 100), 0)::int, lead(at) OVER (ORDER BY at, ord)
      FROM ok
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('price_cents', pc, 'ends_at', ends) ORDER BY rn), '[]'::jsonb)
    INTO v_want FROM steps;

  SELECT coalesce(array_agg(id ORDER BY sort_order, id), '{}') INTO v_have FROM public.exos_price_steps WHERE tier_id = p_tier_id;
  v_n := jsonb_array_length(v_want);
  FOR v_k IN 1..greatest(v_n, coalesce(array_length(v_have, 1), 0)) LOOP
    IF v_k <= v_n AND v_k <= coalesce(array_length(v_have, 1), 0) THEN
      UPDATE public.exos_price_steps
         SET sort_order = v_k - 1, price_cents = (v_want -> (v_k - 1) ->> 'price_cents')::int,
             ends_at = (v_want -> (v_k - 1) ->> 'ends_at')::timestamptz, ends_after_count = NULL, sold_out_at = NULL
       WHERE id = v_have[v_k];
    ELSIF v_k <= v_n THEN
      INSERT INTO public.exos_price_steps (tier_id, org_id, event_id, sort_order, price_cents, ends_at)
      SELECT p_tier_id, e.org_id, t.event_id, v_k - 1, (v_want -> (v_k - 1) ->> 'price_cents')::int,
             (v_want -> (v_k - 1) ->> 'ends_at')::timestamptz
        FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier_id;
    ELSE
      DELETE FROM public.exos_price_steps WHERE id = v_have[v_k];
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_price_steps_from_schedule(uuid) FROM PUBLIC, anon, authenticated;

-- A price / price_schedule write by an old client (not by the sync itself).
CREATE OR REPLACE FUNCTION public.exos_tg_tier_price_schedule_sync()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_counts boolean;
BEGIN
  IF current_setting('exos.price_steps_sync', true) = '1' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.price IS NOT DISTINCT FROM OLD.price
     AND NEW.price_schedule IS NOT DISTINCT FROM OLD.price_schedule THEN
    RETURN NEW;
  END IF;
  SELECT coalesce(bool_or(ends_after_count IS NOT NULL), false) INTO v_counts
    FROM public.exos_price_steps WHERE tier_id = NEW.id;
  IF v_counts THEN
    -- Steps that end on a count have no schedule form.
    IF TG_OP = 'UPDATE' AND NEW.price_schedule IS DISTINCT FROM OLD.price_schedule
       AND NEW.price_schedule IS DISTINCT FROM '[]'::jsonb THEN
      RAISE EXCEPTION 'price_schedule: "%" uses price steps that end on a count; edit its price steps instead', NEW.name
        USING ERRCODE = '22023';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.price IS DISTINCT FROM OLD.price THEN
      UPDATE public.exos_price_steps SET price_cents = greatest(round(coalesce(NEW.price, 0) * 100), 0)::int
       WHERE id = (SELECT id FROM public.exos_price_steps WHERE tier_id = NEW.id ORDER BY sort_order, id LIMIT 1);
    END IF;
    RETURN NEW;
  END IF;
  PERFORM public._exos_price_steps_from_schedule(NEW.id);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_tier_price_schedule_sync() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_ticket_tiers_price_steps_sync ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_price_steps_sync
  AFTER INSERT OR UPDATE OF price, price_schedule ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tier_price_schedule_sync();

-- Backfill: every type with a schedule gets its steps (once).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.id FROM public.exos_ticket_tiers t
            WHERE jsonb_typeof(t.price_schedule) = 'array' AND jsonb_array_length(t.price_schedule) > 0
              AND NOT EXISTS (SELECT 1 FROM public.exos_price_steps s WHERE s.tier_id = t.id) LOOP
    PERFORM public._exos_price_steps_from_schedule(r.id);
  END LOOP;
END $$;

-- ===========================================================================
-- 4. Writing steps (validated): the editor, the API.
-- ===========================================================================

-- Replace a type's steps with p_steps ([{id?, name?, price_cents,
-- ends_after_count?, ends_at?}], in order). [] removes them (the type sells
-- at its price). Rules: 1-20 steps; each but the last ends on a count, a
-- time or both; the last has no end; times don't go backwards. Existing ids
-- are updated in place (their holds and tickets stay on them).
CREATE OR REPLACE FUNCTION public._exos_price_steps_apply(p_tier_id uuid, p_steps jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_n int; v_k int; v_s jsonb; v_key text; v_id uuid; v_keep uuid[] := '{}';
  v_price int; v_cnt int; v_at timestamptz; v_prev_at timestamptz; v_name text;
BEGIN
  PERFORM 1 FROM public.exos_ticket_tiers WHERE id = p_tier_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(coalesce(p_steps, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'steps must be an array' USING ERRCODE = '22023';
  END IF;
  v_n := jsonb_array_length(p_steps);
  IF v_n > 20 THEN
    RAISE EXCEPTION 'at most 20 price steps' USING ERRCODE = '22023';
  END IF;
  -- Serialize with exos_hold_lock_price on this type.
  PERFORM 1 FROM public.exos_price_steps WHERE tier_id = p_tier_id ORDER BY sort_order, id FOR UPDATE;

  FOR v_k IN 0..v_n - 1 LOOP
    v_s := p_steps -> v_k;
    IF jsonb_typeof(v_s) <> 'object' THEN
      RAISE EXCEPTION 'step %: must be an object', v_k + 1 USING ERRCODE = '22023';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_s) LOOP
      IF v_key NOT IN ('id', 'name', 'price_cents', 'ends_after_count', 'ends_at') THEN
        RAISE EXCEPTION 'step %: unknown field %', v_k + 1, left(v_key, 60) USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF jsonb_typeof(v_s -> 'price_cents') <> 'number' OR (v_s ->> 'price_cents') !~ '^[0-9]{1,9}$' THEN
      RAISE EXCEPTION 'step %: price_cents must be a whole number of cents, 0 or more', v_k + 1 USING ERRCODE = '22023';
    END IF;
    v_price := (v_s ->> 'price_cents')::int;
    v_cnt := NULL; v_at := NULL;
    IF v_s ? 'ends_after_count' AND jsonb_typeof(v_s -> 'ends_after_count') <> 'null' THEN
      IF jsonb_typeof(v_s -> 'ends_after_count') <> 'number' OR (v_s ->> 'ends_after_count') !~ '^[0-9]{1,7}$'
         OR (v_s ->> 'ends_after_count')::int < 1 THEN
        RAISE EXCEPTION 'step %: ends_after_count must be a whole number, 1 or more', v_k + 1 USING ERRCODE = '22023';
      END IF;
      v_cnt := (v_s ->> 'ends_after_count')::int;
    END IF;
    IF v_s ? 'ends_at' AND jsonb_typeof(v_s -> 'ends_at') <> 'null' THEN
      BEGIN
        v_at := (v_s ->> 'ends_at')::timestamptz;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'step %: ends_at must be a date and time (ISO 8601)', v_k + 1 USING ERRCODE = '22007';
      END;
    END IF;
    IF v_k < v_n - 1 AND v_cnt IS NULL AND v_at IS NULL THEN
      RAISE EXCEPTION 'step %: give it an end (a number sold, a date, or both); only the last step has none', v_k + 1
        USING ERRCODE = '22023';
    END IF;
    IF v_k = v_n - 1 AND (v_cnt IS NOT NULL OR v_at IS NOT NULL) THEN
      RAISE EXCEPTION 'the last step is the final price: it can''t have an end' USING ERRCODE = '22023';
    END IF;
    IF v_at IS NOT NULL THEN
      IF v_prev_at IS NOT NULL AND v_at < v_prev_at THEN
        RAISE EXCEPTION 'step %: ends before an earlier step', v_k + 1 USING ERRCODE = '22023';
      END IF;
      v_prev_at := v_at;
    END IF;
    v_name := CASE WHEN jsonb_typeof(v_s -> 'name') = 'string' THEN left(btrim(v_s ->> 'name'), 80) ELSE '' END;

    v_id := NULL;
    IF v_s ? 'id' AND jsonb_typeof(v_s -> 'id') <> 'null' THEN
      IF (v_s ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'step %: id is not a step of this ticket type', v_k + 1 USING ERRCODE = '22023';
      END IF;
      v_id := (v_s ->> 'id')::uuid;
      IF NOT EXISTS (SELECT 1 FROM public.exos_price_steps WHERE id = v_id AND tier_id = p_tier_id) OR v_id = ANY (v_keep) THEN
        RAISE EXCEPTION 'step %: id is not a step of this ticket type', v_k + 1 USING ERRCODE = '22023';
      END IF;
      UPDATE public.exos_price_steps
         SET sort_order = v_k, name = v_name, price_cents = v_price, ends_after_count = v_cnt, ends_at = v_at,
             -- A raised count reopens a latched step; otherwise the latch stays.
             sold_out_at = CASE WHEN v_cnt IS NOT NULL AND v_cnt > coalesce(ends_after_count, 0) THEN NULL ELSE sold_out_at END
       WHERE id = v_id;
    ELSE
      INSERT INTO public.exos_price_steps (tier_id, org_id, event_id, sort_order, name, price_cents, ends_after_count, ends_at)
      SELECT p_tier_id, e.org_id, t.event_id, v_k, v_name, v_price, v_cnt, v_at
        FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier_id
      RETURNING id INTO v_id;
    END IF;
    v_keep := v_keep || v_id;
  END LOOP;
  DELETE FROM public.exos_price_steps WHERE tier_id = p_tier_id AND NOT (id = ANY (v_keep));
  IF v_n > 0 THEN
    PERFORM public._exos_price_steps_to_tier(p_tier_id);
  ELSE
    PERFORM set_config('exos.price_steps_sync', '1', true);
    UPDATE public.exos_ticket_tiers SET price_schedule = '[]'::jsonb WHERE id = p_tier_id AND price_schedule <> '[]'::jsonb;
    PERFORM set_config('exos.price_steps_sync', '', true);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_price_steps_apply(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- A type's steps with their counts, for the editor and the API.
CREATE OR REPLACE FUNCTION public._exos_price_steps_json(p_tier_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'ticket_type_id', p_tier_id,
    'door_price_cents', (SELECT door_price_cents FROM public.exos_ticket_tiers WHERE id = p_tier_id),
    'current', public.exos_tier_current_price(p_tier_id, now(), 'online'),
    'steps', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'price_cents', s.price_cents, 'ends_after_count', s.ends_after_count,
        'ends_at', s.ends_at, 'sold_out_at', s.sold_out_at,
        'sold', (SELECT count(*)::int FROM public.exos_tickets k
                  WHERE k.price_step_id = s.id AND k.status IN ('active', 'used', 'transferred')),
        'held', (SELECT coalesce(sum(h.quantity * public.exos_tier_party_size(h.tier_id)), 0)::int
                   FROM public.exos_cart_holds h
                  WHERE h.price_step_id = s.id AND h.status = 'active' AND h.expires_at > now()))
        ORDER BY s.sort_order, s.id) FROM public.exos_price_steps s WHERE s.tier_id = p_tier_id), '[]'::jsonb));
$$;
REVOKE ALL ON FUNCTION public._exos_price_steps_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_price_steps_json(uuid) TO service_role;

-- Dashboard: read (staff) and replace (owner / manager) a type's steps and
-- door price. p_door_price_cents is set only when p_set_door.
CREATE OR REPLACE FUNCTION public.exos_tier_price_steps(p_tier_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager','finance','content'])) THEN
    RAISE EXCEPTION 'exos_tier_price_steps: ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN public._exos_price_steps_json(p_tier_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_tier_price_steps(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_tier_price_steps(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_set_price_steps(p_tier_id uuid, p_steps jsonb, p_door_price_cents integer DEFAULT NULL, p_set_door boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT e.org_id INTO v_org FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier_id;
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager','finance','content'])) THEN
    RAISE EXCEPTION 'exos_set_price_steps: ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_set_price_steps: only an owner or manager can change prices' USING ERRCODE = '42501';
  END IF;
  IF p_set_door AND p_door_price_cents IS NOT NULL AND p_door_price_cents < 0 THEN
    RAISE EXCEPTION 'door price must be 0 or more' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_price_steps_apply(p_tier_id, p_steps);
  IF p_set_door THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = p_door_price_cents WHERE id = p_tier_id;
  END IF;
  RETURN public._exos_price_steps_json(p_tier_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_price_steps(uuid, jsonb, integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_set_price_steps(uuid, jsonb, integer, boolean) TO authenticated;

-- Partner API cores (service role; exos-api/capacity.ts names the org).
CREATE OR REPLACE FUNCTION public._exos_api_price_steps(p_org uuid, p_event uuid, p_tier uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                  WHERE t.id = p_tier AND t.event_id = p_event AND e.org_id = p_org) THEN
    RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN public._exos_price_steps_json(p_tier);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_price_steps(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_api_price_steps(uuid, uuid, uuid) TO service_role;

-- p: { steps: [...], door_price_cents?: int | null } (door price untouched
-- when the key is absent).
CREATE OR REPLACE FUNCTION public._exos_api_price_steps_set(p_org uuid, p_event uuid, p_tier uuid, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_key text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
                  WHERE t.id = p_tier AND t.event_id = p_event AND e.org_id = p_org) THEN
    RAISE EXCEPTION 'ticket type not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(coalesce(p, 'null'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'send a JSON object' USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p) LOOP
    IF v_key NOT IN ('steps', 'door_price_cents') THEN
      RAISE EXCEPTION 'unknown field %', left(v_key, 60) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF NOT p ? 'steps' AND NOT p ? 'door_price_cents' THEN
    RAISE EXCEPTION 'send steps and/or door_price_cents' USING ERRCODE = '22023';
  END IF;
  IF p ? 'door_price_cents' AND jsonb_typeof(p -> 'door_price_cents') <> 'null'
     AND (jsonb_typeof(p -> 'door_price_cents') <> 'number' OR (p ->> 'door_price_cents') !~ '^[0-9]{1,9}$') THEN
    RAISE EXCEPTION 'door_price_cents must be a whole number of cents, 0 or more, or null' USING ERRCODE = '22023';
  END IF;
  IF p ? 'steps' THEN
    PERFORM public._exos_price_steps_apply(p_tier, p -> 'steps');
  END IF;
  IF p ? 'door_price_cents' THEN
    UPDATE public.exos_ticket_tiers SET door_price_cents = (p ->> 'door_price_cents')::int WHERE id = p_tier;
  END IF;
  RETURN public._exos_price_steps_json(p_tier);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_price_steps_set(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_api_price_steps_set(uuid, uuid, uuid, jsonb) TO service_role;

-- ===========================================================================
-- 5. Checkout: lock the step's price on the hold.
-- ===========================================================================
-- exos-checkout read exos_tier_current_price, priced the order at p_price_cents
-- on step p_step_id and created the hold. Under a lock on the type's steps
-- (the same lock exos_set_price_steps takes), the step must still be the
-- current one at that price, with room for the hold; then the hold carries
-- it. XP409: the price moved (the answer has the current one). XP410: fewer
-- than the hold's quantity left at this price.
CREATE OR REPLACE FUNCTION public.exos_hold_lock_price(p_hold_id uuid, p_step_id uuid, p_price_cents integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE h public.exos_cart_holds%ROWTYPE; v_cur jsonb; v_need int; v_rem int;
BEGIN
  SELECT * INTO h FROM public.exos_cart_holds WHERE id = p_hold_id FOR UPDATE;
  IF NOT FOUND OR h.status <> 'active' OR h.expires_at <= now() THEN
    RAISE EXCEPTION 'exos_hold_lock_price: hold not active' USING ERRCODE = 'P0002';
  END IF;
  IF h.price_step_id IS NOT NULL THEN
    IF h.price_step_id = p_step_id AND h.unit_price_cents = p_price_cents THEN
      RETURN public.exos_tier_current_price(h.tier_id, now(), 'online');   -- a retry
    END IF;
    RAISE EXCEPTION 'exos_hold_lock_price: hold already priced' USING ERRCODE = 'XP409';
  END IF;
  PERFORM 1 FROM public.exos_price_steps WHERE tier_id = h.tier_id ORDER BY sort_order, id FOR UPDATE;
  -- This hold isn't on a step yet, so it doesn't count against one here.
  v_cur := public.exos_tier_current_price(h.tier_id, now(), 'online');
  IF (v_cur ->> 'step_id') IS DISTINCT FROM p_step_id::text OR (v_cur ->> 'price_cents')::int IS DISTINCT FROM p_price_cents THEN
    RAISE EXCEPTION 'price_changed: the price is now % cents', v_cur ->> 'price_cents' USING ERRCODE = 'XP409';
  END IF;
  v_need := h.quantity * public.exos_tier_party_size(h.tier_id);
  v_rem := (v_cur ->> 'step_remaining')::int;
  IF v_rem IS NOT NULL AND v_rem < v_need THEN
    RAISE EXCEPTION 'price_step_remaining: only % left at this price', v_rem USING ERRCODE = 'XP410';
  END IF;
  UPDATE public.exos_cart_holds SET price_step_id = p_step_id, unit_price_cents = p_price_cents WHERE id = h.id;
  RETURN v_cur;
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_lock_price(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_hold_lock_price(uuid, uuid, integer) TO service_role;

-- ===========================================================================
-- 6. Tickets remember their step; a step whose count sold stays ended.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_price_step()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_step uuid; v_cur jsonb;
BEGIN
  IF NEW.price_step_id IS NOT NULL OR NEW.tier_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.exos_price_steps WHERE tier_id = NEW.tier_id) THEN
    RETURN NEW;
  END IF;
  -- The step the checkout locked (the session, else its hold).
  IF NEW.order_ref IS NOT NULL THEN
    SELECT s.price_step_id INTO v_step FROM public.exos_checkout_sessions s WHERE s.session_id = NEW.order_ref;
    IF v_step IS NULL THEN
      SELECT h.price_step_id INTO v_step FROM public.exos_cart_holds h
       WHERE h.checkout_session_id = NEW.order_ref AND h.price_step_id IS NOT NULL
       ORDER BY h.created_at DESC LIMIT 1;
    END IF;
  END IF;
  -- Otherwise a sale takes the current step of its channel (a door sale at
  -- the door price takes none). A comp (price 0 from the box office, or a
  -- free ticket while the step isn't free) takes none; a free claim while
  -- the current step is free ("first 10 free") takes it.
  IF v_step IS NULL THEN
    v_cur := public.exos_tier_current_price(NEW.tier_id, now(),
               CASE WHEN NEW.channel_source IN ('door', 'pos', 'box_office') THEN 'door' ELSE 'online' END);
    IF coalesce(NEW.price_paid, 0) > 0
       OR ((v_cur ->> 'price_cents')::int = 0 AND coalesce(NEW.channel_source, '') <> 'boxoffice') THEN
      v_step := (v_cur ->> 'step_id')::uuid;
    END IF;
  END IF;
  NEW.price_step_id := v_step;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_price_step() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_price_step ON public.exos_tickets;
CREATE TRIGGER exos_tickets_price_step BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_price_step();

CREATE OR REPLACE FUNCTION public.exos_tg_ticket_price_step_latch()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_price_steps s
     SET sold_out_at = now()
   WHERE s.id = NEW.price_step_id AND s.sold_out_at IS NULL AND s.ends_after_count IS NOT NULL
     AND (SELECT count(*) FROM public.exos_tickets k
           WHERE k.price_step_id = s.id AND k.status IN ('active', 'used', 'transferred')) >= s.ends_after_count;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_price_step_latch() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_price_step_latch ON public.exos_tickets;
CREATE TRIGGER exos_tickets_price_step_latch AFTER INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.price_step_id IS NOT NULL)
  EXECUTE FUNCTION public.exos_tg_ticket_price_step_latch();

-- ===========================================================================
-- 7. Every reader's price is the current step's.
-- ===========================================================================

-- 7a. The public tiers view (storefront, Google + catalog feeds, MCP, hosted
--     pages). Patched from its current text so other columns survive; its
--     options and grants are put back as they were.
DO $$
DECLARE v_def text; v_opts text[];
BEGIN
  v_def := pg_get_viewdef('public.exos_public_tiers'::regclass, true);
  SELECT reloptions INTO v_opts FROM pg_class WHERE oid = 'public.exos_public_tiers'::regclass;
  IF position('exos_public_tier_price' in v_def) > 0 THEN
    RAISE NOTICE 'exos_public_tiers: already patched (price steps)';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, E'\n    t.price,', ''))) / length(E'\n    t.price,') <> 1 THEN
    RAISE EXCEPTION 'exos_public_tiers: unexpected definition, patch by hand';
  END IF;
  v_def := replace(v_def, E'\n    t.price,',
    E'\n    trim_scale(((exos_public_tier_price(t.id) ->> ''price_cents''::text)::numeric) / 100::numeric) AS price,');
  v_def := rtrim(v_def, E'; \n');
  EXECUTE 'CREATE OR REPLACE VIEW public.exos_public_tiers AS ' || v_def;
  -- Keep the view's options as they were (today: an owner-run security_barrier view).
  IF v_opts IS NOT NULL THEN
    EXECUTE format('ALTER VIEW public.exos_public_tiers SET (%s)', array_to_string(v_opts, ', '));
  END IF;
  REVOKE ALL ON public.exos_public_tiers FROM anon, authenticated;
  GRANT SELECT ON public.exos_public_tiers TO anon, authenticated;
END $$;

-- The step behind that price, for the buyer's "goes up to $25 after Dec 1
-- or 100 sold" line and the door price. Its own view: older migrations
-- replace exos_public_tiers with their column list, so it gets no new ones.
CREATE OR REPLACE VIEW public.exos_public_price_steps WITH (security_barrier = true) AS
  SELECT t.id AS tier_id, t.event_id, public.exos_public_tier_price(t.id) AS price_step, t.door_price_cents
    FROM public.exos_ticket_tiers t
    JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.visibility = 'public' AND e.status = 'published';
REVOKE ALL ON public.exos_public_price_steps FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_price_steps TO anon, authenticated, service_role;

-- 7b. JSON builders.
SELECT pg_temp.exos_patch_n('public._exos_api_public_tiers_json(uuid)',
  '/* exos: price steps */',
  $o$'price', t.price,$o$,
  $n$'price', public.exos_tier_price_now(t.id) /* exos: price steps */, 'price_step', public.exos_tier_current_price(t.id),
           'door_price_cents', t.door_price_cents,$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_api_event_json(uuid)',
  '/* exos: price steps */',
  $o$'price', t.price,$o$,
  $n$'price', public.exos_tier_price_now(t.id) /* exos: price steps */, 'price_step', public.exos_tier_current_price(t.id),
                 'door_price_cents', t.door_price_cents,$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_discovery_event_json(uuid)',
  '/* exos: price steps */',
  $o$'price', t.price, 'capacity'$o$,
  $n$'price', public.exos_tier_price_now(t.id) /* exos: price steps */, 'capacity'$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_listing_feed_event(public.exos_events)',
  '/* exos: price steps */',
  $o$'price', t.price, 'capacity'$o$,
  $n$'price', public.exos_tier_price_now(t.id) /* exos: price steps */, 'capacity'$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_voucher_tier(uuid,text,text)',
  '/* exos: price steps */',
  $o$SELECT t.id, t.event_id, t.name, t.description, t.price, t.capacity$o$,
  $n$SELECT t.id, t.event_id, t.name, t.description, public.exos_tier_price_now(t.id) /* exos: price steps */, t.capacity$n$, 1);

-- 7c. Partner sales and referral rewards: the face price now (was the
--     schedule rule, re-implemented in SQL).
CREATE OR REPLACE FUNCTION public.exos_rr_tier_price(p_tier_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce(public.exos_tier_price_now(p_tier_id), 0);  /* exos: price steps (mig 20261106130000) */
$$;
REVOKE ALL ON FUNCTION public.exos_rr_tier_price(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_rr_tier_price(uuid) TO service_role;

COMMENT ON TABLE public.exos_price_steps IS
  'Price steps of a ticket type (DICE PriceTier; mig 20261106130000). The current one: exos_tier_current_price. '
  'price_schedule on exos_ticket_tiers is kept in sync (time-only form).';
COMMENT ON COLUMN public.exos_ticket_tiers.price_schedule IS
  'Time-only form of the type''s price steps (exos_price_steps, mig 20261106130000), kept in sync both ways; '
  '[] when a step ends on a count. Writable by old clients: a write rebuilds the time-only steps.';
