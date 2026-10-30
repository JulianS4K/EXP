-- ============================================================================
-- Artists, lineups and the listing feed (mig 20261030110000). Self-contained
-- (af… ids), rolled back at the end.
--   AF1  grants: no client writes, no anon table reads, key_hash unreadable,
--        the _exos_ cores are service-role only, anon gets exos_public_lineups only
--   AF2  artists: Spotify URL / URI / id -> one id, derived URI + URL, clearing,
--        bad links refused; generated permalinks dedupe, explicit ones don't
--   AF3  roles + RLS: owner / manager / content write; scanner and strangers
--        are refused; staff of another org read nothing
--   AF4  lineups: positions from the order, default act types, canonical ids,
--        duplicates / foreign artists / bad act types refused, unchanged slots
--        keep their id, performer_names follows (and follows a rename)
--   AF5  merge: slots move, a slot whose event already has the target goes,
--        positions renumber, aliases follow, merged-again / into-merged refused
--   AF6  shared keys: owner only, hash + prefix stored, 20-key cap, revoke
--   AF7  feed eligibility: published, upcoming, listed, the key's org only;
--        one-event mode; revoked / unknown keys answer NULL; last_used_at
--   AF8  secret venues show the area label only; online events no venue
--   AF9  public lineups: published events only, no bio, anon-callable
--   AF10 cross-org isolation of the service-role cores
--   AF11 the API path to shared keys needs an API key an active owner made;
--        revoking (or deleting) that API key revokes the shared keys it minted
--   AF12 noindex events stay out of the feed (like the Google / catalog feeds)
--        but keep their public lineup (their event page is still public)
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_artists_feed.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Columns prod has (or that booking will add: secret_location, location_area)
-- and the minimal harness schema lacks. Rolled back with the rest.
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS performer_names text[],
  ADD COLUMN IF NOT EXISTS genres text[],
  ADD COLUMN IF NOT EXISTS secret_location boolean,
  ADD COLUMN IF NOT EXISTS location_area text;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('af000000-0000-0000-0000-0000000000a0', 'af-owner@x.com', now()),
  ('af000000-0000-0000-0000-0000000000a1', 'af-manager@x.com', now()),
  ('af000000-0000-0000-0000-0000000000a2', 'af-content@x.com', now()),
  ('af000000-0000-0000-0000-0000000000a3', 'af-scanner@x.com', now()),
  ('af000000-0000-0000-0000-0000000000a4', 'af-stranger@x.com', now()),
  ('af000000-0000-0000-0000-0000000000b0', 'af-other@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('af000000-0000-0000-0000-000000000001', 'AF Org', 'af-org', 'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-000000000002', 'AF Other', 'af-other', 'af000000-0000-0000-0000-0000000000b0');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000a0', 'owner'),
  ('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000a1', 'manager'),
  ('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000a2', 'content'),
  ('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000a3', 'scanner'),
  ('af000000-0000-0000-0000-000000000002', 'af000000-0000-0000-0000-0000000000b0', 'owner');
-- e1 main (published, +2 days), e2 jazz (+1 day), e3 secret (+8 days),
-- e4 draft, e5 link-only, e6 past, e7 online (+3 days), e9 the other org's.
INSERT INTO public.exos_events (id, org_id, name, status, starts_at, timezone, venue_name, venue_address,
                                genres, exclusivity, format, created_by) VALUES
  ('af000000-0000-0000-0000-0000000000e1', 'af000000-0000-0000-0000-000000000001', 'AF Main', 'published',
   now() + interval '2 days', 'America/New_York', 'E2E Hall',
   '{"street":"1 Main St","city":"Brooklyn","region":"NY","country":"US"}', ARRAY['Rock'], NULL, 'in_person',
   'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e2', 'af000000-0000-0000-0000-000000000001', 'AF Jazz', 'published',
   now() + interval '1 day', 'America/New_York', 'Blue Room', '{"city":"Queens","country":"US"}', ARRAY['Jazz'],
   NULL, 'in_person', 'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e3', 'af000000-0000-0000-0000-000000000001', 'AF Secret', 'published',
   now() + interval '8 days', 'America/New_York', 'The Hidden Warehouse', '{"street":"99 Secret Rd","city":"Brooklyn"}',
   ARRAY['Techno'], NULL, 'in_person', 'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e4', 'af000000-0000-0000-0000-000000000001', 'AF Draft', 'draft',
   now() + interval '3 days', 'UTC', 'X', NULL, NULL, NULL, 'in_person', 'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e5', 'af000000-0000-0000-0000-000000000001', 'AF Link', 'published',
   now() + interval '3 days', 'UTC', 'X', NULL, NULL, '{"primaryMarketOnly":false,"customUrlOnly":true}', 'in_person',
   'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e6', 'af000000-0000-0000-0000-000000000001', 'AF Past', 'published',
   now() - interval '2 days', 'UTC', 'X', NULL, NULL, NULL, 'in_person', 'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e7', 'af000000-0000-0000-0000-000000000001', 'AF Stream', 'published',
   now() + interval '3 days', 'UTC', 'Somewhere', '{"city":"Austin"}', NULL, NULL, 'online',
   'af000000-0000-0000-0000-0000000000a0'),
  ('af000000-0000-0000-0000-0000000000e9', 'af000000-0000-0000-0000-000000000002', 'AF Foreign', 'published',
   now() + interval '2 days', 'UTC', 'Y', NULL, NULL, NULL, 'in_person', 'af000000-0000-0000-0000-0000000000b0');
UPDATE public.exos_events SET secret_location = true, location_area = 'Williamsburg, Brooklyn'
 WHERE id = 'af000000-0000-0000-0000-0000000000e3';
