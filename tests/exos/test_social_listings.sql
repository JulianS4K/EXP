-- ============================================================================
-- Social posting and listing APIs, dry run only (mig 20261121203000).
--   SL1 grants: the post kit's context is signed in (owner / manager inside),
--       never anon
--   SL2 the new providers (ig_publish, tiktok_publish, meetup, linkedin,
--       google_business) are managed: the generic save / remove refuse them,
--       only the service role decrypts them, Integrations doesn't list them;
--       the older providers are still on the list
--   SL3 exos_social_post_context: owner / manager; the event as discovery
--       reads it (public tiers only) with capacity and location_open; venue
--       org; one boolean per credential (Business Profile counts the Google
--       connection); the Meetup plan, a LinkedIn page, the Business Profile's
--       age; no secret and no account id in the answer
--   SL4 a secret location's venue never reaches the kit; finance, scanner,
--       another org's owner and anon refused; another org's event refused
-- Self-contained (5c1 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5c100000-0000-0000-0000-0000000000a1','so1own@x.com',now()),
  ('5c100000-0000-0000-0000-0000000000a2','so1man@x.com',now()),
  ('5c100000-0000-0000-0000-0000000000a3','so1fin@x.com',now()),
  ('5c100000-0000-0000-0000-0000000000a4','so1scan@x.com',now()),
  ('5c100000-0000-0000-0000-0000000000a5','so1other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5c100000-0000-0000-0000-000000000001','Social Hall','social-hall-so1','5c100000-0000-0000-0000-0000000000a1'),
  ('5c100000-0000-0000-0000-000000000002','Other Promoter','other-promoter-so1','5c100000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5c100000-0000-0000-0000-000000000001','5c100000-0000-0000-0000-0000000000a1','owner'),
  ('5c100000-0000-0000-0000-000000000001','5c100000-0000-0000-0000-0000000000a2','manager'),
  ('5c100000-0000-0000-0000-000000000001','5c100000-0000-0000-0000-0000000000a3','finance'),
  ('5c100000-0000-0000-0000-000000000001','5c100000-0000-0000-0000-0000000000a4','scanner'),
  ('5c100000-0000-0000-0000-000000000002','5c100000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_venues(org_id,name,relationship) VALUES
  ('5c100000-0000-0000-0000-000000000001','Social Hall','owned'),
  ('5c100000-0000-0000-0000-000000000002','A Rented Room','rented');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,venue_address,total_tickets,tickets_sold,image_url,currency,timezone) VALUES
  ('5c100000-0000-0000-0000-0000000000e1','5c100000-0000-0000-0000-000000000001','Post Night','post-night-so1','published',
   now() + interval '10 days','Social Hall','{"street":"1 Main St","city":"Brooklyn","region":"NY","postal":"11211"}',120,0,
   'https://img.example/post.jpg','USD','America/New_York'),
  ('5c100000-0000-0000-0000-0000000000e2','5c100000-0000-0000-0000-000000000001','Secret Party','secret-party-so1','draft',
   now() + interval '12 days','Hidden Loft','{"street":"9 Quiet St","city":"Brooklyn"}',40,0,NULL,'USD','America/New_York'),
  ('5c100000-0000-0000-0000-0000000000e9','5c100000-0000-0000-0000-000000000002','Other Show','other-show-so1','published',
   now() + interval '5 days','Club',NULL,50,0,NULL,'USD','America/New_York');
INSERT INTO public.exos_ticket_tiers(event_id,name,price,capacity,visibility) VALUES
  ('5c100000-0000-0000-0000-0000000000e1','GA',25,100,'public'),
  ('5c100000-0000-0000-0000-0000000000e1','Comp',0,20,'hidden'),
  ('5c100000-0000-0000-0000-0000000000e2','Free',0,40,'public');
UPDATE public.exos_events SET location_mode = 'secret_location', venue_location = 'Bushwick'
 WHERE id = '5c100000-0000-0000-0000-0000000000e2';

-- Credentials, as the (not yet built) connect flows would write them.
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000001', 'ig_publish', 'ig-token-so1-SECRET',
  '{"ig_user_id":"17841400000000001"}', 'Instagram', 'connected', NULL, '@socialhall', true);
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000001', 'meetup', 'meetup-token-so1-SECRET',
  '{"group_urlname":"social-hall-nyc","plan":"Starter"}', 'Meetup', 'connected', NULL, NULL, false);
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000001', 'linkedin', 'li-token-so1-SECRET',
  '{"organization_id":"5551234"}', 'LinkedIn', 'connected', NULL, NULL, false);
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000001', 'google_business', NULL,
  jsonb_build_object('account_id','1122334455','location_id','9988776655','verified_at', (current_date - 90)::text),
  'Business Profile', 'unverified', NULL, NULL, false);
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000001', 'ads_google_ads', 'google-refresh-so1-SECRET',
  '{"customer_id":"1234567890"}', 'Google Ads', 'connected', NULL, NULL, false);
