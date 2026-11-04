-- ============================================================================
-- Migration 20261030140000 — Exos: reserved seating (seat maps, seat holds,
-- seats on tickets). docs/seating.md.
--
-- Touches:  W: TABLE exos_seat_maps, exos_event_seating, exos_event_seats,
--                    exos_event_seat_claims (new)
--              COLUMN exos_ticket_tiers.seated (new, server-written)
--              COLUMN exos_tickets.seat_id, seat_label, seat_section,
--                     seat_row, seat_number (new, server-written)
--              FUNCTION _exos_seat_map_error, _exos_seat_map_seats,
--                       _exos_seat_tier_sync, exos_set_event_seating,
--                       exos_set_seats_blocked, exos_hold_seats,
--                       exos_public_event_seating, exos_public_event_seats,
--                       exos_event_seat_status, exos_event_seat_roster,
--                       exos_seat_reconciliation, exos_release_orphan_seats,
--                       trigger functions _exos_tg_seat_map_check,
--                       _exos_tg_tier_seated_guard, _exos_tg_ticket_seat_assign,
--                       _exos_tg_ticket_seat_guard, _exos_tg_ticket_seat_release,
--                       _exos_tg_hold_seat_lapse (new)
--              FUNCTION exos_receipt_html (replaced: adds a "Seats:" line;
--                       everything else as in 20261027100000)
--              FUNCTION _exos_wallet_payload (replaced: ticket.seat added;
--                       everything else as in 20260929072000)
--           R: exos_events, exos_cart_holds, exos_checkout_sessions,
--              exos_org_memberships
-- Pre-reqs: 20260702123000 (cart holds), 20260926050000 (exos.table_mint,
--           set by exos_fulfill_checkout before it mints), 20260929072000
--           (wallet passes), 20261027100000 (latest exos_receipt_html).
--
-- Model (Postgres port of the Firebase build's docs/SEATING.md):
--   * exos_seat_maps: an org's reusable map (sections → rows → seats, plus
--     standing areas and a stage), JSONB, checked on save. room_id is an
--     optional pointer for the venues / rooms work (no FK yet).
--   * Assigning a map to an event (exos_set_event_seating) snapshots it into
--     exos_event_seating and expands one exos_event_seats row per seat, with
--     the ticket type (tier) it sells as (price levels: seat > row > section).
--     Tiers stay the pricing unit. A seated tier's capacity is its seats minus
--     the blocked ones; later edits of the org's map never move sold seats.
--   * exos_event_seat_claims: a seat that is not available. One LIVE claim
--     (held / sold / blocked) per (event, seat), enforced by a partial unique
--     index: two buyers racing for a seat can't both get it. A held claim
--     belongs to a cart hold (exos_cart_holds) and lives exactly as long as
--     the hold: when the hold is released or expires the claim lapses; a hold
--     still 'active' past expires_at counts as lapsed for the next buyer.
--   * Fulfillment (exos_fulfill_checkout, unchanged) mints the tickets; a
--     BEFORE INSERT trigger gives ticket i the hold's seat i in the same
--     transaction and marks the claim sold. A seat lost while the buyer was
--     paying (their hold lapsed and someone else took it) raises XF001, which
--     the fulfillment turns into a failed, refunded order.
--   * A ticket that stops being live (void, refund, release, delete) frees
--     its seat. Transfers and resales keep the seat (same ticket row).
--   * Only the seat picker sells seats: any other ticket insert for a seated
--     tier (comps, box office / POS, partner and marketplace orders, the free
--     claim RPC, waitlist) is refused, as tables are (20260926050000).
--
-- Public surface: exos_public_event_seating (layout of a published event)
-- and exos_public_event_seats (seat id / labels / tier / position and an
-- `available` flag only — no holder, ticket or hold data). Staff see full
-- status through exos_event_seat_status (RLS-equivalent role checks).
--
-- Additive, re-run safe. Prod apply needs operator OK.
-- ROLLBACK: restore exos_receipt_html (20261027100000) and
--   _exos_wallet_payload (20260929072000); DROP the triggers and functions
--   above, the four tables, and the new columns.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns on existing tables
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS seated boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_ticket_tiers.seated IS
  'Reserved seating (mig 20261030140000): sold as seats of the event''s seat map. Server-written by exos_set_event_seating.';

ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS seat_id      text;
ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS seat_label   text;
ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS seat_section text;
ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS seat_row     text;
ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS seat_number  text;
COMMENT ON COLUMN public.exos_tickets.seat_label IS
  'Reserved seat, e.g. "Orchestra · Row C · Seat 12" (mig 20261030140000). NULL for general admission. Kept after a void as the seat the buyer had.';
GRANT SELECT (seat_id, seat_label, seat_section, seat_row, seat_number) ON public.exos_tickets TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Seat maps (org-owned, reusable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_seat_maps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Optional pointer to a venue room (venues / rooms work); no FK yet.
  room_id     uuid,
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  map         jsonb NOT NULL,
  seat_count  integer NOT NULL DEFAULT 0,
  version     integer NOT NULL DEFAULT 1,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_seat_maps_size CHECK (octet_length(map::text) <= 2000000)
);
COMMENT ON TABLE public.exos_seat_maps IS
  'Reserved seating (mig 20261030140000): an org''s reusable seat map (sections, rows, seats, standing areas, stage). docs/seating.md.';
CREATE INDEX IF NOT EXISTS exos_seat_maps_org_idx ON public.exos_seat_maps (org_id);
CREATE INDEX IF NOT EXISTS exos_seat_maps_room_idx ON public.exos_seat_maps (room_id) WHERE room_id IS NOT NULL;

-- The event's snapshot of a map + its price levels.
CREATE TABLE IF NOT EXISTS public.exos_event_seating (
  event_id    uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  map_id      uuid REFERENCES public.exos_seat_maps (id) ON DELETE SET NULL,
  map_version integer,
  map         jsonb NOT NULL,
  levels      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(levels) = 'object'),
  seat_count  integer NOT NULL DEFAULT 0,
  updated_by  uuid,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_event_seating IS
  'Reserved seating (mig 20261030140000): the event''s snapshot of a seat map and its price levels (section / row / seat id → tier id).';

-- One row per seat of the event (expanded from the snapshot).
CREATE TABLE IF NOT EXISTS public.exos_event_seats (
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  seat_id     text NOT NULL,
  org_id      uuid NOT NULL,
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  section_id  text NOT NULL,
  section     text NOT NULL,
  row_id      text NOT NULL,
  row_label   text NOT NULL,
  number      text NOT NULL,
  label       text NOT NULL,
  x           numeric NOT NULL,
  y           numeric NOT NULL,
  accessible  boolean NOT NULL DEFAULT false,
  companion   boolean NOT NULL DEFAULT false,
  obstructed  boolean NOT NULL DEFAULT false,
  sort        integer NOT NULL,
  PRIMARY KEY (event_id, seat_id)
);
COMMENT ON TABLE public.exos_event_seats IS
  'Reserved seating (mig 20261030140000): every seat of an event''s map, with the tier it sells as (NULL = not on sale). Written by exos_set_event_seating only.';