-- e8: published and upcoming, but hidden from search (noindex).
INSERT INTO public.exos_events (id, org_id, name, status, starts_at, timezone, venue_name, format, noindex, created_by)
VALUES ('af000000-0000-0000-0000-0000000000e8', 'af000000-0000-0000-0000-000000000001', 'AF Hidden', 'published',
        now() + interval '4 days', 'UTC', 'Z', 'in_person', true, 'af000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('af000000-0000-0000-0000-0000000000d1', 'af000000-0000-0000-0000-0000000000e1', 'GA', 25, 100, 0, 'public', 1),
  ('af000000-0000-0000-0000-0000000000d2', 'af000000-0000-0000-0000-0000000000e1', 'Free', 0, 10, 0, 'public', 0),
  ('af000000-0000-0000-0000-0000000000d3', 'af000000-0000-0000-0000-0000000000e1', 'Presale', 5, 10, 0, 'hidden', 2);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true)
$$;
-- The SQLSTATE a statement raises ('' when it doesn't).
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN others THEN
  RETURN SQLSTATE;
END $$;
-- performer_names as the owner sees it (the harness has no client grant on exos_events).
CREATE FUNCTION pg_temp.names(p_event uuid) RETURNS text[] LANGUAGE sql SECURITY DEFINER AS $$
  SELECT performer_names FROM public.exos_events WHERE id = p_event
$$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text), pg_temp.act(text), pg_temp.names(uuid) TO PUBLIC;
CREATE TEMP TABLE af (k text PRIMARY KEY, v text);
GRANT ALL ON af TO PUBLIC;

-- AF1 -----------------------------------------------------------------------
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_artists', 'exos_event_lineup', 'exos_listing_keys'] LOOP
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'AF1: anon reads ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT'), 'AF1: authenticated inserts ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE'), 'AF1: authenticated updates ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'AF1: authenticated deletes ' || t;
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'AF1: RLS off on ' || t;
  END LOOP;
  ASSERT NOT has_column_privilege('authenticated', 'public.exos_listing_keys', 'key_hash', 'SELECT'), 'AF1: key_hash readable';
  ASSERT has_column_privilege('authenticated', 'public.exos_listing_keys', 'key_prefix', 'SELECT'), 'AF1: prefix not readable';
  FOREACH f IN ARRAY ARRAY['public._exos_artist_save(uuid,uuid,jsonb,uuid)', 'public._exos_artist_merge(uuid,uuid,uuid)',
                           'public._exos_lineup_save(uuid,uuid,jsonb)', 'public._exos_listing_key_create(uuid,text,text,uuid,uuid)',
                           'public._exos_listing_key_revoke(uuid,uuid,uuid)', 'public._exos_api_key_owner_ok(uuid,uuid)', 'public.exos_listing_feed_source(text,uuid,timestamptz)',
                           'public.exos_api_artist_events(uuid,uuid,integer,integer)', 'public._exos_lineup_json(uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'AF1: authenticated runs ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'AF1: anon runs ' || f;
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'AF1: service_role can''t run ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_artist_save(uuid,uuid,jsonb)', 'public.exos_artist_merge(uuid,uuid)',
                           'public.exos_lineup_save(uuid,jsonb)', 'public.exos_listing_key_create(uuid,text,text)',
                           'public.exos_listing_key_revoke(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'AF1: anon runs ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'AF1: authenticated can''t run ' || f;
  END LOOP;
  ASSERT has_function_privilege('anon', 'public.exos_public_lineups(uuid[])', 'EXECUTE'), 'AF1: anon can''t read lineups';
  ASSERT (SELECT bool_and(p.proconfig::text LIKE '%search_path=public, pg_temp%')
            FROM pg_proc p WHERE p.proname IN ('_exos_artist_save', '_exos_artist_merge', '_exos_lineup_save',
              'exos_artist_save', 'exos_artist_merge', 'exos_lineup_save', 'exos_public_lineups',
              '_exos_listing_key_create', 'exos_listing_key_create', '_exos_listing_key_revoke',
              'exos_listing_key_revoke', 'exos_listing_feed_source', '_exos_listing_feed_event',
              'exos_api_artist_events', '_exos_lineup_json', '_exos_lineup_sync_performers', '_exos_tg_lineup_guard',
              '_exos_api_key_owner_ok', '_exos_tg_api_key_revoke_listing_keys')),
         'AF1: a definer function without the pinned search_path';
  ASSERT public._exos_artist_slugify('Beyoncé & Jay-Z') = 'beyonce-and-jay-z', 'AF2: slug accents';
  ASSERT public._exos_artist_slugify('  !!DJ  Aurora!! ') = 'dj-aurora', 'AF2: slug punctuation';
  ASSERT public._exos_artist_slugify('???') = 'artist', 'AF2: slug fallback';
  ASSERT public._exos_spotify_artist_id('open.spotify.com/artist/4Z8W4fKeB5YxbusRsdQVPb/') = '4Z8W4fKeB5YxbusRsdQVPb', 'AF2: url without scheme';
  ASSERT public._exos_spotify_artist_id('  ') IS NULL, 'AF2: empty is no id';
  RAISE NOTICE 'OK  AF1 grants: no client writes, cores service-role only, key_hash hidden';
END $$;

-- AF2 -----------------------------------------------------------------------
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a0');
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  org constant uuid := 'af000000-0000-0000-0000-000000000001';
  sp  constant text := '4Z8W4fKeB5YxbusRsdQVPb';
  sp2 constant text := '0OdUWJ0sBjDrqHygGUXeCF';
  a jsonb; b jsonb; c jsonb;
BEGIN
  a := public.exos_artist_save(org, NULL, jsonb_build_object('name', '  Lumen ', 'genres', jsonb_build_array('House', 'house', 'Disco'),
         'spotify', 'https://open.spotify.com/intl-de/artist/' || sp || '?si=x1',
         'links', jsonb_build_object('instagram', 'https://instagram.com/lumen', 'website', '')));
  ASSERT a->>'name' = 'Lumen' AND a->>'permalink' = 'lumen', 'AF2: name / permalink ' || a::text;
  ASSERT a->>'spotify_id' = sp AND a->>'spotify_uri' = 'spotify:artist:' || sp
     AND a->>'spotify_url' = 'https://open.spotify.com/artist/' || sp, 'AF2: spotify ' || a::text;
  ASSERT a->'genres' = '["House", "Disco"]'::jsonb, 'AF2: genres deduped ' || (a->'genres')::text;
  ASSERT a->'links' = '{"instagram": "https://instagram.com/lumen"}'::jsonb, 'AF2: links ' || (a->'links')::text;
  ASSERT a->'canonical_artist_id' = 'null'::jsonb, 'AF2: canonical';
  INSERT INTO af VALUES ('lumen', a->>'id');
  b := public.exos_artist_save(org, NULL, jsonb_build_object('name', 'Lumen', 'spotifyUri', 'spotify:artist:' || sp2));
  ASSERT b->>'permalink' = 'lumen-2' AND b->>'spotify_id' = sp2, 'AF2: generated permalinks dedupe ' || b::text;
  INSERT INTO af VALUES ('dupe', b->>'id');
  c := public.exos_artist_save(org, NULL, jsonb_build_object('name', 'Nova Echo', 'spotify_id', sp2, 'image_url', 'https://cdn.example/n.jpg'));
  ASSERT c->>'image_thumb_url' = 'https://cdn.example/n.jpg', 'AF2: thumb falls back to the photo';
  INSERT INTO af VALUES ('nova', c->>'id');
  ASSERT (SELECT spotify_id FROM public.exos_artists WHERE id = (c->>'id')::uuid) = sp2, 'AF2: stored id';
  c := public.exos_artist_save(org, (c->>'id')::uuid, '{"spotify": ""}');
  ASSERT c->'spotify_id' = 'null'::jsonb AND c->'spotify_uri' = 'null'::jsonb AND c->'spotify_url' = 'null'::jsonb,
         'AF2: clearing nulls all three ' || c::text;
END $$;
INSERT INTO af SELECT 'e', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL,
  '{"name":"Bad","spotify":"https://open.spotify.com/album/4Z8W4fKeB5YxbusRsdQVPb"}')$q$))::text;
