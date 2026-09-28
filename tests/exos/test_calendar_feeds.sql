-- ============================================================================
-- Calendar feeds (mig 20260929073000). Self-contained (8b prefix), rolled back.
--   K1 exos_venue_key: the same vectors as src/lib/calendar/feed.test.ts
--   K2 feed tokens: create returns exc_ + 48 hex once, only the hash is stored,
--      rotate kills the old token, revoke kills the live one, one live per user
--   K3 other users (and anon) can't read tokens; status shows only my own
--   K4 my feed = followed orgs' public events + events I hold tickets for,
--      nothing else, and no buyer / ticket data in the rows
--   K5 public feeds: org, venue (name key + Place ID merge, place- key), event;
--      drafts never, cancelled only when it was on sale, stale coordinates hidden
--   K6 a deleted (tombstoned) account's feed resolves to nothing
--   K7 grants: feed reads service role only; token RPCs signed-in only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- The P0 harness chain doesn't include 20260520140000 (its view needs the
-- phase-1 org columns); stub the follow table in its prod shape when absent.
CREATE TABLE IF NOT EXISTS public.exos_org_follows (
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_uid, org_id)
);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('8b000000-0000-0000-0000-0000000000a1','8b-a@x.com',now()),
  ('8b000000-0000-0000-0000-0000000000b1','8b-b@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('8b000000-0000-0000-0000-000000000001','8B Followed','8b-followed','8b000000-0000-0000-0000-0000000000b1'),
  ('8b000000-0000-0000-0000-000000000002','8B Ticketed','8b-ticketed','8b000000-0000-0000-0000-0000000000b1'),
  ('8b000000-0000-0000-0000-000000000003','8B Other','8b-other','8b000000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_follows(follower_uid,org_id) VALUES
  ('8b000000-0000-0000-0000-0000000000a1','8b000000-0000-0000-0000-000000000001'),
  ('8b000000-0000-0000-0000-0000000000b1','8b000000-0000-0000-0000-000000000003');

INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,venue_address,tickets_sold,description) VALUES
  -- followed org
  ('8b000000-0000-0000-0000-0000000000e1','8b000000-0000-0000-0000-000000000001','8B Live','8b-live','published',now()+interval '10 days','America/New_York','Brooklyn Steel','{"street":"319 Frost St","city":"Brooklyn","region":"NY","country":"US"}',5,'Doors early'),
  ('8b000000-0000-0000-0000-0000000000e2','8b000000-0000-0000-0000-000000000001','8B Draft','8b-draft','draft',now()+interval '11 days','America/New_York','Brooklyn Steel','{"city":"Brooklyn"}',0,NULL),
  ('8b000000-0000-0000-0000-0000000000e3','8b000000-0000-0000-0000-000000000001','8B Long Ago','8b-old','published',now()-interval '60 days','America/New_York','Brooklyn Steel','{"city":"Brooklyn"}',9,NULL),
  ('8b000000-0000-0000-0000-0000000000e4','8b000000-0000-0000-0000-000000000001','8B Called Off','8b-off','cancelled',now()+interval '12 days','America/New_York','Brooklyn Steel','{"city":"Brooklyn"}',3,NULL),
  ('8b000000-0000-0000-0000-0000000000e9','8b000000-0000-0000-0000-000000000001','8B Never Sold','8b-never','cancelled',now()+interval '13 days','America/New_York','Brooklyn Steel','{"city":"Brooklyn"}',0,NULL),
  -- not followed; A holds a ticket for e5, had one refunded for e7, and one for cancelled e8
  ('8b000000-0000-0000-0000-0000000000e5','8b000000-0000-0000-0000-000000000002','8B Ticket Show','8b-tix','published',now()+interval '20 days','America/Chicago','Brooklyn Steel (Main Room)','{"city":"Brooklyn"}',1,NULL),
  ('8b000000-0000-0000-0000-0000000000e7','8b000000-0000-0000-0000-000000000002','8B Refunded','8b-refunded','published',now()+interval '21 days','America/Chicago','Café Oto','{"city":"London"}',1,NULL),
  ('8b000000-0000-0000-0000-0000000000e8','8b000000-0000-0000-0000-000000000002','8B Cancelled Mine','8b-cxl-mine','cancelled',now()+interval '22 days','America/Chicago','Elsewhere','{"city":"Brooklyn"}',0,NULL),
  -- B's world
  ('8b000000-0000-0000-0000-0000000000e6','8b000000-0000-0000-0000-000000000003','8B B Only','8b-b-only','published',now()+interval '15 days','America/New_York','Knockdown Center','{"city":"Queens"}',1,NULL);

INSERT INTO public.exos_tickets(id,event_id,org_id,owner_id,buyer_id,buyer_email,status,barcode_secret) VALUES
  ('8b000000-0000-0000-0000-00000000c005','8b000000-0000-0000-0000-0000000000e5','8b000000-0000-0000-0000-000000000002','8b000000-0000-0000-0000-0000000000a1','8b000000-0000-0000-0000-0000000000a1','8b-a@x.com','active','s'),
  ('8b000000-0000-0000-0000-00000000c007','8b000000-0000-0000-0000-0000000000e7','8b000000-0000-0000-0000-000000000002','8b000000-0000-0000-0000-0000000000a1','8b000000-0000-0000-0000-0000000000a1','8b-a@x.com','voided','s'),
  ('8b000000-0000-0000-0000-00000000c008','8b000000-0000-0000-0000-0000000000e8','8b000000-0000-0000-0000-000000000002','8b000000-0000-0000-0000-0000000000a1','8b000000-0000-0000-0000-0000000000a1','8b-a@x.com','voided','s'),
  ('8b000000-0000-0000-0000-00000000c006','8b000000-0000-0000-0000-0000000000e6','8b000000-0000-0000-0000-000000000003','8b000000-0000-0000-0000-0000000000b1','8b000000-0000-0000-0000-0000000000b1','8b-b@x.com','active','s');

-- e1 and e5 geocoded to the same place (fresh); e7 geocoded long ago (stale coordinates).
INSERT INTO public.exos_event_geo(event_id,query,status,place_id,lat,lng,geocoded_at) VALUES
  ('8b000000-0000-0000-0000-0000000000e1','q1','ok','ChIJ8bSteel',40.7,-73.9,now()),
  ('8b000000-0000-0000-0000-0000000000e5','q5','ok','ChIJ8bSteel',40.7,-73.9,now()),
  ('8b000000-0000-0000-0000-0000000000e7','q7','ok','ChIJ8bOto',51.5,-0.07,now()-interval '40 days');

-- K1 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT public.exos_venue_key('Brooklyn Steel', '{"city":"Brooklyn"}') = 'brooklyn-steel--brooklyn', 'K1 basic';
  ASSERT public.exos_venue_key('  Brooklyn  Steel! ', '{"city":"BROOKLYN"}') = 'brooklyn-steel--brooklyn', 'K1 case/punct';
  ASSERT public.exos_venue_key('Café Oto', '{"city":"London"}') = 'cafe-oto--london', 'K1 accents';
  ASSERT public.exos_venue_key('Le Poisson Rouge', NULL) = 'le-poisson-rouge', 'K1 no city';
  ASSERT public.exos_venue_key('Brooklyn Mirage', '{"city":"  "}') = 'brooklyn-mirage', 'K1 blank city';
  ASSERT public.exos_venue_key('Säälchen & Co.', '{"city":"Berlin"}') = 'saalchen-co--berlin', 'K1 umlaut + ampersand';
  ASSERT public.exos_venue_key('東京ドーム', '{"city":"Tokyo"}') IS NULL, 'K1 no Latin name';
  ASSERT public.exos_venue_key(NULL, '{"city":"Tokyo"}') IS NULL, 'K1 null name';
  ASSERT public.exos_venue_key(repeat('a', 58) || ' bb', NULL) = repeat('a', 58) || '-b', 'K1 60 chars';
  ASSERT public.exos_venue_key(repeat('a', 59) || ' b', NULL) = repeat('a', 59), 'K1 no trailing dash after cut';
  RAISE NOTICE 'PASS K1 venue key vectors';
END $$;

-- K2 / K3 -------------------------------------------------------------------
CREATE TEMP TABLE k_tokens (label text PRIMARY KEY, token text) ON COMMIT DROP;
GRANT ALL ON k_tokens TO authenticated;

DO $$
DECLARE t1 text; t2 text; s jsonb; n int;
BEGIN
  PERFORM set_config('app.uid', '8b000000-0000-0000-0000-0000000000a1', true);
  SET LOCAL ROLE authenticated;
  t1 := public.exos_calendar_feed_token_create();
  s  := public.exos_calendar_feed_token_status();
  RESET ROLE;
  ASSERT t1 ~ '^exc_[0-9a-f]{48}$', 'K2 token shape: ' || t1;
  ASSERT (s->>'active')::boolean AND s ? 'created_at' AND NOT s ? 'token_hash', 'K2 status: ' || s::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_calendar_feed_tokens WHERE token_hash = t1), 'K2 raw token stored';
  ASSERT EXISTS (SELECT 1 FROM public.exos_calendar_feed_tokens
                  WHERE token_hash = encode(extensions.digest(t1, 'sha256'), 'hex') AND revoked_at IS NULL), 'K2 hash stored';
  ASSERT public.exos_calendar_my_feed(encode(extensions.digest(t1, 'sha256'), 'hex')) IS NOT NULL, 'K2 t1 resolves';

  SET LOCAL ROLE authenticated;
  t2 := public.exos_calendar_feed_token_create();
  RESET ROLE;
  ASSERT t2 <> t1, 'K2 rotate gives a new token';
  ASSERT public.exos_calendar_my_feed(encode(extensions.digest(t1, 'sha256'), 'hex')) IS NULL, 'K2 rotated token dead';
  ASSERT public.exos_calendar_my_feed(encode(extensions.digest(t2, 'sha256'), 'hex')) IS NOT NULL, 'K2 new token live';
  SELECT count(*) INTO n FROM public.exos_calendar_feed_tokens
   WHERE user_id = '8b000000-0000-0000-0000-0000000000a1' AND revoked_at IS NULL;
  ASSERT n = 1, 'K2 one live token, got ' || n;
  ASSERT (SELECT last_used_at FROM public.exos_calendar_feed_tokens
           WHERE token_hash = encode(extensions.digest(t2, 'sha256'), 'hex')) IS NOT NULL, 'K2 last_used_at stamped';

  SET LOCAL ROLE authenticated;
  ASSERT public.exos_calendar_feed_token_revoke(), 'K2 revoke true';
  ASSERT NOT public.exos_calendar_feed_token_revoke(), 'K2 second revoke false';
  s := public.exos_calendar_feed_token_status();
  RESET ROLE;
  ASSERT NOT (s->>'active')::boolean, 'K2 status after revoke';
  ASSERT public.exos_calendar_my_feed(encode(extensions.digest(t2, 'sha256'), 'hex')) IS NULL, 'K2 revoked token dead';
  ASSERT public.exos_calendar_my_feed('nope') IS NULL AND public.exos_calendar_my_feed(NULL) IS NULL, 'K2 junk hash';
  RAISE NOTICE 'PASS K2 token create / rotate / revoke; hash only at rest; one live per user';

  -- A makes a fresh one for K4; B makes one too.
  SET LOCAL ROLE authenticated;
  INSERT INTO k_tokens VALUES ('a', public.exos_calendar_feed_token_create());
  PERFORM set_config('app.uid', '8b000000-0000-0000-0000-0000000000b1', true);
  INSERT INTO k_tokens VALUES ('b', public.exos_calendar_feed_token_create());
  s := public.exos_calendar_feed_token_status();
  RESET ROLE;
  ASSERT (s->>'active')::boolean, 'K3 B has its own live token';

  -- B (signed in) can't see any token row, A's or its own.
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM count(*) FROM public.exos_calendar_feed_tokens;
    RAISE EXCEPTION 'K3 FAIL: authenticated read the token table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM count(*) FROM public.exos_calendar_feed_tokens;
    RAISE EXCEPTION 'K3 FAIL: anon read the token table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  -- Nor resolve a feed (A's or anyone's) directly.
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.exos_calendar_my_feed(encode(extensions.digest((SELECT token FROM k_tokens WHERE label = 'a'), 'sha256'), 'hex'));
    RAISE EXCEPTION 'K3 FAIL: authenticated resolved a feed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;
  -- Signed out: no token.
  PERFORM set_config('app.uid', '', true);
  BEGIN
    PERFORM public.exos_calendar_feed_token_create();
    RAISE EXCEPTION 'K3 FAIL: no-uid create';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT NOT has_function_privilege('anon', 'public.exos_calendar_feed_token_create()', 'EXECUTE'), 'K3 anon create grant';
  RAISE NOTICE 'PASS K3 other users and anon cannot read tokens; status is per user';
