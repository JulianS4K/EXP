-- ============================================================================
-- Migration 20261030110000 — Exos: artists, lineups and the public listing feed
--
-- Touches:  W: TABLE exos_artists, exos_event_lineup, exos_listing_keys (new)
--              FUNCTION _exos_spotify_artist_id, _exos_slugify,
--                       _exos_artist_json, _exos_lineup_json,
--                       _exos_lineup_sync_performers, _exos_tg_lineup_guard,
--                       _exos_artist_save, _exos_artist_merge, _exos_lineup_save,
--                       _exos_listing_key_create, _exos_listing_key_revoke,
--                       _exos_listing_feed_event, exos_listing_feed_source,
--                       exos_api_artist_events (new, service role only)
--              FUNCTION exos_artist_save, exos_artist_merge, exos_lineup_save,
--                       exos_listing_key_create, exos_listing_key_revoke
--                       (new, signed-in org staff)
--              FUNCTION exos_public_lineups (new, anon: published events only)
--           W: exos_events.performer_names (derived from the lineup on save,
--              where the column exists)
--           R: exos_events, exos_ticket_tiers, exos_orgs, exos_org_memberships
-- Pre-reqs: 20261027090000 (partner API scopes; the feed lives in exos-api)
--
-- Port of the Firebase build's round-12 "Opendate parity" artists + listing
-- feed (Exos-Bridge server/artists.ts, server/listingFeed.ts). docs/listing-feed.md.
--
-- Artists: an organization's record of an act. One canonical Spotify id
-- (22 base-62 characters) parsed from whatever the organizer pastes (URL,
-- spotify:artist: URI or bare id); the URI and URL are derived on every read
-- (_exos_artist_json) so the three can never disagree. Permalinks are unique
-- per org (generated `lumen`, `lumen-2`, …; an explicit taken one is refused).
-- Duplicates are merged: the source keeps its row as an alias
-- (canonical_artist_id), every lineup slot moves to the target, and later
-- lineup saves naming the source get the target.
--
-- Lineups: ordered slots (artist, act type, position 1..n, optional set time)
-- in exos_event_lineup, a child table (the Firebase build kept an array on the
-- event document to save reads; here a join is free and an artist rename needs
-- no snapshot refresh). Every save rewrites exos_events.performer_names (the
-- first 10 names), so emails, the catalog / Google / calendar feeds and the
-- partner API keep working unchanged. The store-content `lineup` jsonb
-- (mig 20260929120000) is the organizer's free-text bill and is left alone.
--
-- Listing feed: per-partner shared keys (sh_live_…, shown once; only the
-- SHA-256 hash and a 16-character prefix are stored, like exos_api_keys). The
-- exos-api edge function hashes the presented key and calls
-- exos_listing_feed_source, which answers the key's org's listable events:
-- published, starting at/after the cutoff, not link-only
-- (exclusivity.customUrlOnly). Venue fields are redacted for an event whose
-- row says secret_location = true (only `location_area` is shown) — that
-- column does not exist yet (venues and their privacy belong to booking); the
-- function reads the row through to_jsonb so the redaction starts working the
-- day the column lands, with no change here. Same for `venue_id` /
-- `venue_permalink`.
--
-- Writes go through the SECURITY DEFINER functions only (no client INSERT /
-- UPDATE / DELETE on the three tables). The `_exos_*` core functions take the
-- org explicitly and are for the service role (exos-api, authenticated by an
-- org API key); the `exos_*` wrappers check the caller's org role and pass
-- auth.uid().
--
-- Additive, re-run safe. Prod apply needs operator OK.
-- ROLLBACK: DROP the three tables and the functions above; then restore
-- performer_names from the editor if needed (the lineup only ever rewrote it
-- for events that had a lineup).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Pure helpers.
-- ---------------------------------------------------------------------------