INSERT INTO af SELECT 'e2', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL,
  '{"name":"Bad","spotify":"spotify:track:4Z8W4fKeB5YxbusRsdQVPb"}')$q$))::text;
INSERT INTO af SELECT 'e3', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL, '{"name":"Other","permalink":"lumen"}')$q$))::text;
INSERT INTO af SELECT 'e4', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL, '{}')$q$))::text;
INSERT INTO af SELECT 'e5', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL,
  '{"name":"X","links":{"myspace":"https://myspace.com/x"}}')$q$))::text;
INSERT INTO af SELECT 'e6', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL,
  '{"name":"X","image_url":"http://insecure.example/x.jpg"}')$q$))::text;
DO $$
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'e') = '22023' AND (SELECT v FROM af WHERE k = 'e2') = '22023', 'AF2: album / track refused';
  ASSERT (SELECT v FROM af WHERE k = 'e3') = '23505', 'AF2: explicit taken permalink is a conflict, got ' || (SELECT v FROM af WHERE k = 'e3');
  ASSERT (SELECT v FROM af WHERE k = 'e4') = '22023' AND (SELECT v FROM af WHERE k = 'e5') = '22023' AND (SELECT v FROM af WHERE k = 'e6') = '22023', 'AF2: missing name / unknown link / http image';
  RAISE NOTICE 'OK  AF2 artists: Spotify normalised, permalinks, validation';
END $$;
RESET ROLE;

-- AF3 -----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a2');  -- content
INSERT INTO af SELECT 'content_act', ((public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL, '{"name":"Content Act"}'))->>'id')::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a3');  -- scanner
INSERT INTO af SELECT 's1', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL, '{"name":"Nope"}')$q$))::text;
INSERT INTO af SELECT 'scanner_sees', count(*)::text FROM public.exos_artists;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a4');  -- stranger
INSERT INTO af SELECT 's2', (pg_temp.err($q$SELECT public.exos_artist_save('af000000-0000-0000-0000-000000000001', NULL, '{"name":"Nope"}')$q$))::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000b0');  -- other org's owner
INSERT INTO af SELECT 'other_sees', count(*)::text FROM public.exos_artists WHERE org_id = 'af000000-0000-0000-0000-000000000001';
INSERT INTO af SELECT 's3', (pg_temp.err(format('SELECT public.exos_artist_save(%L, %L, %L)', 'af000000-0000-0000-0000-000000000001',
  (SELECT v FROM af WHERE k = 'lumen'), '{"name":"Hijack"}')))::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a2');
INSERT INTO af SELECT 'content_sees', count(*)::text FROM public.exos_artists;
DO $$
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'content_act') IS NOT NULL, 'AF3: content creates';
  ASSERT (SELECT v FROM af WHERE k = 's1') = '42501' AND (SELECT v FROM af WHERE k = 's2') = '42501' AND (SELECT v FROM af WHERE k = 's3') = '42501', 'AF3: scanner / stranger / other org refused';
  ASSERT (SELECT v::int FROM af WHERE k = 'scanner_sees') = 0 AND (SELECT v::int FROM af WHERE k = 'other_sees') = 0, 'AF3: scanner and other org read nothing';
  ASSERT (SELECT v::int FROM af WHERE k = 'content_sees') = 4, 'AF3: content reads the org''s artists, got ' || (SELECT v::int FROM af WHERE k = 'content_sees');
  RAISE NOTICE 'OK  AF3 roles and RLS';
END $$;
RESET ROLE;

-- AF4 -----------------------------------------------------------------------
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a0');
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  ev constant uuid := 'af000000-0000-0000-0000-0000000000e1';
  lumen uuid := (SELECT v::uuid FROM af WHERE k = 'lumen');
  dupe  uuid := (SELECT v::uuid FROM af WHERE k = 'dupe');
  nova  uuid := (SELECT v::uuid FROM af WHERE k = 'nova');
  l jsonb; slot uuid; touched timestamptz;
