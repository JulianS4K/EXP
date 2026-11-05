-- ============================================================================
-- Promoter-run events with no venue on Exos: org type, event location modes
-- (venue record, unlisted venue, secret location, to be announced), the
-- secret address revealed to ticket holders, capacity required (2026-11-05).
-- docs/promoter-events.md.
-- ============================================================================
-- Operator decision (Julian): a promoter or collective creates and sells its
-- own events with no venue organization on Exos: venues not on Exos,
-- pop-ups, warehouses, secret locations. They get their own event pages and
-- checkout.
--
-- Touches:  W: TABLE exos_orgs (+ org_type: organizer | promoter | collective;
--              a label and UI defaults, never a permission)
--           C: FUNCTION exos_org_type_set (authenticated: the org owner)
--           W: TABLE exos_events (+ location_mode, location_reveal_at,
--              tba_allow_sales; SELECT granted to anon / authenticated, no
--              client write grant: writes go through exos_event_location_set)
--           C: TABLE exos_event_secret_locations (the exact address of a
--              secret_location event; RLS: org staff and the event's door
--              staff read; no client writes)
--           C: TABLE exos_event_location_notices (reveal / announcement mail
--              runs; RLS: owner, manager, content read)
--           C: FUNCTION _exos_location_reveal_at, _exos_location_blockers_row,
--              _exos_location_blockers, _exos_event_location_json,
--              _exos_event_location_for_ticket, _exos_event_location_set,
--              _exos_location_venue_matches, _exos_event_location_holders,
--              _exos_location_notice_send (service role: exos-api, cron),
--              triggers _exos_tg_event_location, _exos_tg_event_location_after,
--              _exos_tg_secret_location, _exos_tg_event_geo_location,
--              _exos_tg_tier_capacity_location, _exos_tg_cart_holds_location
--           C: FUNCTION exos_event_location_set (authenticated: owner /
--              manager), exos_event_location (authenticated: staff, ticket
--              holders, anyone for a published event's public part),
--              exos_ticket_link_location (anon: the ticket's 256-bit link
--              key), exos_location_venue_matches (authenticated: owner /
--              manager / content)
--           C: FUNCTION exos_send_location_notices (service role; cron
--              exos-location-notices-5min, created INACTIVE)
--           W: VIEW exos_public_event_geo (wrapped: never a secret_location or
--              tba event's pin); exos_public_events (+ the three location
--              columns, when the view exists)
--           W: FUNCTION _exos_event_publish_blockers (patched: missing_venue
--              skips tba / secret_location; the location blockers and
--              capacity_required appended)
--           W: FUNCTION exos_api_write (patched: event create / update take
--              location_mode, location_reveal_at, tba_allow_sales and a
--              secret_location object), _exos_api_event_json (+ location)
--           W: FUNCTION _exos_wallet_payload (+ location: the address once
--              revealed to that ticket)
--           W: FUNCTION exos_claim_free_tickets (patched: refused for a tba
--              event that isn't selling yet)
--           W: TABLE exos_mail (template allowlist + location-announced,
--              location-revealed)
-- Pre-reqs: 20261104180000 (org access: venue gate, venue directory),
--           20261031110000 (publish blockers, API writes),
--           20260924230000 (event geo), 20261029072000 / 20260929072000
--           (wallet), 20261016120000 (SMS), 20261016100000 (cart hold gate)
--
-- Location modes (exos_events.location_mode):
--   venue_record     today's behaviour, unchanged: the event may link one of
--                    the org's venue records (exos_venue_id, venue gate as in
--                    20261104180000) and carries free-text labels. Every
--                    existing event is this (the column default).
--   unlisted_venue   a venue that isn't on Exos: free-text name and address
--                    (public), never linked to a venue record. Not gated: a
--                    name + city that matches an owned venue on Exos taking
--                    requests is only a suggestion ("this venue is on Exos;
--                    request to book?"), never a link and never a refusal
--                    (the anti-squatting rule of 20261104180000).
--   secret_location  the public page shows the area (venue_location) only.
--                    The exact address lives in exos_event_secret_locations,
--                    never in exos_events: venue_name / venue_address are
--                    forced empty, so no public view, feed, partner or API
--                    path that reads exos_events can carry it. Ticket holders
--                    get it from location_reveal_at (always by the start):
--                    on the ticket page, by mail / SMS and in the wallet pass.
--   tba              the location is to be announced. tba_allow_sales is the
--                    organizer's explicit choice (publish blocker while NULL);
--                    false = published but not on sale (cart holds and free
--                    claims refuse). When the location is set, ticket holders
--                    are mailed.
-- No pin is ever stored for a secret_location or tba event (the geo row is
-- dropped and later writes skipped), so nothing maps or geocodes more than
-- the public text.
--
-- Capacity: an event in one of the three promoter modes needs a capacity on
-- every ticket type it sells on Exos (capacity 0 means unlimited): a publish
-- blocker, and refused on a published event.
--
-- The reveal is computed at read time (now() >= least(location_reveal_at,
-- starts_at)); the cron only sends the mail / SMS and refreshes wallet passes.
--
-- Errors: 22023 bad input (including "location: ..." when a published event
-- would break a location rule), 42501 not allowed, P0002 not found. Additive
-- only; re-run safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked patches
-- with pg_temp.exos_patch_n). The one anon function is link-key gated.
-- Prod apply needs operator OK.
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
-- 1. Org type: a label plus UI defaults
-- ===========================================================================
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS org_type text NOT NULL DEFAULT 'organizer';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_orgs_org_type_chk') THEN
    ALTER TABLE public.exos_orgs ADD CONSTRAINT exos_orgs_org_type_chk
      CHECK (org_type IN ('organizer', 'promoter', 'collective'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_orgs.org_type IS
  'mig 20261105130000: organizer (default) | promoter | collective (runs events with no venue of its own). A label and UI defaults only (hides venue-management screens, default location mode); no permission ever reads it.';
GRANT SELECT (org_type) ON public.exos_orgs TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_org_type_set(p_org_id uuid, p_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'exos_org_type_set: the organization''s owner only' USING ERRCODE = '42501';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('organizer', 'promoter', 'collective') THEN
    RAISE EXCEPTION 'exos_org_type_set: type is organizer, promoter or collective' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_orgs SET org_type = p_type WHERE id = p_org_id;
  RETURN jsonb_build_object('org_id', p_org_id, 'org_type', p_type);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_type_set(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_type_set(uuid, text) TO authenticated;

-- ===========================================================================
-- 2. Event location columns
-- ===========================================================================
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS location_mode text NOT NULL DEFAULT 'venue_record';
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS location_reveal_at timestamptz;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS tba_allow_sales boolean;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_location_mode_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_location_mode_chk
      CHECK (location_mode IN ('venue_record', 'unlisted_venue', 'secret_location', 'tba'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_events.location_mode IS
  'mig 20261105130000: venue_record (default, today) | unlisted_venue (free text, not on Exos) | secret_location (public area in venue_location; the address is in exos_event_secret_locations) | tba. docs/promoter-events.md.';
COMMENT ON COLUMN public.exos_events.location_reveal_at IS
  'mig 20261105130000: secret_location only: when ticket holders get the address (public; the reveal is always by starts_at).';
COMMENT ON COLUMN public.exos_events.tba_allow_sales IS
  'mig 20261105130000: tba only: the organizer''s explicit choice to sell before the location is announced (NULL = not chosen, a publish blocker).';
-- Public facts (the event page shows them). Writes: exos_event_location_set.
GRANT SELECT (location_mode, location_reveal_at, tba_allow_sales) ON public.exos_events TO anon, authenticated;

-- The public view carries them, when it exists (prod; the SQL harness has none).
DO $$
DECLARE d text; opts text; i int;
BEGIN
  IF to_regclass('public.exos_public_events') IS NULL THEN
    RAISE NOTICE 'exos_public_events: view not present here, skipping';
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_events'::regclass);
  IF position('location_mode' in d) > 0 THEN
    RAISE NOTICE 'exos_public_events: already has the location columns, skipping';
    RETURN;
  END IF;
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_events: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    location_mode,
    location_reveal_at,
    tba_allow_sales' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_events'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_events%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_events TO anon, authenticated;
END $$;

-- ===========================================================================
-- 3. The secret address and the notice log
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_secret_locations (
  event_id          uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  venue_name        text CHECK (venue_name IS NULL OR char_length(venue_name) BETWEEN 1 AND 200),
  -- { street, city, region, postal, country } like exos_events.venue_address;
  -- street is required (it is the exact address).
  address           jsonb NOT NULL CHECK (jsonb_typeof(address) = 'object' AND octet_length(address::text) <= 2000
                                          AND btrim(coalesce(address ->> 'street', '')) <> ''),
  directions        text CHECK (directions IS NULL OR char_length(directions) <= 1000),
  version           integer NOT NULL DEFAULT 1,
  notified_version  integer NOT NULL DEFAULT 0,
  notified_at       timestamptz,
  updated_by        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_secret_locations_org_idx ON public.exos_event_secret_locations (org_id);
ALTER TABLE public.exos_event_secret_locations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_secret_locations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_secret_locations TO authenticated;
GRANT ALL ON public.exos_event_secret_locations TO service_role;
DROP POLICY IF EXISTS exos_event_secret_locations_staff_read ON public.exos_event_secret_locations;
CREATE POLICY exos_event_secret_locations_staff_read ON public.exos_event_secret_locations
  FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance'])
         OR public.exos_can_door_event(event_id));
COMMENT ON TABLE public.exos_event_secret_locations IS
  'mig 20261105130000: a secret_location event''s exact address. Org staff and the event''s door staff read it; ticket holders get it through exos_event_location / exos_ticket_link_location / the wallet pass / the reveal mail once revealed. Never in exos_events or any public path. Writes: exos_event_location_set.';

CREATE TABLE IF NOT EXISTS public.exos_event_location_notices (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('announced', 'revealed')),
  version     integer NOT NULL,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'skipped')),
  mailed      integer NOT NULL DEFAULT 0,
  texted      integer NOT NULL DEFAULT 0,
  passes      integer NOT NULL DEFAULT 0,
  note        text CHECK (note IS NULL OR char_length(note) <= 200),
  sent_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, kind, version)
);
CREATE INDEX IF NOT EXISTS exos_event_location_notices_pending_idx
  ON public.exos_event_location_notices (created_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS exos_event_location_notices_org_idx ON public.exos_event_location_notices (org_id);
ALTER TABLE public.exos_event_location_notices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_event_location_notices FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_event_location_notices TO authenticated;
GRANT ALL ON public.exos_event_location_notices TO service_role;
DROP POLICY IF EXISTS exos_event_location_notices_staff_read ON public.exos_event_location_notices;
CREATE POLICY exos_event_location_notices_staff_read ON public.exos_event_location_notices
  FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
COMMENT ON TABLE public.exos_event_location_notices IS
  'mig 20261105130000: one row per location mail run (announced: a tba event''s location was set; revealed: a secret address reached its reveal time, or changed after it). Written by triggers and exos_send_location_notices only.';

DROP TRIGGER IF EXISTS exos_event_secret_locations_touch ON public.exos_event_secret_locations;
CREATE TRIGGER exos_event_secret_locations_touch BEFORE UPDATE ON public.exos_event_secret_locations
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_event_location_notices_touch ON public.exos_event_location_notices;
CREATE TRIGGER exos_event_location_notices_touch BEFORE UPDATE ON public.exos_event_location_notices
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 4. Rules: reveal time, blockers, the location trigger
-- ===========================================================================

-- When ticket holders get a secret address: the reveal time, and never later
-- than the start.
CREATE OR REPLACE FUNCTION public._exos_location_reveal_at(p_reveal timestamptz, p_starts timestamptz)
RETURNS timestamptz LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_reveal IS NULL THEN p_starts
              WHEN p_starts IS NULL THEN p_reveal
              ELSE least(p_reveal, p_starts) END
$$;
REVOKE ALL ON FUNCTION public._exos_location_reveal_at(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_reveal_at(timestamptz, timestamptz) TO service_role;

-- What stops this event row (as it is, or is about to be) from going live
-- because of its location mode or an unlimited ticket type. Read by the
-- publish blockers and by the trigger that refuses a published row breaking
-- them. Mirrors src/lib/eventLocation.ts locationBlockers.
CREATE OR REPLACE FUNCTION public._exos_location_blockers_row(e public.exos_events, p_capacity boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_out  jsonb := '[]'::jsonb;
  s      public.exos_event_secret_locations%ROWTYPE;
  v_fmt  text := coalesce(to_jsonb(e) ->> 'format', 'in_person');
  v_back text := coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos');
BEGIN
  IF v_fmt <> 'online' THEN
    IF e.location_mode = 'unlisted_venue'
       AND btrim(coalesce(e.venue_address ->> 'street', '')) = '' AND btrim(coalesce(e.venue_address ->> 'city', '')) = '' THEN
      v_out := v_out || jsonb_build_object('code', 'missing_venue_address', 'field', 'venue_address',
        'message', 'Add the venue''s address (street and city).');
    END IF;
    IF e.location_mode = 'secret_location' THEN
      IF btrim(coalesce(e.venue_location, '')) = '' THEN
        v_out := v_out || jsonb_build_object('code', 'missing_location_area', 'field', 'venue_location',
          'message', 'Add the area or neighbourhood shown on the event page (the exact address stays private).');
      END IF;
      SELECT * INTO s FROM public.exos_event_secret_locations WHERE event_id = e.id;
      IF s.event_id IS NULL THEN
        v_out := v_out || jsonb_build_object('code', 'missing_secret_address', 'field', 'secret_location',
          'message', 'Add the exact address ticket holders get at the reveal.');
      END IF;
      IF e.location_reveal_at IS NULL THEN
        v_out := v_out || jsonb_build_object('code', 'missing_reveal_time', 'field', 'location_reveal_at',
          'message', 'Pick when ticket holders get the address.');
      ELSIF e.starts_at IS NOT NULL AND e.location_reveal_at >= e.starts_at THEN
        v_out := v_out || jsonb_build_object('code', 'reveal_after_start', 'field', 'location_reveal_at',
          'message', 'The address has to be revealed before the event starts.');
      END IF;
    END IF;
    IF e.location_mode = 'tba' AND e.tba_allow_sales IS NULL THEN
      v_out := v_out || jsonb_build_object('code', 'tba_sales_choice', 'field', 'tba_allow_sales',
        'message', 'Choose whether tickets go on sale before the location is announced.');
    END IF;
  END IF;
  -- Operator rule: no unlimited capacity on a promoter-run event.
  IF p_capacity AND e.location_mode <> 'venue_record' AND v_back = 'exos'
     AND EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.event_id = e.id AND coalesce(t.capacity, 0) <= 0) THEN
    v_out := v_out || jsonb_build_object('code', 'capacity_required', 'field', 'ticket_types',
      'message', 'Give every ticket type a capacity (events without a venue on Exos can''t be unlimited).');
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._exos_location_blockers_row(public.exos_events, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_blockers_row(public.exos_events, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_location_blockers(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  RETURN public._exos_location_blockers_row(e, true);
END $$;
REVOKE ALL ON FUNCTION public._exos_location_blockers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_blockers(uuid) TO service_role;

-- The location trigger (BEFORE INSERT / UPDATE on exos_events):
--   * secret_location / tba: venue_name and venue_address are public, so the
--     row never carries them (an explicit value is refused; one carried over
--     from the previous mode is cleared). No venue record either.
--   * unlisted_venue: no venue record (refused when set, cleared when
--     carried over). Not gated: it is free text.
--   * location_reveal_at only means something for secret_location.
--   * A published row that would break a location rule is refused: going
--     live, or changing the location while live (a reschedule alone never
--     is: the reveal is always by the start).
CREATE OR REPLACE FUNCTION public._exos_tg_event_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ins   boolean := TG_OP = 'INSERT';
  v_block jsonb;
  v_check boolean;
BEGIN
  IF NEW.location_mode IN ('secret_location', 'tba') THEN
    IF NEW.venue_name IS NOT NULL AND (v_ins OR NEW.venue_name IS DISTINCT FROM OLD.venue_name)
       AND btrim(NEW.venue_name) <> '' THEN
      RAISE EXCEPTION 'location: a % event keeps venue_name empty (it is public); put the area in venue_location%',
        NEW.location_mode, CASE WHEN NEW.location_mode = 'secret_location' THEN ' and the place in secret_location' ELSE '' END
        USING ERRCODE = '22023';
    END IF;
    IF NEW.venue_address IS NOT NULL AND (v_ins OR NEW.venue_address IS DISTINCT FROM OLD.venue_address)
       AND NEW.venue_address <> '{}'::jsonb AND NEW.venue_address <> 'null'::jsonb THEN
      RAISE EXCEPTION 'location: a % event keeps venue_address empty (it is public)%',
        NEW.location_mode, CASE WHEN NEW.location_mode = 'secret_location' THEN '; the exact address goes in secret_location' ELSE '' END
        USING ERRCODE = '22023';
    END IF;
    NEW.venue_name := NULL;
    NEW.venue_address := NULL;
  END IF;
  IF NEW.location_mode <> 'venue_record' THEN
    IF NEW.exos_venue_id IS NOT NULL AND (v_ins OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id) THEN
      RAISE EXCEPTION 'location: a % event isn''t linked to a venue record (use location_mode venue_record for that)',
        NEW.location_mode USING ERRCODE = '22023';
    END IF;
    NEW.exos_venue_id := NULL;
    NEW.exos_room_id := NULL;
  END IF;
  IF NEW.location_mode <> 'secret_location' THEN
    NEW.location_reveal_at := NULL;
  END IF;
  IF NEW.location_mode <> 'tba' THEN
    NEW.tba_allow_sales := NULL;
  END IF;

  IF NEW.status = 'published' THEN
    v_check := v_ins OR OLD.status IS DISTINCT FROM 'published'
      OR NEW.location_mode IS DISTINCT FROM OLD.location_mode
      OR NEW.location_reveal_at IS DISTINCT FROM OLD.location_reveal_at
      OR NEW.tba_allow_sales IS DISTINCT FROM OLD.tba_allow_sales
      OR NEW.venue_location IS DISTINCT FROM OLD.venue_location
      OR NEW.venue_address IS DISTINCT FROM OLD.venue_address;
    IF v_check THEN
      -- Capacity only when going live or entering a promoter mode.
      v_block := public._exos_location_blockers_row(NEW,
        v_ins OR OLD.status IS DISTINCT FROM 'published' OR NEW.location_mode IS DISTINCT FROM OLD.location_mode);
      -- A reschedule that moved the start before the reveal is not this
      -- write's doing: the reveal is by the start anyway.
      IF NOT v_ins AND OLD.status = 'published' AND NEW.location_reveal_at IS NOT DISTINCT FROM OLD.location_reveal_at THEN
        v_block := coalesce((SELECT jsonb_agg(b) FROM jsonb_array_elements(v_block) b
                              WHERE b ->> 'code' <> 'reveal_after_start'), '[]'::jsonb);
      END IF;
      IF jsonb_array_length(v_block) > 0 THEN
        RAISE EXCEPTION 'location: %', (SELECT string_agg(b ->> 'message', ' ') FROM jsonb_array_elements(v_block) b)
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_location() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_location_mode ON public.exos_events;
CREATE TRIGGER exos_events_location_mode BEFORE INSERT OR UPDATE ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_location();

-- After a change: drop the pin of an event whose location isn't public, and
-- queue the "location announced" mail when a live tba event gets one.
CREATE OR REPLACE FUNCTION public._exos_tg_event_location_after()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.location_mode IN ('secret_location', 'tba') THEN
    DELETE FROM public.exos_event_geo WHERE event_id = NEW.id;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.location_mode = 'tba' AND NEW.location_mode <> 'tba' AND NEW.status = 'published' THEN
    INSERT INTO public.exos_event_location_notices (org_id, event_id, kind, version)
    VALUES (NEW.org_id, NEW.id, 'announced',
            1 + (SELECT count(*) FROM public.exos_event_location_notices n
                  WHERE n.event_id = NEW.id AND n.kind = 'announced'))
    ON CONFLICT (event_id, kind, version) DO NOTHING;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_location_after() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_location_after ON public.exos_events;
CREATE TRIGGER exos_events_location_after AFTER INSERT OR UPDATE OF location_mode, status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_location_after();

-- Never store a pin for a secret_location / tba event (a geocode already in
-- flight when the mode changed is dropped here).
CREATE OR REPLACE FUNCTION public._exos_tg_event_geo_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_events e
              WHERE e.id = NEW.event_id AND e.location_mode IN ('secret_location', 'tba')) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_geo_location() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_geo_location ON public.exos_event_geo;
CREATE TRIGGER exos_event_geo_location BEFORE INSERT OR UPDATE ON public.exos_event_geo
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_geo_location();

-- And the public pin view leaves them out too (wrapped, so whatever its
-- current definition is stays as it is).
DO $$
DECLARE d text; opts text;
BEGIN
  IF to_regclass('public.exos_public_event_geo') IS NULL THEN RETURN; END IF;
  d := pg_get_viewdef('public.exos_public_event_geo'::regclass);
  IF position('location_mode' in d) > 0 THEN
    RAISE NOTICE 'exos_public_event_geo: already filters the location modes, skipping';
    RETURN;
  END IF;
  d := rtrim(btrim(d), ';');
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_event_geo'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_event_geo%s AS SELECT q.* FROM (%s) q '
                 'WHERE NOT EXISTS (SELECT 1 FROM public.exos_events le WHERE le.id = q.event_id '
                 'AND le.location_mode IN (''secret_location'', ''tba''))', opts, d);
  REVOKE ALL ON public.exos_public_event_geo FROM PUBLIC, anon, authenticated;
  GRANT SELECT ON public.exos_public_event_geo TO anon, authenticated, service_role;
END $$;
-- Pins dropped for events already in those modes (none before this migration).
DELETE FROM public.exos_event_geo g USING public.exos_events e
 WHERE e.id = g.event_id AND e.location_mode IN ('secret_location', 'tba');

-- The secret row: its org is the event's; a content change bumps the
-- version (holders who already had it get the new one); a live secret event
-- keeps one.
CREATE OR REPLACE FUNCTION public._exos_tg_secret_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE e public.exos_events%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO e FROM public.exos_events WHERE id = OLD.event_id;
    IF e.id IS NOT NULL AND e.status = 'published' AND e.location_mode = 'secret_location' THEN
      RAISE EXCEPTION 'location: a live secret-location event keeps its address (change it, or change the location mode first)'
        USING ERRCODE = '22023';
    END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = NEW.event_id;
  IF e.id IS NULL THEN RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002'; END IF;
  NEW.org_id := e.org_id;
  IF TG_OP = 'UPDATE' THEN
    NEW.created_at := OLD.created_at;
    IF NEW.venue_name IS DISTINCT FROM OLD.venue_name OR NEW.address IS DISTINCT FROM OLD.address
       OR NEW.directions IS DISTINCT FROM OLD.directions THEN
      NEW.version := OLD.version + 1;
    ELSE
      NEW.version := OLD.version;
    END IF;
  ELSE
    NEW.version := 1;
    NEW.notified_version := 0;
    NEW.notified_at := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_secret_location() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_secret_locations_guard ON public.exos_event_secret_locations;
CREATE TRIGGER exos_event_secret_locations_guard BEFORE INSERT OR UPDATE OR DELETE ON public.exos_event_secret_locations
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_secret_location();

-- Capacity on a live promoter-run event: never unlimited.
CREATE OR REPLACE FUNCTION public._exos_tg_tier_capacity_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF coalesce(NEW.capacity, 0) <= 0 AND EXISTS (
       SELECT 1 FROM public.exos_events e
        WHERE e.id = NEW.event_id AND e.status = 'published' AND e.location_mode <> 'venue_record'
          AND coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos') = 'exos') THEN
    RAISE EXCEPTION 'capacity_required: every ticket type of this event needs a capacity (it has no venue on Exos, so it can''t be unlimited)'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_tier_capacity_location() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_ticket_tiers_location_capacity ON public.exos_ticket_tiers;
CREATE TRIGGER exos_ticket_tiers_location_capacity BEFORE INSERT OR UPDATE OF capacity ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_tier_capacity_location();

-- A tba event the organizer isn't selling yet: Exos's own sale paths refuse
-- it (checkout and partner reservations take cart holds; free claims below).
CREATE OR REPLACE FUNCTION public._exos_tg_cart_holds_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_events e
              WHERE e.id = NEW.event_id AND e.location_mode = 'tba' AND e.tba_allow_sales IS NOT TRUE) THEN
    RAISE EXCEPTION 'tickets for this event go on sale once the location is announced' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_cart_holds_location() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_cart_holds_location ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_location BEFORE INSERT ON public.exos_cart_holds
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_cart_holds_location();

SELECT pg_temp.exos_patch_n(
  (SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'exos_claim_free_tickets' ORDER BY p.oid DESC LIMIT 1),
  'exos:location-tba',
  $o$  -- exos:ticket-backend: another platform sells this event.$o$,
  $n$  -- exos:location-tba (mig 20261105130000): not on sale until the location is announced.
  IF EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND location_mode = 'tba' AND tba_allow_sales IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tickets go on sale once the location is announced' USING ERRCODE = '42501';
  END IF;
  -- exos:ticket-backend: another platform sells this event.$n$, 1);

-- ---- Publish blockers ------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_event_publish_blockers(uuid)',
  '/* exos: location modes */',
  $o$IF v_fmt <> 'online' AND$o$,
  $n$IF v_fmt <> 'online' AND coalesce(to_jsonb(e) ->> 'location_mode', 'venue_record') NOT IN ('tba', 'secret_location') /* exos: location modes */ AND$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_event_publish_blockers(uuid)',
  '/* exos: location blockers */',
  $o$  RETURN v_out;$o$,
  $n$  v_out := v_out || public._exos_location_blockers(p_event_id);   /* exos: location blockers */ -- mig 20261105130000
  RETURN v_out;$n$, 1);

-- ===========================================================================
-- 5. Reading a location: the public part, staff, ticket holders
-- ===========================================================================

-- The event's location as a staff member (p_secret) or the public sees it.
-- The public part never has the secret address: venue_name / venue_address
-- are empty for secret_location and tba (the trigger above), and the secret
-- row is only read when p_secret.
CREATE OR REPLACE FUNCTION public._exos_event_location_json(p_event_id uuid, p_secret boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  e      public.exos_events%ROWTYPE;
  s      public.exos_event_secret_locations%ROWTYPE;
  v_rev  timestamptz;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_rev := CASE WHEN e.location_mode = 'secret_location' THEN public._exos_location_reveal_at(e.location_reveal_at, e.starts_at) END;
  IF p_secret THEN
    SELECT * INTO s FROM public.exos_event_secret_locations WHERE event_id = e.id;
  END IF;
  RETURN jsonb_build_object(
    'event_id', e.id,
    'location_mode', e.location_mode,
    'venue_name', e.venue_name,
    'venue_location', e.venue_location,
    'venue_address', e.venue_address,
    'exos_venue_id', e.exos_venue_id,
    'location_reveal_at', e.location_reveal_at,
    'reveal_at', v_rev,
    'revealed', v_rev IS NOT NULL AND now() >= v_rev,
    'tba_allow_sales', e.tba_allow_sales,
    'sales_open', NOT (e.location_mode = 'tba' AND e.tba_allow_sales IS NOT TRUE),
    'has_secret', CASE WHEN p_secret THEN s.event_id IS NOT NULL END,
    'secret_location', CASE WHEN p_secret AND s.event_id IS NOT NULL THEN jsonb_build_object(
      'venue_name', s.venue_name, 'address', s.address, 'directions', s.directions,
      'version', s.version, 'notified_version', s.notified_version, 'notified_at', s.notified_at,
      'updated_at', s.updated_at) END);
END $$;
REVOKE ALL ON FUNCTION public._exos_event_location_json(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_location_json(uuid, boolean) TO service_role;

-- What one ticket's holder sees: the public part, plus the secret address
-- once revealed (an active or used ticket of a secret_location event).
CREATE OR REPLACE FUNCTION public._exos_event_location_for_ticket(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  t     record;
  v     jsonb;
  s     public.exos_event_secret_locations%ROWTYPE;
BEGIN
  SELECT id, event_id, status INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  v := public._exos_event_location_json(t.event_id, false);
  IF v IS NULL THEN RETURN NULL; END IF;
  IF v ->> 'location_mode' = 'secret_location' AND (v ->> 'revealed')::boolean AND t.status IN ('active', 'used') THEN
    SELECT * INTO s FROM public.exos_event_secret_locations WHERE event_id = t.event_id;
    IF s.event_id IS NOT NULL THEN
      v := v || jsonb_build_object('secret_location', jsonb_build_object(
        'venue_name', s.venue_name, 'address', s.address, 'directions', s.directions, 'updated_at', s.updated_at));
    END IF;
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_location_for_ticket(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_location_for_ticket(uuid) TO service_role;

-- Signed in: org staff (and the event's door staff) see everything; a
-- ticket holder sees the address once revealed; anyone else sees a
-- published event's public part only.
CREATE OR REPLACE FUNCTION public.exos_event_location(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  e    public.exos_events%ROWTYPE;
  v_t  uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002'; END IF;
  IF public.exos_has_org_role(e.org_id, ARRAY['owner', 'manager', 'content', 'finance'])
     OR public.exos_can_door_event(e.id) THEN
    RETURN public._exos_event_location_json(e.id, true) || jsonb_build_object('viewer', 'staff');
  END IF;
  IF e.status NOT IN ('published', 'cancelled') THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT t.id INTO v_t FROM public.exos_tickets t
   WHERE t.event_id = e.id AND t.owner_id = auth.uid() AND t.status IN ('active', 'used')
   ORDER BY t.created_at LIMIT 1;
  IF v_t IS NOT NULL THEN
    RETURN public._exos_event_location_for_ticket(v_t) || jsonb_build_object('viewer', 'holder');
  END IF;
  RETURN public._exos_event_location_json(e.id, false) || jsonb_build_object('viewer', 'public');
END $$;
REVOKE ALL ON FUNCTION public.exos_event_location(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_location(uuid) TO authenticated;

-- A ticket's live link (no account): the same 256-bit key as
-- exos_ticket_link_view; a wrong key and an unknown ticket answer alike.
CREATE OR REPLACE FUNCTION public.exos_ticket_link_location(p_ticket_id uuid, p_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t record;
BEGIN
  IF p_ticket_id IS NULL OR p_key IS NULL OR p_key !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT id, owner_id, barcode_secret INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL OR t.owner_id IS NULL OR t.barcode_secret IS NULL
     OR public._exos_ticket_link_key(t.id, t.owner_id, t.barcode_secret) IS DISTINCT FROM p_key THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  RETURN jsonb_build_object('ok', true) || coalesce(public._exos_event_location_for_ticket(t.id), '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_ticket_link_location(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ticket_link_location(uuid, text) TO anon, authenticated;

-- ===========================================================================
-- 6. "This venue is on Exos": a suggestion, never a link or a refusal
-- ===========================================================================
-- Owned venues of other orgs that take requests, with the same name and
-- city (case and spaces aside) as a free-text venue. Same candidates as the
-- directory shows anyone; all of them, with `verified`.
CREATE OR REPLACE FUNCTION public._exos_location_venue_matches(p_org uuid, p_name text, p_city text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'venue_id', v.id, 'name', v.name, 'city', v.address ->> 'city', 'region', v.address ->> 'region',
           'verified', v.verified, 'org', jsonb_build_object('id', o.id, 'name', o.name),
           'request_endpoint', 'POST /v1/venue-requests') ORDER BY v.verified DESC, o.name, v.id), '[]'::jsonb)
    FROM public.exos_venues v JOIN public.exos_orgs o ON o.id = v.org_id
   WHERE btrim(coalesce(p_name, '')) <> '' AND btrim(coalesce(p_city, '')) <> ''
     AND v.relationship = 'owned' AND v.accepts_requests AND v.org_id IS DISTINCT FROM p_org
     AND lower(btrim(v.name)) = lower(btrim(p_name))
     AND lower(btrim(coalesce(v.address ->> 'city', ''))) = lower(btrim(p_city))
$$;
REVOKE ALL ON FUNCTION public._exos_location_venue_matches(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_venue_matches(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_location_venue_matches(p_org_id uuid, p_name text, p_city text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'content']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_location_venue_matches(p_org_id, left(p_name, 200), left(p_city, 120));
END $$;
REVOKE ALL ON FUNCTION public.exos_location_venue_matches(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_location_venue_matches(uuid, text, text) TO authenticated;

-- The suggestions for an event as saved: its unlisted venue, or its secret
-- place (name + city).
CREATE OR REPLACE FUNCTION public._exos_event_venue_matches(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE e public.exos_events%ROWTYPE; s public.exos_event_secret_locations%ROWTYPE;
BEGIN
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF e.location_mode = 'unlisted_venue' THEN
    RETURN public._exos_location_venue_matches(e.org_id, e.venue_name, e.venue_address ->> 'city');
  ELSIF e.location_mode = 'secret_location' THEN
    SELECT * INTO s FROM public.exos_event_secret_locations WHERE event_id = e.id;
    RETURN public._exos_location_venue_matches(e.org_id, s.venue_name, s.address ->> 'city');
  END IF;
  RETURN '[]'::jsonb;
END $$;
REVOKE ALL ON FUNCTION public._exos_event_venue_matches(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_venue_matches(uuid) TO service_role;

-- ===========================================================================
-- 7. Setting a location (dashboard and API)
-- ===========================================================================
-- p (every key optional; only the keys present change):
--   location_mode        venue_record | unlisted_venue | secret_location | tba
--   venue_name, venue_location (alias: area), venue_address (object)
--   location_reveal_at   timestamptz, or reveal_hours_before (0-720, from
--                        the start)
--   tba_allow_sales      true | false | null
--   secret_location      { venue_name?, address: { street, city, ... },
--                        directions? }, or null to remove it
-- One transaction: the secret is saved before the event row (so a live event
-- switching to secret_location passes its own check) and removed after it.
CREATE OR REPLACE FUNCTION public._exos_event_location_set(p_org uuid, p_event uuid, p_actor uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  e        public.exos_events%ROWTYPE;
  v_bad    text;
  v_mode   text;
  v_area   text;
  v_reveal timestamptz;
  v_sec    jsonb;
  v_addr   jsonb;
  v_hours  numeric;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'location: the body must be a JSON object' USING ERRCODE = '22023';
  END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(p) k
   WHERE k NOT IN ('location_mode', 'venue_name', 'venue_location', 'area', 'venue_address', 'location_reveal_at',
                   'reveal_hours_before', 'tba_allow_sales', 'secret_location')
   ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'location: unknown field %', left(v_bad, 60) USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event AND org_id = p_org FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002'; END IF;

  v_mode := coalesce(p ->> 'location_mode', e.location_mode);
  IF v_mode NOT IN ('venue_record', 'unlisted_venue', 'secret_location', 'tba') THEN
    RAISE EXCEPTION 'location: location_mode is venue_record, unlisted_venue, secret_location or tba' USING ERRCODE = '22023';
  END IF;
  IF p ? 'venue_location' AND p ? 'area' THEN
    RAISE EXCEPTION 'location: send venue_location or area, not both' USING ERRCODE = '22023';
  END IF;
  v_area := CASE WHEN p ? 'area' THEN p ->> 'area' WHEN p ? 'venue_location' THEN p ->> 'venue_location' ELSE e.venue_location END;
  IF v_area IS NOT NULL AND char_length(v_area) > 200 THEN
    RAISE EXCEPTION 'location: the area is at most 200 characters' USING ERRCODE = '22023';
  END IF;
  IF p ? 'venue_address' AND jsonb_typeof(p -> 'venue_address') NOT IN ('object', 'null') THEN
    RAISE EXCEPTION 'location: venue_address must be an object' USING ERRCODE = '22023';
  END IF;
  IF p ? 'tba_allow_sales' AND jsonb_typeof(p -> 'tba_allow_sales') NOT IN ('boolean', 'null') THEN
    RAISE EXCEPTION 'location: tba_allow_sales is true, false or null' USING ERRCODE = '22023';
  END IF;
  IF p ? 'location_reveal_at' AND p ? 'reveal_hours_before' THEN
    RAISE EXCEPTION 'location: send location_reveal_at or reveal_hours_before, not both' USING ERRCODE = '22023';
  END IF;
  v_reveal := e.location_reveal_at;
  IF p ? 'location_reveal_at' THEN
    BEGIN
      v_reveal := (p ->> 'location_reveal_at')::timestamptz;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'location: location_reveal_at must be a timestamp' USING ERRCODE = '22023';
    END;
  ELSIF p ? 'reveal_hours_before' THEN
    IF jsonb_typeof(p -> 'reveal_hours_before') <> 'number' THEN
      RAISE EXCEPTION 'location: reveal_hours_before must be a number of hours' USING ERRCODE = '22023';
    END IF;
    v_hours := (p ->> 'reveal_hours_before')::numeric;
    IF v_hours < 0 OR v_hours > 720 THEN
      RAISE EXCEPTION 'location: reveal_hours_before is 0 to 720' USING ERRCODE = '22023';
    END IF;
    IF e.starts_at IS NULL THEN
      RAISE EXCEPTION 'location: set the start time first (the reveal counts back from it)' USING ERRCODE = '22023';
    END IF;
    v_reveal := e.starts_at - make_interval(secs => v_hours * 3600);
  END IF;

  -- The secret first (when given as an object), so the event's check sees it.
  IF p ? 'secret_location' AND jsonb_typeof(p -> 'secret_location') = 'object' THEN
    v_sec := p -> 'secret_location';
    SELECT k INTO v_bad FROM jsonb_object_keys(v_sec) k WHERE k NOT IN ('venue_name', 'address', 'directions') LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'location: unknown secret_location field %', left(v_bad, 60) USING ERRCODE = '22023';
    END IF;
    v_addr := v_sec -> 'address';
    IF v_addr IS NULL OR jsonb_typeof(v_addr) <> 'object' OR btrim(coalesce(v_addr ->> 'street', '')) = '' THEN
      RAISE EXCEPTION 'location: secret_location.address needs at least a street' USING ERRCODE = '22023';
    END IF;
    SELECT k INTO v_bad FROM jsonb_object_keys(v_addr) k
     WHERE k NOT IN ('street', 'city', 'region', 'postal', 'country') OR jsonb_typeof(v_addr -> k) NOT IN ('string', 'null')
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'location: secret_location.address takes street, city, region, postal, country (text)' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_event_secret_locations AS s (event_id, org_id, venue_name, address, directions, updated_by)
    VALUES (e.id, e.org_id, nullif(btrim(coalesce(v_sec ->> 'venue_name', '')), ''), v_addr,
            nullif(btrim(coalesce(v_sec ->> 'directions', '')), ''), p_actor)
    ON CONFLICT (event_id) DO UPDATE
       SET venue_name = EXCLUDED.venue_name, address = EXCLUDED.address, directions = EXCLUDED.directions,
           updated_by = EXCLUDED.updated_by;
  ELSIF p ? 'secret_location' AND jsonb_typeof(p -> 'secret_location') <> 'null' THEN
    RAISE EXCEPTION 'location: secret_location must be an object (or null to remove it)' USING ERRCODE = '22023';
  END IF;

  -- (Only the secret given: the event row is left alone.)
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k <> 'secret_location') THEN
    UPDATE public.exos_events
       SET location_mode = v_mode,
           venue_name = CASE WHEN p ? 'venue_name' THEN nullif(btrim(coalesce(p ->> 'venue_name', '')), '') ELSE venue_name END,
           venue_location = CASE WHEN p ? 'area' OR p ? 'venue_location' THEN nullif(btrim(coalesce(v_area, '')), '')
                                 ELSE venue_location END,
           venue_address = CASE WHEN p ? 'venue_address' THEN nullif(p -> 'venue_address', 'null'::jsonb) ELSE venue_address END,
           location_reveal_at = v_reveal,
           tba_allow_sales = CASE WHEN p ? 'tba_allow_sales' THEN (p ->> 'tba_allow_sales')::boolean ELSE tba_allow_sales END
     WHERE id = e.id;
  END IF;

  IF p ? 'secret_location' AND jsonb_typeof(p -> 'secret_location') = 'null' THEN
    DELETE FROM public.exos_event_secret_locations WHERE event_id = e.id;
  END IF;
  RETURN public._exos_event_location_json(e.id, true)
      || jsonb_build_object('venue_suggestions', public._exos_event_venue_matches(e.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_event_location_set(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_location_set(uuid, uuid, uuid, jsonb) TO service_role;

-- The dashboard: owners and managers (who edit events).
CREATE OR REPLACE FUNCTION public.exos_event_location_set(p_event_id uuid, p_location jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_org uuid := (SELECT org_id FROM public.exos_events WHERE id = p_event_id);
BEGIN
  IF auth.uid() IS NULL OR v_org IS NULL
     OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_event_location_set: owners and managers edit an event''s location' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_event_location_set(v_org, p_event_id, auth.uid(), p_location);
END $$;
REVOKE ALL ON FUNCTION public.exos_event_location_set(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_event_location_set(uuid, jsonb) TO authenticated;

-- ---- The partner API's event create / update ------------------------------
-- The three public columns are plain event fields; secret_location is
-- set through _exos_event_location_set in the same call (after the row exists).
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)',
  '''location_mode'', ''location_reveal_at'', ''tba_allow_sales'',',
  $o$c_event   CONSTANT text[] := ARRAY[$o$,
  $n$c_event   CONSTANT text[] := ARRAY['location_mode', 'location_reveal_at', 'tba_allow_sales',$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)',
  '/* exos: location create */',
  $o$public._exos_api_insert('public.exos_events', c_event, v_tmp,$o$,
  $n$public._exos_api_insert('public.exos_events', c_event, v_tmp - 'secret_location' /* exos: location create */,$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)',
  '/* exos: location create secret */',
  $o$    v_out := public._exos_api_event_json(v_id);$o$,
  $n$    IF v_tmp ? 'secret_location' THEN   /* exos: location create secret */ -- mig 20261105130000
      PERFORM public._exos_event_location_set(v_org, v_id, v_actor,
        jsonb_build_object('secret_location', v_tmp -> 'secret_location'));
    END IF;
    v_out := public._exos_api_event_json(v_id);$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_api_write(uuid, text, text, jsonb, text)',
  '/* exos: location update */',
  $o$PERFORM public._exos_api_update('public.exos_events', v_event, c_event, v_tmp);$o$,
  $n$IF v_tmp ? 'secret_location' THEN   /* exos: location update */ -- mig 20261105130000: secret first
      PERFORM public._exos_event_location_set(v_org, v_event, v_actor,
        jsonb_build_object('secret_location', v_tmp -> 'secret_location'));
    END IF;
    PERFORM public._exos_api_update('public.exos_events', v_event, c_event, v_tmp - 'secret_location');$n$, 1);
SELECT pg_temp.exos_patch_n('public._exos_api_event_json(uuid)',
  '/* exos: location json */',
  $o$'publish_blockers', public._exos_event_publish_blockers(e.id))$o$,
  $n$'location', public._exos_event_location_json(e.id, false) /* exos: location json */,
    'publish_blockers', public._exos_event_publish_blockers(e.id))$n$, 1);

-- ---- The wallet pass: the address once revealed to that ticket ------------
SELECT pg_temp.exos_patch_n('public._exos_wallet_payload(text)',
  '/* exos: location wallet */',
  $o$    'org_name',      o.name,$o$,
  $n$    'location',      public._exos_event_location_for_ticket(t.id) /* exos: location wallet */,
    'org_name',      o.name,$n$, 1);

-- ===========================================================================
-- 8. Notices: the reveal and the announcement (mail, SMS, wallet refresh)
-- ===========================================================================
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['location-announced', 'location-revealed'];
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
    UNION SELECT unnest(v_new)) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- Who gets location mail: owners of active / used tickets with an email,
-- not the org's own members (they know).
CREATE OR REPLACE FUNCTION public._exos_event_location_holders(p_event_id uuid)
RETURNS TABLE (user_id uuid, email text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT DISTINCT t.owner_id, lower(u.email)
    FROM public.exos_tickets t
    JOIN public.exos_events e ON e.id = t.event_id
    JOIN auth.users u ON u.id = t.owner_id
   WHERE t.event_id = p_event_id AND t.status IN ('active', 'used')
     AND coalesce(u.email, '') <> ''
     AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                      WHERE m.org_id = e.org_id AND m.user_id = t.owner_id AND m.disabled IS NOT TRUE)
$$;
REVOKE ALL ON FUNCTION public._exos_event_location_holders(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_event_location_holders(uuid) TO service_role;

-- One address as one escaped line: "Venue, 1 Street, City, Region Postal".
CREATE OR REPLACE FUNCTION public._exos_location_line(p_name text, p_addr jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT nullif(array_to_string(ARRAY(
    SELECT btrim(x) FROM unnest(ARRAY[p_name, p_addr ->> 'street', p_addr ->> 'city',
                                       btrim(coalesce(p_addr ->> 'region', '') || ' ' || coalesce(p_addr ->> 'postal', '')),
                                       p_addr ->> 'country']) x
     WHERE btrim(coalesce(x, '')) <> ''), ', '), '')
$$;
REVOKE ALL ON FUNCTION public._exos_location_line(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_line(text, jsonb) TO service_role;

-- Send one notice: a mail per holder (deduped per notice and holder), one
-- SMS run to the holders who opted in to the org's texts (when the org has a
-- connected Twilio / Telnyx number; quiet hours as campaigns), and a refresh
-- of the holders' wallet passes. Returns the counts.
CREATE OR REPLACE FUNCTION public._exos_location_notice_send(p_notice_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  n        public.exos_event_location_notices%ROWTYPE;
  e        public.exos_events%ROWTYPE;
  s        public.exos_event_secret_locations%ROWTYPE;
  v_org    text;
  v_tz     text;
  v_when   text;
  v_line   text;
  v_public text;
  v_subj   text;
  v_body   text;
  v_text   text;
  v_tpl    text;
  v_mailed int := 0;
  v_texted int := 0;
  v_passes int := 0;
  v_prov   text;
  v_at     timestamptz := now();
  v_local  timestamp;
  v_camp   uuid;
  h        record;
BEGIN
  SELECT * INTO n FROM public.exos_event_location_notices WHERE id = p_notice_id FOR UPDATE;
  IF n.id IS NULL OR n.status <> 'pending' THEN RETURN NULL; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = n.event_id;
  IF e.id IS NULL OR e.status <> 'published'
     OR coalesce(e.ends_at, e.starts_at + interval '12 hours', now()) < now() THEN
    UPDATE public.exos_event_location_notices SET status = 'skipped', note = 'event not live', sent_at = now() WHERE id = n.id;
    RETURN jsonb_build_object('status', 'skipped');
  END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = e.org_id;
  v_tz := coalesce(nullif(e.timezone, ''), 'UTC');
  BEGIN
    v_when := to_char(e.starts_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
  EXCEPTION WHEN others THEN
    v_tz := 'UTC';
    v_when := to_char(e.starts_at AT TIME ZONE 'UTC', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
  END;
  v_public := public._exos_location_line(e.venue_name, e.venue_address);

  IF n.kind = 'revealed' THEN
    SELECT * INTO s FROM public.exos_event_secret_locations WHERE event_id = e.id;
    IF s.event_id IS NULL OR e.location_mode <> 'secret_location' THEN
      UPDATE public.exos_event_location_notices SET status = 'skipped', note = 'no secret location', sent_at = now() WHERE id = n.id;
      RETURN jsonb_build_object('status', 'skipped');
    END IF;
    v_line := public._exos_location_line(s.venue_name, s.address);
    v_tpl := 'location-revealed';
    v_subj := left(CASE WHEN n.version > 1 AND s.notified_version > 0 THEN 'New location: ' ELSE 'Location: ' END
                   || coalesce(e.name, 'your event'), 200);
    v_body := '<p>Here''s where <strong>' || public.exos_mail_escape(coalesce(e.name, 'your event')) || '</strong> is happening ('
           || public.exos_mail_escape(v_when) || '):</p>'
           || '<p><strong>' || public.exos_mail_escape(v_line) || '</strong></p>'
           || CASE WHEN s.directions IS NOT NULL THEN '<p>' || public.exos_mail_escape(s.directions) || '</p>' ELSE '' END
           || '<p>It''s on your ticket too. Please keep it to ticket holders.</p>'
           || '<p><a href="{{app_url}}/my-tickets">Your tickets</a></p>';
    v_text := left(coalesce(e.name, 'Your event') || ' location: ' || v_line, 300);
  ELSE
    v_tpl := 'location-announced';
    v_subj := left('Location announced: ' || coalesce(e.name, 'your event'), 200);
    IF e.location_mode = 'secret_location' THEN
      v_body := '<p>The area for <strong>' || public.exos_mail_escape(coalesce(e.name, 'your event')) || '</strong> ('
             || public.exos_mail_escape(v_when) || ') is <strong>'
             || public.exos_mail_escape(coalesce(e.venue_location, 'set')) || '</strong>. The exact address comes to you '
             || public.exos_mail_escape(coalesce(to_char(public._exos_location_reveal_at(e.location_reveal_at, e.starts_at)
                                                         AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM'), 'before the start'))
             || '.</p><p><a href="{{app_url}}/my-tickets">Your tickets</a></p>';
      v_text := left(coalesce(e.name, 'Your event') || ': it''s in ' || coalesce(e.venue_location, 'the area announced')
                     || '. The exact address comes before the start.', 300);
    ELSE
      v_line := coalesce(v_public, e.venue_location, 'see the event page');
      v_body := '<p>The location for <strong>' || public.exos_mail_escape(coalesce(e.name, 'your event')) || '</strong> ('
             || public.exos_mail_escape(v_when) || ') is set:</p><p><strong>'
             || public.exos_mail_escape(v_line) || '</strong></p>'
             || '<p><a href="{{app_url}}/my-tickets">Your tickets</a></p>';
      v_text := left(coalesce(e.name, 'Your event') || ' location: ' || v_line, 300);
    END IF;
  END IF;

  FOR h IN SELECT * FROM public._exos_event_location_holders(e.id) LOOP
    INSERT INTO public.exos_mail_dedupe (dedupe_key, template)
    VALUES (left(v_tpl || ':' || e.id || ':' || n.version || ':' || h.user_id, 300), v_tpl)
    ON CONFLICT DO NOTHING;
    IF FOUND THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, status)
      VALUES (v_tpl, h.email, v_subj, v_body, 'pending');
      v_mailed := v_mailed + 1;
    END IF;
  END LOOP;

  -- SMS: the org's own number, opted-in holders only, quiet hours 9-20 local.
  IF to_regclass('public.exos_sms_campaigns') IS NOT NULL AND to_regclass('public.exos_org_integrations') IS NOT NULL THEN
    SELECT i.provider INTO v_prov FROM public.exos_org_integrations i
     WHERE i.org_id = e.org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
     ORDER BY (i.provider = 'twilio') DESC LIMIT 1;
    IF v_prov IS NOT NULL THEN
      v_local := v_at AT TIME ZONE v_tz;
      IF v_local::time < time '09:00' THEN
        v_at := (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
      ELSIF v_local::time >= time '20:00' THEN
        v_at := (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
      END IF;
      v_text := left(left(coalesce(v_org, 'Exos'), 40) || ': ' || v_text, 430) || ' Reply STOP to opt out.';
      INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider, send_after)
      VALUES (e.org_id, e.id, 'event_buyers', v_text, v_prov, v_at)
      RETURNING id INTO v_camp;
      INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
      SELECT v_camp, e.org_id, sub.phone, v_text, v_at
        FROM public.exos_sms_subscribers sub
       WHERE sub.org_id = e.org_id AND sub.opted_out_at IS NULL AND sub.user_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.exos_tickets t
                      WHERE t.event_id = e.id AND t.owner_id = sub.user_id AND t.status IN ('active', 'used'))
      ON CONFLICT DO NOTHING;
      GET DIAGNOSTICS v_texted = ROW_COUNT;
      UPDATE public.exos_sms_campaigns SET queued_count = v_texted,
             status = CASE WHEN v_texted = 0 THEN 'sent' ELSE 'queued' END
       WHERE id = v_camp;
    END IF;
  END IF;

  -- Wallet passes re-read their payload (which carries the location).
  IF to_regclass('public.exos_wallet_passes') IS NOT NULL THEN
    UPDATE public.exos_wallet_passes w SET updated_at = clock_timestamp(), push_pending = true
      FROM public.exos_tickets t
     WHERE t.id = w.ticket_id AND t.event_id = e.id AND w.status = 'active' AND t.status IN ('active', 'used');
    GET DIAGNOSTICS v_passes = ROW_COUNT;
  END IF;

  UPDATE public.exos_event_location_notices
     SET status = 'sent', mailed = v_mailed, texted = v_texted, passes = v_passes, sent_at = now()
   WHERE id = n.id;
  IF n.kind = 'revealed' THEN
    UPDATE public.exos_event_secret_locations
       SET notified_version = greatest(notified_version, n.version), notified_at = now()
     WHERE event_id = e.id;
  END IF;
  RETURN jsonb_build_object('status', 'sent', 'mailed', v_mailed, 'texted', v_texted, 'passes', v_passes);
END $$;
REVOKE ALL ON FUNCTION public._exos_location_notice_send(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_location_notice_send(uuid) TO service_role;

-- The cron: queue the reveals that are due (a live secret_location event at
-- or past its reveal, not over, whose current address hasn't been sent),
-- then send pending notices. Safe to run often and concurrently (the notice
-- row is locked and only a pending one is sent; mail is deduped).
CREATE OR REPLACE FUNCTION public.exos_send_location_notices(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_queued int := 0;
  v_sent   int := 0;
  v_limit  int := greatest(least(coalesce(p_limit, 100), 500), 1);
  r        record;
  v        jsonb;
BEGIN
  IF session_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_location_notices: service role only' USING ERRCODE = '42501';
  END IF;
  IF to_regprocedure('public.cron_should_fire(text)') IS NOT NULL
     AND NOT public.cron_should_fire('exos_send_location_notices') THEN
    RETURN jsonb_build_object('skipped', true);
  END IF;
  INSERT INTO public.exos_event_location_notices (org_id, event_id, kind, version)
  SELECT e.org_id, e.id, 'revealed', s.version
    FROM public.exos_events e JOIN public.exos_event_secret_locations s ON s.event_id = e.id
   WHERE e.status = 'published' AND e.location_mode = 'secret_location'
     AND public._exos_location_reveal_at(e.location_reveal_at, e.starts_at) <= now()
     AND coalesce(e.ends_at, e.starts_at + interval '12 hours') > now()
     AND s.version > s.notified_version
  ON CONFLICT (event_id, kind, version) DO NOTHING;
  GET DIAGNOSTICS v_queued = ROW_COUNT;
  FOR r IN SELECT id FROM public.exos_event_location_notices
            WHERE status = 'pending' ORDER BY created_at LIMIT v_limit
              FOR UPDATE SKIP LOCKED LOOP
    v := public._exos_location_notice_send(r.id);
    IF v ->> 'status' = 'sent' THEN v_sent := v_sent + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('queued', v_queued, 'sent', v_sent);
END $$;
REVOKE ALL ON FUNCTION public.exos_send_location_notices(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_send_location_notices(int) TO service_role;

-- Every 5 minutes, created INACTIVE (prod keeps Exos crons off): the
-- operator turns it on with
--   SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-location-notices-5min'), active := true);
-- once the mail drain is live. Holders see the address on their ticket at the
-- reveal time either way (read time). A re-run leaves the job alone.
DO $$
DECLARE v_job bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1' INTO v_job USING 'exos-location-notices-5min';
  IF v_job IS NULL THEN
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_job
      USING 'exos-location-notices-5min', '2-57/5 * * * *', 'SELECT public.exos_send_location_notices(100);';
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_job;
  END IF;
END $$;