SELECT public._exos_integration_put('5c100000-0000-0000-0000-000000000002', 'tiktok_publish', 'tt-token-other-SECRET',
  '{}', 'TikTok', 'connected', NULL, NULL, false);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.org(p int DEFAULT 1) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5c100000-0000-0000-0000-00000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.org(int) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.ev(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5c100000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.ev(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.state_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN others THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.state_of(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.cred(p_provider text, p_org int DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  r := public.exos_integration_secret(pg_temp.org(p_org), p_provider);
  RESET ROLE;
  RETURN r;
END $$;

-- SL1 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT has_function_privilege('authenticated', 'public.exos_social_post_context(uuid,uuid)', 'EXECUTE'), 'SL1: the context is signed in';
  ASSERT has_function_privilege('service_role', 'public.exos_social_post_context(uuid,uuid)', 'EXECUTE'), 'SL1: the service role may read it';
  ASSERT NOT has_function_privilege('anon', 'public.exos_social_post_context(uuid,uuid)', 'EXECUTE'), 'SL1: anon has no context';
  ASSERT NOT has_function_privilege('anon', 'public._exos_cred_managed(text)', 'EXECUTE'), 'SL1: anon has no provider list';
  ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.exos_social_post_context(uuid,uuid)'::regprocedure)
     AND (SELECT proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = 'public.exos_social_post_context(uuid,uuid)'::regprocedure),
    'SL1: security definer with a pinned search_path';
  RAISE NOTICE 'OK  SL1 the post kit''s context is signed in only';
END $$;

-- SL2 ------------------------------------------------------------------------
DO $$
DECLARE p text; c jsonb;
BEGIN
  FOREACH p IN ARRAY ARRAY['ig_publish', 'tiktok_publish', 'meetup', 'linkedin', 'google_business'] LOOP
    ASSERT public._exos_cred_managed(p), 'SL2: ' || p || ' is managed';
    ASSERT p = ANY (public._exos_cred_providers()), 'SL2: ' || p || ' is a store provider';
  END LOOP;
  FOREACH p IN ARRAY ARRAY['ads_x', 'ads_meta_api', 'ads_reddit_api', 'ads_snap', 'eventbrite', 'pretix'] LOOP
    ASSERT p = ANY (public._exos_cred_providers()), 'SL2: the list kept ' || p;
  END LOOP;
  ASSERT public._exos_cred_managed('ads_x') AND NOT public._exos_cred_managed('pretix'), 'SL2: the old managed set kept';
  c := pg_temp.cred('ig_publish');
  ASSERT c ->> 'source' = 'store' AND c ->> 'secret' = 'ig-token-so1-SECRET' AND c -> 'config' ->> 'ig_user_id' = '17841400000000001'
     AND (c ->> 'writes_enabled')::boolean, 'SL2: the service role reads ig_publish, got ' || coalesce(c::text, 'null');
  ASSERT pg_temp.cred('google_business') IS NULL, 'SL2: a managed row with no secret reads NULL (Business Profile never borrows the Google Ads secret)';
  ASSERT pg_temp.cred('tiktok_publish') IS NULL AND pg_temp.cred('tiktok_publish', 2) ->> 'secret' = 'tt-token-other-SECRET',
    'SL2: per org';
END $$;
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE p text;
BEGIN
  FOREACH p IN ARRAY ARRAY['ig_publish', 'tiktok_publish', 'meetup', 'linkedin', 'google_business'] LOOP
    ASSERT pg_temp.state_of(format($q$SELECT public.exos_save_integration(pg_temp.org(), %L, '{}', 'x123456789')$q$, p)) LIKE '%unknown provider%',
      'SL2: generic save refuses ' || p;
  END LOOP;
  ASSERT pg_temp.state_of($q$SELECT public.exos_remove_integration(pg_temp.org(), 'ig_publish')$q$) LIKE '%disconnect it where%', 'SL2: generic remove refuses ig_publish';
  ASSERT pg_temp.state_of($q$SELECT public.exos_integration_secret(pg_temp.org(), 'meetup')$q$) LIKE '42501%', 'SL2: the owner can''t decrypt';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_list_integrations(pg_temp.org())
                      WHERE provider IN ('ig_publish', 'tiktok_publish', 'meetup', 'linkedin', 'google_business')), 'SL2: not listed in Integrations';
  RAISE NOTICE 'OK  SL2 the social providers are managed and service-role read';
END $$;
RESET ROLE;

-- SL3 ------------------------------------------------------------------------
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$
DECLARE c jsonb; e jsonb;
BEGIN
  c := public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e1'));
  e := c -> 'event';
  ASSERT c -> 'org' ->> 'name' = 'Social Hall' AND (c -> 'org' ->> 'venue_org')::boolean, 'SL3: the org, a venue org, got ' || (c -> 'org');
  ASSERT e ->> 'name' = 'Post Night' AND e ->> 'slug' = 'post-night-so1' AND e ->> 'image_url' = 'https://img.example/post.jpg'
     AND e ->> 'timezone' = 'America/New_York' AND (e ->> 'capacity')::int = 120 AND (e ->> 'location_open')::boolean
     AND e ->> 'venue_name' = 'Social Hall' AND e -> 'venue_address' ->> 'street' = '1 Main St', 'SL3: event facts, got ' || e;
  ASSERT jsonb_array_length(e -> 'tiers') = 1 AND (e -> 'tiers' -> 0 ->> 'name') = 'GA', 'SL3: public tiers only';
  ASSERT (c -> 'connected' ->> 'ig_publish')::boolean AND (c -> 'connected' ->> 'meetup')::boolean
     AND (c -> 'connected' ->> 'linkedin')::boolean AND NOT (c -> 'connected' ->> 'tiktok_publish')::boolean
     AND NOT (c -> 'connected' ->> 'google_business')::boolean,
     'SL3: connected booleans (Business Profile has no secret of its own: the Google Ads connection does not count), got ' || (c -> 'connected');
  ASSERT c -> 'facts' ->> 'meetup_plan' = 'starter' AND NOT (c -> 'facts' ->> 'meetup_pro_network')::boolean
     AND (c -> 'facts' ->> 'linkedin_org_page')::boolean AND (c -> 'facts' ->> 'gbp_verified_days')::int = 90
     AND NOT (c -> 'facts' ? 'gbp_own_connection'), 'SL3: facts, got ' || (c -> 'facts');
  ASSERT c::text NOT LIKE '%SECRET%' AND c::text NOT LIKE '%17841400000000001%' AND c::text NOT LIKE '%5551234%'
     AND c::text NOT LIKE '%9988776655%' AND c::text NOT LIKE '%social-hall-nyc%', 'SL3: no secret, no account id';
  RAISE NOTICE 'OK  SL3 the context: the event, venue org, booleans and non-secret facts';
END $$;
RESET ROLE;
-- Another org: no venue of its own (a rented room isn't one), nothing connected but TikTok.
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a5');
SET LOCAL ROLE authenticated;
DO $$
DECLARE c jsonb;
BEGIN
  c := public.exos_social_post_context(pg_temp.org(2), pg_temp.ev('e9'));
  ASSERT NOT (c -> 'org' ->> 'venue_org')::boolean, 'SL3: a rented room is not a venue org';
  ASSERT (c -> 'connected' ->> 'tiktok_publish')::boolean AND NOT (c -> 'connected' ->> 'google_business')::boolean
     AND c -> 'facts' -> 'meetup_plan' = 'null'::jsonb AND c -> 'facts' -> 'gbp_verified_days' = 'null'::jsonb,
    'SL3: the other org''s own answer, got ' || c;
END $$;
RESET ROLE;

-- SL4 ------------------------------------------------------------------------
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE c jsonb;
BEGIN
  c := public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e2'));
  ASSERT NOT (c -> 'event' ->> 'location_open')::boolean AND c -> 'event' ->> 'location_mode' = 'secret_location'
     AND NOT (c -> 'event') ? 'venue_address' AND c -> 'event' -> 'venue_name' = 'null'::jsonb, 'SL4: no venue for a secret location, got ' || (c -> 'event');
  ASSERT c::text NOT LIKE '%Hidden Loft%' AND c::text NOT LIKE '%Quiet St%' AND c::text NOT LIKE '%Bushwick%', 'SL4: nothing of the place';
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e9'))$q$) LIKE '22023%', 'SL4: another org''s event';
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), NULL)$q$) LIKE '22023%', 'SL4: no event';
END $$;
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a3');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'SL4: finance refused';
END $$;
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a4');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'SL4: scanner refused';
END $$;
SELECT pg_temp.act('5c100000-0000-0000-0000-0000000000a5');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'SL4: another org''s owner refused';
END $$;
RESET ROLE;
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_social_post_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'SL4: anon refused';
  RAISE NOTICE 'OK  SL4 a secret location stays out; other roles and orgs refused';
END $$;
RESET ROLE;

ROLLBACK;