BEGIN
  l := public.exos_lineup_save(ev, jsonb_build_array(
         jsonb_build_object('artist_id', lumen),
         jsonb_build_object('artistId', dupe, 'actType', 'dj'),
         jsonb_build_object('artist_id', nova, 'act_type', 'opener', 'set_time', '2030-01-01T23:30:00Z')));
  ASSERT (SELECT jsonb_agg(jsonb_build_array(x->>'artist_id', (x->>'position')::int, x->>'act_type')) FROM jsonb_array_elements(l) x)
       = jsonb_build_array(jsonb_build_array(lumen, 1, 'headline'), jsonb_build_array(dupe, 2, 'dj'), jsonb_build_array(nova, 3, 'opener')),
         'AF4: order / positions / act types ' || l::text;
  ASSERT l->2->'artist'->>'name' = 'Nova Echo' AND (l->2->>'set_time')::timestamptz = '2030-01-01T23:30:00Z', 'AF4: artist block + set time';
  ASSERT pg_temp.names(ev) = ARRAY['Lumen', 'Lumen', 'Nova Echo'], 'AF4: performer_names';
  SELECT id, updated_at INTO slot, touched FROM public.exos_event_lineup WHERE event_id = ev AND artist_id = lumen;
  INSERT INTO af VALUES ('lumen_slot', slot::text);
  -- Same lineup with one act type changed: the untouched slot keeps id + updated_at.
  l := public.exos_lineup_save(ev, jsonb_build_array(
         jsonb_build_object('artist_id', lumen, 'act_type', 'headline'),
         jsonb_build_object('artist_id', dupe, 'act_type', 'support'),
         jsonb_build_object('artist_id', nova, 'act_type', 'opener', 'set_time', '2030-01-01T23:30:00Z')));
  ASSERT (SELECT id = slot AND updated_at = touched FROM public.exos_event_lineup WHERE event_id = ev AND artist_id = lumen),
         'AF4: unchanged slot kept';
  -- Rename shows in performer_names.
  PERFORM public.exos_artist_save('af000000-0000-0000-0000-000000000001', nova, '{"name":"Nova Echo Trio"}');
  ASSERT pg_temp.names(ev) = ARRAY['Lumen', 'Lumen', 'Nova Echo Trio'], 'AF4: rename';
  -- Lineup on the jazz show too (for the merge).
  PERFORM public.exos_lineup_save('af000000-0000-0000-0000-0000000000e2', jsonb_build_array(
            jsonb_build_object('artist_id', dupe), jsonb_build_object('artist_id', nova)));
  -- An empty save clears.
  PERFORM public.exos_lineup_save('af000000-0000-0000-0000-0000000000e7', jsonb_build_array(jsonb_build_object('artist_id', nova)));
  PERFORM public.exos_lineup_save('af000000-0000-0000-0000-0000000000e7', '[]');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_lineup WHERE event_id = 'af000000-0000-0000-0000-0000000000e7'), 'AF4: cleared';
  ASSERT pg_temp.names('af000000-0000-0000-0000-0000000000e7') = '{}'::text[], 'AF4: names cleared';
END $$;
INSERT INTO af SELECT 'd1', (pg_temp.err(format('SELECT public.exos_lineup_save(%L, %L)', 'af000000-0000-0000-0000-0000000000e1',
  jsonb_build_array(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k='lumen')), jsonb_build_object('artist_id', (SELECT v FROM af WHERE k='lumen'))))))::text;
INSERT INTO af SELECT 'd2', (pg_temp.err(format('SELECT public.exos_lineup_save(%L, %L)', 'af000000-0000-0000-0000-0000000000e1',
  jsonb_build_array(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k='lumen'), 'act_type', 'rapper')))))::text;
INSERT INTO af SELECT 'd3', (pg_temp.err($q$SELECT public.exos_lineup_save('af000000-0000-0000-0000-0000000000e1', '[{"artist_id":"nope"}]')$q$))::text;
INSERT INTO af SELECT 'd4', (pg_temp.err(format('SELECT public.exos_lineup_save(%L, %L)', 'af000000-0000-0000-0000-0000000000e9', '[]')))::text;
INSERT INTO af SELECT 'd5', (pg_temp.err(format('SELECT public.exos_lineup_save(%L, %L)', 'af000000-0000-0000-0000-0000000000e1',
  (SELECT jsonb_agg(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k='lumen'))) FROM generate_series(1, 21)))))::text;
RESET ROLE;
-- A foreign artist (made by the other org's owner).
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000b0');
SET LOCAL ROLE authenticated;
INSERT INTO af SELECT 'foreign_artist', ((public.exos_artist_save('af000000-0000-0000-0000-000000000002', NULL, '{"name":"Foreign"}'))->>'id')::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a0');
INSERT INTO af SELECT 'd6', (pg_temp.err(format('SELECT public.exos_lineup_save(%L, %L)', 'af000000-0000-0000-0000-0000000000e1',
  jsonb_build_array(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k = 'foreign_artist'))))))::text;
DO $$
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'd1') = '22023' AND (SELECT v FROM af WHERE k = 'd2') = '22023' AND (SELECT v FROM af WHERE k = 'd3') = '22023' AND (SELECT v FROM af WHERE k = 'd5') = '22023' AND (SELECT v FROM af WHERE k = 'd6') = '22023',
         'AF4: duplicate / act type / bad id / 21 slots / foreign artist refused';
  ASSERT (SELECT v FROM af WHERE k = 'd4') = '42501', 'AF4: another org''s event refused, got ' || (SELECT v FROM af WHERE k = 'd4');
  RAISE NOTICE 'OK  AF4 lineups: order, act types, kept slots, performer_names, refusals';
END $$;
RESET ROLE;

-- AF5 -----------------------------------------------------------------------
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a2');  -- content can't merge
SET LOCAL ROLE authenticated;
INSERT INTO af SELECT 'm0', (pg_temp.err(format('SELECT public.exos_artist_merge(%L, %L)', (SELECT v FROM af WHERE k='dupe'), (SELECT v FROM af WHERE k='lumen'))))::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a1');  -- manager can
DO $$
DECLARE
  lumen uuid := (SELECT v::uuid FROM af WHERE k = 'lumen');
  dupe  uuid := (SELECT v::uuid FROM af WHERE k = 'dupe');
  nova  uuid := (SELECT v::uuid FROM af WHERE k = 'nova');
  r jsonb; l jsonb;