END $$;

-- K4 ------------------------------------------------------------------------
DO $$
DECLARE f jsonb; ids text[]; r jsonb; keys text[];
BEGIN
  f := public.exos_calendar_my_feed(encode(extensions.digest((SELECT token FROM k_tokens WHERE label = 'a'), 'sha256'), 'hex'));
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT ids = ARRAY['e1','e4','e5','e8'], 'K4 A feed ids: ' || ids::text;
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'id') INTO ids FROM jsonb_array_elements(f->'events') x
   WHERE (x->>'has_tickets')::boolean;
  ASSERT ids = ARRAY['e5','e8'], 'K4 has_tickets: ' || ids::text;
  FOR r IN SELECT * FROM jsonb_array_elements(f->'events') LOOP
    SELECT array_agg(k ORDER BY k) INTO keys FROM jsonb_object_keys(r) k;
    ASSERT keys = ARRAY['description','doors_at','ends_at','has_tickets','id','image_url','lat','lng','name','org_name',
                        'org_slug','place_id','slug','starts_at','status','timezone','updated_at','venue_address',
                        'venue_key','venue_name'], 'K4 row fields: ' || keys::text;
  END LOOP;
  ASSERT position('8b-a@x.com' in f::text) = 0 AND position('8b-b@x.com' in f::text) = 0
     AND position('c006' in f::text) = 0, 'K4 no buyer or ticket data';

  f := public.exos_calendar_my_feed(encode(extensions.digest((SELECT token FROM k_tokens WHERE label = 'b'), 'sha256'), 'hex'));
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT ids = ARRAY['e6'], 'K4 B feed ids: ' || coalesce(ids::text, '{}');
  RAISE NOTICE 'PASS K4 my feed = followed orgs'' public events + my ticketed events, nothing else';
