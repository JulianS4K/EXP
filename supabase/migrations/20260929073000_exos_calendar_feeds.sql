-- ============================================================================
-- Migration 20260929073000 — Exos (Bridge / D4): calendar feeds
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  C: TABLE exos_calendar_feed_tokens;
--              FUNCTION exos_venue_slug, exos_venue_key,
--                exos_calendar_feed_token_create, exos_calendar_feed_token_revoke,
--                exos_calendar_feed_token_status (signed-in users, own token only),
--                exos_calendar_event_rows, exos_calendar_public_feed,
--                exos_calendar_my_feed (service role only)
--           R: exos_events, exos_orgs, exos_event_geo, exos_tickets,
--              exos_org_follows (20260520140000), auth.users
-- Pre-reqs: 20260924230000 (exos_event_geo), 20260520140000 (exos_org_follows)
--
-- The exos-calendar edge function (docs/calendar.md) serves .ics feeds a
-- calendar app subscribes to: an organizer's events, a venue's events, one
-- event ("add to calendar"), and a per-user feed of the organizers they
-- follow plus the events they hold tickets for. These are its reads.
--
-- Public feeds (org / venue / event) only carry what the event page already
-- shows: published events, and cancelled ones that were on sale (so a
-- subscriber's calendar shows the cancellation instead of silently dropping
-- the entry). Coordinates only while fresh (the 30-day Google caching limit,
-- as exos_public_event_geo).
--
-- Personal feed: calendar apps can't send an Authorization header, so the
-- feed URL carries an unguessable token (exc_ + 48 hex). Only its SHA-256 is
-- stored; the raw token is returned once by exos_calendar_feed_token_create
-- (which also rotates: the old token stops working). One live token per user.
-- The feed holds only that user's followed organizers' events and the events
-- they hold tickets for; no ticket, order or other buyer data. A deleted
-- account (tombstoned by exos_delete_my_account) resolves to nothing.
--
-- Venue key: slug(venue_name, else venue_location) [ "--" slug(city) ], slug = NFKD, drop
-- combining marks, lowercase, runs of non [a-z0-9] -> "-", trimmed, <= 60.
-- Mirrors venueKey() in supabase/functions/_shared/calendar/feed.ts (same
-- test vectors in tests/exos/test_calendar_feeds.sql and feed.test.ts).
-- "place-<Google Place ID>" is a second key form for geocoded venues.
--
-- Re-run safe (IF NOT EXISTS / CREATE OR REPLACE). D4 authors; applying to
-- prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-user feed tokens (hash only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_calendar_feed_tokens (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  token_hash   text        NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  last_used_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_calendar_feed_tokens_one_live
  ON public.exos_calendar_feed_tokens (user_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_calendar_feed_tokens_user_idx
  ON public.exos_calendar_feed_tokens (user_id, created_at);

-- No client reads the table at all (not even its own rows): the status RPC
-- returns the safe columns. Service role only.
ALTER TABLE public.exos_calendar_feed_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_calendar_feed_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_calendar_feed_tokens TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Venue key (pure)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_venue_slug(p text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT regexp_replace(
           left(btrim(regexp_replace(lower(regexp_replace(normalize(coalesce(p, ''), NFKD), '[̀-ͯ]', '', 'g')),
                                     '[^a-z0-9]+', '-', 'g'), '-'), 60),
           '-+$', '');
$$;

CREATE OR REPLACE FUNCTION public.exos_venue_key(p_name text, p_address jsonb)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN public.exos_venue_slug(p_name) = '' THEN NULL
           WHEN public.exos_venue_slug(p_address ->> 'city') = '' THEN public.exos_venue_slug(p_name)
           ELSE public.exos_venue_slug(p_name) || '--' || public.exos_venue_slug(p_address ->> 'city')
         END;
$$;
REVOKE ALL ON FUNCTION public.exos_venue_slug(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.exos_venue_key(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_venue_slug(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_venue_key(text, jsonb) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. My feed token: create / rotate, revoke, status (signed-in users)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_calendar_feed_token_create()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_token text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_calendar_feed_token_create: not authenticated' USING ERRCODE = '42501';
  END IF;
  -- One rotation at a time per user (the one-live-token index would reject a
  -- racing insert anyway; this makes it wait instead of fail).
  PERFORM pg_advisory_xact_lock(hashtext('exos_calendar_feed_token:' || v_uid::text));
  IF (SELECT count(*) FROM public.exos_calendar_feed_tokens
       WHERE user_id = v_uid AND created_at > now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'exos_calendar_feed_token_create: too many new feed links, try again later' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.exos_calendar_feed_tokens SET revoked_at = now()
   WHERE user_id = v_uid AND revoked_at IS NULL;
  v_token := 'exc_' || encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.exos_calendar_feed_tokens (user_id, token_hash)
  VALUES (v_uid, encode(extensions.digest(v_token, 'sha256'), 'hex'));
  RETURN v_token;   -- shown once; only the hash is kept
END $$;

CREATE OR REPLACE FUNCTION public.exos_calendar_feed_token_revoke()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_calendar_feed_token_revoke: not authenticated' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_calendar_feed_tokens SET revoked_at = now()
   WHERE user_id = v_uid AND revoked_at IS NULL;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;

-- Whether I have a live feed link, and when it was made / last fetched. Never the hash.
CREATE OR REPLACE FUNCTION public.exos_calendar_feed_token_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); r record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_calendar_feed_token_status: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT created_at, last_used_at INTO r FROM public.exos_calendar_feed_tokens
   WHERE user_id = v_uid AND revoked_at IS NULL;
  IF NOT FOUND THEN RETURN jsonb_build_object('active', false); END IF;
  RETURN jsonb_build_object('active', true, 'created_at', r.created_at, 'last_used_at', r.last_used_at);
END $$;

REVOKE ALL ON FUNCTION public.exos_calendar_feed_token_create() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_calendar_feed_token_revoke() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_calendar_feed_token_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_calendar_feed_token_create() TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_calendar_feed_token_revoke() TO authenticated;
GRANT EXECUTE ON FUNCTION public.exos_calendar_feed_token_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Feed reads (service role: the exos-calendar edge function)
-- ---------------------------------------------------------------------------

-- The public calendar fields of these events, in start order. `p_ticketed`
-- marks the ones the /me subscriber holds tickets for.
CREATE OR REPLACE FUNCTION public.exos_calendar_event_rows(p_ids uuid[], p_ticketed uuid[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', e.id, 'slug', e.slug, 'name', e.name, 'description', e.description,
             'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
             'doors_at', e.doors_at, 'timezone', e.timezone,
             'venue_name', coalesce(e.venue_name, e.venue_location), 'venue_address', e.venue_address,
             'image_url', e.image_url, 'updated_at', e.updated_at,
             'org_name', o.name, 'org_slug', o.slug,
             'lat', CASE WHEN g.geocoded_at > now() - interval '30 days' THEN g.lat END,
             'lng', CASE WHEN g.geocoded_at > now() - interval '30 days' THEN g.lng END,
             'place_id', g.place_id,
             'venue_key', public.exos_venue_key(coalesce(e.venue_name, e.venue_location), e.venue_address),
             'has_tickets', e.id = ANY (coalesce(p_ticketed, '{}')))
           ORDER BY e.starts_at, e.id)
      FROM public.exos_events e
      JOIN public.exos_orgs o ON o.id = e.org_id
      LEFT JOIN public.exos_event_geo g ON g.event_id = e.id AND g.status = 'ok'
     WHERE e.id = ANY (coalesce(p_ids, '{}'))
  ), '[]'::jsonb);
END $$;

-- org / venue / event feeds. NULL when there's nothing public by that name.
--   org   p_ref = org slug          upcoming + last 30 days, max 500
--   venue p_ref = venue key         same window; "place-<id>" or a name key
--   event p_ref = event uuid        that one event, any date
CREATE OR REPLACE FUNCTION public.exos_calendar_public_feed(p_kind text, p_ref text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_since timestamptz := now() - interval '30 days';
  v_ids   uuid[];
  v_org   record;
  v_ev    record;
  v_place text;
BEGIN
  IF p_ref IS NULL OR length(p_ref) > 320 THEN RETURN NULL; END IF;

  IF p_kind = 'org' THEN
    SELECT o.id, o.name, o.slug INTO v_org FROM public.exos_orgs o WHERE o.slug = p_ref;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT array_agg(x.id ORDER BY x.starts_at) INTO v_ids FROM (
      SELECT e.id, e.starts_at FROM public.exos_events e
       WHERE e.org_id = v_org.id AND e.starts_at >= v_since
         AND (e.status = 'published' OR (e.status = 'cancelled' AND e.tickets_sold > 0))
       ORDER BY e.starts_at LIMIT 500) x;
    RETURN jsonb_build_object('kind', 'org', 'name', v_org.name, 'slug', v_org.slug,
      'timezone', (SELECT mode() WITHIN GROUP (ORDER BY e.timezone) FROM public.exos_events e WHERE e.id = ANY (coalesce(v_ids, '{}'))),
      'events', public.exos_calendar_event_rows(v_ids));

  ELSIF p_kind = 'venue' THEN
    IF p_ref LIKE 'place-%' THEN
      v_place := substr(p_ref, 7);
      SELECT array_agg(x.id ORDER BY x.starts_at) INTO v_ids FROM (
        SELECT e.id, e.starts_at FROM public.exos_events e
          JOIN public.exos_event_geo g ON g.event_id = e.id AND g.place_id = v_place
         WHERE e.starts_at >= v_since
           AND (e.status = 'published' OR (e.status = 'cancelled' AND e.tickets_sold > 0))
         ORDER BY e.starts_at LIMIT 500) x;
      -- The newest public event there names the calendar; none ever: unknown.
      SELECT coalesce(e.venue_name, e.venue_location) AS venue_name, e.venue_address, e.timezone INTO v_ev FROM public.exos_events e
        JOIN public.exos_event_geo g ON g.event_id = e.id AND g.place_id = v_place
       WHERE e.status IN ('published', 'cancelled') ORDER BY e.starts_at DESC NULLS LAST LIMIT 1;
    ELSE
      SELECT array_agg(x.id ORDER BY x.starts_at) INTO v_ids FROM (
        SELECT e.id, e.starts_at FROM public.exos_events e
         WHERE e.starts_at >= v_since
           AND (e.status = 'published' OR (e.status = 'cancelled' AND e.tickets_sold > 0))
           AND (public.exos_venue_key(coalesce(e.venue_name, e.venue_location), e.venue_address) = p_ref
                OR EXISTS (   -- geocoded to the same place as an event under this key
                  SELECT 1 FROM public.exos_event_geo g
                   WHERE g.event_id = e.id AND g.place_id IS NOT NULL
                     AND g.place_id IN (
                       SELECT g2.place_id FROM public.exos_event_geo g2
                         JOIN public.exos_events e2 ON e2.id = g2.event_id
                        WHERE e2.status IN ('published', 'cancelled')
                          AND public.exos_venue_key(coalesce(e2.venue_name, e2.venue_location), e2.venue_address) = p_ref)))
         ORDER BY e.starts_at LIMIT 500) x;
      SELECT coalesce(e.venue_name, e.venue_location) AS venue_name, e.venue_address, e.timezone INTO v_ev FROM public.exos_events e
       WHERE e.status IN ('published', 'cancelled')
         AND public.exos_venue_key(coalesce(e.venue_name, e.venue_location), e.venue_address) = p_ref
       ORDER BY e.starts_at DESC NULLS LAST LIMIT 1;
    END IF;
    IF v_ev IS NULL OR v_ev.venue_name IS NULL THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('kind', 'venue', 'key', p_ref,
      'name', concat_ws(', ', btrim(v_ev.venue_name), nullif(btrim(v_ev.venue_address ->> 'city'), '')),
      'timezone', v_ev.timezone,
      'events', public.exos_calendar_event_rows(v_ids));

  ELSIF p_kind = 'event' THEN
    IF p_ref !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN NULL; END IF;
    SELECT e.id, e.name, e.timezone INTO v_ev FROM public.exos_events e
     WHERE e.id = p_ref::uuid
       AND (e.status = 'published' OR (e.status = 'cancelled' AND e.tickets_sold > 0));
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('kind', 'event', 'name', v_ev.name, 'timezone', v_ev.timezone,
      'events', public.exos_calendar_event_rows(ARRAY[v_ev.id]));
  END IF;
  RETURN NULL;
END $$;

-- The /me feed for a token hash: the user's followed organizers' public events
-- and the events they hold tickets for (upcoming + last 30 days, max 500).
-- NULL for an unknown or revoked token, or a deleted account.
CREATE OR REPLACE FUNCTION public.exos_calendar_my_feed(p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_since    timestamptz := now() - interval '30 days';
  v_tok      record;
  v_ticketed uuid[];
  v_ids      uuid[];
BEGIN
  IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT t.id, t.user_id, t.last_used_at INTO v_tok FROM public.exos_calendar_feed_tokens t
   WHERE t.token_hash = p_token_hash AND t.revoked_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- exos_delete_my_account tombstones the login rather than deleting it.
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_tok.user_id
                  AND coalesce(u.email, '') NOT LIKE 'deleted+%@deleted.invalid') THEN
    RETURN NULL;
  END IF;
  IF v_tok.last_used_at IS NULL OR v_tok.last_used_at < now() - interval '1 hour' THEN
    UPDATE public.exos_calendar_feed_tokens SET last_used_at = now() WHERE id = v_tok.id;
  END IF;

  -- Tickets they hold now (a transferred-away or refunded ticket doesn't
  -- count); for a cancelled event, any ticket they had, so the entry shows
  -- the cancellation.
  SELECT coalesce(array_agg(DISTINCT t.event_id), '{}') INTO v_ticketed
    FROM public.exos_tickets t
    JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.owner_id = v_tok.user_id
     AND e.starts_at >= v_since
     AND ((e.status = 'published' AND t.status IN ('active', 'used'))
          OR (e.status = 'cancelled' AND t.status IN ('active', 'used', 'voided')));

  SELECT array_agg(x.id ORDER BY x.starts_at) INTO v_ids FROM (
    SELECT e.id, e.starts_at FROM public.exos_events e
     WHERE e.id = ANY (v_ticketed)
        OR (e.starts_at >= v_since
            AND (e.status = 'published' OR (e.status = 'cancelled' AND e.tickets_sold > 0))
            AND e.org_id IN (SELECT f.org_id FROM public.exos_org_follows f WHERE f.follower_uid = v_tok.user_id))
     ORDER BY e.starts_at LIMIT 500) x;

  RETURN jsonb_build_object('kind', 'me', 'name', 'My Exos events',
    'events', public.exos_calendar_event_rows(v_ids, v_ticketed));
END $$;

REVOKE ALL ON FUNCTION public.exos_calendar_event_rows(uuid[], uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_calendar_public_feed(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.exos_calendar_my_feed(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_calendar_event_rows(uuid[], uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_calendar_public_feed(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.exos_calendar_my_feed(text) TO service_role;