BEGIN
  r := public.exos_artist_merge(dupe, lumen);
  ASSERT r->'artist'->>'canonical_artist_id' = lumen::text AND (r->>'events_updated')::int = 2, 'AF5: merge result ' || r::text;
  -- Main show had both: dupe's slot goes, positions renumber.
  ASSERT (SELECT array_agg(artist_id ORDER BY position) FROM public.exos_event_lineup WHERE event_id = 'af000000-0000-0000-0000-0000000000e1')
       = ARRAY[lumen, nova], 'AF5: main show slots';
  ASSERT (SELECT array_agg(position ORDER BY position) FROM public.exos_event_lineup WHERE event_id = 'af000000-0000-0000-0000-0000000000e1')
       = ARRAY[1, 2]::smallint[], 'AF5: renumbered';
  ASSERT (SELECT id::text FROM public.exos_event_lineup WHERE event_id = 'af000000-0000-0000-0000-0000000000e1' AND artist_id = lumen)
       = (SELECT v FROM af WHERE k = 'lumen_slot'), 'AF5: surviving slot kept its id';
  -- Jazz show had only dupe: its slot now points at Lumen.
  ASSERT (SELECT array_agg(artist_id ORDER BY position) FROM public.exos_event_lineup WHERE event_id = 'af000000-0000-0000-0000-0000000000e2')
       = ARRAY[lumen, nova], 'AF5: jazz show repointed';
  ASSERT pg_temp.names('af000000-0000-0000-0000-0000000000e1') = ARRAY['Lumen', 'Nova Echo Trio'],
         'AF5: names follow';
  -- A save naming the merged artist gets the canonical one.
  l := public.exos_lineup_save('af000000-0000-0000-0000-0000000000e2', jsonb_build_array(jsonb_build_object('artist_id', dupe)));
  ASSERT l->0->>'artist_id' = lumen::text, 'AF5: canonical substitution';
END $$;
INSERT INTO af SELECT 'm1', (pg_temp.err(format('SELECT public.exos_artist_merge(%L, %L)', (SELECT v FROM af WHERE k='dupe'), (SELECT v FROM af WHERE k='nova'))))::text;
INSERT INTO af SELECT 'm2', (pg_temp.err(format('SELECT public.exos_artist_merge(%L, %L)', (SELECT v FROM af WHERE k='nova'), (SELECT v FROM af WHERE k='dupe'))))::text;
INSERT INTO af SELECT 'm3', (pg_temp.err(format('SELECT public.exos_artist_merge(%L, %L)', (SELECT v FROM af WHERE k='nova'), (SELECT v FROM af WHERE k='nova'))))::text;
INSERT INTO af SELECT 'm4', (pg_temp.err(format('SELECT public.exos_artist_merge(%L, %L)', (SELECT v FROM af WHERE k='nova'), (SELECT v FROM af WHERE k = 'foreign_artist'))))::text;
DO $$
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'm0') = '42501', 'AF5: content can''t merge';
  ASSERT (SELECT v FROM af WHERE k = 'm1') = '55000' AND (SELECT v FROM af WHERE k = 'm2') = '55000', 'AF5: merged again / into a merged artist refused';
  ASSERT (SELECT v FROM af WHERE k = 'm3') = '22023', 'AF5: into itself refused';
  ASSERT (SELECT v FROM af WHERE k = 'm4') = 'P0002', 'AF5: into another org''s artist is not found, got ' || (SELECT v FROM af WHERE k = 'm4');
  RAISE NOTICE 'OK  AF5 merge';
END $$;
RESET ROLE;

-- AF6 -----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a1');  -- manager: owner only
INSERT INTO af SELECT 'k0', (pg_temp.err($q$SELECT public.exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'x', 'bandsintown')$q$))::text;
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a0');
INSERT INTO af SELECT 'k1', (pg_temp.err($q$SELECT public.exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'x', 'myspace')$q$))::text;
INSERT INTO af SELECT 'bkey_json', (public.exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'Bandsintown', 'bandsintown'))::text;
INSERT INTO af SELECT 'k2', (pg_temp.err($q$SELECT key_hash FROM public.exos_listing_keys$q$))::text;
INSERT INTO af SELECT 'owner_keys', count(*)::text FROM public.exos_listing_keys;
RESET ROLE;
DO $$
DECLARE
  kk jsonb := (SELECT v::jsonb FROM af WHERE af.k = 'bkey_json');
  i int;
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'k0') = '42501' AND (SELECT v FROM af WHERE k = 'k1') = '22023', 'AF6: manager / bad partner refused';
  ASSERT (SELECT v FROM af WHERE k = 'k2') = '42501', 'AF6: key_hash is not readable, got ' || (SELECT v FROM af WHERE k = 'k2');
  ASSERT (SELECT v::int FROM af WHERE k = 'owner_keys') = 1, 'AF6: owner lists keys';
  ASSERT kk->>'key' ~ '^sh_live_[0-9a-f]{48}$' AND kk->>'key_prefix' = left(kk->>'key', 16), 'AF6: key shape ' || kk::text;
  ASSERT (SELECT key_hash FROM public.exos_listing_keys WHERE id = (kk->>'id')::uuid)
       = encode(extensions.digest(kk->>'key', 'sha256'), 'hex'), 'AF6: hash stored';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_listing_keys t WHERE to_jsonb(t)::text LIKE '%' || (kk->>'key') || '%'), 'AF6: key not stored';
  INSERT INTO af VALUES ('bkey', kk->>'key'), ('bkey_id', kk->>'id');
  FOR i IN 1..19 LOOP
    PERFORM public._exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'k' || i, 'website', NULL, NULL);
  END LOOP;
  BEGIN
    PERFORM public._exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'k21', 'website', NULL, NULL);
    RAISE EXCEPTION 'AF6: 21st key accepted';
  EXCEPTION WHEN program_limit_exceeded THEN NULL;
  END;
  RAISE NOTICE 'OK  AF6 shared keys: owner only, hashed, capped';
END $$;

