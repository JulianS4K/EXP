-- ============================================================================
-- Migration 20261030100000 — Exos: booking core (venues, rooms, holds, show
-- schedule, staff notes and contacts). docs/booking.md.
--
-- Touches:  C: TABLE exos_venues, exos_venue_rooms, exos_holds,
--              exos_hold_positions, exos_show_activities, exos_event_notes,
--              exos_event_contacts
--           W: TABLE exos_events (+ exos_venue_id, exos_room_id, hold_id,
--              hold_position_id; nullable links, nothing existing changes)
--           C: FUNCTION exos_hold_create / _update / _clear / _convert
--              (signed-in owner / manager), their _exos_hold_* cores
--              (service_role: the exos-api edge function), _exos_hold_json,
--              _exos_slot_place, _exos_hold_refresh, trigger functions
--           R: exos_orgs, exos_org_memberships, exos_events,
--              exos_ticket_tiers, exos_webhooks (via exos_enqueue_webhook)
-- Pre-reqs: 20260616200000 (exos_enqueue_webhook), 20260929041000
--           (exos_can_door_event)
--
-- Port of the Firebase build's booking (Exos-Bridge round 12, docs/BOOKING.md,
-- server/booking.ts + server/holdLadder.ts), with Opendate's hold model as the
-- yardstick:
--
--   * A venue belongs to one organization: `owned`, `rented` or `partner`
--     (promoters book rooms they don't own) with an optional booking contact.
--     A venue has rooms.
--   * A hold pencils one or more nights ("positions"); each position is a date
--     at a venue, in one room or the whole venue (room_id NULL), at a level.
--     Levels count per slot (org + venue + room + date) and are always 1..N:
--     a new night goes to the end unless a level is asked for; clearing or
--     converting a night moves the ones behind it up (level 2 becomes 1).
--     Levels only ever count the organization's own holds.
--   * Converting one night makes a draft event (one free General Admission
--     tier sized to the room, else the venue, else 100) in the venue's time
--     zone, marks the night converted, drops the hold's other rooms that night
--     (optionally every other hold on that date at the venue) and promotes the
--     holds behind.
--   * Holds are written only by the functions below, under a per-org advisory
--     lock, so levels can't be corrupted from a browser. Every write enqueues
--     hold.created / hold.updated / hold.converted webhooks, and hold.updated
--     for each other hold whose level moved.
--   * Show schedule rows; the `doors` row and exos_events.doors_at are one
--     fact (triggers keep them in step both ways). Notes and contacts are
--     staff-only (never scanners, never the public).
--
-- Errors: 22023 bad input, P0002 not found, 23505 / 55000 / 54000 conflict
-- or limit, 42501 not allowed. exos-api maps them to 400 / 404 / 409 / 404.
--
-- Additive only; re-run safe (IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF
-- EXISTS before CREATE for policies and triggers). Nothing is granted to anon.
-- ============================================================================

-- ===========================================================================
-- 1. Venues and rooms
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_venues (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name          text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  address       jsonb CHECK (address IS NULL OR jsonb_typeof(address) = 'object'),
  timezone      text CHECK (timezone IS NULL OR char_length(timezone) <= 64),
  capacity      integer CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 1000000),
  website       text CHECK (website IS NULL OR (website ~ '^https://' AND char_length(website) <= 300)),
  permalink     text CHECK (permalink IS NULL OR permalink ~ '^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$'),
  relationship  text NOT NULL DEFAULT 'owned' CHECK (relationship IN ('owned', 'rented', 'partner')),
  contact_name  text CHECK (contact_name IS NULL OR char_length(contact_name) <= 100),
  contact_email text CHECK (contact_email IS NULL OR (char_length(contact_email) <= 200
                            AND contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  contact_phone text CHECK (contact_phone IS NULL OR char_length(contact_phone) <= 40),
  notes         text CHECK (notes IS NULL OR char_length(notes) <= 2000),
  created_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id),
  UNIQUE (org_id, permalink)
);
CREATE INDEX IF NOT EXISTS exos_venues_org_idx ON public.exos_venues (org_id, name);

CREATE TABLE IF NOT EXISTS public.exos_venue_rooms (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  venue_id   uuid NOT NULL,
  name       text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  capacity   integer CHECK (capacity IS NULL OR capacity BETWEEN 0 AND 1000000),
  color      text CHECK (color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'),
  notes      text CHECK (notes IS NULL OR char_length(notes) <= 1000),
  sort_order integer NOT NULL DEFAULT 0,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- A room's org is its venue's org.
  FOREIGN KEY (venue_id, org_id) REFERENCES public.exos_venues (id, org_id) ON DELETE CASCADE,
  UNIQUE (id, venue_id)
);
CREATE INDEX IF NOT EXISTS exos_venue_rooms_venue_idx ON public.exos_venue_rooms (venue_id, sort_order, name);
CREATE INDEX IF NOT EXISTS exos_venue_rooms_org_idx ON public.exos_venue_rooms (org_id);

-- Lowercase-dash slug of a venue name (no accent folding: unaccent isn't
-- assumed). Pure.
CREATE OR REPLACE FUNCTION public._exos_slugify(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT nullif(regexp_replace(left(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60), '-+$', ''), '')
$$;
REVOKE ALL ON FUNCTION public._exos_slugify(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_slugify(text) TO authenticated, service_role;

-- Venue rows: trim, validate the time zone, default the permalink (unique in
-- the org: a taken slug gets -2, -3 ...), the creator, and the 200 cap.
CREATE OR REPLACE FUNCTION public._exos_tg_venue()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_base text; v_try text; i int := 1;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.org_id IS DISTINCT FROM OLD.org_id THEN
    RAISE EXCEPTION 'exos_venues: a venue can''t move to another organization' USING ERRCODE = '22023';
  END IF;
  NEW.name := btrim(NEW.name);
  NEW.timezone := nullif(btrim(NEW.timezone), '');
  IF NEW.timezone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'exos_venues: timezone must be an IANA zone, e.g. America/New_York' USING ERRCODE = '22023';
  END IF;
  NEW.website := nullif(btrim(NEW.website), '');
  NEW.contact_name := nullif(btrim(NEW.contact_name), '');
  NEW.contact_email := nullif(lower(btrim(NEW.contact_email)), '');
  NEW.contact_phone := nullif(btrim(NEW.contact_phone), '');
  NEW.permalink := nullif(lower(btrim(NEW.permalink)), '');
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_venues:' || NEW.org_id::text, 0));
    IF (SELECT count(*) FROM public.exos_venues WHERE org_id = NEW.org_id) >= 200 THEN
      RAISE EXCEPTION 'exos_venues: at most 200 venues per organization' USING ERRCODE = '54000';
    END IF;
    IF NEW.permalink IS NULL THEN
      v_base := coalesce(public._exos_slugify(NEW.name), 'venue');
      v_try := v_base;
      WHILE EXISTS (SELECT 1 FROM public.exos_venues WHERE org_id = NEW.org_id AND permalink = v_try) LOOP
        i := i + 1;
        v_try := left(v_base, 60 - 1 - length(i::text)) || '-' || i;
      END LOOP;
      NEW.permalink := v_try;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_venue() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_venues_guard ON public.exos_venues;
CREATE TRIGGER exos_venues_guard BEFORE INSERT OR UPDATE ON public.exos_venues
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_venue();

-- Room rows: org from the venue, trim, creator, 50 per venue.
CREATE OR REPLACE FUNCTION public._exos_tg_room()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.venue_id IS DISTINCT FROM OLD.venue_id THEN
    RAISE EXCEPTION 'exos_venue_rooms: a room can''t move to another venue' USING ERRCODE = '22023';
  END IF;
  SELECT v.org_id INTO NEW.org_id FROM public.exos_venues v WHERE v.id = NEW.venue_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION 'exos_venue_rooms: venue not found' USING ERRCODE = 'P0002';
  END IF;
  NEW.name := btrim(NEW.name);
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_venue_rooms:' || NEW.venue_id::text, 0));
    IF (SELECT count(*) FROM public.exos_venue_rooms WHERE venue_id = NEW.venue_id) >= 50 THEN
      RAISE EXCEPTION 'exos_venue_rooms: at most 50 rooms per venue' USING ERRCODE = '54000';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_room() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_venue_rooms_guard ON public.exos_venue_rooms;
CREATE TRIGGER exos_venue_rooms_guard BEFORE INSERT OR UPDATE ON public.exos_venue_rooms
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_room();

-- ===========================================================================
-- 2. Holds and their positions (nights)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_holds (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  title           text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  notes           text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 2000),
  -- Lineup by id; resolved by the artists port (no FK yet).
  artist_ids      uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(artist_ids) <= 20),
  announce_at     timestamptz,
  ticket_forecast integer CHECK (ticket_forecast IS NULL OR ticket_forecast BETWEEN 0 AND 1000000),
  age_restriction text CHECK (age_restriction IS NULL OR char_length(age_restriction) <= 40),
  -- Rental terms (promoter mode, a rented or partner room). Present when
  -- rental_status is set; amounts in major units.
  rental_status   text CHECK (rental_status IS NULL OR rental_status IN ('requested', 'confirmed', 'declined')),
  rental_fee      numeric(12, 2) CHECK (rental_fee IS NULL OR rental_fee BETWEEN 0 AND 10000000),
  rental_deposit  numeric(12, 2) CHECK (rental_deposit IS NULL OR rental_deposit BETWEEN 0 AND 10000000),
  rental_currency text CHECK (rental_currency IS NULL OR rental_currency ~ '^[A-Z]{3}$'),
  rental_notes    text CHECK (rental_notes IS NULL OR char_length(rental_notes) <= 1000),
  -- Derived from the positions by _exos_hold_refresh: active while any night
  -- is active, else converted (any night converted) or cleared.
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cleared', 'converted')),
  first_date      date,
  last_date       date,
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_via     text NOT NULL DEFAULT 'dashboard' CHECK (created_via IN ('dashboard', 'api')),
  api_key_id      uuid,
  cleared_at      timestamptz,
  converted_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE INDEX IF NOT EXISTS exos_holds_org_idx ON public.exos_holds (org_id, status, first_date);

CREATE TABLE IF NOT EXISTS public.exos_hold_positions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  hold_id      uuid NOT NULL,
  venue_id     uuid NOT NULL,
  room_id      uuid,                       -- NULL = the whole venue
  date         date NOT NULL,              -- the venue's local calendar date
  start_time   time,                       -- venue-local show time, if known
  is_target    boolean NOT NULL DEFAULT false,
  level        integer NOT NULL CHECK (level BETWEEN 1 AND 50),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cleared', 'converted')),
  event_id     uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  cleared_at   timestamptz,
  converted_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (hold_id, org_id) REFERENCES public.exos_holds (id, org_id) ON DELETE CASCADE,
  FOREIGN KEY (venue_id, org_id) REFERENCES public.exos_venues (id, org_id) ON DELETE RESTRICT,
  FOREIGN KEY (room_id, venue_id) REFERENCES public.exos_venue_rooms (id, venue_id) ON DELETE RESTRICT
);
-- A hold holds a slot once.
CREATE UNIQUE INDEX IF NOT EXISTS exos_hold_positions_one_per_slot
  ON public.exos_hold_positions (hold_id, venue_id, coalesce(room_id, '00000000-0000-0000-0000-000000000000'::uuid), date)
  WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_hold_positions_slot_idx
  ON public.exos_hold_positions (org_id, venue_id, date) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_hold_positions_hold_idx ON public.exos_hold_positions (hold_id);
CREATE INDEX IF NOT EXISTS exos_hold_positions_date_idx ON public.exos_hold_positions (org_id, date);
CREATE INDEX IF NOT EXISTS exos_hold_positions_event_idx ON public.exos_hold_positions (event_id) WHERE event_id IS NOT NULL;

-- ===========================================================================
-- 3. Event links (all nullable; legacy events have none and keep working)
-- ===========================================================================
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS exos_venue_id uuid REFERENCES public.exos_venues (id) ON DELETE SET NULL;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS exos_room_id uuid REFERENCES public.exos_venue_rooms (id) ON DELETE SET NULL;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS hold_id uuid REFERENCES public.exos_holds (id) ON DELETE SET NULL;
ALTER TABLE public.exos_events ADD COLUMN IF NOT EXISTS hold_position_id uuid REFERENCES public.exos_hold_positions (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_events_exos_venue_idx ON public.exos_events (exos_venue_id) WHERE exos_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_events_hold_idx ON public.exos_events (hold_id) WHERE hold_id IS NOT NULL;
COMMENT ON COLUMN public.exos_events.exos_venue_id IS
  'mig 20261030100000: the org''s own venue (exos_venues). Distinct from venue_id, the canonical/TEvo id.';

-- An event may only link its own org's venue and a room of that venue, and
-- the hold links are set only by the convert function (it sets
-- exos.booking_convert for the transaction).
CREATE OR REPLACE FUNCTION public._exos_tg_event_booking_links()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.exos_venue_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id OR NEW.exos_room_id IS DISTINCT FROM OLD.exos_room_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venues v WHERE v.id = NEW.exos_venue_id AND v.org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'exos_events: venue not found in this organization' USING ERRCODE = '22023';
  END IF;
  IF NEW.exos_room_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.exos_room_id IS DISTINCT FROM OLD.exos_room_id OR NEW.exos_venue_id IS DISTINCT FROM OLD.exos_venue_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_venue_rooms r WHERE r.id = NEW.exos_room_id AND r.venue_id = NEW.exos_venue_id) THEN
    RAISE EXCEPTION 'exos_events: room not found in that venue' USING ERRCODE = '22023';
  END IF;
  IF coalesce(current_setting('exos.booking_convert', true), '') <> 'on' THEN
    IF TG_OP = 'INSERT' THEN
      -- A copy of a converted event (a series date, a duplicate) is not the
      -- night it came from: it starts without the hold links.
      NEW.hold_id := NULL;
      NEW.hold_position_id := NULL;
    ELSIF (NEW.hold_id IS DISTINCT FROM OLD.hold_id OR NEW.hold_position_id IS DISTINCT FROM OLD.hold_position_id)
          AND (NEW.hold_id IS NOT NULL OR NEW.hold_position_id IS NOT NULL) THEN
      RAISE EXCEPTION 'exos_events: hold links are set by converting a hold' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_booking_links() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_booking_links ON public.exos_events;
CREATE TRIGGER exos_events_booking_links BEFORE INSERT OR UPDATE OF exos_venue_id, exos_room_id, hold_id, hold_position_id
  ON public.exos_events FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_booking_links();

-- ===========================================================================
-- 4. Show schedule, notes, contacts (per event)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_show_activities (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind            text NOT NULL DEFAULT 'other' CHECK (kind IN
                    ('announce', 'load_in', 'soundcheck', 'doors', 'set', 'changeover', 'curfew', 'load_out', 'other')),
  name            text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  starts_at       timestamptz NOT NULL,
  ends_at         timestamptz,
  notes           text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 500),
  -- false = the time is pencilled, not decided.
  is_set          boolean NOT NULL DEFAULT true,
  -- shown on the advance / day sheet.
  show_in_advance boolean NOT NULL DEFAULT true,
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR ends_at >= starts_at)
);
CREATE INDEX IF NOT EXISTS exos_show_activities_event_idx ON public.exos_show_activities (event_id, starts_at);
CREATE INDEX IF NOT EXISTS exos_show_activities_org_idx ON public.exos_show_activities (org_id);
CREATE UNIQUE INDEX IF NOT EXISTS exos_show_activities_one_doors ON public.exos_show_activities (event_id) WHERE kind = 'doors';