END $$;

-- K5 ------------------------------------------------------------------------
DO $$
DECLARE f jsonb; ids text[]; e jsonb;
BEGIN
  f := public.exos_calendar_public_feed('org', '8b-followed');
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT f->>'name' = '8B Followed' AND ids = ARRAY['e1','e4'], 'K5 org feed: ' || coalesce(ids::text, '{}');
  ASSERT f->>'timezone' = 'America/New_York', 'K5 org tz';
  ASSERT public.exos_calendar_public_feed('org', 'no-such-org') IS NULL, 'K5 unknown org';
  f := public.exos_calendar_public_feed('org', '8b-other');
  ASSERT jsonb_array_length(f->'events') = 1, 'K5 other org';

  -- Name key; e5 is spelled differently but shares e1's Place ID.
  f := public.exos_calendar_public_feed('venue', 'brooklyn-steel--brooklyn');
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT ids = ARRAY['e1','e4','e5'], 'K5 venue feed: ' || coalesce(ids::text, '{}');
  ASSERT f->>'name' = 'Brooklyn Steel, Brooklyn', 'K5 venue name: ' || (f->>'name');
  f := public.exos_calendar_public_feed('venue', 'place-ChIJ8bSteel');
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT ids = ARRAY['e1','e5'], 'K5 place feed: ' || coalesce(ids::text, '{}');
  ASSERT public.exos_calendar_public_feed('venue', 'nowhere--atall') IS NULL, 'K5 unknown venue';
  ASSERT public.exos_calendar_public_feed('venue', 'place-nope') IS NULL, 'K5 unknown place';
  -- A draft-only venue is unknown.
  UPDATE public.exos_events SET venue_name = 'Secret Room' WHERE id = '8b000000-0000-0000-0000-0000000000e2';
  ASSERT public.exos_calendar_public_feed('venue', 'secret-room--brooklyn') IS NULL, 'K5 draft venue';

  f := public.exos_calendar_public_feed('event', '8b000000-0000-0000-0000-0000000000e1');
  e := f->'events'->0;
  ASSERT jsonb_array_length(f->'events') = 1 AND e->>'venue_key' = 'brooklyn-steel--brooklyn'
     AND (e->>'lat')::float = 40.7 AND e->>'org_slug' = '8b-followed', 'K5 event feed: ' || e::text;
  ASSERT public.exos_calendar_public_feed('event', '8b000000-0000-0000-0000-0000000000e2') IS NULL, 'K5 draft event';
  ASSERT public.exos_calendar_public_feed('event', '8b000000-0000-0000-0000-0000000000e9') IS NULL, 'K5 never-sold cancelled';
  ASSERT public.exos_calendar_public_feed('event', '8b000000-0000-0000-0000-0000000000e4') IS NOT NULL, 'K5 cancelled on sale';
  ASSERT public.exos_calendar_public_feed('event', 'not-a-uuid') IS NULL, 'K5 junk id';
  ASSERT public.exos_calendar_public_feed('nope', 'x') IS NULL, 'K5 junk kind';
  f := public.exos_calendar_public_feed('event', '8b000000-0000-0000-0000-0000000000e7');
  e := f->'events'->0;
  ASSERT e->'lat' = 'null'::jsonb AND e->>'place_id' = 'ChIJ8bOto', 'K5 stale coords hidden: ' || e::text;
  -- No venue_name: the key falls back to venue_location (as the SPA's event.location does).
  INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,venue_name,venue_location,venue_address,tickets_sold)
  VALUES ('8b000000-0000-0000-0000-0000000000ea','8b000000-0000-0000-0000-000000000002','8B Loc Only','8b-loc','published',
          now()+interval '16 days','America/New_York',NULL,'Knockdown Center','{"city":"Queens"}',0);
  f := public.exos_calendar_public_feed('venue', 'knockdown-center--queens');
  SELECT array_agg(right(x->>'id', 2) ORDER BY x->>'starts_at') INTO ids FROM jsonb_array_elements(f->'events') x;
  ASSERT ids = ARRAY['e6','ea'] AND f->'events'->1->>'venue_name' = 'Knockdown Center', 'K5 venue_location fallback: ' || coalesce(ids::text, '{}');
  RAISE NOTICE 'PASS K5 org / venue / event feeds: public events only, place merge, stale coordinates hidden';