-- AF7 / AF8 -------------------------------------------------------------------
INSERT INTO af SELECT 'bhash', encode(extensions.digest((SELECT v FROM af WHERE k = 'bkey'), 'sha256'), 'hex');
SET LOCAL ROLE service_role;
DO $$
DECLARE
  h text := (SELECT v FROM af WHERE k = 'bhash');
  r jsonb; ids text[]; ev jsonb; sec jsonb; one jsonb;
BEGIN
  r := public.exos_listing_feed_source(h);
  ASSERT r->'key'->>'org_id' = 'af000000-0000-0000-0000-000000000001' AND r->'key'->>'partner_type' = 'bandsintown', 'AF7: key ' || (r->'key')::text;
  SELECT array_agg(x->>'id' ORDER BY o) INTO ids FROM jsonb_array_elements(r->'events') WITH ORDINALITY t(x, o);
  ASSERT ids = ARRAY['af000000-0000-0000-0000-0000000000e2', 'af000000-0000-0000-0000-0000000000e1',
                     'af000000-0000-0000-0000-0000000000e7', 'af000000-0000-0000-0000-0000000000e3'],
         'AF7: published, upcoming, listed, own org, start order: ' || ids::text;
  ASSERT (SELECT last_used_at IS NOT NULL FROM public.exos_listing_keys WHERE key_hash = h), 'AF7: last_used_at stamped';
  SELECT x INTO ev FROM jsonb_array_elements(r->'events') x WHERE x->>'id' = 'af000000-0000-0000-0000-0000000000e1';
  ASSERT ev->'venue' = '{"secret": false, "online": false, "venue_id": null, "name": "E2E Hall", "permalink": "e2e-hall",
                         "city": "Brooklyn", "region": "NY", "country": "US"}'::jsonb, 'AF7: venue ' || (ev->'venue')::text;
  ASSERT (SELECT array_agg(t->>'id' ORDER BY o) FROM jsonb_array_elements(ev->'tiers') WITH ORDINALITY q(t, o))
       = ARRAY['af000000-0000-0000-0000-0000000000d2', 'af000000-0000-0000-0000-0000000000d1'], 'AF7: public tiers only';
  ASSERT jsonb_array_length(ev->'lineup') = 2 AND ev->'lineup'->0->'artist'->>'spotify_uri' = 'spotify:artist:4Z8W4fKeB5YxbusRsdQVPb',
         'AF7: lineup in the entry';
  ASSERT ev->'genres' = '["Rock"]'::jsonb, 'AF7: genres';
  -- AF8: secret venue -> area label only; online -> no venue.
  SELECT x INTO sec FROM jsonb_array_elements(r->'events') x WHERE x->>'id' = 'af000000-0000-0000-0000-0000000000e3';
  ASSERT sec->'venue' = '{"secret": true, "online": false, "venue_id": null, "name": "Williamsburg, Brooklyn", "permalink": null,
                          "city": null, "region": null, "country": null}'::jsonb, 'AF8: secret venue ' || (sec->'venue')::text;
  ASSERT position('Hidden Warehouse' in r::text) = 0 AND position('99 Secret Rd' in r::text) = 0, 'AF8: secret venue leaked';
  SELECT x INTO sec FROM jsonb_array_elements(r->'events') x WHERE x->>'id' = 'af000000-0000-0000-0000-0000000000e7';
  ASSERT sec->'venue'->>'online' = 'true' AND sec->'venue'->'name' = 'null'::jsonb AND sec->'venue'->'city' = 'null'::jsonb, 'AF8: online';
  -- Cutoff: an early date brings the past show; one-event mode.
  r := public.exos_listing_feed_source(h, NULL, now() - interval '5 days');
  ASSERT jsonb_array_length(r->'events') = 5, 'AF7: since';
  one := public.exos_listing_feed_source(h, 'af000000-0000-0000-0000-0000000000e6');
  ASSERT jsonb_array_length(one->'events') = 1, 'AF7: one listable past event';
  FOREACH ev IN ARRAY ARRAY['"af000000-0000-0000-0000-0000000000e4"', '"af000000-0000-0000-0000-0000000000e5"',
                            '"af000000-0000-0000-0000-0000000000e8"',
                            '"af000000-0000-0000-0000-0000000000e9"']::jsonb[] LOOP
    one := public.exos_listing_feed_source(h, (ev #>> '{}')::uuid);
    ASSERT jsonb_array_length(one->'events') = 0, 'AF7: not listable: ' || ev::text;
  END LOOP;
  ASSERT public.exos_listing_feed_source(repeat('0', 64)) IS NULL, 'AF7: unknown key';
  ASSERT public.exos_listing_feed_source('not-a-hash') IS NULL, 'AF7: junk';
  RAISE NOTICE 'OK  AF7 feed eligibility, one-event mode, unknown keys';
  RAISE NOTICE 'OK  AF8 secret venue shows its area only; online shows no venue';
END $$;
RESET ROLE;
-- Revoke (owner), idempotent; the key then answers NULL.
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000a0');
SET LOCAL ROLE authenticated;
SELECT public.exos_listing_key_revoke((SELECT v::uuid FROM af WHERE k = 'bkey_id'));
SELECT public.exos_listing_key_revoke((SELECT v::uuid FROM af WHERE k = 'bkey_id'));
SELECT pg_temp.act('af000000-0000-0000-0000-0000000000b0');
INSERT INTO af SELECT 'r1', (pg_temp.err(format('SELECT public.exos_listing_key_revoke(%L)', (SELECT v FROM af WHERE k = 'bkey_id'))))::text;
RESET ROLE;
DO $$
BEGIN
  ASSERT public.exos_listing_feed_source(encode(extensions.digest((SELECT v FROM af WHERE k = 'bkey'), 'sha256'), 'hex')) IS NULL,
         'AF7: revoked key still answers';
  ASSERT (SELECT v FROM af WHERE k = 'r1') = '42501', 'AF7: another org can''t revoke';
  RAISE NOTICE 'OK  AF7 revoke is immediate and idempotent';
END $$;

-- AF9 -----------------------------------------------------------------------
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
INSERT INTO af SELECT 'pub', (public.exos_public_lineups(ARRAY['af000000-0000-0000-0000-0000000000e1', 'af000000-0000-0000-0000-0000000000e4',
                                        'af000000-0000-0000-0000-0000000000e6']::uuid[]))::text;
INSERT INTO af SELECT 'a1', (pg_temp.err('SELECT * FROM public.exos_artists'))::text;
RESET ROLE;
-- Put a lineup on the draft: still not public.
INSERT INTO af SELECT 'ok', (public._exos_lineup_save('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000e4',
  jsonb_build_array(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k = 'nova')))) IS NOT NULL)::text;