CREATE TABLE IF NOT EXISTS public.exos_event_notes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  body        text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 5000),
  author_id   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  author_name text NOT NULL DEFAULT '' CHECK (char_length(author_name) <= 100),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_notes_event_idx ON public.exos_event_notes (event_id, created_at);
CREATE INDEX IF NOT EXISTS exos_event_notes_org_idx ON public.exos_event_notes (org_id, created_at);

CREATE TABLE IF NOT EXISTS public.exos_event_contacts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  role       text NOT NULL DEFAULT 'other' CHECK (role IN ('promoter', 'agent', 'production', 'settlement', 'other')),
  title      text CHECK (title IS NULL OR char_length(title) <= 80),    -- free text, e.g. "Tour manager"
  name       text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  email      text CHECK (email IS NULL OR (char_length(email) <= 200
                         AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
  phone      text CHECK (phone IS NULL OR char_length(phone) <= 40),
  company    text CHECK (company IS NULL OR char_length(company) <= 100),
  notes      text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 500),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_contacts_event_idx ON public.exos_event_contacts (event_id);
CREATE INDEX IF NOT EXISTS exos_event_contacts_org_idx ON public.exos_event_contacts (org_id);

-- Shared BEFORE trigger for the three per-event tables: org_id comes from the
-- event (whatever the client sent), the event can't change, the author /
-- creator is the signed-in user, and each table has a per-event cap.
CREATE OR REPLACE FUNCTION public._exos_tg_event_child()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_cap int; v_n int;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.event_id IS DISTINCT FROM OLD.event_id THEN
    RAISE EXCEPTION '%: a row can''t move to another event', TG_TABLE_NAME USING ERRCODE = '22023';
  END IF;
  SELECT e.org_id INTO NEW.org_id FROM public.exos_events e WHERE e.id = NEW.event_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION '%: event not found', TG_TABLE_NAME USING ERRCODE = 'P0002';
  END IF;
  IF TG_OP = 'INSERT' THEN
    v_cap := CASE TG_TABLE_NAME WHEN 'exos_show_activities' THEN 60 WHEN 'exos_event_notes' THEN 500 ELSE 100 END;
    PERFORM pg_advisory_xact_lock(hashtextextended(TG_TABLE_NAME || ':' || NEW.event_id::text, 0));
    EXECUTE format('SELECT count(*) FROM public.%I WHERE event_id = $1', TG_TABLE_NAME) INTO v_n USING NEW.event_id;
    IF v_n >= v_cap THEN
      RAISE EXCEPTION '%: at most % rows per event', TG_TABLE_NAME, v_cap USING ERRCODE = '54000';
    END IF;
    IF TG_TABLE_NAME = 'exos_event_notes' THEN
      NEW.author_id := coalesce(auth.uid(), NEW.author_id);
    ELSE
      NEW.created_by := coalesce(auth.uid(), NEW.created_by);
    END IF;
  ELSIF TG_TABLE_NAME = 'exos_event_notes' THEN
    NEW.author_id := OLD.author_id;   -- authorship is fixed
  ELSE
    NEW.created_by := OLD.created_by;
  END IF;
  IF TG_TABLE_NAME = 'exos_event_contacts' THEN
    NEW.name := btrim(NEW.name);
    NEW.email := nullif(lower(btrim(NEW.email)), '');
    NEW.phone := nullif(btrim(NEW.phone), '');
    NEW.company := nullif(btrim(NEW.company), '');
    NEW.title := nullif(btrim(NEW.title), '');
  ELSIF TG_TABLE_NAME = 'exos_show_activities' THEN
    NEW.name := btrim(NEW.name);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_child() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_show_activities_guard ON public.exos_show_activities;
CREATE TRIGGER exos_show_activities_guard BEFORE INSERT OR UPDATE ON public.exos_show_activities
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_child();
DROP TRIGGER IF EXISTS exos_event_notes_guard ON public.exos_event_notes;
CREATE TRIGGER exos_event_notes_guard BEFORE INSERT OR UPDATE ON public.exos_event_notes
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_child();
DROP TRIGGER IF EXISTS exos_event_contacts_guard ON public.exos_event_contacts;
CREATE TRIGGER exos_event_contacts_guard BEFORE INSERT OR UPDATE ON public.exos_event_contacts
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_event_child();

-- ---- The doors row ↔ exos_events.doors_at ----------------------------------
-- A doors row written directly (not by the event-side sync below) may not be
-- after the event's start.
CREATE OR REPLACE FUNCTION public._exos_tg_show_activity_doors_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_start timestamptz;
BEGIN
  IF NEW.kind = 'doors' AND pg_trigger_depth() = 1 THEN
    SELECT starts_at INTO v_start FROM public.exos_events WHERE id = NEW.event_id;
    IF v_start IS NOT NULL AND NEW.starts_at > v_start THEN
      RAISE EXCEPTION 'exos_show_activities: doors must not be after the event start' USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_show_activity_doors_check() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_show_activities_doors_check ON public.exos_show_activities;
CREATE TRIGGER exos_show_activities_doors_check BEFORE INSERT OR UPDATE ON public.exos_show_activities
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_show_activity_doors_check();

-- Saving a doors row sets doors_at; deleting it (or re-kinding it) clears it.
CREATE OR REPLACE FUNCTION public._exos_tg_show_activity_doors_sync()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.kind = 'doors' THEN
    UPDATE public.exos_events SET doors_at = NEW.starts_at
     WHERE id = NEW.event_id AND doors_at IS DISTINCT FROM NEW.starts_at;
  END IF;
  IF TG_OP = 'DELETE' AND OLD.kind = 'doors'
     OR TG_OP = 'UPDATE' AND OLD.kind = 'doors' AND NEW.kind <> 'doors' THEN
    UPDATE public.exos_events SET doors_at = NULL WHERE id = OLD.event_id AND doors_at IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_show_activity_doors_sync() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_show_activities_doors_sync ON public.exos_show_activities;
CREATE TRIGGER exos_show_activities_doors_sync AFTER INSERT OR UPDATE OR DELETE ON public.exos_show_activities
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_show_activity_doors_sync();

-- Changing doors_at anywhere (Edit Event, the API) moves the doors row, or
-- deletes it when doors were cleared. Creates nothing: an event with doors_at
-- and no doors row shows an implied one.
CREATE OR REPLACE FUNCTION public._exos_tg_event_doors_sync()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.doors_at IS NULL THEN
    DELETE FROM public.exos_show_activities WHERE event_id = NEW.id AND kind = 'doors';
  ELSE
    UPDATE public.exos_show_activities SET starts_at = NEW.doors_at,
           ends_at = CASE WHEN ends_at IS NOT NULL AND ends_at < NEW.doors_at THEN NULL ELSE ends_at END
     WHERE event_id = NEW.id AND kind = 'doors' AND starts_at IS DISTINCT FROM NEW.doors_at;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_event_doors_sync() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_events_doors_sync ON public.exos_events;
CREATE TRIGGER exos_events_doors_sync AFTER UPDATE OF doors_at ON public.exos_events
  FOR EACH ROW WHEN (NEW.doors_at IS DISTINCT FROM OLD.doors_at)
  EXECUTE FUNCTION public._exos_tg_event_doors_sync();

-- updated_at touches.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_venues', 'exos_venue_rooms', 'exos_holds', 'exos_hold_positions',
                           'exos_show_activities', 'exos_event_notes', 'exos_event_contacts'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- ===========================================================================
-- 5. RLS
--    Venues, rooms: every staff role reads; owner / manager write.
--    Holds, positions: owner / manager / content / finance read; written only
--      by the functions below (no client write grant at all).
--    Show schedule: staff read (a scanner only for events they may work);
--      owner / manager / content write.
--    Notes, contacts: owner / manager / content / finance read; owner /
--      manager / content write (a note: its author, or owner / manager).
-- ===========================================================================
ALTER TABLE public.exos_venues          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_venue_rooms     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_holds           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_hold_positions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_show_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_notes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_contacts  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_venues', 'exos_venue_rooms', 'exos_holds', 'exos_hold_positions',
                           'exos_show_activities', 'exos_event_notes', 'exos_event_contacts'] LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated;', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role;', t);
  END LOOP;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_venues, public.exos_venue_rooms,
  public.exos_show_activities, public.exos_event_notes, public.exos_event_contacts TO authenticated;