-- One canonical Spotify artist id from a URL, a spotify:artist: URI or a bare
-- id. NULL for empty input; anything else raises 22023. Mirrors
-- parseSpotifyArtist in supabase/functions/_shared/artists.ts.
CREATE OR REPLACE FUNCTION public._exos_spotify_artist_id(p_input text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  s text := btrim(coalesce(p_input, ''));
  m text[];
BEGIN
  IF s = '' THEN RETURN NULL; END IF;
  IF length(s) > 300 THEN
    RAISE EXCEPTION 'spotify: not a Spotify artist link, URI or id' USING ERRCODE = '22023';
  END IF;
  IF s ~ '^[0-9A-Za-z]{22}$' THEN RETURN s; END IF;
  m := regexp_match(s, '^spotify:artist:([0-9A-Za-z]{22})$', 'i');
  IF m IS NOT NULL THEN RETURN m[1]; END IF;
  m := regexp_match(s,
    '^(?:https?://)?(?:open|play)\.spotify\.com/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?(?:embed/)?artist/([0-9A-Za-z]{22})(?:[/?#].*)?$', 'i');
  IF m IS NOT NULL THEN RETURN m[1]; END IF;
  RAISE EXCEPTION 'spotify: not a Spotify artist link, URI or id' USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public._exos_spotify_artist_id(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_spotify_artist_id(text) TO service_role;

-- URL-safe permalink: "Beyoncé & Jay-Z" -> "beyonce-and-jay-z"; "artist" when
-- nothing is left. Common Latin accents are folded; anything else non-ASCII
-- becomes a dash.
CREATE OR REPLACE FUNCTION public._exos_slugify(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(nullif(
    regexp_replace(left(
      regexp_replace(
        regexp_replace(
          lower(translate(replace(coalesce(p_text, ''), '&', ' and '),
            'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿÑñÇçß',
            'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOOooooooUUUUuuuuYyyNnCcs')),
          '[^a-z0-9]+', '-', 'g'),
        '^-+|-+$', '', 'g'),
      80), '-+$', ''),
    ''), 'artist')
$$;
REVOKE ALL ON FUNCTION public._exos_slugify(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_slugify(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 1. Tables.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.exos_artists (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  name                text NOT NULL,
  permalink           text NOT NULL,
  bio                 text,
  genres              text[] NOT NULL DEFAULT '{}'::text[],
  links               jsonb NOT NULL DEFAULT '{}'::jsonb,
  image_url           text,
  image_thumb_url     text,
  spotify_id          text,
  canonical_artist_id uuid REFERENCES public.exos_artists(id) ON DELETE SET NULL,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_artists_name_chk CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  CONSTRAINT exos_artists_permalink_chk CHECK (permalink ~ '^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$'),
  CONSTRAINT exos_artists_permalink_uq UNIQUE (org_id, permalink),
  CONSTRAINT exos_artists_bio_chk CHECK (bio IS NULL OR length(bio) <= 4000),
  CONSTRAINT exos_artists_genres_chk CHECK (cardinality(genres) <= 10),
  CONSTRAINT exos_artists_links_chk CHECK (jsonb_typeof(links) = 'object'),
  CONSTRAINT exos_artists_image_chk CHECK (image_url IS NULL OR (image_url ~ '^https://' AND length(image_url) <= 1000)),
  CONSTRAINT exos_artists_thumb_chk CHECK (image_thumb_url IS NULL OR (image_thumb_url ~ '^https://' AND length(image_thumb_url) <= 1000)),
  CONSTRAINT exos_artists_spotify_chk CHECK (spotify_id IS NULL OR spotify_id ~ '^[0-9A-Za-z]{22}$'),
  CONSTRAINT exos_artists_not_self_chk CHECK (canonical_artist_id IS DISTINCT FROM id)
);
CREATE INDEX IF NOT EXISTS exos_artists_org_name_idx ON public.exos_artists (org_id, lower(name));
CREATE INDEX IF NOT EXISTS exos_artists_org_spotify_idx ON public.exos_artists (org_id, spotify_id) WHERE spotify_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_artists_canonical_idx ON public.exos_artists (canonical_artist_id) WHERE canonical_artist_id IS NOT NULL;
DROP TRIGGER IF EXISTS exos_artists_touch ON public.exos_artists;
CREATE TRIGGER exos_artists_touch BEFORE UPDATE ON public.exos_artists
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_artists IS
  'mig 20261030110000: an org''s artists (docs/listing-feed.md). Written only by
   exos_artist_save / exos_artist_merge (and their _exos_ service-role cores).
   spotify_uri / spotify_url are derived from spotify_id on read.';

CREATE TABLE IF NOT EXISTS public.exos_event_lineup (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  artist_id   uuid NOT NULL REFERENCES public.exos_artists(id) ON DELETE CASCADE,
  act_type    text NOT NULL DEFAULT 'support',
  position    smallint NOT NULL,
  set_time    timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_event_lineup_act_type_chk
    CHECK (act_type IN ('headline', 'support', 'opener', 'dj', 'host', 'other')),
  CONSTRAINT exos_event_lineup_position_chk CHECK (position BETWEEN 1 AND 20),
  CONSTRAINT exos_event_lineup_artist_uq UNIQUE (event_id, artist_id),
  CONSTRAINT exos_event_lineup_position_uq UNIQUE (event_id, position) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS exos_event_lineup_artist_idx ON public.exos_event_lineup (artist_id);
CREATE INDEX IF NOT EXISTS exos_event_lineup_org_idx ON public.exos_event_lineup (org_id);
DROP TRIGGER IF EXISTS exos_event_lineup_touch ON public.exos_event_lineup;
CREATE TRIGGER exos_event_lineup_touch BEFORE UPDATE ON public.exos_event_lineup
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- A slot's org, event and artist must agree (belt and braces: the functions
-- below already check it).
CREATE OR REPLACE FUNCTION public._exos_tg_lineup_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = NEW.event_id AND e.org_id = NEW.org_id)
     OR NOT EXISTS (SELECT 1 FROM public.exos_artists a WHERE a.id = NEW.artist_id AND a.org_id = NEW.org_id) THEN
    RAISE EXCEPTION 'lineup: the event and the artist must belong to the same organization' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_lineup_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_event_lineup_guard ON public.exos_event_lineup;
CREATE TRIGGER exos_event_lineup_guard BEFORE INSERT OR UPDATE OF org_id, event_id, artist_id ON public.exos_event_lineup
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_lineup_guard();
COMMENT ON TABLE public.exos_event_lineup IS
  'mig 20261030110000: lineup slots (performer_id in the listing feed). Written
   only by exos_lineup_save / exos_artist_merge. Public reads: exos_public_lineups.';

CREATE TABLE IF NOT EXISTS public.exos_listing_keys (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs(id) ON DELETE CASCADE,
  label              text NOT NULL,
  partner_type       text NOT NULL DEFAULT 'other',
  key_prefix         text NOT NULL,
  key_hash           text NOT NULL,
  created_by         uuid,
  created_by_api_key uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz,
  revoked_at         timestamptz,
  CONSTRAINT exos_listing_keys_label_chk CHECK (length(btrim(label)) BETWEEN 1 AND 80),
  CONSTRAINT exos_listing_keys_partner_chk
    CHECK (partner_type IN ('bandsintown', 'jambase', 'songkick', 'website', 'other')),
  CONSTRAINT exos_listing_keys_hash_chk CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT exos_listing_keys_hash_uq UNIQUE (key_hash)
);
CREATE INDEX IF NOT EXISTS exos_listing_keys_org_idx ON public.exos_listing_keys (org_id);
COMMENT ON TABLE public.exos_listing_keys IS
  'mig 20261030110000: listing-feed shared keys, one per partner. Only the
   SHA-256 hash and a 16-character prefix are stored. key_hash is not readable
   by any client role. Written only by exos_listing_key_create / _revoke.';

-- RLS: staff read; nobody writes directly.
ALTER TABLE public.exos_artists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_lineup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_listing_keys ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS exos_artists_staff_read ON public.exos_artists;
CREATE POLICY exos_artists_staff_read ON public.exos_artists FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content']));
DROP POLICY IF EXISTS exos_event_lineup_staff_read ON public.exos_event_lineup;
CREATE POLICY exos_event_lineup_staff_read ON public.exos_event_lineup FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
DROP POLICY IF EXISTS exos_listing_keys_owner_read ON public.exos_listing_keys;
CREATE POLICY exos_listing_keys_owner_read ON public.exos_listing_keys FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner']));

REVOKE ALL ON public.exos_artists, public.exos_event_lineup, public.exos_listing_keys FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_artists, public.exos_event_lineup TO authenticated;
GRANT SELECT (id, org_id, label, partner_type, key_prefix, created_by, created_by_api_key,
              created_at, last_used_at, revoked_at) ON public.exos_listing_keys TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exos_artists, public.exos_event_lineup, public.exos_listing_keys TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Read shapes.
-- ---------------------------------------------------------------------------

-- An artist as the API and the dashboard see it (snake_case; Spotify URI and
-- URL derived from the one stored id).
CREATE OR REPLACE FUNCTION public._exos_artist_json(a public.exos_artists)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', a.id, 'org_id', a.org_id, 'name', a.name, 'permalink', a.permalink,
    'bio', a.bio, 'genres', to_jsonb(a.genres), 'links', a.links,
    'image_url', a.image_url, 'image_thumb_url', coalesce(a.image_thumb_url, a.image_url),
    'spotify_id', a.spotify_id,
    'spotify_uri', CASE WHEN a.spotify_id IS NULL THEN NULL ELSE 'spotify:artist:' || a.spotify_id END,
    'spotify_url', CASE WHEN a.spotify_id IS NULL THEN NULL ELSE 'https://open.spotify.com/artist/' || a.spotify_id END,
    'canonical_artist_id', a.canonical_artist_id,
    'created_at', a.created_at, 'updated_at', a.updated_at)
$$;
REVOKE ALL ON FUNCTION public._exos_artist_json(public.exos_artists) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_artist_json(public.exos_artists) TO service_role;

-- An event's lineup in running order: slot fields plus the artist's public
-- block (no bio, no links, no org).
CREATE OR REPLACE FUNCTION public._exos_lineup_json(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id, 'artist_id', l.artist_id, 'act_type', l.act_type, 'position', l.position,
      'set_time', l.set_time, 'updated_at', l.updated_at,
      'artist', jsonb_build_object(
        'id', a.id, 'name', a.name, 'permalink', a.permalink, 'updated_at', a.updated_at,
        'image_url', a.image_url, 'image_thumb_url', coalesce(a.image_thumb_url, a.image_url),
        'spotify_id', a.spotify_id,
        'spotify_uri', CASE WHEN a.spotify_id IS NULL THEN NULL ELSE 'spotify:artist:' || a.spotify_id END,
        'spotify_url', CASE WHEN a.spotify_id IS NULL THEN NULL ELSE 'https://open.spotify.com/artist/' || a.spotify_id END,
        'canonical_artist_id', a.canonical_artist_id))
    ORDER BY l.position, l.id), '[]'::jsonb)
  FROM public.exos_event_lineup l
  JOIN public.exos_artists a ON a.id = l.artist_id
  WHERE l.event_id = p_event_id
$$;
REVOKE ALL ON FUNCTION public._exos_lineup_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_lineup_json(uuid) TO service_role;

-- The legacy performer names follow the lineup: the first 10 names, in order.
-- Only on databases that have the column (prod does; the SQL harness may not).
CREATE OR REPLACE FUNCTION public._exos_lineup_sync_performers(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_names text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'public.exos_events'::regclass AND attname = 'performer_names'
                    AND NOT attisdropped) THEN
    RETURN;
  END IF;
  SELECT coalesce(array_agg(n ORDER BY p), '{}'::text[]) INTO v_names
    FROM (SELECT left(btrim(a.name), 80) AS n, l.position AS p
            FROM public.exos_event_lineup l JOIN public.exos_artists a ON a.id = l.artist_id
           WHERE l.event_id = p_event_id ORDER BY l.position LIMIT 10) s;
  EXECUTE 'UPDATE public.exos_events SET performer_names = $1
            WHERE id = $2 AND performer_names IS DISTINCT FROM $1'
    USING v_names, p_event_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_lineup_sync_performers(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Artists: create / update, merge.
-- ---------------------------------------------------------------------------

-- p_fields keys (each optional on update): name, permalink, bio, genres[],
-- links{website, instagram, facebook, twitter, tiktok, youtube, soundcloud,
-- bandcamp, apple_music}, image_url, image_thumb_url, and the Spotify value as
-- any of spotify, spotify_id, spotify_url, spotify_uri (or camelCase). A JSON
-- null or "" clears an optional field.
CREATE OR REPLACE FUNCTION public._exos_artist_save(p_org_id uuid, p_artist_id uuid, p_fields jsonb, p_actor uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  f        jsonb := coalesce(p_fields, '{}'::jsonb);
  a        public.exos_artists%ROWTYPE;
  v_new    boolean := p_artist_id IS NULL;
  v_old_name text;
  v_key    text;
  v_val    jsonb;
  v_text   text;
  v_base   text;
  v_n      int;
  v_genres text[];
  v_links  jsonb;
  k        text;
  ev       uuid;
BEGIN
  IF jsonb_typeof(f) <> 'object' THEN
    RAISE EXCEPTION 'artist: the body must be an object' USING ERRCODE = '22023';
  END IF;
  IF v_new THEN
    a.id := gen_random_uuid();
    a.org_id := p_org_id;
    a.genres := '{}'::text[];
    a.links := '{}'::jsonb;
    a.created_by := p_actor;
  ELSE
    SELECT * INTO a FROM public.exos_artists WHERE id = p_artist_id AND org_id = p_org_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'artist not found' USING ERRCODE = 'P0002'; END IF;
  END IF;
  v_old_name := a.name;

  -- name
  IF f ? 'name' OR v_new THEN
    IF jsonb_typeof(f->'name') IS DISTINCT FROM 'string' OR length(btrim(f->>'name')) = 0 THEN
      RAISE EXCEPTION 'artist: name is required' USING ERRCODE = '22023';
    END IF;
    IF length(btrim(f->>'name')) > 120 THEN
      RAISE EXCEPTION 'artist: name is at most 120 characters' USING ERRCODE = '22023';
    END IF;
    a.name := regexp_replace(btrim(f->>'name'), '\s+', ' ', 'g');
  END IF;

  -- bio
  IF f ? 'bio' THEN
    IF jsonb_typeof(f->'bio') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'artist: bio must be a string' USING ERRCODE = '22023';
    END IF;
    a.bio := nullif(btrim(coalesce(f->>'bio', '')), '');
    IF length(a.bio) > 4000 THEN RAISE EXCEPTION 'artist: bio is at most 4000 characters' USING ERRCODE = '22023'; END IF;
  END IF;

  -- genres
  IF f ? 'genres' THEN
    IF jsonb_typeof(f->'genres') = 'null' THEN
      v_genres := '{}'::text[];
    ELSIF jsonb_typeof(f->'genres') <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(f->'genres') g WHERE jsonb_typeof(g) <> 'string') THEN
      RAISE EXCEPTION 'artist: genres must be a list of strings' USING ERRCODE = '22023';
    ELSE
      SELECT coalesce(array_agg(g ORDER BY i), '{}'::text[]) INTO v_genres FROM (
        SELECT DISTINCT ON (lower(btrim(x))) btrim(x) AS g, i
          FROM jsonb_array_elements_text(f->'genres') WITH ORDINALITY AS t(x, i)
         WHERE btrim(x) <> ''
         ORDER BY lower(btrim(x)), i) s;
      IF cardinality(v_genres) > 10 OR EXISTS (SELECT 1 FROM unnest(v_genres) g WHERE length(g) > 40) THEN
        RAISE EXCEPTION 'artist: at most 10 genres of 40 characters' USING ERRCODE = '22023';
      END IF;
    END IF;
    a.genres := v_genres;
  END IF;

  -- links
  IF f ? 'links' THEN
    IF jsonb_typeof(f->'links') = 'null' THEN
      v_links := '{}'::jsonb;
    ELSIF jsonb_typeof(f->'links') <> 'object' THEN
      RAISE EXCEPTION 'artist: links must be an object' USING ERRCODE = '22023';
    ELSE
      v_links := '{}'::jsonb;
      FOR k, v_val IN SELECT * FROM jsonb_each(f->'links') LOOP
        k := CASE k WHEN 'appleMusic' THEN 'apple_music' ELSE k END;
        IF k NOT IN ('website','instagram','facebook','twitter','tiktok','youtube','soundcloud','bandcamp','apple_music') THEN
          RAISE EXCEPTION 'artist: unknown link "%"', left(k, 40) USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(v_val) = 'null' OR btrim(coalesce(v_val #>> '{}', '')) = '' THEN CONTINUE; END IF;
        v_text := btrim(v_val #>> '{}');
        IF jsonb_typeof(v_val) <> 'string' OR v_text !~* '^https?://[^\s/]+\.[^\s]+$' OR length(v_text) > 500 THEN
          RAISE EXCEPTION 'artist: link "%" must be an http(s) URL', k USING ERRCODE = '22023';
        END IF;
        v_links := v_links || jsonb_build_object(k, v_text);
      END LOOP;
    END IF;
    a.links := v_links;
  END IF;

  -- images (https only; the dashboard uploads to the exos-media bucket)
  FOREACH k IN ARRAY ARRAY['image_url', 'image_thumb_url'] LOOP
    v_key := CASE WHEN f ? k THEN k WHEN f ? (CASE k WHEN 'image_url' THEN 'imageUrl' ELSE 'imageThumbUrl' END)
                  THEN CASE k WHEN 'image_url' THEN 'imageUrl' ELSE 'imageThumbUrl' END END;
    CONTINUE WHEN v_key IS NULL;
    IF jsonb_typeof(f->v_key) NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'artist: % must be a string', k USING ERRCODE = '22023';
    END IF;
    v_text := nullif(btrim(coalesce(f->>v_key, '')), '');
    IF v_text IS NOT NULL AND (v_text !~ '^https://[^\s]+$' OR length(v_text) > 1000) THEN
      RAISE EXCEPTION 'artist: % must be an https URL', k USING ERRCODE = '22023';
    END IF;
    IF k = 'image_url' THEN
      a.image_url := v_text;
      -- A new photo without its own thumbnail: the thumbnail is the photo.
      IF NOT (f ? 'image_thumb_url' OR f ? 'imageThumbUrl') THEN a.image_thumb_url := NULL; END IF;
    ELSE
      a.image_thumb_url := v_text;
    END IF;
  END LOOP;

  -- Spotify: the first of the accepted keys present.
  SELECT x INTO v_key FROM unnest(ARRAY['spotify', 'spotify_id', 'spotifyId', 'spotify_url', 'spotifyUrl',
                                        'spotify_uri', 'spotifyUri']) WITH ORDINALITY t(x, i)
   WHERE f ? x ORDER BY i LIMIT 1;
  IF v_key IS NOT NULL THEN
    IF jsonb_typeof(f->v_key) NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'spotify: not a Spotify artist link, URI or id' USING ERRCODE = '22023';
    END IF;
    a.spotify_id := public._exos_spotify_artist_id(f->>v_key);
  END IF;

  -- permalink: explicit (must be free) or generated from the name on create.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_artists:' || p_org_id::text, 0));
  IF f ? 'permalink' AND nullif(btrim(coalesce(f->>'permalink', '')), '') IS NOT NULL THEN
    v_text := lower(btrim(f->>'permalink'));
    IF jsonb_typeof(f->'permalink') <> 'string' OR v_text !~ '^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$' THEN
      RAISE EXCEPTION 'artist: permalink must be lowercase letters, digits and dashes (at most 80)' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_artists WHERE org_id = p_org_id AND permalink = v_text AND id <> a.id) THEN
      RAISE EXCEPTION 'artist: permalink "%" is taken', v_text USING ERRCODE = '23505';
    END IF;
    a.permalink := v_text;
  ELSIF v_new THEN
    v_base := public._exos_slugify(a.name);
    a.permalink := v_base;
    v_n := 1;
    WHILE EXISTS (SELECT 1 FROM public.exos_artists WHERE org_id = p_org_id AND permalink = a.permalink) LOOP
      v_n := v_n + 1;
      a.permalink := regexp_replace(left(v_base, 80 - length(v_n::text) - 1), '-+$', '') || '-' || v_n;
    END LOOP;
  END IF;

  IF v_new THEN
    INSERT INTO public.exos_artists (id, org_id, name, permalink, bio, genres, links, image_url, image_thumb_url,
                                     spotify_id, created_by)
    VALUES (a.id, a.org_id, a.name, a.permalink, a.bio, a.genres, a.links, a.image_url, a.image_thumb_url,
            a.spotify_id, a.created_by)
    RETURNING * INTO a;
  ELSE
    UPDATE public.exos_artists SET name = a.name, permalink = a.permalink, bio = a.bio, genres = a.genres,
           links = a.links, image_url = a.image_url, image_thumb_url = a.image_thumb_url, spotify_id = a.spotify_id
     WHERE id = a.id
    RETURNING * INTO a;
    -- A rename shows on every event that has the artist on its bill.
    IF a.name IS DISTINCT FROM v_old_name THEN
      FOR ev IN SELECT DISTINCT event_id FROM public.exos_event_lineup WHERE artist_id = a.id LOOP
        PERFORM public._exos_lineup_sync_performers(ev);
      END LOOP;
    END IF;
  END IF;
  RETURN public._exos_artist_json(a);
END $$;
REVOKE ALL ON FUNCTION public._exos_artist_save(uuid, uuid, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_artist_save(uuid, uuid, jsonb, uuid) TO service_role;

-- Signed-in: owner, manager or content of the org. p_artist_id NULL creates.
CREATE OR REPLACE FUNCTION public.exos_artist_save(p_org_id uuid, p_artist_id uuid, p_fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner','manager','content']) THEN
    RAISE EXCEPTION 'exos_artist_save: owner, manager or content role only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_artist_save(p_org_id, p_artist_id, p_fields, auth.uid());
END $$;
REVOKE ALL ON FUNCTION public.exos_artist_save(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_artist_save(uuid, uuid, jsonb) TO authenticated;

-- Merge p_source into p_target (same org): the source becomes an alias, its
-- lineup slots move to the target (dropped where the target is already on
-- the bill), artists merged into the source follow. Returns
-- { artist: <source>, events_updated }.
CREATE OR REPLACE FUNCTION public._exos_artist_merge(p_org_id uuid, p_source uuid, p_target uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s  public.exos_artists%ROWTYPE;
  t  public.exos_artists%ROWTYPE;
  ev uuid;
  v_events uuid[];
BEGIN
  IF p_source IS NULL OR p_target IS NULL OR p_source = p_target THEN
    RAISE EXCEPTION 'artist: pick another artist to merge into' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_artists:' || p_org_id::text, 0));
  SELECT * INTO s FROM public.exos_artists WHERE id = p_source AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'artist not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO t FROM public.exos_artists WHERE id = p_target AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'merge target not found' USING ERRCODE = 'P0002'; END IF;
  IF s.canonical_artist_id IS NOT NULL THEN
    RAISE EXCEPTION 'artist: already merged into another artist' USING ERRCODE = '55000';
  END IF;
  IF t.canonical_artist_id IS NOT NULL THEN
    RAISE EXCEPTION 'artist: the target was itself merged; merge into its canonical artist' USING ERRCODE = '55000';
  END IF;

  SELECT coalesce(array_agg(DISTINCT event_id), '{}') INTO v_events
    FROM public.exos_event_lineup WHERE artist_id = p_source;
  -- Where the target is already on the bill the source's slot goes; elsewhere
  -- the slot points at the target.
  DELETE FROM public.exos_event_lineup l
   WHERE l.artist_id = p_source
     AND EXISTS (SELECT 1 FROM public.exos_event_lineup x WHERE x.event_id = l.event_id AND x.artist_id = p_target);
  UPDATE public.exos_event_lineup SET artist_id = p_target WHERE artist_id = p_source;
  UPDATE public.exos_artists SET canonical_artist_id = p_target WHERE canonical_artist_id = p_source;
  UPDATE public.exos_artists SET canonical_artist_id = p_target WHERE id = p_source RETURNING * INTO s;

  FOREACH ev IN ARRAY v_events LOOP
    -- Renumber 1..n (the deferred unique check runs at commit).
    UPDATE public.exos_event_lineup l SET position = r.rn
      FROM (SELECT id, row_number() OVER (ORDER BY position, id) AS rn
              FROM public.exos_event_lineup WHERE event_id = ev) r
     WHERE l.id = r.id AND l.position <> r.rn;
    PERFORM public._exos_lineup_sync_performers(ev);
  END LOOP;
  RETURN jsonb_build_object('artist', public._exos_artist_json(s), 'events_updated', cardinality(v_events));
END $$;
REVOKE ALL ON FUNCTION public._exos_artist_merge(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_artist_merge(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_artist_merge(p_source uuid, p_target uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_artists WHERE id = p_source;
  IF auth.uid() IS NULL OR v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_artist_merge: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_artist_merge(v_org, p_source, p_target);
END $$;
REVOKE ALL ON FUNCTION public.exos_artist_merge(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_artist_merge(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Lineups.
-- ---------------------------------------------------------------------------

-- Replace an event's lineup. p_slots: [{ artist_id, act_type?, set_time? }] in
-- running order (camelCase accepted). At most 20; every artist must be the
-- event's org's; a merged artist is replaced by its canonical artist; the same
-- artist twice is refused. Unchanged slots keep their id and updated_at.
-- Returns the lineup (_exos_lineup_json).
CREATE OR REPLACE FUNCTION public._exos_lineup_save(p_org_id uuid, p_event_id uuid, p_slots jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_slots jsonb := coalesce(p_slots, '[]'::jsonb);
  s       jsonb;
  i       int := 0;
  v_raw   text;
  v_aid   uuid;
  v_canon uuid;
  v_type  text;
  v_set   timestamptz;
  v_ids   uuid[] := '{}';
  v_types text[] := '{}';
  v_sets  timestamptz[] := '{}';
  v_had   boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(v_slots) <> 'array' THEN
    RAISE EXCEPTION 'lineup: must be a list of slots' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(v_slots) > 20 THEN
    RAISE EXCEPTION 'lineup: at most 20 slots' USING ERRCODE = '22023';
  END IF;
  -- One save at a time per event.
  PERFORM 1 FROM public.exos_events WHERE id = p_event_id FOR UPDATE;
  v_had := EXISTS (SELECT 1 FROM public.exos_event_lineup WHERE event_id = p_event_id);

  FOR s IN SELECT value FROM jsonb_array_elements(v_slots) LOOP
    i := i + 1;
    IF jsonb_typeof(s) <> 'object' THEN
      RAISE EXCEPTION 'lineup: slot % must be an object', i USING ERRCODE = '22023';
    END IF;
    v_raw := coalesce(s->>'artist_id', s->>'artistId');
    IF v_raw IS NULL OR v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'lineup: slot % needs an artist_id', i USING ERRCODE = '22023';
    END IF;
    v_aid := v_raw::uuid;
    SELECT coalesce(canonical_artist_id, id) INTO v_canon
      FROM public.exos_artists WHERE id = v_aid AND org_id = p_org_id;
    IF v_canon IS NULL THEN
      RAISE EXCEPTION 'lineup: slot % names an artist this organization does not have', i USING ERRCODE = '22023';
    END IF;
    v_type := coalesce(s->>'act_type', s->>'actType', CASE WHEN i = 1 THEN 'headline' ELSE 'support' END);
    IF v_type NOT IN ('headline', 'support', 'opener', 'dj', 'host', 'other') THEN
      RAISE EXCEPTION 'lineup: act_type must be headline, support, opener, dj, host or other' USING ERRCODE = '22023';
    END IF;
    v_raw := nullif(coalesce(s->>'set_time', s->>'setTime'), '');
    v_set := NULL;
    IF v_raw IS NOT NULL THEN
      BEGIN
        v_set := v_raw::timestamptz;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'lineup: slot % set_time must be an ISO 8601 time', i USING ERRCODE = '22023';
      END;
    END IF;
    IF v_canon = ANY (v_ids) THEN
      RAISE EXCEPTION 'lineup: the same artist is on the bill twice' USING ERRCODE = '22023';
    END IF;
    v_ids := v_ids || v_canon;
    v_types := v_types || v_type;
    v_sets := v_sets || v_set;
  END LOOP;

  DELETE FROM public.exos_event_lineup WHERE event_id = p_event_id AND NOT (artist_id = ANY (v_ids));
  UPDATE public.exos_event_lineup l SET position = n.pos, act_type = n.act_type, set_time = n.set_time
    FROM unnest(v_ids, v_types, v_sets) WITH ORDINALITY AS n(artist_id, act_type, set_time, pos)
   WHERE l.event_id = p_event_id AND l.artist_id = n.artist_id
     AND (l.position, l.act_type, l.set_time) IS DISTINCT FROM (n.pos::smallint, n.act_type, n.set_time);
  INSERT INTO public.exos_event_lineup (org_id, event_id, artist_id, act_type, position, set_time)
  SELECT p_org_id, p_event_id, n.artist_id, n.act_type, n.pos, n.set_time
    FROM unnest(v_ids, v_types, v_sets) WITH ORDINALITY AS n(artist_id, act_type, set_time, pos)
   WHERE NOT EXISTS (SELECT 1 FROM public.exos_event_lineup l WHERE l.event_id = p_event_id AND l.artist_id = n.artist_id);
  SET CONSTRAINTS public.exos_event_lineup_position_uq IMMEDIATE;
  SET CONSTRAINTS public.exos_event_lineup_position_uq DEFERRED;

  IF v_had OR i > 0 THEN
    PERFORM public._exos_lineup_sync_performers(p_event_id);
  END IF;
  RETURN public._exos_lineup_json(p_event_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_lineup_save(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_lineup_save(uuid, uuid, jsonb) TO service_role;

-- Signed-in: owner, manager or content of the event's org.
CREATE OR REPLACE FUNCTION public.exos_lineup_save(p_event_id uuid, p_slots jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF auth.uid() IS NULL OR v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner','manager','content']) THEN
    RAISE EXCEPTION 'exos_lineup_save: owner, manager or content role only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_lineup_save(v_org, p_event_id, p_slots);
END $$;
REVOKE ALL ON FUNCTION public.exos_lineup_save(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_lineup_save(uuid, jsonb) TO authenticated;

-- Public: the lineups of up to 100 published events, as
-- { "<event id>": [slot, …] } (events without a lineup are left out). Only
-- what the event page shows: name, permalink, photo, Spotify, act type,
-- position, set time.
CREATE OR REPLACE FUNCTION public.exos_public_lineups(p_event_ids uuid[])
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(e.id::text, public._exos_lineup_json(e.id)), '{}'::jsonb)
    FROM public.exos_events e
   WHERE e.id = ANY ((p_event_ids)[1:100])
     AND e.status = 'published'
     AND EXISTS (SELECT 1 FROM public.exos_event_lineup l WHERE l.event_id = e.id)
$$;
REVOKE ALL ON FUNCTION public.exos_public_lineups(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_public_lineups(uuid[]) TO anon, authenticated, service_role;

-- Events with this artist (or an artist merged into it) on the bill, newest
-- first, for GET /v1/artists/:id/events. Service role (exos-api).
CREATE OR REPLACE FUNCTION public.exos_api_artist_events(p_org_id uuid, p_artist_id uuid, p_limit int, p_offset int)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH ids AS (
    SELECT a.id FROM public.exos_artists a
     WHERE a.org_id = p_org_id AND (a.id = p_artist_id OR a.canonical_artist_id = p_artist_id)
  ), hits AS (
    SELECT e.id, e.name, e.slug, e.status, e.starts_at, l.id AS performer_id, l.artist_id, l.act_type, l.position
      FROM public.exos_event_lineup l JOIN public.exos_events e ON e.id = l.event_id
     WHERE l.artist_id IN (SELECT id FROM ids) AND e.org_id = p_org_id
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM hits),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.starts_at DESC NULLS LAST, r.id)
                        FROM (SELECT * FROM hits ORDER BY starts_at DESC NULLS LAST, id
                              LIMIT greatest(least(p_limit, 200), 1) OFFSET greatest(p_offset, 0)) r), '[]'::jsonb))
$$;
REVOKE ALL ON FUNCTION public.exos_api_artist_events(uuid, uuid, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_artist_events(uuid, uuid, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Listing-feed shared keys.
-- ---------------------------------------------------------------------------

-- Returns { id, label, partner_type, key_prefix, created_at, key }. The key
-- (sh_live_ + 48 hex) is returned ONCE and never stored. At most 20 active
-- keys per org.
CREATE OR REPLACE FUNCTION public._exos_listing_key_create(p_org_id uuid, p_label text, p_partner_type text,
                                                           p_actor uuid, p_api_key_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_type text := coalesce(nullif(btrim(p_partner_type), ''), 'other');
  v_key  text;
  r      public.exos_listing_keys%ROWTYPE;
BEGIN
  IF v_type NOT IN ('bandsintown', 'jambase', 'songkick', 'website', 'other') THEN
    RAISE EXCEPTION 'listing key: partner_type must be bandsintown, jambase, songkick, website or other'
      USING ERRCODE = '22023';
  END IF;
  IF length(btrim(coalesce(p_label, ''))) > 80 THEN
    RAISE EXCEPTION 'listing key: label is at most 80 characters' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_listing_keys:' || p_org_id::text, 0));
  IF (SELECT count(*) FROM public.exos_listing_keys WHERE org_id = p_org_id AND revoked_at IS NULL) >= 20 THEN
    RAISE EXCEPTION 'listing key: at most 20 active shared keys per organization; revoke one first'
      USING ERRCODE = '54000';
  END IF;
  v_key := 'sh_live_' || encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.exos_listing_keys (org_id, label, partner_type, key_prefix, key_hash, created_by, created_by_api_key)
  VALUES (p_org_id, coalesce(nullif(btrim(p_label), ''), v_type), v_type, left(v_key, 16),
          encode(extensions.digest(v_key, 'sha256'), 'hex'), p_actor, p_api_key_id)
  RETURNING * INTO r;
  RETURN jsonb_build_object('id', r.id, 'label', r.label, 'partner_type', r.partner_type,
                            'key_prefix', r.key_prefix, 'created_at', r.created_at, 'key', v_key);
END $$;
REVOKE ALL ON FUNCTION public._exos_listing_key_create(uuid, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_listing_key_create(uuid, text, text, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_listing_key_create(p_org_id uuid, p_label text, p_partner_type text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'exos_listing_key_create: owner only' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_listing_key_create(p_org_id, p_label, p_partner_type, auth.uid(), NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_listing_key_create(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_listing_key_create(uuid, text, text) TO authenticated;

-- Idempotent: revoking a revoked key is fine; an unknown or foreign id is P0002.
CREATE OR REPLACE FUNCTION public._exos_listing_key_revoke(p_org_id uuid, p_key_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_listing_keys SET revoked_at = coalesce(revoked_at, now())
   WHERE id = p_key_id AND org_id = p_org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'shared key not found' USING ERRCODE = 'P0002'; END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_listing_key_revoke(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_listing_key_revoke(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_listing_key_revoke(p_key_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_listing_keys WHERE id = p_key_id;
  IF auth.uid() IS NULL OR v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner']) THEN
    -- Same answer for "no such key" and "not yours".
    RAISE EXCEPTION 'exos_listing_key_revoke: owner only' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_listing_key_revoke(v_org, p_key_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_listing_key_revoke(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_listing_key_revoke(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. The feed's source rows.
-- ---------------------------------------------------------------------------

-- One listable event, with the venue redacted when the event's location is
-- secret (only its public area label) and blank when it is online-only.
-- Reads the row through to_jsonb so optional columns (secret_location,
-- location_area, venue_id, venue_permalink: booking's seam) are picked up when
-- they exist and are simply absent until then.
CREATE OR REPLACE FUNCTION public._exos_listing_feed_event(e public.exos_events)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  j       jsonb := to_jsonb(e);
  v_addr  jsonb := CASE WHEN jsonb_typeof(to_jsonb(e)->'venue_address') = 'object' THEN to_jsonb(e)->'venue_address' ELSE '{}'::jsonb END;
  v_name  text := nullif(btrim(coalesce(to_jsonb(e)->>'venue_name', to_jsonb(e)->>'venue_location', '')), '');
  v_venue jsonb;
  v_tiers jsonb;
BEGIN
  IF coalesce(j->>'secret_location', 'false') = 'true' THEN
    v_venue := jsonb_build_object('secret', true, 'online', false, 'venue_id', NULL,
      'name', nullif(btrim(coalesce(j->>'location_area', '')), ''), 'permalink', NULL,
      'city', NULL, 'region', NULL, 'country', NULL);
  ELSIF j->>'format' = 'online' THEN
    v_venue := jsonb_build_object('secret', false, 'online', true, 'venue_id', NULL, 'name', NULL,
      'permalink', NULL, 'city', NULL, 'region', NULL, 'country', NULL);
  ELSE
    v_venue := jsonb_build_object('secret', false, 'online', false,
      'venue_id', j->>'venue_id',
      'name', v_name,
      'permalink', coalesce(nullif(j->>'venue_permalink', ''),
                            CASE WHEN v_name IS NULL THEN NULL ELSE public._exos_slugify(v_name) END),
      'city', nullif(btrim(coalesce(v_addr->>'city', '')), ''),
      'region', nullif(btrim(coalesce(v_addr->>'region', v_addr->>'state', '')), ''),
      'country', nullif(btrim(coalesce(v_addr->>'country', '')), ''));
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'price', t.price, 'capacity', t.capacity, 'sold', t.sold,
           'sales_start', t.sales_start, 'sales_end', t.sales_end,
           'price_schedule', to_jsonb(t)->'price_schedule',
           'exclusive_tax_percent', public.exos_tier_exclusive_tax_percent(t.id))
         ORDER BY t.sort_order, t.id), '[]'::jsonb)
    INTO v_tiers
    FROM public.exos_ticket_tiers t
   WHERE t.event_id = e.id AND coalesce(t.visibility, 'public') = 'public';
  RETURN jsonb_build_object(
    'id', e.id, 'slug', j->>'slug', 'name', e.name, 'status', e.status,
    'starts_at', e.starts_at, 'ends_at', j->'ends_at', 'doors_at', j->'doors_at',
    'timezone', j->>'timezone', 'currency', j->>'currency', 'image_url', j->>'image_url',
    'genres', coalesce(j->'genres', '[]'::jsonb), 'subgenres', coalesce(j->'subgenres', '[]'::jsonb),
    'performer_names', coalesce(j->'performer_names', '[]'::jsonb),
    'format', j->>'format',
    'tickets_sold', j->'tickets_sold', 'total_tickets', j->'total_tickets',
    'created_at', j->'created_at', 'updated_at', j->'updated_at',
    'published_at', coalesce(j->'published_at', j->'created_at'),
    'venue', v_venue, 'tiers', v_tiers, 'lineup', public._exos_lineup_json(e.id));
END $$;
REVOKE ALL ON FUNCTION public._exos_listing_feed_event(public.exos_events) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_listing_feed_event(public.exos_events) TO service_role;

-- The listing feed's source: for a shared key's SHA-256 hash, its org's
-- listable events — published, not link-only, starting at or after p_since
-- (default now) — in start order, at most 2000; or the one event p_event_id
-- when it is listable (any start time). NULL for an unknown or revoked key.
-- Stamps last_used_at at most once a minute. Service role (exos-api).
CREATE OR REPLACE FUNCTION public.exos_listing_feed_source(p_key_hash text, p_event_id uuid DEFAULT NULL,
                                                           p_since timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  k        public.exos_listing_keys%ROWTYPE;
  v_events jsonb;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO k FROM public.exos_listing_keys WHERE key_hash = p_key_hash AND revoked_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF k.last_used_at IS NULL OR k.last_used_at < now() - interval '60 seconds' THEN
    UPDATE public.exos_listing_keys SET last_used_at = now() WHERE id = k.id;
  END IF;
  WITH pick AS (
    SELECT e.id FROM public.exos_events e
     WHERE e.org_id = k.org_id
       AND e.status = 'published'
       AND e.starts_at IS NOT NULL
       AND coalesce(to_jsonb(e)->'exclusivity'->>'customUrlOnly', 'false') <> 'true'
       AND coalesce(to_jsonb(e)->>'is_test', 'false') <> 'true'
       AND CASE WHEN p_event_id IS NOT NULL THEN e.id = p_event_id
                ELSE e.starts_at >= coalesce(p_since, now()) END
     ORDER BY e.starts_at, e.id
     LIMIT 2000
  )
  SELECT coalesce(jsonb_agg(public._exos_listing_feed_event(e) ORDER BY e.starts_at, e.id), '[]'::jsonb)
    INTO v_events
    FROM public.exos_events e JOIN pick USING (id);
  RETURN jsonb_build_object(
    'key', jsonb_build_object('id', k.id, 'org_id', k.org_id, 'partner_type', k.partner_type),
    'events', v_events);
END $$;
REVOKE ALL ON FUNCTION public.exos_listing_feed_source(text, uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_listing_feed_source(text, uuid, timestamptz) TO service_role;