END $$;

-- K6 ------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE auth.users SET email = 'deleted+8b000000-0000-0000-0000-0000000000a1@deleted.invalid'
   WHERE id = '8b000000-0000-0000-0000-0000000000a1';
  ASSERT public.exos_calendar_my_feed(encode(extensions.digest((SELECT token FROM k_tokens WHERE label = 'a'), 'sha256'), 'hex')) IS NULL,
    'K6 deleted account feed';
  RAISE NOTICE 'PASS K6 a deleted account''s feed resolves to nothing';
END $$;

-- K7 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_calendar_public_feed(text, text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_calendar_public_feed(text, text)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_calendar_my_feed(text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_calendar_event_rows(uuid[], uuid[])', 'EXECUTE')
     AND has_function_privilege('service_role', 'public.exos_calendar_my_feed(text)', 'EXECUTE')
     AND has_function_privilege('service_role', 'public.exos_calendar_public_feed(text, text)', 'EXECUTE'), 'K7 feed grants';
  ASSERT has_function_privilege('authenticated', 'public.exos_calendar_feed_token_create()', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.exos_calendar_feed_token_revoke()', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_calendar_feed_token_revoke()', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_calendar_feed_token_status()', 'EXECUTE'), 'K7 token grants';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_calendar_feed_tokens', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_calendar_feed_tokens', 'SELECT'), 'K7 table grants';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_calendar_feed_tokens'::regclass), 'K7 RLS on';
  RAISE NOTICE 'PASS K7 grants';
END $$;

ROLLBACK;