CREATE INDEX IF NOT EXISTS exos_event_seats_tier_idx ON public.exos_event_seats (tier_id);

-- Seats that are not available. No live claim = available.
CREATE TABLE IF NOT EXISTS public.exos_event_seat_claims (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL,
  seat_id     text NOT NULL,
  org_id      uuid NOT NULL,
  status      text NOT NULL CHECK (status IN ('held', 'sold', 'blocked', 'lapsed', 'released')),
  hold_id     uuid REFERENCES public.exos_cart_holds (id) ON DELETE SET NULL,
  ticket_id   uuid,
  reason      text CHECK (reason IS NULL OR length(reason) <= 200),
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (event_id, seat_id) REFERENCES public.exos_event_seats (event_id, seat_id) ON DELETE CASCADE
);
COMMENT ON TABLE public.exos_event_seat_claims IS
  'Reserved seating (mig 20261030140000): held (a cart hold), sold (a ticket) or blocked seats. One live claim per seat (unique index); lapsed / released rows are history.';
CREATE UNIQUE INDEX IF NOT EXISTS exos_event_seat_claims_live_uq
  ON public.exos_event_seat_claims (event_id, seat_id) WHERE status IN ('held', 'sold', 'blocked');
CREATE INDEX IF NOT EXISTS exos_event_seat_claims_hold_idx ON public.exos_event_seat_claims (hold_id) WHERE hold_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_event_seat_claims_ticket_idx ON public.exos_event_seat_claims (ticket_id) WHERE ticket_id IS NOT NULL;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_seat_maps', 'exos_event_seat_claims'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()', t || '_touch', t);
  END LOOP;
END $$;