SET LOCAL ROLE anon;
INSERT INTO af SELECT 'pub_draft', (public.exos_public_lineups(ARRAY['af000000-0000-0000-0000-0000000000e4']::uuid[]))::text;
RESET ROLE;
DO $$
DECLARE p jsonb := (SELECT v FROM af WHERE k = 'pub');
BEGIN
  ASSERT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p) k) = ARRAY['af000000-0000-0000-0000-0000000000e1'],
         'AF9: published events with a lineup only ' || p::text;
  ASSERT p->'af000000-0000-0000-0000-0000000000e1'->0->'artist'->>'name' = 'Lumen', 'AF9: names';
  ASSERT position('"bio"' in p::text) = 0 AND position('"links"' in p::text) = 0, 'AF9: no bio / links';
  ASSERT (SELECT v FROM af WHERE k = 'pub_draft')::jsonb = '{}'::jsonb, 'AF9: draft lineup hidden';
  ASSERT (SELECT v FROM af WHERE k = 'a1') = '42501', 'AF9: anon can''t read the artists table';
  RAISE NOTICE 'OK  AF9 public lineups';
END $$;

-- AF10 ----------------------------------------------------------------------
SET LOCAL ROLE service_role;
INSERT INTO af SELECT 'x1', (pg_temp.err(format('SELECT public._exos_artist_save(%L, %L, %L, NULL)', 'af000000-0000-0000-0000-000000000002',
  (SELECT v FROM af WHERE k = 'lumen'), '{"name":"x"}')))::text;
INSERT INTO af SELECT 'x2', (pg_temp.err(format('SELECT public._exos_lineup_save(%L, %L, %L)', 'af000000-0000-0000-0000-000000000002',
  'af000000-0000-0000-0000-0000000000e1', '[]')))::text;
INSERT INTO af SELECT 'x3', (pg_temp.err(format('SELECT public._exos_listing_key_revoke(%L, %L)', 'af000000-0000-0000-0000-000000000002',
  (SELECT v FROM af WHERE k = 'bkey_id'))))::text;
INSERT INTO af SELECT 'x4', (public.exos_api_artist_events('af000000-0000-0000-0000-000000000002', (SELECT v::uuid FROM af WHERE k = 'lumen'), 50, 0))::text;
INSERT INTO af SELECT 'x5', (public.exos_api_artist_events('af000000-0000-0000-0000-000000000001', (SELECT v::uuid FROM af WHERE k = 'lumen'), 50, 0))::text;
RESET ROLE;
DO $$
DECLARE r jsonb := (SELECT v FROM af WHERE k = 'x5');
BEGIN
  ASSERT (SELECT v FROM af WHERE k = 'x1') = 'P0002' AND (SELECT v FROM af WHERE k = 'x2') = 'P0002' AND (SELECT v FROM af WHERE k = 'x3') = 'P0002', 'AF10: another org''s ids are not found';
  ASSERT ((SELECT v FROM af WHERE k = 'x4')::jsonb)->>'total' = '0', 'AF10: artist events scoped to the org';
  ASSERT (r->>'total')::int = 2 AND r->'rows'->0->>'act_type' IS NOT NULL, 'AF10: artist events ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_lineup l JOIN public.exos_artists a ON a.id = l.artist_id
                      JOIN public.exos_events e ON e.id = l.event_id WHERE a.org_id <> e.org_id OR l.org_id <> e.org_id),
         'AF10: a slot crosses orgs';
  BEGIN
    INSERT INTO public.exos_event_lineup (org_id, event_id, artist_id, position)
    VALUES ('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000e6', (SELECT v::uuid FROM af WHERE k = 'foreign_artist'), 1);
    RAISE EXCEPTION 'AF10: guard let a foreign artist in';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  AF10 cross-org isolation';
END $$;

-- AF11 ----------------------------------------------------------------------
-- Org 2: b0 is the owner, a1 joins as manager; each makes an API key.
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('af000000-0000-0000-0000-000000000002', 'af000000-0000-0000-0000-0000000000a1', 'manager');
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('af000000-0000-0000-0000-0000000000f1', 'af000000-0000-0000-0000-000000000002', 'owner key', 'sk_live_af1',
   encode(extensions.digest('af-owner-key', 'sha256'), 'hex'), ARRAY['org:admin'], 'af000000-0000-0000-0000-0000000000b0'),
  ('af000000-0000-0000-0000-0000000000f2', 'af000000-0000-0000-0000-000000000002', 'manager key', 'sk_live_af2',
   encode(extensions.digest('af-manager-key', 'sha256'), 'hex'), ARRAY['org:admin'], 'af000000-0000-0000-0000-0000000000a1'),
  ('af000000-0000-0000-0000-0000000000f3', 'af000000-0000-0000-0000-000000000002', 'doomed key', 'sk_live_af3',
   encode(extensions.digest('af-doomed-key', 'sha256'), 'hex'), ARRAY['org:admin'], 'af000000-0000-0000-0000-0000000000b0');