GRANT SELECT ON public.exos_holds, public.exos_hold_positions TO authenticated;

DROP POLICY IF EXISTS exos_venues_sel ON public.exos_venues;
CREATE POLICY exos_venues_sel ON public.exos_venues FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance', 'scanner']));
DROP POLICY IF EXISTS exos_venues_write ON public.exos_venues;
CREATE POLICY exos_venues_write ON public.exos_venues FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager']));

DROP POLICY IF EXISTS exos_venue_rooms_sel ON public.exos_venue_rooms;
CREATE POLICY exos_venue_rooms_sel ON public.exos_venue_rooms FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance', 'scanner']));
DROP POLICY IF EXISTS exos_venue_rooms_write ON public.exos_venue_rooms;
CREATE POLICY exos_venue_rooms_write ON public.exos_venue_rooms FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager']));

DROP POLICY IF EXISTS exos_holds_sel ON public.exos_holds;
CREATE POLICY exos_holds_sel ON public.exos_holds FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));
DROP POLICY IF EXISTS exos_hold_positions_sel ON public.exos_hold_positions;
CREATE POLICY exos_hold_positions_sel ON public.exos_hold_positions FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));

DROP POLICY IF EXISTS exos_show_activities_sel ON public.exos_show_activities;
CREATE POLICY exos_show_activities_sel ON public.exos_show_activities FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance'])
         OR exos_can_door_event(event_id));