-- Called by a client (PostgREST role authenticated / anon), not the service
-- role or a maintenance session. The `role` setting survives SECURITY
-- DEFINER (current_user doesn't: it is always the definer).
CREATE OR REPLACE FUNCTION public._exos_seat_client_call()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$ SELECT coalesce(current_setting('role', true), 'none') IN ('authenticated', 'anon') $$;
REVOKE ALL ON FUNCTION public._exos_seat_client_call() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_seat_client_call() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Map validation + expansion (mirrors src/lib/seating.ts validateMap)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_seat_map_error(p_map jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  s jsonb; r jsonb; q jsonb;
  v_secs text[] := '{}'; v_rows text[]; v_keys text[];
  v_seats int := 0;
  v_name text;
BEGIN
  IF p_map IS NULL OR jsonb_typeof(p_map) <> 'object' THEN RETURN 'The seat map is missing.'; END IF;
  IF jsonb_typeof(p_map->'width') <> 'number' OR jsonb_typeof(p_map->'height') <> 'number'
     OR (p_map->>'width')::numeric NOT BETWEEN 100 AND 10000 OR (p_map->>'height')::numeric NOT BETWEEN 100 AND 10000 THEN
    RETURN 'The canvas must be between 100 and 10000 units wide and high.';
  END IF;
  IF p_map ? 'stage' AND (jsonb_typeof(p_map->'stage') <> 'object'
       OR jsonb_typeof(p_map->'stage'->'x') <> 'number' OR jsonb_typeof(p_map->'stage'->'y') <> 'number'
       OR jsonb_typeof(p_map->'stage'->'w') <> 'number' OR jsonb_typeof(p_map->'stage'->'h') <> 'number') THEN
    RETURN 'The stage position is invalid.';
  END IF;
  IF jsonb_typeof(p_map->'sections') <> 'array' OR jsonb_array_length(p_map->'sections') = 0 THEN
    RETURN 'Add at least one section.';
  END IF;
  IF jsonb_array_length(p_map->'sections') > 100 THEN RETURN 'A map can have at most 100 sections.'; END IF;
  FOR s IN SELECT * FROM jsonb_array_elements(p_map->'sections') LOOP
    IF jsonb_typeof(s) <> 'object' OR coalesce(s->>'id', '') !~ '^[A-Za-z0-9]{1,12}$' THEN
      RETURN 'Section ids are 1-12 letters or digits.';
    END IF;
    IF (s->>'id') = ANY (v_secs) THEN RETURN format('Two sections share the id %s.', s->>'id'); END IF;
    v_secs := v_secs || (s->>'id');
    v_name := coalesce(s->>'name', '');
    IF length(btrim(v_name)) NOT BETWEEN 1 AND 40 OR v_name ~ '[|;]' THEN
      RETURN 'Section names are 1-40 characters, without | or ;.';
    END IF;
    IF jsonb_typeof(s->'x') <> 'number' OR jsonb_typeof(s->'y') <> 'number'
       OR abs((s->>'x')::numeric) > 10000 OR abs((s->>'y')::numeric) > 10000 THEN
      RETURN format('Section %s: position is invalid.', v_name);
    END IF;
    IF coalesce(s->>'kind', 'seated') = 'ga' THEN
      IF jsonb_typeof(s->'capacity') <> 'number' OR (s->>'capacity')::numeric NOT BETWEEN 1 AND 100000 THEN
        RETURN format('Standing area %s: capacity must be 1-100000.', v_name);
      END IF;
      IF jsonb_typeof(s->'rows') = 'array' AND jsonb_array_length(s->'rows') > 0 THEN
        RETURN format('Standing area %s can''t have rows.', v_name);
      END IF;
      CONTINUE;
    END IF;
    IF coalesce(s->>'kind', 'seated') <> 'seated' THEN RETURN format('Section %s: kind must be seated or ga.', v_name); END IF;
    IF jsonb_typeof(s->'rows') <> 'array' OR jsonb_array_length(s->'rows') = 0 THEN
      RETURN format('Section %s has no rows.', v_name);
    END IF;
    IF jsonb_array_length(s->'rows') > 200 THEN RETURN format('Section %s: at most 200 rows.', v_name); END IF;
    v_rows := '{}';
    FOR r IN SELECT * FROM jsonb_array_elements(s->'rows') LOOP
      IF jsonb_typeof(r) <> 'object' OR coalesce(r->>'id', '') !~ '^[A-Za-z0-9]{1,12}$' THEN
        RETURN format('Section %s: row ids are 1-12 letters or digits.', v_name);
      END IF;
      IF (r->>'id') = ANY (v_rows) THEN RETURN format('Section %s: two rows share the id %s.', v_name, r->>'id'); END IF;
      v_rows := v_rows || (r->>'id');
      IF coalesce(r->>'label', '') !~ '^[^|;]{1,24}$' THEN
        RETURN format('Section %s: row labels are 1-24 characters, without | or ;.', v_name);
      END IF;
      IF jsonb_typeof(r->'seats') <> 'array' OR jsonb_array_length(r->'seats') = 0 THEN
        RETURN format('Section %s, row %s has no seats.', v_name, r->>'label');
      END IF;
      IF jsonb_array_length(r->'seats') > 200 THEN RETURN format('Section %s, row %s: at most 200 seats.', v_name, r->>'label'); END IF;
      v_keys := '{}';
      FOR q IN SELECT * FROM jsonb_array_elements(r->'seats') LOOP
        IF jsonb_typeof(q) <> 'object' OR coalesce(q->>'key', '') !~ '^[A-Za-z0-9]{1,6}$' THEN
          RETURN format('Section %s, row %s: seat keys are 1-6 letters or digits.', v_name, r->>'label');
        END IF;
        IF (q->>'key') = ANY (v_keys) THEN
          RETURN format('Section %s, row %s: two seats share the key %s.', v_name, r->>'label', q->>'key');
        END IF;
        v_keys := v_keys || (q->>'key');
        IF q ? 'label' AND coalesce(q->>'label', '') !~ '^[^|;]{1,24}$' THEN
          RETURN format('Section %s, row %s: seat numbers are 1-24 characters, without | or ;.', v_name, r->>'label');
        END IF;
        IF jsonb_typeof(q->'x') <> 'number' OR jsonb_typeof(q->'y') <> 'number'
           OR abs((q->>'x')::numeric) > 10000 OR abs((q->>'y')::numeric) > 10000 THEN
          RETURN format('Section %s, row %s: a seat position is invalid.', v_name, r->>'label');
        END IF;
        v_seats := v_seats + 1;
      END LOOP;
    END LOOP;
  END LOOP;
  IF v_seats > 10000 THEN RETURN format('A map can have at most 10,000 seats (this one has %s).', v_seats); END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_seat_map_error(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_seat_map_error(jsonb) TO service_role;

-- Every seat of a (valid) map, positions absolute, in physical order.
CREATE OR REPLACE FUNCTION public._exos_seat_map_seats(p_map jsonb)
RETURNS TABLE (seat_id text, section_id text, section text, row_id text, row_label text, number text,
               x numeric, y numeric, accessible boolean, companion boolean, obstructed boolean, sort integer)
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT (sc.s->>'id') || '-' || (rw.r->>'id') || '-' || (st.q->>'key'),
         sc.s->>'id', btrim(sc.s->>'name'), rw.r->>'id', rw.r->>'label',
         coalesce(nullif(st.q->>'label', ''), st.q->>'key'),
         (sc.s->>'x')::numeric + (st.q->>'x')::numeric,
         (sc.s->>'y')::numeric + (st.q->>'y')::numeric,
         coalesce(st.q->>'accessible', '') = 'true',
         coalesce(st.q->>'companion', '') = 'true',
         coalesce(st.q->>'obstructed', '') = 'true',
         (row_number() OVER (ORDER BY sc.si, rw.ri, st.qi))::int
    FROM jsonb_array_elements(p_map->'sections') WITH ORDINALITY AS sc(s, si)
   CROSS JOIN LATERAL jsonb_array_elements(
           CASE WHEN coalesce(sc.s->>'kind', 'seated') = 'seated' AND jsonb_typeof(sc.s->'rows') = 'array'
                THEN sc.s->'rows' ELSE '[]'::jsonb END) WITH ORDINALITY AS rw(r, ri)
   CROSS JOIN LATERAL jsonb_array_elements(
           CASE WHEN jsonb_typeof(rw.r->'seats') = 'array' THEN rw.r->'seats' ELSE '[]'::jsonb END) WITH ORDINALITY AS st(q, qi);
$$;
REVOKE ALL ON FUNCTION public._exos_seat_map_seats(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_seat_map_seats(jsonb) TO service_role;

-- Seat maps: checked on save; seat count kept; at most 200 per org; a map
-- can't move to another org.
CREATE OR REPLACE FUNCTION public._exos_tg_seat_map_check()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_err text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'seat maps: a map can''t move to another org' USING ERRCODE = '42501';
  END IF;
  v_err := public._exos_seat_map_error(NEW.map);
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION 'seat maps: %', v_err USING ERRCODE = '23514';
  END IF;
  NEW.seat_count := (SELECT count(*) FROM public._exos_seat_map_seats(NEW.map));
  IF TG_OP = 'INSERT' THEN
    NEW.version := 1;
    NEW.created_by := coalesce(NEW.created_by, auth.uid());
    IF (SELECT count(*) FROM public.exos_seat_maps WHERE org_id = NEW.org_id) >= 200 THEN
      RAISE EXCEPTION 'seat maps: an org can have at most 200 seat maps' USING ERRCODE = '23514';
    END IF;
  ELSIF NEW.map IS DISTINCT FROM OLD.map OR NEW.name IS DISTINCT FROM OLD.name THEN
    NEW.version := OLD.version + 1;
  ELSE
    NEW.version := OLD.version;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_seat_map_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_seat_maps_check ON public.exos_seat_maps;
CREATE TRIGGER exos_seat_maps_check BEFORE INSERT OR UPDATE ON public.exos_seat_maps
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_seat_map_check();

-- ---------------------------------------------------------------------------
-- 4. RLS: org staff read; owner / manager write maps; the rest is RPC-only.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_seat_maps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_seating ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_seat_claims ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS exos_seat_maps_sel ON public.exos_seat_maps;
CREATE POLICY exos_seat_maps_sel ON public.exos_seat_maps FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
DROP POLICY IF EXISTS exos_seat_maps_ins ON public.exos_seat_maps;
CREATE POLICY exos_seat_maps_ins ON public.exos_seat_maps FOR INSERT TO authenticated
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
DROP POLICY IF EXISTS exos_seat_maps_upd ON public.exos_seat_maps;
CREATE POLICY exos_seat_maps_upd ON public.exos_seat_maps FOR UPDATE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
DROP POLICY IF EXISTS exos_seat_maps_del ON public.exos_seat_maps;
CREATE POLICY exos_seat_maps_del ON public.exos_seat_maps FOR DELETE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_event_seating', 'exos_event_seats'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_sel', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
      USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']))$f$, t || '_sel', t);
  END LOOP;
END $$;
DROP POLICY IF EXISTS exos_event_seat_claims_sel ON public.exos_event_seat_claims;
CREATE POLICY exos_event_seat_claims_sel ON public.exos_event_seat_claims FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

REVOKE ALL ON public.exos_seat_maps, public.exos_event_seating, public.exos_event_seats,
              public.exos_event_seat_claims FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_seat_maps TO authenticated;
GRANT SELECT ON public.exos_event_seating, public.exos_event_seats, public.exos_event_seat_claims TO authenticated;
GRANT ALL ON public.exos_seat_maps, public.exos_event_seating, public.exos_event_seats,
             public.exos_event_seat_claims TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Guards: `seated` and a seated tier's capacity are server-written; so are
--    a ticket's seat columns. Changes from anywhere else are ignored (kept as
--    they were), so the event editor's ordinary saves keep working.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_tier_seated_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('exos.seating_write', true), '') = 'on' THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.seated := false;
  ELSE
    NEW.seated := OLD.seated;
    IF OLD.seated THEN NEW.capacity := OLD.capacity; END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_tier_seated_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_ticket_tiers_seated_guard ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_seated_guard BEFORE INSERT OR UPDATE ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_tier_seated_guard();

CREATE OR REPLACE FUNCTION public._exos_tg_ticket_seat_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('exos.seating_write', true), '') = 'on' THEN RETURN NEW; END IF;
  NEW.seat_id := OLD.seat_id;
  NEW.seat_label := OLD.seat_label;
  NEW.seat_section := OLD.seat_section;
  NEW.seat_row := OLD.seat_row;
  NEW.seat_number := OLD.seat_number;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_seat_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_seat_guard ON public.exos_tickets;
CREATE TRIGGER exos_tickets_seat_guard BEFORE UPDATE ON public.exos_tickets
  FOR EACH ROW
  WHEN (OLD.seat_id IS DISTINCT FROM NEW.seat_id OR OLD.seat_label IS DISTINCT FROM NEW.seat_label
        OR OLD.seat_section IS DISTINCT FROM NEW.seat_section OR OLD.seat_row IS DISTINCT FROM NEW.seat_row
        OR OLD.seat_number IS DISTINCT FROM NEW.seat_number)
  EXECUTE FUNCTION public._exos_tg_ticket_seat_guard();

-- ---------------------------------------------------------------------------
-- 6. Tier capacities follow the seats: seats of the tier minus blocked ones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_seat_tier_sync(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_sum int;
BEGIN
  PERFORM set_config('exos.seating_write', 'on', true);
  UPDATE public.exos_ticket_tiers tt
     SET seated = x.n IS NOT NULL,
         capacity = CASE WHEN x.n IS NOT NULL THEN greatest(x.n - x.blocked, tt.sold) ELSE tt.capacity END
    FROM (SELECT t.id,
                 (SELECT nullif(count(*), 0) FROM public.exos_event_seats s WHERE s.event_id = p_event_id AND s.tier_id = t.id)::int AS n,
                 (SELECT count(*) FROM public.exos_event_seats s
                    JOIN public.exos_event_seat_claims c ON c.event_id = s.event_id AND c.seat_id = s.seat_id AND c.status = 'blocked'
                   WHERE s.event_id = p_event_id AND s.tier_id = t.id)::int AS blocked
            FROM public.exos_ticket_tiers t WHERE t.event_id = p_event_id) x
   WHERE tt.id = x.id
     AND (tt.seated IS DISTINCT FROM (x.n IS NOT NULL)
          OR (x.n IS NOT NULL AND tt.capacity IS DISTINCT FROM greatest(x.n - x.blocked, tt.sold)));
  -- A capped event grows to hold every ticket type's capacity.
  SELECT sum(capacity) INTO v_sum FROM public.exos_ticket_tiers WHERE event_id = p_event_id AND capacity > 0;
  UPDATE public.exos_events SET total_tickets = v_sum
   WHERE id = p_event_id AND total_tickets > 0 AND total_tickets < coalesce(v_sum, 0);
  PERFORM set_config('exos.seating_write', '', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_seat_tier_sync(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Assign (or clear) an event's seat map: owner / manager.
--    p_levels: { "<section id>" | "<section>-<row>" | "<seat id>": "<tier uuid>" }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_event_seating(p_event_id uuid, p_map_id uuid, p_levels jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid;
  v_map   public.exos_seat_maps%ROWTYPE;
  v_key   text;
  v_val   text;
  v_bad   text;
  v_n     int;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  IF v_org IS NULL THEN RAISE EXCEPTION 'seating: event not found' USING ERRCODE = '42501'; END IF;
  IF public._exos_seat_client_call()
     AND NOT public.exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'seating: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_event_seat_claims WHERE event_id = p_event_id AND status IN ('held', 'sold')) THEN
    RAISE EXCEPTION 'seating: seats of this event were already held or sold; block or unblock single seats instead'
      USING ERRCODE = '23514';
  END IF;

  IF p_map_id IS NULL THEN
    DELETE FROM public.exos_event_seats WHERE event_id = p_event_id;
    DELETE FROM public.exos_event_seating WHERE event_id = p_event_id;
    PERFORM public._exos_seat_tier_sync(p_event_id);
    RETURN jsonb_build_object('seat_count', 0, 'tiers', '{}'::jsonb);
  END IF;

  SELECT * INTO v_map FROM public.exos_seat_maps WHERE id = p_map_id AND org_id = v_org;
  IF NOT FOUND THEN RAISE EXCEPTION 'seating: seat map not found' USING ERRCODE = '42501'; END IF;
  IF p_levels IS NULL OR jsonb_typeof(p_levels) <> 'object' THEN
    RAISE EXCEPTION 'seating: price levels are missing' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p_levels)) > 20000 THEN
    RAISE EXCEPTION 'seating: too many price levels' USING ERRCODE = '22023';
  END IF;

  -- Every key names a section, row or seat of the map; every value a tier of
  -- this event that isn't a table and has no sales as general admission.
  FOR v_key, v_val IN SELECT * FROM jsonb_each_text(p_levels) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_map.map->'sections') s WHERE s->>'id' = v_key)
       AND NOT EXISTS (SELECT 1 FROM public._exos_seat_map_seats(v_map.map) m
                        WHERE m.seat_id = v_key OR m.section_id || '-' || m.row_id = v_key) THEN
      RAISE EXCEPTION 'seating: price level for %: no such section, row or seat in this map', v_key USING ERRCODE = '22023';
    END IF;
    IF v_val !~ '^[0-9a-fA-F-]{36}$' OR NOT EXISTS (
         SELECT 1 FROM public.exos_ticket_tiers WHERE id = v_val::uuid AND event_id = p_event_id) THEN
      RAISE EXCEPTION 'seating: price level for %: % is not a ticket type of this event', v_key, v_val USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- A tier is sold as seats or as a standing area, never both.
  SELECT string_agg(DISTINCT v, ', ') INTO v_bad
    FROM (SELECT p_levels->>(s->>'id') AS v FROM jsonb_array_elements(v_map.map->'sections') s
           WHERE coalesce(s->>'kind', 'seated') = 'ga' AND p_levels ? (s->>'id')) ga
   WHERE v IN (SELECT coalesce(p_levels->>m.seat_id, p_levels->>(m.section_id || '-' || m.row_id), p_levels->>m.section_id)
                 FROM public._exos_seat_map_seats(v_map.map) m);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'seating: a ticket type can be sold as seats or as a standing area, not both' USING ERRCODE = '22023';
  END IF;

  -- Rebuild the event's seats.
  DELETE FROM public.exos_event_seats WHERE event_id = p_event_id;
  INSERT INTO public.exos_event_seats (event_id, seat_id, org_id, tier_id, section_id, section, row_id, row_label,
                                       number, label, x, y, accessible, companion, obstructed, sort)
  SELECT p_event_id, m.seat_id, v_org,
         nullif(coalesce(p_levels->>m.seat_id, p_levels->>(m.section_id || '-' || m.row_id), p_levels->>m.section_id), '')::uuid,
         m.section_id, m.section, m.row_id, m.row_label, m.number,
         m.section || ' · Row ' || m.row_label || ' · Seat ' || m.number,
         m.x, m.y, m.accessible, m.companion, m.obstructed, m.sort
    FROM public._exos_seat_map_seats(v_map.map) m;

  -- Seated tiers: not tables, and no general-admission tickets already sold.
  SELECT string_agg(t.name, ', ') INTO v_bad
    FROM public.exos_ticket_tiers t
   WHERE t.event_id = p_event_id AND NOT t.seated
     AND EXISTS (SELECT 1 FROM public.exos_event_seats s WHERE s.event_id = p_event_id AND s.tier_id = t.id)
     AND (t.kind = 'table' OR t.sold > 0
          OR EXISTS (SELECT 1 FROM public.exos_tickets k WHERE k.tier_id = t.id));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'seating: % already sold as general admission (or is a table) and can''t become seats', v_bad
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.exos_event_seating (event_id, org_id, map_id, map_version, map, levels, seat_count, updated_by, updated_at)
  VALUES (p_event_id, v_org, v_map.id, v_map.version, v_map.map, p_levels, v_map.seat_count, auth.uid(), now())
  ON CONFLICT (event_id) DO UPDATE
     SET map_id = EXCLUDED.map_id, map_version = EXCLUDED.map_version, map = EXCLUDED.map,
         levels = EXCLUDED.levels, seat_count = EXCLUDED.seat_count,
         updated_by = EXCLUDED.updated_by, updated_at = now();

  PERFORM public._exos_seat_tier_sync(p_event_id);
  SELECT count(*) INTO v_n FROM public.exos_event_seats WHERE event_id = p_event_id AND tier_id IS NOT NULL;
  RETURN jsonb_build_object(
    'seat_count', v_map.seat_count, 'on_sale', v_n,
    'tiers', coalesce((SELECT jsonb_object_agg(id, capacity) FROM public.exos_ticket_tiers
                        WHERE event_id = p_event_id AND seated), '{}'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_set_event_seating(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_event_seating(uuid, uuid, jsonb) TO authenticated, service_role;

-- Block (kills, house seats, camera positions) or unblock seats: owner /
-- manager. Only free seats can be blocked; returns the seats it changed.
CREATE OR REPLACE FUNCTION public.exos_set_seats_blocked(p_event_id uuid, p_seat_ids text[], p_blocked boolean, p_reason text DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org  uuid;
  v_seat text;
  v_done text[] := '{}';
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR (public._exos_seat_client_call()
                       AND NOT public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'seating: owners and managers only' USING ERRCODE = '42501';
  END IF;
  IF coalesce(cardinality(p_seat_ids), 0) = 0 OR cardinality(p_seat_ids) > 500 THEN
    RAISE EXCEPTION 'seating: pick 1-500 seats' USING ERRCODE = '22023';
  END IF;
  FOREACH v_seat IN ARRAY (SELECT array_agg(DISTINCT x) FROM unnest(p_seat_ids) x) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.exos_event_seats WHERE event_id = p_event_id AND seat_id = v_seat) THEN
      CONTINUE;
    END IF;
    IF p_blocked THEN
      PERFORM public._exos_seat_lapse_stale(p_event_id, ARRAY[v_seat]);
      BEGIN
        INSERT INTO public.exos_event_seat_claims (event_id, seat_id, org_id, status, reason, created_by)
        VALUES (p_event_id, v_seat, v_org, 'blocked', left(p_reason, 200), auth.uid());
        v_done := v_done || v_seat;
      EXCEPTION WHEN unique_violation THEN
        NULL;  -- held, sold or already blocked
      END;
    ELSE
      UPDATE public.exos_event_seat_claims SET status = 'released'
       WHERE event_id = p_event_id AND seat_id = v_seat AND status = 'blocked';
      IF FOUND THEN v_done := v_done || v_seat; END IF;
    END IF;
  END LOOP;
  PERFORM public._exos_seat_tier_sync(p_event_id);
  RETURN v_done;
END $$;

-- Held claims whose cart hold is no longer live (released, expired, or still
-- 'active' past expires_at) stop counting: mark them lapsed.
CREATE OR REPLACE FUNCTION public._exos_seat_lapse_stale(p_event_id uuid, p_seat_ids text[])
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_event_seat_claims c SET status = 'lapsed'
   WHERE c.event_id = p_event_id AND c.seat_id = ANY (p_seat_ids) AND c.status = 'held'
     AND NOT EXISTS (SELECT 1 FROM public.exos_cart_holds h
                      WHERE h.id = c.hold_id
                        AND (h.status = 'consumed' OR (h.status = 'active' AND h.expires_at > now())));
$$;
REVOKE ALL ON FUNCTION public._exos_seat_lapse_stale(uuid, text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_set_seats_blocked(uuid, text[], boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_set_seats_blocked(uuid, text[], boolean, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Seat holds: claim the picked seats for a cart hold (exos-checkout, service
--    role, right after exos_create_hold / exos_create_guest_hold).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_hold_seats(p_hold_id uuid, p_seat_ids text[])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  h       public.exos_cart_holds%ROWTYPE;
  v_ids   text[];
  v_seat  text;
  v_taken text[] := '{}';
  v_n     int;
BEGIN
  IF public._exos_seat_client_call() THEN
    RAISE EXCEPTION 'exos_hold_seats: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO h FROM public.exos_cart_holds WHERE id = p_hold_id FOR UPDATE;
  IF NOT FOUND OR h.status <> 'active' OR h.expires_at <= now() THEN
    RAISE EXCEPTION 'exos_hold_seats: the hold is gone; pick your seats again' USING ERRCODE = '23514';
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_ids FROM unnest(p_seat_ids) x WHERE x IS NOT NULL;
  IF coalesce(cardinality(v_ids), 0) <> h.quantity THEN
    RAISE EXCEPTION 'exos_hold_seats: pick % seat(s)', h.quantity USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = h.tier_id AND seated) THEN
    RAISE EXCEPTION 'exos_hold_seats: this ticket type is not sold as seats' USING ERRCODE = '22023';
  END IF;
  SELECT count(*) INTO v_n FROM public.exos_event_seats
   WHERE event_id = h.event_id AND seat_id = ANY (v_ids) AND tier_id = h.tier_id;
  IF v_n <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'exos_hold_seats: those seats aren''t sold as this ticket type' USING ERRCODE = '22023';
  END IF;

  -- A repeat call for the same hold replaces its seats.
  UPDATE public.exos_event_seat_claims SET status = 'released'
   WHERE hold_id = p_hold_id AND status = 'held';
  PERFORM public._exos_seat_lapse_stale(h.event_id, v_ids);

  -- One live claim per seat (unique index): a seat someone else holds, bought
  -- or that is blocked fails here, also when two buyers race for it.
  FOREACH v_seat IN ARRAY v_ids LOOP
    BEGIN
      INSERT INTO public.exos_event_seat_claims (event_id, seat_id, org_id, status, hold_id, created_by)
      VALUES (h.event_id, v_seat, h.org_id, 'held', p_hold_id, h.buyer_uid);
    EXCEPTION WHEN unique_violation THEN
      v_taken := v_taken || v_seat;
    END;
  END LOOP;
  IF cardinality(v_taken) > 0 THEN
    RAISE EXCEPTION 'Sorry, % was just taken by someone else. Pick another seat.',
      (SELECT string_agg(label, ', ' ORDER BY sort) FROM public.exos_event_seats
        WHERE event_id = h.event_id AND seat_id = ANY (v_taken))
      USING ERRCODE = 'XS409', DETAIL = array_to_string(v_taken, ',');
  END IF;

  RETURN jsonb_build_object(
    'hold_id', p_hold_id, 'expires_at', h.expires_at,
    'seats', (SELECT jsonb_agg(jsonb_build_object('id', seat_id, 'section', section, 'row', row_label,
                                                  'number', number, 'label', label) ORDER BY sort)
                FROM public.exos_event_seats WHERE event_id = h.event_id AND seat_id = ANY (v_ids)));
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_seats(uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_hold_seats(uuid, text[]) TO service_role;

-- A hold that is released (checkout failed, buyer started over, fulfillment
-- refused) or expires lets its seats go.
CREATE OR REPLACE FUNCTION public._exos_tg_hold_seat_lapse()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_event_seat_claims SET status = 'lapsed'
   WHERE hold_id = NEW.id AND status = 'held';
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_hold_seat_lapse() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_cart_holds_seat_lapse ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_seat_lapse AFTER UPDATE OF status ON public.exos_cart_holds
  FOR EACH ROW WHEN (NEW.status IN ('released', 'expired') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public._exos_tg_hold_seat_lapse();

-- ---------------------------------------------------------------------------
-- 9. Fulfillment: ticket i gets the hold's seat i, in the minting transaction.
--    Any other insert for a seated tier is refused (seat picker only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_ticket_seat_assign()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fulfil boolean;
  c        public.exos_event_seat_claims%ROWTYPE;
  s        public.exos_event_seats%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = NEW.tier_id AND seated) THEN
    RETURN NEW;
  END IF;
  -- exos_fulfill_checkout sets exos.table_mint to the session it mints.
  v_fulfil := NEW.order_ref IS NOT NULL
              AND coalesce(current_setting('exos.table_mint', true), '') = NEW.order_ref;
  IF NOT v_fulfil OR NOT EXISTS (SELECT 1 FROM public.exos_cart_holds WHERE checkout_session_id = NEW.order_ref) THEN
    IF v_fulfil THEN
      RAISE EXCEPTION 'seats were not held for this order' USING ERRCODE = 'XF001';
    END IF;
    RAISE EXCEPTION 'exos: seats are sold through the seat picker, not as general admission'
      USING ERRCODE = '23514';
  END IF;

  SELECT c0.* INTO c
    FROM public.exos_event_seat_claims c0
    JOIN public.exos_cart_holds h ON h.id = c0.hold_id AND h.checkout_session_id = NEW.order_ref
    JOIN public.exos_event_seats s0 ON s0.event_id = c0.event_id AND s0.seat_id = c0.seat_id
   WHERE c0.event_id = NEW.event_id AND c0.status IN ('held', 'lapsed') AND c0.ticket_id IS NULL
   ORDER BY (c0.status = 'held') DESC, s0.sort
   LIMIT 1
   FOR UPDATE OF c0;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'seats were not held for this order' USING ERRCODE = 'XF001';
  END IF;
  SELECT * INTO s FROM public.exos_event_seats WHERE event_id = c.event_id AND seat_id = c.seat_id;
  BEGIN
    -- A lapsed claim comes back only if nobody took the seat meanwhile.
    UPDATE public.exos_event_seat_claims SET status = 'sold', ticket_id = NEW.id WHERE id = c.id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'seat % was taken while you were paying', s.label USING ERRCODE = 'XF001';
  END;
  NEW.seat_id := s.seat_id;
  NEW.seat_label := s.label;
  NEW.seat_section := s.section;
  NEW.seat_row := s.row_label;
  NEW.seat_number := s.number;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_seat_assign() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_seat_assign ON public.exos_tickets;
CREATE TRIGGER exos_tickets_seat_assign BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.tier_id IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_ticket_seat_assign();

-- A ticket that stops being live (voided / refunded / released / deleted)
-- gives its seat back.
CREATE OR REPLACE FUNCTION public._exos_tg_ticket_seat_release()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_event_seat_claims SET status = 'released'
   WHERE ticket_id = OLD.id AND status = 'sold';
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_ticket_seat_release() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_seat_release ON public.exos_tickets;
CREATE TRIGGER exos_tickets_seat_release AFTER UPDATE OF status ON public.exos_tickets
  FOR EACH ROW WHEN (OLD.seat_id IS NOT NULL AND OLD.status IN ('active', 'used')
                     AND NEW.status NOT IN ('active', 'used'))
  EXECUTE FUNCTION public._exos_tg_ticket_seat_release();
DROP TRIGGER IF EXISTS exos_tickets_seat_release_del ON public.exos_tickets;
CREATE TRIGGER exos_tickets_seat_release_del AFTER DELETE ON public.exos_tickets
  FOR EACH ROW WHEN (OLD.seat_id IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_ticket_seat_release();

-- ---------------------------------------------------------------------------
-- 10. Reads
-- ---------------------------------------------------------------------------
-- Public: the layout of a published event's seat map, and which ticket types
-- are seats. NULL when the event has no seat map (or isn't published).
CREATE OR REPLACE FUNCTION public.exos_public_event_seating(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'map', jsonb_build_object(
             'width', es.map->'width', 'height', es.map->'height', 'stage', es.map->'stage',
             'sections', coalesce((SELECT jsonb_agg(jsonb_build_object(
                           'id', s->'id', 'name', s->'name', 'kind', coalesce(s->'kind', '"seated"'::jsonb),
                           'x', s->'x', 'y', s->'y', 'w', s->'w', 'h', s->'h',
                           'labelX', s->'labelX', 'labelY', s->'labelY',
                           'tier_id', es.levels->(s->>'id')))
                           FROM jsonb_array_elements(es.map->'sections') s), '[]'::jsonb)),
           'seated_tier_ids', coalesce((SELECT jsonb_agg(t.id ORDER BY t.sort_order)
                                          FROM public.exos_ticket_tiers t
                                         WHERE t.event_id = es.event_id AND t.seated), '[]'::jsonb),
           'seat_count', es.seat_count)
    FROM public.exos_event_seating es
    JOIN public.exos_events e ON e.id = es.event_id AND e.status = 'published'
   WHERE es.event_id = p_event_id;
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_seating(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_public_event_seating(uuid) TO anon, authenticated, service_role;

-- Public: every seat of a published event with a plain `available` flag.
-- Nothing about who holds or bought a seat.
CREATE OR REPLACE FUNCTION public.exos_public_event_seats(p_event_id uuid)
RETURNS TABLE (seat_id text, section_id text, section text, row_label text, number text, label text,
               tier_id uuid, x numeric, y numeric, accessible boolean, companion boolean, obstructed boolean,
               available boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT s.seat_id, s.section_id, s.section, s.row_label, s.number, s.label, s.tier_id, s.x, s.y,
         s.accessible, s.companion, s.obstructed,
         s.tier_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.exos_event_seat_claims c
             LEFT JOIN public.exos_cart_holds h ON h.id = c.hold_id
            WHERE c.event_id = s.event_id AND c.seat_id = s.seat_id
              AND (c.status IN ('sold', 'blocked')
                   OR (c.status = 'held' AND (h.status = 'consumed' OR (h.status = 'active' AND h.expires_at > now())))))
    FROM public.exos_event_seats s
    JOIN public.exos_events e ON e.id = s.event_id AND e.status = 'published'
   WHERE s.event_id = p_event_id
   ORDER BY s.sort;
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_seats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_public_event_seats(uuid) TO anon, authenticated, service_role;

-- Staff: full status of every seat (event report, the editor's block mode).
CREATE OR REPLACE FUNCTION public.exos_event_seat_status(p_event_id uuid)
RETURNS TABLE (seat_id text, label text, tier_id uuid, status text, ticket_id uuid, hold_expires_at timestamptz, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR (public._exos_seat_client_call()
                       AND NOT public.exos_has_org_role(v_org, ARRAY['owner','manager','finance','scanner','content'])) THEN
    RAISE EXCEPTION 'seating: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT s.seat_id, s.label, s.tier_id,
         CASE WHEN c.status = 'held' AND NOT (h.status = 'consumed' OR (h.status = 'active' AND h.expires_at > now()))
              THEN 'available' ELSE coalesce(c.status, 'available') END,
         c.ticket_id,
         CASE WHEN c.status = 'held' THEN h.expires_at END,
         c.reason
    FROM public.exos_event_seats s
    LEFT JOIN public.exos_event_seat_claims c
      ON c.event_id = s.event_id AND c.seat_id = s.seat_id AND c.status IN ('held', 'sold', 'blocked')
    LEFT JOIN public.exos_cart_holds h ON h.id = c.hold_id
   WHERE s.event_id = p_event_id
   ORDER BY s.sort;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_seat_status(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_seat_status(uuid) TO authenticated, service_role;

-- Door: the seat of every seated ticket (the door's result card, cached for
-- offline use alongside the roster).
CREATE OR REPLACE FUNCTION public.exos_event_seat_roster(p_event_id uuid)
RETURNS TABLE (ticket_id uuid, seat_label text, seat_section text, seat_row text, seat_number text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public._exos_seat_client_call() AND NOT public.exos_can_door_event(p_event_id) THEN
    RAISE EXCEPTION 'seating: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT t.id, t.seat_label, t.seat_section, t.seat_row, t.seat_number
    FROM public.exos_tickets t
   WHERE t.event_id = p_event_id AND t.seat_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_seat_roster(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_seat_roster(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11. Reconciliation (Opendate's admin seat_reconciliation, for our own
--     claims): sold claims without a live ticket, live seated tickets
--     without their sold claim, and held claims of dead holds.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_seat_reconciliation(p_event_id uuid)
RETURNS TABLE (kind text, seat_id text, label text, ticket_id uuid, claim_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR (public._exos_seat_client_call()
                       AND NOT public.exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'seating: owners and managers only' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT 'claim_without_ticket'::text, c.seat_id, s.label, c.ticket_id, c.id
    FROM public.exos_event_seat_claims c
    JOIN public.exos_event_seats s ON s.event_id = c.event_id AND s.seat_id = c.seat_id
   WHERE c.event_id = p_event_id AND c.status = 'sold'
     AND NOT EXISTS (SELECT 1 FROM public.exos_tickets t
                      WHERE t.id = c.ticket_id AND t.status IN ('active', 'used') AND t.seat_id = c.seat_id)
  UNION ALL
  SELECT 'ticket_without_claim', t.seat_id, t.seat_label, t.id, NULL::uuid
    FROM public.exos_tickets t
   WHERE t.event_id = p_event_id AND t.seat_id IS NOT NULL AND t.status IN ('active', 'used')
     AND NOT EXISTS (SELECT 1 FROM public.exos_event_seat_claims c
                      WHERE c.event_id = t.event_id AND c.seat_id = t.seat_id AND c.status = 'sold' AND c.ticket_id = t.id)
  UNION ALL
  SELECT 'stale_hold', c.seat_id, s.label, NULL::uuid, c.id
    FROM public.exos_event_seat_claims c
    JOIN public.exos_event_seats s ON s.event_id = c.event_id AND s.seat_id = c.seat_id
    LEFT JOIN public.exos_cart_holds h ON h.id = c.hold_id
   WHERE c.event_id = p_event_id AND c.status = 'held'
     AND NOT (coalesce(h.status, '') = 'consumed' OR (h.status = 'active' AND h.expires_at > now()));
END $$;
REVOKE ALL ON FUNCTION public.exos_seat_reconciliation(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_seat_reconciliation(uuid) TO authenticated, service_role;

-- Release orphaned claims (claim_without_ticket / stale_hold). Re-runs the
-- check; the whole call is refused if any seat is held by a live ticket or a
-- live hold.
CREATE OR REPLACE FUNCTION public.exos_release_orphan_seats(p_event_id uuid, p_seat_ids text[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids text[];
  v_bad text;
  v_n   int;
BEGIN
  -- Role check inside the reconciliation.
  SELECT array_agg(r.seat_id) INTO v_ids
    FROM public.exos_seat_reconciliation(p_event_id) r
   WHERE r.kind IN ('claim_without_ticket', 'stale_hold') AND r.seat_id = ANY (p_seat_ids);
  SELECT string_agg(x, ', ') INTO v_bad FROM unnest(p_seat_ids) x WHERE NOT (x = ANY (coalesce(v_ids, '{}')));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'seating: not orphaned: %', v_bad USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_event_seat_claims c SET status = 'released', reason = 'orphan released'
   WHERE c.event_id = p_event_id AND c.seat_id = ANY (v_ids) AND c.status IN ('sold', 'held')
     AND c.id IN (SELECT r.claim_id FROM public.exos_seat_reconciliation(p_event_id) r WHERE r.claim_id IS NOT NULL);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_release_orphan_seats(uuid, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_release_orphan_seats(uuid, text[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 12. Receipt: a "Seats:" line (exos_receipt_html as of 20261027100000 + it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_receipt_html(p_session_id text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce((
    SELECT '<p>Paid: <strong>' || to_char(s.amount_cents / 100.0, 'FM999,999,990.00') || ' ' ||
           upper(coalesce(s.currency, 'usd')) || '</strong>' ||
           CASE WHEN coalesce(s.tax_cents, 0) > 0
                THEN ' (including ' || to_char(s.tax_cents / 100.0, 'FM999,999,990.00') || ' tax)' ELSE '' END ||
           '. Order reference: ' || public.exos_mail_escape(s.session_id) || '.</p>' ||
           coalesce((
             SELECT '<table style="border-collapse:collapse;font-size:14px">' ||
                    string_agg('<tr><td style="padding:2px 12px 2px 0">' || l.quantity || ' &times; ' ||
                               public.exos_mail_escape(coalesce(l.item_name, 'Ticket')) ||
                               '</td><td style="padding:2px 0;text-align:right">' ||
                               to_char(l.line_total_cents / 100.0, 'FM999,999,990.00') || '</td></tr>',
                               '' ORDER BY l.line_no) ||
                    '</table>'
               FROM public.exos_price_disclosure_lines l
              WHERE l.session_id = s.session_id), '') ||
           -- Reserved seating (mig 20261030140000).
           coalesce((
             SELECT '<p>Seat' || CASE WHEN count(*) > 1 THEN 's' ELSE '' END || ': ' ||
                    string_agg(public.exos_mail_escape(t.seat_label), '; ' ORDER BY es.sort, t.seat_label) || '</p>'
               FROM public.exos_tickets t
               LEFT JOIN public.exos_event_seats es ON es.event_id = t.event_id AND es.seat_id = t.seat_id
              WHERE t.order_ref = s.session_id AND t.seat_label IS NOT NULL
             HAVING count(*) > 0), '') ||
           coalesce((
             SELECT '<p style="color:#666;font-size:13px">All-in price: the prices above include ' ||
                    string_agg(to_char(x.amount / 100.0, 'FM999,999,990.00') || ' ' ||
                               public.exos_mail_escape(lower(x.rule_name)), ', ' ORDER BY x.first_id) ||
                    CASE WHEN coalesce(s.tax_cents, 0) > 0 THEN ' and tax' ELSE '' END ||
                    '; nothing was added at checkout.</p>'
               FROM (SELECT left(coalesce(nullif(btrim(f.el->>'name'), ''), 'Fee'), 60) AS rule_name,
                            sum((f.el->>'amount_cents')::int) AS amount, min(f.ord) AS first_id
                       FROM jsonb_array_elements(coalesce((
                              SELECT fs.lines FROM public.exos_checkout_fee_snapshots fs
                               WHERE fs.session_id = s.session_id), '[]'::jsonb))
                              WITH ORDINALITY AS f(el, ord)
                      WHERE f.el->>'kind' = 'passed_on' AND (f.el->>'amount_cents') ~ '^[0-9]{1,9}$'
                      GROUP BY 1) x
             HAVING count(*) > 0),
             '<p style="color:#666;font-size:13px">All-in price: no fees were added at checkout' ||
             CASE WHEN coalesce(s.tax_cents, 0) > 0 THEN ' and tax is included' ELSE '' END || '.</p>') ||
           CASE WHEN EXISTS (SELECT 1 FROM public.exos_tickets t
                              WHERE t.order_ref = s.session_id AND t.pending_transfer_id IS NOT NULL)
                THEN ''
                ELSE '<p><a href="{{app_url}}/my-tickets">View your tickets</a></p>' END
      FROM public.exos_checkout_sessions s
     WHERE s.session_id = p_session_id AND coalesce(s.amount_cents, 0) > 0), '');
$function$;

-- ---------------------------------------------------------------------------
-- 13. Wallet payload: ticket.seat (_exos_wallet_payload as of 20260929072000
--     + the seat object; NULL for general admission).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_wallet_payload(p_serial text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'serial',        w.serial_number,
    'pass_type',     w.pass_type_identifier,
    'status',        w.status,
    'void_reason',   w.void_reason,
    'code_epoch',    w.code_epoch,
    'updated_at',    w.updated_at,
    'ticket', jsonb_build_object(
      'id', t.id, 'status', t.status, 'tier_name', coalesce(tt.name, t.tier_name),
      'section_label', tt.section_label, 'attendee_name', t.attendee_name,
      'in_transfer', t.pending_transfer_id IS NOT NULL, 'check_in_at', t.check_in_at,
      'seat', CASE WHEN t.seat_id IS NOT NULL THEN jsonb_build_object(
                'section', t.seat_section, 'row', t.seat_row, 'number', t.seat_number, 'label', t.seat_label) END),
    'event', jsonb_build_object(
      'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
      'doors_at', e.doors_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
      'venue_location', e.venue_location, 'lat', CASE WHEN e.format = 'online' THEN NULL ELSE g.lat END,
      'lng', CASE WHEN e.format = 'online' THEN NULL ELSE g.lng END, 'format', e.format),
    'org_name',      o.name,
    'apple_code',    CASE WHEN w.status = 'active' AND t.status IN ('active', 'used') AND t.owner_id = w.owner_id
                          THEN public._exos_wallet_apple_code(t.id, w.owner_id, t.barcode_secret, w.code_epoch) END,
    'google_key_hex', CASE WHEN w.status = 'active' AND t.status IN ('active', 'used') AND t.owner_id = w.owner_id
                          THEN encode(public._exos_wallet_google_key(t.id, w.owner_id, t.barcode_secret, w.code_epoch), 'hex') END,
    'google_pattern', 'W-' || t.id || ':' || w.owner_id || ':g' || w.code_epoch || ':{totp_value_0}')
    FROM public.exos_wallet_passes w
    JOIN public.exos_tickets t ON t.id = w.ticket_id
    JOIN public.exos_events  e ON e.id = t.event_id
    LEFT JOIN public.exos_ticket_tiers tt ON tt.id = t.tier_id
    LEFT JOIN public.exos_orgs o ON o.id = t.org_id
    LEFT JOIN public.exos_event_geo g ON g.event_id = e.id
   WHERE w.serial_number = p_serial;
$function$;
REVOKE ALL ON FUNCTION public._exos_wallet_payload(text) FROM PUBLIC, anon, authenticated;