SET LOCAL ROLE service_role;
INSERT INTO af SELECT 'n1', pg_temp.err($q$SELECT public._exos_listing_key_create('af000000-0000-0000-0000-000000000002', 'x', 'website', NULL, 'af000000-0000-0000-0000-0000000000f2')$q$);
INSERT INTO af SELECT 'n2', pg_temp.err($q$SELECT public._exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'x', 'website', NULL, 'af000000-0000-0000-0000-0000000000f1')$q$);
INSERT INTO af SELECT 'k_owner', (public._exos_listing_key_create('af000000-0000-0000-0000-000000000002', 'Site', 'website', NULL, 'af000000-0000-0000-0000-0000000000f1'))->>'id';
INSERT INTO af SELECT 'k_doomed', (public._exos_listing_key_create('af000000-0000-0000-0000-000000000002', 'Doomed', 'jambase', NULL, 'af000000-0000-0000-0000-0000000000f3'))->>'id';
INSERT INTO af SELECT 'n3', pg_temp.err(format('SELECT public._exos_listing_key_revoke(%L, %L, %L)', 'af000000-0000-0000-0000-000000000002',
  (SELECT v FROM af WHERE k = 'k_owner'), 'af000000-0000-0000-0000-0000000000f2'));
RESET ROLE;
DO $$
DECLARE k uuid := (SELECT v::uuid FROM af WHERE af.k = 'k_owner');
BEGIN
  ASSERT (SELECT v FROM af WHERE af.k = 'n1') = '42501', 'AF11: a manager''s API key minted a shared key';
  ASSERT (SELECT v FROM af WHERE af.k = 'n2') = '42501', 'AF11: an API key of another org minted one';
  ASSERT (SELECT v FROM af WHERE af.k = 'n3') = '42501', 'AF11: a manager''s API key revoked one';
  ASSERT (SELECT created_by_api_key FROM public.exos_listing_keys WHERE id = k) = 'af000000-0000-0000-0000-0000000000f1',
         'AF11: the minting API key is recorded';
  ASSERT (SELECT revoked_at IS NULL FROM public.exos_listing_keys WHERE id = k), 'AF11: refused revoke still revoked';
  PERFORM public._exos_listing_key_revoke('af000000-0000-0000-0000-000000000002', k, 'af000000-0000-0000-0000-0000000000f1');
  ASSERT (SELECT revoked_at IS NOT NULL FROM public.exos_listing_keys WHERE id = k), 'AF11: owner''s API key revokes';
  -- Revoking the minting API key revokes its shared keys; so does deleting it.
  INSERT INTO af SELECT 'k_owner2', (public._exos_listing_key_create('af000000-0000-0000-0000-000000000002', 'Site 2', 'website', NULL,
                                       'af000000-0000-0000-0000-0000000000f1'))->>'id';
  UPDATE public.exos_api_keys SET revoked_at = now() WHERE id = 'af000000-0000-0000-0000-0000000000f1';
  ASSERT (SELECT revoked_at IS NOT NULL FROM public.exos_listing_keys WHERE id = (SELECT v::uuid FROM af WHERE af.k = 'k_owner2')),
         'AF11: API key revoke didn''t cascade';
  DELETE FROM public.exos_api_keys WHERE id = 'af000000-0000-0000-0000-0000000000f3';
  ASSERT (SELECT revoked_at IS NOT NULL FROM public.exos_listing_keys WHERE id = (SELECT v::uuid FROM af WHERE af.k = 'k_doomed')),
         'AF11: API key delete didn''t revoke';
  -- The owner is demoted: an API key they made no longer manages shared keys
  -- (checked on the key's own row: an active key, no longer an owner's).
  INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
    ('af000000-0000-0000-0000-0000000000f4', 'af000000-0000-0000-0000-000000000002', 'later key', 'sk_live_af4',
     encode(extensions.digest('af-later-key', 'sha256'), 'hex'), ARRAY['org:admin'], 'af000000-0000-0000-0000-0000000000b0');
  ASSERT public._exos_api_key_owner_ok('af000000-0000-0000-0000-000000000002', 'af000000-0000-0000-0000-0000000000f4'), 'AF11: owner key';
  UPDATE public.exos_org_memberships SET role = 'manager'
   WHERE org_id = 'af000000-0000-0000-0000-000000000002' AND user_id = 'af000000-0000-0000-0000-0000000000b0';
  ASSERT NOT public._exos_api_key_owner_ok('af000000-0000-0000-0000-000000000002', 'af000000-0000-0000-0000-0000000000f4'),
         'AF11: a demoted owner''s key still passes';
  RAISE NOTICE 'OK  AF11 shared keys over the API need an owner''s API key; revoking it revokes them';
END $$;

-- AF12 ----------------------------------------------------------------------
INSERT INTO af SELECT 'okey', (public._exos_listing_key_create('af000000-0000-0000-0000-000000000001', 'AF12', 'website', NULL, NULL))->>'key'
 WHERE (SELECT count(*) FROM public.exos_listing_keys WHERE org_id = 'af000000-0000-0000-0000-000000000001' AND revoked_at IS NULL) < 20;
SELECT public._exos_lineup_save('af000000-0000-0000-0000-000000000001', 'af000000-0000-0000-0000-0000000000e8',
  jsonb_build_array(jsonb_build_object('artist_id', (SELECT v FROM af WHERE k = 'nova')))) IS NOT NULL AS ok;
DO $$
DECLARE
  h text := encode(extensions.digest((SELECT v FROM af WHERE af.k = 'okey'), 'sha256'), 'hex');
  r jsonb;
BEGIN
  r := public.exos_listing_feed_source(h, NULL, now() - interval '30 days');
  ASSERT r IS NOT NULL, 'AF12: key';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'events') x WHERE x->>'id' = 'af000000-0000-0000-0000-0000000000e8'),
         'AF12: a noindex event is in the feed';
  ASSERT jsonb_array_length(public.exos_listing_feed_source(h, 'af000000-0000-0000-0000-0000000000e8')->'events') = 0,
         'AF12: a noindex event answers by id';
  ASSERT public.exos_public_lineups(ARRAY['af000000-0000-0000-0000-0000000000e8']::uuid[]) ? 'af000000-0000-0000-0000-0000000000e8',
         'AF12: the noindex event page lost its lineup';
  RAISE NOTICE 'OK  AF12 noindex events are left out of the feed; their page keeps its lineup';
END $$;

ROLLBACK;