DROP POLICY IF EXISTS exos_show_activities_write ON public.exos_show_activities;
CREATE POLICY exos_show_activities_write ON public.exos_show_activities FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));

DROP POLICY IF EXISTS exos_event_notes_sel ON public.exos_event_notes;
CREATE POLICY exos_event_notes_sel ON public.exos_event_notes FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));
DROP POLICY IF EXISTS exos_event_notes_ins ON public.exos_event_notes;
CREATE POLICY exos_event_notes_ins ON public.exos_event_notes FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
DROP POLICY IF EXISTS exos_event_notes_upd ON public.exos_event_notes;
CREATE POLICY exos_event_notes_upd ON public.exos_event_notes FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager'])
         OR (author_id = auth.uid() AND exos_has_org_role(org_id, ARRAY['content'])))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));
DROP POLICY IF EXISTS exos_event_notes_del ON public.exos_event_notes;
CREATE POLICY exos_event_notes_del ON public.exos_event_notes FOR DELETE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager'])
         OR (author_id = auth.uid() AND exos_has_org_role(org_id, ARRAY['content'])));

DROP POLICY IF EXISTS exos_event_contacts_sel ON public.exos_event_contacts;
CREATE POLICY exos_event_contacts_sel ON public.exos_event_contacts FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content', 'finance']));
DROP POLICY IF EXISTS exos_event_contacts_write ON public.exos_event_contacts;
CREATE POLICY exos_event_contacts_write ON public.exos_event_contacts FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner', 'manager', 'content']));

-- ===========================================================================
-- 6. Hold logic. Internal pieces first (no client grants).
-- ===========================================================================

-- The hold as the API and the webhooks show it.
CREATE OR REPLACE FUNCTION public._exos_hold_json(p_hold_id uuid)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', h.id, 'title', h.title, 'notes', h.notes, 'status', h.status,
    'artist_ids', to_jsonb(h.artist_ids), 'announce_at', h.announce_at,
    'ticket_forecast', h.ticket_forecast, 'age_restriction', h.age_restriction,
    'rental', CASE WHEN h.rental_status IS NULL THEN NULL ELSE jsonb_build_object(
      'status', h.rental_status, 'fee', h.rental_fee, 'deposit', h.rental_deposit,
      'currency', coalesce(h.rental_currency, 'USD'), 'notes', coalesce(h.rental_notes, '')) END,
    'first_date', h.first_date, 'last_date', h.last_date,
    'created_via', h.created_via, 'cleared_at', h.cleared_at, 'converted_at', h.converted_at,
    'created_at', h.created_at, 'updated_at', h.updated_at,
    'positions', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', p.id, 'date', p.date, 'venue_id', p.venue_id, 'room_id', p.room_id,
               'start_time', to_char(p.start_time, 'HH24:MI'), 'is_target', p.is_target,
               'level', p.level, 'status', p.status, 'event_id', p.event_id,
               'cleared_at', p.cleared_at, 'converted_at', p.converted_at)
             ORDER BY p.date, p.venue_id, p.room_id NULLS FIRST, p.id)
        FROM public.exos_hold_positions p WHERE p.hold_id = h.id), '[]'::jsonb))
  FROM public.exos_holds h WHERE h.id = p_hold_id
$$;
REVOKE ALL ON FUNCTION public._exos_hold_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_hold_json(uuid) TO service_role;

-- Renumber one slot to 1..N. p_target (optional) is re-inserted at p_level
-- (NULL = the end); everyone else keeps their order. Returns the holds whose
-- levels moved. Callers hold the org's hold lock.
CREATE OR REPLACE FUNCTION public._exos_slot_place(p_org uuid, p_venue uuid, p_room uuid, p_date date,
                                                   p_target uuid DEFAULT NULL, p_level integer DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_moved uuid[];
BEGIN
  WITH s AS (
    SELECT p.id, p.hold_id, p.level
      FROM public.exos_hold_positions p
     WHERE p.org_id = p_org AND p.venue_id = p_venue AND p.room_id IS NOT DISTINCT FROM p_room
       AND p.date = p_date AND p.status = 'active'
  ), others AS (
    SELECT id, hold_id, row_number() OVER (ORDER BY level, hold_id, id)::numeric AS k
      FROM s WHERE p_target IS NULL OR id <> p_target
  ), keyed AS (
    SELECT id, hold_id, k FROM others
    UNION ALL
    SELECT id, hold_id, CASE WHEN p_level IS NULL THEN 1e9 ELSE greatest(p_level, 1) - 0.5 END
      FROM s WHERE id = p_target
  ), ranked AS (
    SELECT id, row_number() OVER (ORDER BY k, hold_id, id)::int AS nl FROM keyed
  ), upd AS (
    UPDATE public.exos_hold_positions p SET level = r.nl
      FROM ranked r WHERE p.id = r.id AND p.level <> r.nl
    RETURNING p.hold_id
  )
  SELECT coalesce(array_agg(DISTINCT hold_id), '{}') INTO v_moved FROM upd;
  RETURN v_moved;
END $$;
REVOKE ALL ON FUNCTION public._exos_slot_place(uuid, uuid, uuid, date, uuid, integer) FROM PUBLIC, anon, authenticated;

-- Re-derive a hold's status / first / last date from its positions.
CREATE OR REPLACE FUNCTION public._exos_hold_refresh(p_hold_id uuid)
RETURNS void LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_holds h SET
    status = x.status,
    first_date = x.first_date, last_date = x.last_date,
    cleared_at = CASE WHEN x.status = 'cleared' THEN coalesce(h.cleared_at, now()) ELSE NULL END,
    converted_at = CASE WHEN x.any_converted THEN coalesce(h.converted_at, now()) ELSE NULL END
  FROM (
    SELECT CASE WHEN bool_or(status = 'active') THEN 'active'
                WHEN bool_or(status = 'converted') THEN 'converted' ELSE 'cleared' END AS status,
           bool_or(status = 'converted') AS any_converted,
           min(date) AS first_date, max(date) AS last_date
      FROM public.exos_hold_positions WHERE hold_id = p_hold_id
  ) x
  WHERE h.id = p_hold_id
    AND (h.status, h.first_date, h.last_date) IS DISTINCT FROM (x.status, x.first_date, x.last_date)
$$;
REVOKE ALL ON FUNCTION public._exos_hold_refresh(uuid) FROM PUBLIC, anon, authenticated;

-- Parse a time 'HH:MM' (or NULL).
CREATE OR REPLACE FUNCTION public._exos_hm(p text, p_field text)
RETURNS time LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p IS NULL OR p = '' THEN RETURN NULL; END IF;
  IF p !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION '% must be HH:MM (24-hour)', p_field USING ERRCODE = '22023';
  END IF;
  RETURN p::time;
END $$;
REVOKE ALL ON FUNCTION public._exos_hm(text, text) FROM PUBLIC, anon, authenticated;

-- jsonb text field → uuid, or a 22023 naming the field.
CREATE OR REPLACE FUNCTION public._exos_uuid(p text, p_field text)
RETURNS uuid LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p IS NULL OR p = '' THEN RETURN NULL; END IF;
  IF p !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION '% is not a valid id', p_field USING ERRCODE = '22023';
  END IF;
  RETURN p::uuid;
END $$;
REVOKE ALL ON FUNCTION public._exos_uuid(text, text) FROM PUBLIC, anon, authenticated;

-- Apply the plain (non-position) hold fields of p from a jsonb body.
CREATE OR REPLACE FUNCTION public._exos_hold_set_fields(p_hold_id uuid, p jsonb)
RETURNS void LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE r jsonb; v_artists uuid[];
BEGIN
  IF p ? 'title' THEN
    IF jsonb_typeof(p->'title') <> 'string' OR char_length(btrim(p->>'title')) NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'title is required (at most 100 characters)' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_holds SET title = btrim(p->>'title') WHERE id = p_hold_id;
  END IF;
  IF p ? 'notes' THEN
    IF char_length(coalesce(p->>'notes', '')) > 2000 THEN
      RAISE EXCEPTION 'notes must be at most 2000 characters' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_holds SET notes = coalesce(p->>'notes', '') WHERE id = p_hold_id;
  END IF;
  IF p ? 'artist_ids' THEN
    IF jsonb_typeof(p->'artist_ids') NOT IN ('array', 'null') THEN
      RAISE EXCEPTION 'artist_ids must be a list of ids' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT public._exos_uuid(x, 'artist_ids')), '{}') INTO v_artists
      FROM jsonb_array_elements_text(coalesce(p->'artist_ids', '[]')) x;
    IF cardinality(v_artists) > 20 THEN
      RAISE EXCEPTION 'artist_ids: at most 20' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_holds SET artist_ids = v_artists WHERE id = p_hold_id;
  END IF;
  IF p ? 'announce_at' THEN
    BEGIN
      UPDATE public.exos_holds SET announce_at = (p->>'announce_at')::timestamptz WHERE id = p_hold_id;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION 'announce_at must be an ISO 8601 time' USING ERRCODE = '22023';
    END;
  END IF;
  IF p ? 'ticket_forecast' THEN
    IF p->'ticket_forecast' <> 'null'::jsonb AND (jsonb_typeof(p->'ticket_forecast') <> 'number'
       OR (p->>'ticket_forecast')::numeric NOT BETWEEN 0 AND 1000000 OR (p->>'ticket_forecast')::numeric % 1 <> 0) THEN
      RAISE EXCEPTION 'ticket_forecast must be a whole number from 0' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_holds SET ticket_forecast = (p->>'ticket_forecast')::int WHERE id = p_hold_id;
  END IF;
  IF p ? 'age_restriction' THEN
    IF char_length(coalesce(p->>'age_restriction', '')) > 40 THEN
      RAISE EXCEPTION 'age_restriction must be at most 40 characters' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_holds SET age_restriction = nullif(btrim(p->>'age_restriction'), '') WHERE id = p_hold_id;
  END IF;
  IF p ? 'rental' THEN
    r := p->'rental';
    IF r IS NULL OR r = 'null'::jsonb THEN
      UPDATE public.exos_holds SET rental_status = NULL, rental_fee = NULL, rental_deposit = NULL,
             rental_currency = NULL, rental_notes = NULL WHERE id = p_hold_id;
    ELSE
      IF jsonb_typeof(r) <> 'object' THEN
        RAISE EXCEPTION 'rental must be an object' USING ERRCODE = '22023';
      END IF;
      IF coalesce(r->>'status', 'requested') NOT IN ('requested', 'confirmed', 'declined') THEN
        RAISE EXCEPTION 'rental.status must be one of requested, confirmed, declined' USING ERRCODE = '22023';
      END IF;
      IF upper(coalesce(nullif(r->>'currency', ''), 'USD')) !~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'rental.currency must be a 3-letter ISO 4217 code' USING ERRCODE = '22023';
      END IF;
      BEGIN
        UPDATE public.exos_holds SET
          rental_status = coalesce(r->>'status', 'requested'),
          rental_fee = round(nullif(r->>'fee', '')::numeric, 2),
          rental_deposit = round(nullif(r->>'deposit', '')::numeric, 2),
          rental_currency = upper(coalesce(nullif(r->>'currency', ''), 'USD')),
          rental_notes = coalesce(r->>'notes', '')
        WHERE id = p_hold_id;
      EXCEPTION WHEN invalid_text_representation OR check_violation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'rental.fee and rental.deposit must be non-negative amounts' USING ERRCODE = '22023';
      END;
      IF char_length(coalesce(r->>'notes', '')) > 1000 THEN
        RAISE EXCEPTION 'rental.notes must be at most 1000 characters' USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_set_fields(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- Add one new night to a hold (validated) and place it in its slot.
-- Returns the holds whose levels moved.
CREATE OR REPLACE FUNCTION public._exos_hold_add_position(p_org uuid, p_hold_id uuid, p jsonb, p_label text)
RETURNS uuid[] LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_date date; v_venue uuid; v_room uuid; v_level int; v_id uuid; v_n int;
BEGIN
  IF jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION '% must be an object', p_label USING ERRCODE = '22023';
  END IF;
  IF coalesce(p->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RAISE EXCEPTION '%.date must be a date written YYYY-MM-DD', p_label USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_date := (p->>'date')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '%.date must be a date written YYYY-MM-DD', p_label USING ERRCODE = '22023';
  END;
  IF to_char(v_date, 'YYYY-MM-DD') <> p->>'date' THEN
    RAISE EXCEPTION '%.date must be a real date', p_label USING ERRCODE = '22023';
  END IF;
  v_venue := public._exos_uuid(p->>'venue_id', p_label || '.venue_id');
  IF v_venue IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_venues WHERE id = v_venue AND org_id = p_org) THEN
    RAISE EXCEPTION '%.venue_id: venue not found in this organization', p_label USING ERRCODE = '22023';
  END IF;
  v_room := public._exos_uuid(p->>'room_id', p_label || '.room_id');
  IF v_room IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_venue_rooms WHERE id = v_room AND venue_id = v_venue) THEN
    RAISE EXCEPTION '%.room_id: room not found in that venue', p_label USING ERRCODE = '22023';
  END IF;
  IF p ? 'level' AND p->'level' <> 'null'::jsonb THEN
    IF jsonb_typeof(p->'level') <> 'number' OR (p->>'level')::numeric NOT BETWEEN 1 AND 50 OR (p->>'level')::numeric % 1 <> 0 THEN
      RAISE EXCEPTION '%.level must be a whole number from 1 to 50', p_label USING ERRCODE = '22023';
    END IF;
    v_level := (p->>'level')::int;
  END IF;
  SELECT count(*) INTO v_n FROM public.exos_hold_positions
   WHERE org_id = p_org AND venue_id = v_venue AND room_id IS NOT DISTINCT FROM v_room AND date = v_date AND status = 'active';
  IF v_n >= 50 THEN
    RAISE EXCEPTION '% already has 50 holds in that room', v_date USING ERRCODE = '54000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_hold_positions
              WHERE hold_id = p_hold_id AND venue_id = v_venue AND room_id IS NOT DISTINCT FROM v_room
                AND date = v_date AND status = 'active') THEN
    RAISE EXCEPTION 'This hold already has % in that room', v_date USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.exos_hold_positions (org_id, hold_id, venue_id, room_id, date, start_time, is_target, level)
  VALUES (p_org, p_hold_id, v_venue, v_room, v_date, public._exos_hm(p->>'start_time', p_label || '.start_time'),
          coalesce((p->>'is_target')::boolean, false), least(v_n + 1, 50))
  RETURNING id INTO v_id;
  RETURN public._exos_slot_place(p_org, v_venue, v_room, v_date, v_id, v_level);
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_add_position(uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;

-- Take active positions out of their slots (cleared or converted) and close
-- the gaps. Returns the holds whose levels moved.
CREATE OR REPLACE FUNCTION public._exos_hold_release(p_org uuid, p_position_ids uuid[], p_status text, p_event_id uuid DEFAULT NULL)
RETURNS uuid[] LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_moved uuid[] := '{}';
BEGIN
  FOR r IN
    UPDATE public.exos_hold_positions SET status = p_status,
           cleared_at = CASE WHEN p_status = 'cleared' THEN now() ELSE cleared_at END,
           converted_at = CASE WHEN p_status = 'converted' THEN now() ELSE converted_at END,
           event_id = CASE WHEN p_status = 'converted' THEN p_event_id ELSE event_id END
     WHERE id = ANY (p_position_ids) AND org_id = p_org AND status = 'active'
    RETURNING venue_id, room_id, date
  LOOP
    v_moved := v_moved || public._exos_slot_place(p_org, r.venue_id, r.room_id, r.date);
  END LOOP;
  RETURN v_moved;
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_release(uuid, uuid[], text, uuid) FROM PUBLIC, anon, authenticated;

-- Refresh every hold touched and send the webhooks: p_type for the target,
-- hold.updated for every other hold whose levels moved.
CREATE OR REPLACE FUNCTION public._exos_hold_finish(p_org uuid, p_hold_id uuid, p_moved uuid[], p_type text, p_extra jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid; v_hold jsonb;
BEGIN
  PERFORM public._exos_hold_refresh(p_hold_id);
  FOR v_id IN SELECT DISTINCT x FROM unnest(p_moved) x WHERE x IS NOT NULL AND x <> p_hold_id LOOP
    PERFORM public._exos_hold_refresh(v_id);
    PERFORM public.exos_enqueue_webhook(p_org, 'hold.updated',
      jsonb_build_object('hold', public._exos_hold_json(v_id), 'reason', 'level_changed'));
  END LOOP;
  v_hold := public._exos_hold_json(p_hold_id);
  PERFORM public.exos_enqueue_webhook(p_org, p_type, jsonb_build_object('hold', v_hold) || coalesce(p_extra, '{}'));
  RETURN v_hold;
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_finish(uuid, uuid, uuid[], text, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_hold_lock(p_org uuid)
RETURNS void LANGUAGE sql
SET search_path = public, pg_temp
AS $$ SELECT pg_advisory_xact_lock(hashtextextended('exos_holds:' || p_org::text, 0)) $$;
REVOKE ALL ON FUNCTION public._exos_hold_lock(uuid) FROM PUBLIC, anon, authenticated;

-- ---- Cores (service_role: the exos-api edge function, org from the key) ----

-- p: { title, notes?, artist_ids?, announce_at?, ticket_forecast?,
--      age_restriction?, rental?, positions: [{ date, venue_id, room_id?,
--      level?, start_time?, is_target? }] (1..30) }
CREATE OR REPLACE FUNCTION public._exos_hold_create(p_org uuid, p_actor uuid, p_via text, p_api_key uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid; v_moved uuid[] := '{}'; v_pos jsonb; i int := 0;
BEGIN
  IF p_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org) THEN
    RAISE EXCEPTION 'organization not found' USING ERRCODE = 'P0002';
  END IF;
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'body must be an object' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p->'title') IS DISTINCT FROM 'string' OR char_length(btrim(p->>'title')) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'title is required (at most 100 characters)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p->'positions') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'positions') NOT BETWEEN 1 AND 30 THEN
    RAISE EXCEPTION 'positions must be a list of 1 to 30 nights' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_hold_lock(p_org);
  INSERT INTO public.exos_holds (org_id, title, created_by, created_via, api_key_id)
  VALUES (p_org, btrim(p->>'title'), p_actor, coalesce(p_via, 'dashboard'), p_api_key)
  RETURNING id INTO v_id;
  PERFORM public._exos_hold_set_fields(v_id, p - 'title' - 'positions');
  FOR v_pos IN SELECT x FROM jsonb_array_elements(p->'positions') x LOOP
    v_moved := v_moved || public._exos_hold_add_position(p_org, v_id, v_pos, 'positions[' || i || ']');
    i := i + 1;
  END LOOP;
  RETURN public._exos_hold_finish(p_org, v_id, v_moved, 'hold.created');
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_create(uuid, uuid, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_hold_create(uuid, uuid, text, uuid, jsonb) TO service_role;

-- p: any of the create fields. `positions`, when sent, is the full list of
-- nights the hold keeps: an existing { id, level?, start_time?, is_target? }
-- or a new night; active nights left out are cleared.
CREATE OR REPLACE FUNCTION public._exos_hold_update(p_org uuid, p_hold_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_moved uuid[] := '{}'; v_item jsonb; v_pid uuid; v_keep uuid[] := '{}'; v_pos record; i int := 0;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' OR p = '{}'::jsonb THEN
    RAISE EXCEPTION 'Nothing to update' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_hold_lock(p_org);
  IF NOT EXISTS (SELECT 1 FROM public.exos_holds WHERE id = p_hold_id AND org_id = p_org) THEN
    RAISE EXCEPTION 'Hold not found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM public._exos_hold_set_fields(p_hold_id, p - 'positions');
  IF p ? 'positions' THEN
    IF jsonb_typeof(p->'positions') <> 'array' OR jsonb_array_length(p->'positions') > 30 THEN
      RAISE EXCEPTION 'positions must be a list of at most 30 nights' USING ERRCODE = '22023';
    END IF;
    -- Existing nights named: keep, maybe move / edit.
    FOR v_item IN SELECT x FROM jsonb_array_elements(p->'positions') x WHERE x ? 'id' LOOP
      v_pid := public._exos_uuid(v_item->>'id', 'positions[].id');
      SELECT * INTO v_pos FROM public.exos_hold_positions WHERE id = v_pid AND hold_id = p_hold_id AND status = 'active';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Position % is not an active night of this hold', v_pid USING ERRCODE = '22023';
      END IF;
      v_keep := v_keep || v_pid;
      IF v_item ? 'start_time' THEN
        UPDATE public.exos_hold_positions SET start_time = public._exos_hm(v_item->>'start_time', 'positions[].start_time') WHERE id = v_pid;
      END IF;
      IF v_item ? 'is_target' THEN
        UPDATE public.exos_hold_positions SET is_target = coalesce((v_item->>'is_target')::boolean, false) WHERE id = v_pid;
      END IF;
    END LOOP;
    -- Active nights left out are cleared.
    v_moved := v_moved || public._exos_hold_release(p_org,
      ARRAY(SELECT id FROM public.exos_hold_positions WHERE hold_id = p_hold_id AND status = 'active' AND NOT (id = ANY (v_keep))),
      'cleared');
    -- Level moves (after the clears, so levels read against the new line).
    FOR v_item IN SELECT x FROM jsonb_array_elements(p->'positions') x
                   WHERE x ? 'id' AND x->'level' IS NOT NULL AND x->'level' <> 'null'::jsonb LOOP
      IF jsonb_typeof(v_item->'level') <> 'number' OR (v_item->>'level')::numeric NOT BETWEEN 1 AND 50
         OR (v_item->>'level')::numeric % 1 <> 0 THEN
        RAISE EXCEPTION 'positions[].level must be a whole number from 1 to 50' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_pos FROM public.exos_hold_positions WHERE id = (v_item->>'id')::uuid;
      IF v_pos.level <> (v_item->>'level')::int THEN
        v_moved := v_moved || public._exos_slot_place(p_org, v_pos.venue_id, v_pos.room_id, v_pos.date, v_pos.id, (v_item->>'level')::int);
      END IF;
    END LOOP;
    -- New nights.
    FOR v_item IN SELECT x FROM jsonb_array_elements(p->'positions') x WHERE NOT (x ? 'id') LOOP
      v_moved := v_moved || public._exos_hold_add_position(p_org, p_hold_id, v_item, 'positions[new ' || i || ']');
      i := i + 1;
    END LOOP;
    IF (SELECT count(*) FROM public.exos_hold_positions WHERE hold_id = p_hold_id) > 30 THEN
      RAISE EXCEPTION 'A hold can have at most 30 nights' USING ERRCODE = '22023';
    END IF;
  END IF;
  UPDATE public.exos_holds SET updated_at = now() WHERE id = p_hold_id;
  RETURN public._exos_hold_finish(p_org, p_hold_id, v_moved, 'hold.updated');
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_update(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_hold_update(uuid, uuid, jsonb) TO service_role;

-- Clear nights: the listed positions (already-cleared ones are skipped), or
-- every active night (409 when there are none). The holds behind move up.
CREATE OR REPLACE FUNCTION public._exos_hold_clear(p_org uuid, p_hold_id uuid, p_position_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_ids uuid[]; v_bad uuid;
BEGIN
  PERFORM public._exos_hold_lock(p_org);
  IF NOT EXISTS (SELECT 1 FROM public.exos_holds WHERE id = p_hold_id AND org_id = p_org) THEN
    RAISE EXCEPTION 'Hold not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_position_ids IS NULL THEN
    v_ids := ARRAY(SELECT id FROM public.exos_hold_positions WHERE hold_id = p_hold_id AND status = 'active');
    IF cardinality(v_ids) = 0 THEN
      RAISE EXCEPTION 'This hold has no active nights' USING ERRCODE = '55000';
    END IF;
  ELSE
    SELECT x INTO v_bad FROM unnest(p_position_ids) x
     WHERE NOT EXISTS (SELECT 1 FROM public.exos_hold_positions WHERE id = x AND hold_id = p_hold_id) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'Position % is not a night of this hold', v_bad USING ERRCODE = 'P0002';
    END IF;
    v_ids := p_position_ids;
  END IF;
  RETURN public._exos_hold_finish(p_org, p_hold_id, public._exos_hold_release(p_org, v_ids, 'cleared'), 'hold.updated');
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_clear(uuid, uuid, uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_hold_clear(uuid, uuid, uuid[]) TO service_role;

-- Convert one active night into a draft event. p: { position_id } or
-- { date, room_id? }, plus time ('HH:MM', venue-local; default the night's
-- start_time, else 20:00), title?, capacity?, clear_holds_on_day? (also clear
-- every other hold's night at the venue that date). Returns
-- { hold, position_id, event_id }.
CREATE OR REPLACE FUNCTION public._exos_hold_convert(p_org uuid, p_actor uuid, p_via text, p_api_key uuid, p_hold_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hold public.exos_holds; v_pos public.exos_hold_positions; v_venue public.exos_venues; v_room public.exos_venue_rooms;
  v_n int; v_tz text; v_time time; v_local timestamp; v_start timestamptz; v_cap int; v_title text;
  v_name text; v_event uuid; v_moved uuid[] := '{}'; v_others uuid[]; v_off interval; v_creator uuid;
  v_h uuid; v_hold_json jsonb;
BEGIN
  p := coalesce(p, '{}'::jsonb);
  PERFORM public._exos_hold_lock(p_org);
  SELECT * INTO v_hold FROM public.exos_holds WHERE id = p_hold_id AND org_id = p_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hold not found' USING ERRCODE = 'P0002';
  END IF;
  -- Which night.
  IF coalesce(p->>'position_id', '') <> '' THEN
    SELECT * INTO v_pos FROM public.exos_hold_positions
     WHERE id = public._exos_uuid(p->>'position_id', 'position_id') AND hold_id = p_hold_id;
    IF NOT FOUND OR v_pos.status <> 'active' THEN
      RAISE EXCEPTION 'That night is not an active night of this hold' USING ERRCODE = '55000';
    END IF;
  ELSIF coalesce(p->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$' THEN
    SELECT count(*) INTO v_n FROM public.exos_hold_positions
     WHERE hold_id = p_hold_id AND status = 'active' AND date = (p->>'date')::date
       AND (coalesce(p->>'room_id', '') = '' OR room_id = public._exos_uuid(p->>'room_id', 'room_id'));
    IF v_n = 0 THEN
      RAISE EXCEPTION 'The hold has no active night on %', p->>'date' USING ERRCODE = '55000';
    ELSIF v_n > 1 THEN
      RAISE EXCEPTION 'The hold has several rooms that night; pass position_id' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_pos FROM public.exos_hold_positions
     WHERE hold_id = p_hold_id AND status = 'active' AND date = (p->>'date')::date
       AND (coalesce(p->>'room_id', '') = '' OR room_id = (p->>'room_id')::uuid);
  ELSE
    RAISE EXCEPTION 'position_id (or date) is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_venue FROM public.exos_venues WHERE id = v_pos.venue_id;
  IF v_pos.room_id IS NOT NULL THEN
    SELECT * INTO v_room FROM public.exos_venue_rooms WHERE id = v_pos.room_id;
  END IF;
  v_tz := coalesce(v_venue.timezone, 'UTC');
  v_time := coalesce(public._exos_hm(p->>'time', 'time'), v_pos.start_time, '20:00'::time);
  v_local := v_pos.date + v_time;
  v_start := v_local AT TIME ZONE v_tz;
  v_off := v_local - (v_start AT TIME ZONE 'UTC');
  IF p ? 'capacity' AND p->'capacity' <> 'null'::jsonb THEN
    IF jsonb_typeof(p->'capacity') <> 'number' OR (p->>'capacity')::numeric NOT BETWEEN 1 AND 1000000
       OR (p->>'capacity')::numeric % 1 <> 0 THEN
      RAISE EXCEPTION 'capacity must be a whole number from 1' USING ERRCODE = '22023';
    END IF;
    v_cap := (p->>'capacity')::int;
  ELSE
    v_cap := coalesce(nullif(v_room.capacity, 0), nullif(v_venue.capacity, 0), 100);
  END IF;
  IF p ? 'title' THEN
    IF jsonb_typeof(p->'title') <> 'string' OR char_length(btrim(p->>'title')) NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'title must be 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    v_title := btrim(p->>'title');
  ELSE
    v_title := v_hold.title;
  END IF;
  v_name := left(CASE WHEN v_room.id IS NULL THEN v_venue.name ELSE v_venue.name || ' — ' || v_room.name END, 200);
  v_creator := coalesce(p_actor, (SELECT owner_uid FROM public.exos_orgs WHERE id = p_org));

  -- The draft event: the night, in the venue's zone, one free GA tier.
  PERFORM set_config('exos.booking_convert', 'on', true);
  INSERT INTO public.exos_events (org_id, name, status, starts_at, timezone, occurs_at_local, venue_name,
                                  venue_location, venue_address, total_tickets, created_by,
                                  exos_venue_id, exos_room_id, hold_id, hold_position_id)
  VALUES (p_org, v_title, 'draft', v_start, v_tz,
          to_char(v_local, 'YYYY-MM-DD"T"HH24:MI:SS')
            || CASE WHEN v_off < interval '0' THEN '-' ELSE '+' END
            || to_char(justify_hours(abs(extract(epoch FROM v_off))::int * interval '1 second'), 'HH24:MI'),
          v_name,
          nullif(concat_ws(', ', nullif(v_venue.address->>'city', ''), nullif(v_venue.address->>'region', '')), ''),
          v_venue.address, v_cap, v_creator,
          v_venue.id, v_room.id, p_hold_id, v_pos.id)
  RETURNING id INTO v_event;
  PERFORM set_config('exos.booking_convert', 'off', true);
  INSERT INTO public.exos_ticket_tiers (event_id, name, price, capacity, ticket_type, sort_order)
  VALUES (v_event, 'General Admission', 0, v_cap, 'free', 0);
  -- An announce time still ahead becomes the schedule's Announce row; the
  -- hold's notes become the show's first staff note.
  IF v_hold.announce_at IS NOT NULL AND v_hold.announce_at > now() THEN
    INSERT INTO public.exos_show_activities (org_id, event_id, kind, name, starts_at, created_by)
    VALUES (p_org, v_event, 'announce', 'Announce', v_hold.announce_at, v_creator);
  END IF;
  IF btrim(v_hold.notes) <> '' THEN
    INSERT INTO public.exos_event_notes (org_id, event_id, body, author_id, author_name)
    VALUES (p_org, v_event, left(v_hold.notes, 5000), v_creator, 'From the hold');
  END IF;

  -- The night leaves its line; the hold's other rooms that night drop away
  -- (and, if asked, every other hold's night at this venue that date).
  v_moved := public._exos_hold_release(p_org, ARRAY[v_pos.id], 'converted', v_event);
  v_moved := v_moved || public._exos_hold_release(p_org,
    ARRAY(SELECT id FROM public.exos_hold_positions
           WHERE hold_id = p_hold_id AND status = 'active' AND date = v_pos.date), 'cleared');
  IF coalesce((p->>'clear_holds_on_day')::boolean, false) THEN
    v_others := ARRAY(SELECT id FROM public.exos_hold_positions
                       WHERE org_id = p_org AND venue_id = v_pos.venue_id AND date = v_pos.date AND status = 'active');
    v_moved := v_moved || ARRAY(SELECT DISTINCT hold_id FROM public.exos_hold_positions WHERE id = ANY (v_others));
    v_moved := v_moved || public._exos_hold_release(p_org, v_others, 'cleared');
  END IF;
  v_hold_json := public._exos_hold_finish(p_org, p_hold_id, v_moved, 'hold.converted',
    jsonb_build_object('position_id', v_pos.id, 'event', jsonb_build_object(
      'id', v_event, 'name', v_title, 'status', 'draft', 'starts_at', v_start, 'timezone', v_tz,
      'venue_name', v_name, 'total_tickets', v_cap)));
  RETURN jsonb_build_object('hold', v_hold_json, 'position_id', v_pos.id, 'event_id', v_event);
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_convert(uuid, uuid, text, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_hold_convert(uuid, uuid, text, uuid, uuid, jsonb) TO service_role;

-- ---- Signed-in wrappers (owner / manager of the hold's org) ----------------
-- The same answer (42501) for "no such hold" and "not yours", so ids can't be
-- probed.
CREATE OR REPLACE FUNCTION public._exos_hold_org_for_staff(p_hold_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_holds WHERE id = p_hold_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN v_org;
END $$;
REVOKE ALL ON FUNCTION public._exos_hold_org_for_staff(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_hold_create(p_org_id uuid, p_hold jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_hold_create(p_org_id, auth.uid(), 'dashboard', NULL, p_hold);
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_create(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_hold_create(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_hold_update(p_hold_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_hold_update(public._exos_hold_org_for_staff(p_hold_id), p_hold_id, p_patch);
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_update(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_hold_update(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_hold_clear(p_hold_id uuid, p_position_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_hold_clear(public._exos_hold_org_for_staff(p_hold_id), p_hold_id, p_position_ids);
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_clear(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_hold_clear(uuid, uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_hold_convert(p_hold_id uuid, p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._exos_hold_convert(public._exos_hold_org_for_staff(p_hold_id), auth.uid(), 'dashboard', NULL,
                                   p_hold_id, p_args);
END $$;
REVOKE ALL ON FUNCTION public.exos_hold_convert(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_hold_convert(uuid, jsonb) TO authenticated;

COMMENT ON TABLE public.exos_holds IS
  'mig 20261030100000: calendar holds (docs/booking.md). Written only by exos_hold_* / _exos_hold_*; levels per org + venue + room + date in exos_hold_positions.';
COMMENT ON TABLE public.exos_hold_positions IS
  'mig 20261030100000: one held night of a hold. Active levels in a slot are always 1..N.';

-- ===========================================================================
-- 7. Reads for exos-api (service_role; the org comes from the API key)
-- ===========================================================================

-- A page of holds, ordered by first night then id.
-- Filters match any night of the hold (whatever its status): from / to on the
-- date, venue, room; status on the hold; q in the title.
CREATE OR REPLACE FUNCTION public._exos_holds_page(p_org uuid, p_from date, p_to date, p_venue uuid, p_room uuid,
                                                   p_status text, p_q text, p_limit integer, p_offset integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH m AS (
    SELECT h.id, h.first_date
      FROM public.exos_holds h
     WHERE h.org_id = p_org
       AND (p_status IS NULL OR h.status = p_status)
       AND (p_q IS NULL OR h.title ILIKE '%' || replace(replace(replace(p_q, '\', '\\'), '%', '\%'), '_', '\_') || '%')
       AND (p_from IS NULL AND p_to IS NULL AND p_venue IS NULL AND p_room IS NULL
            OR EXISTS (SELECT 1 FROM public.exos_hold_positions p
                        WHERE p.hold_id = h.id
                          AND (p_from IS NULL OR p.date >= p_from) AND (p_to IS NULL OR p.date <= p_to)
                          AND (p_venue IS NULL OR p.venue_id = p_venue) AND (p_room IS NULL OR p.room_id = p_room)))
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM m),
    'data', coalesce((SELECT jsonb_agg(public._exos_hold_json(x.id) ORDER BY x.first_date NULLS LAST, x.id)
                        FROM (SELECT id, first_date FROM m ORDER BY first_date NULLS LAST, id
                               LIMIT least(greatest(p_limit, 1), 200) OFFSET greatest(p_offset, 0)) x), '[]'::jsonb))
$$;
REVOKE ALL ON FUNCTION public._exos_holds_page(uuid, date, date, uuid, uuid, text, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_holds_page(uuid, date, date, uuid, uuid, text, text, integer, integer) TO service_role;

-- The calendar between two dates (at most 92 days): every active hold night
-- with its hold's title and the slot's size, and every event of the org that
-- night (its local date), with the venue / room it is linked to. A night is
-- `challenged` when its slot has more than one hold or a non-cancelled event
-- is booked in the same room (or the whole venue) that date.
CREATE OR REPLACE FUNCTION public._exos_booking_calendar(p_org uuid, p_from date, p_to date, p_venue uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 92 THEN
    RAISE EXCEPTION 'from and to are required, to not before from, at most 92 days apart' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH ev AS (
      SELECT e.id, e.name, e.status, e.starts_at, e.timezone, e.exos_venue_id, e.exos_room_id, e.hold_id,
             (e.starts_at AT TIME ZONE coalesce(nullif(e.timezone, ''), 'UTC'))::date AS local_date
        FROM public.exos_events e
       WHERE e.org_id = p_org AND e.starts_at IS NOT NULL
         AND e.starts_at >= (p_from - 1)::timestamp AT TIME ZONE 'UTC'
         AND e.starts_at < (p_to + 2)::timestamp AT TIME ZONE 'UTC'
         AND (p_venue IS NULL OR e.exos_venue_id = p_venue)
    ), evd AS (
      SELECT * FROM ev WHERE local_date BETWEEN p_from AND p_to
    ), pos AS (
      SELECT p.id, p.hold_id, h.title, p.venue_id, p.room_id, p.date, p.level, p.is_target, p.start_time,
             count(*) OVER (PARTITION BY p.venue_id, p.room_id, p.date) AS holds_in_slot
        FROM public.exos_hold_positions p JOIN public.exos_holds h ON h.id = p.hold_id
       WHERE p.org_id = p_org AND p.status = 'active' AND p.date BETWEEN p_from AND p_to
         AND (p_venue IS NULL OR p.venue_id = p_venue)
    )
    SELECT jsonb_build_object(
      'from', p_from, 'to', p_to,
      'holds', coalesce((SELECT jsonb_agg(jsonb_build_object(
          'position_id', pos.id, 'hold_id', pos.hold_id, 'title', pos.title, 'date', pos.date,
          'venue_id', pos.venue_id, 'room_id', pos.room_id, 'level', pos.level, 'is_target', pos.is_target,
          'start_time', to_char(pos.start_time, 'HH24:MI'), 'holds_in_slot', pos.holds_in_slot,
          'challenged', pos.holds_in_slot > 1 OR EXISTS (
            SELECT 1 FROM evd WHERE evd.status <> 'cancelled' AND evd.exos_venue_id = pos.venue_id
               AND evd.local_date = pos.date
               AND (pos.room_id IS NULL OR evd.exos_room_id IS NULL OR evd.exos_room_id = pos.room_id)))
        ORDER BY pos.date, pos.venue_id, pos.room_id NULLS FIRST, pos.level) FROM pos), '[]'::jsonb),
      'events', coalesce((SELECT jsonb_agg(jsonb_build_object(
          'id', evd.id, 'name', evd.name, 'status', evd.status, 'starts_at', evd.starts_at, 'date', evd.local_date,
          'venue_id', evd.exos_venue_id, 'room_id', evd.exos_room_id, 'hold_id', evd.hold_id)
        ORDER BY evd.starts_at, evd.id) FROM evd), '[]'::jsonb)));
END $$;
REVOKE ALL ON FUNCTION public._exos_booking_calendar(uuid, date, date, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_booking_calendar(uuid, date, date, uuid) TO service_role;
