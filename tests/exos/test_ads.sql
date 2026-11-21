-- ============================================================================
-- The ads phase, dry run only (mig 20261121190500).
--   AD1 grants: the audience source is service role only; the planner's
--       context is signed in (owner / manager inside); the hash, the
--       triggers and the connected check have no client EXECUTE
--   AD2 Reddit's email: _exos_email_sha256_reddit (the same constants as
--       hashedIds.ts's test), and a Reddit outbox row gets em_reddit while
--       the other platforms' rows don't
--   AD3 X conversions: 'x' on the outbox; a row only with the org's ads_x
--       store row on and the usual rules (paid, fulfilled, consent granted);
--       the new providers are managed (the generic save refuses them) and
--       only the service role reads them; the claim hands an X row over
--       without a credential (the drain reads the store)
--   AD4 exos_ads_campaign_context: owner / manager; the event facts, the
--       cheapest public price, booleans for the credentials; no pin for a
--       secret location; finance / scanner / anon / another org refused
--   AD5 exos_ads_audience_source: buyers and fans with advertising consent
--       (the latest choice wins, by email and by account); mail opt-outs,
--       the org list's opt-outs, discarded fans and signups without ad
--       consent left out; event scope; each call logged; 20 a day
-- Self-contained (ad1 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ad100000-0000-0000-0000-0000000000a1','ad1own@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000a2','ad1man@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000a3','ad1fin@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000a4','ad1scan@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000a5','ad1other@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b1','buyer1@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b2','buyer2@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b3','buyer3@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b4','fan4@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b6','buyer6@x.com',now()),
  ('ad100000-0000-0000-0000-0000000000b7','buyer7@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ad100000-0000-0000-0000-000000000001','Ads Org','ads-org-ad1','ad100000-0000-0000-0000-0000000000a1'),
  ('ad100000-0000-0000-0000-000000000002','Other Org','other-org-ad1','ad100000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('ad100000-0000-0000-0000-000000000001','ad100000-0000-0000-0000-0000000000a1','owner'),
  ('ad100000-0000-0000-0000-000000000001','ad100000-0000-0000-0000-0000000000a2','manager'),
  ('ad100000-0000-0000-0000-000000000001','ad100000-0000-0000-0000-0000000000a3','finance'),
  ('ad100000-0000-0000-0000-000000000001','ad100000-0000-0000-0000-0000000000a4','scanner'),
  ('ad100000-0000-0000-0000-000000000002','ad100000-0000-0000-0000-0000000000a5','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,venue_address,total_tickets,tickets_sold,image_url,currency) VALUES
  ('ad100000-0000-0000-0000-0000000000e1','ad100000-0000-0000-0000-000000000001','Boost Night','boost-night-ad1','published',
   now() + interval '10 days','Hall','{"city":"Brooklyn","region":"NY","postal":"11211"}',100,0,'https://img.example/boost.jpg','USD'),
  ('ad100000-0000-0000-0000-0000000000e2','ad100000-0000-0000-0000-000000000001','Secret Show','secret-show-ad1','draft',
   now() + interval '12 days','Somewhere',NULL,50,0,NULL,'USD'),
  ('ad100000-0000-0000-0000-0000000000e9','ad100000-0000-0000-0000-000000000002','Other Show','other-show-ad1','published',
   now() + interval '5 days','Club',NULL,50,0,NULL,'USD');
INSERT INTO public.exos_ticket_tiers(event_id,name,price,capacity,visibility) VALUES
  ('ad100000-0000-0000-0000-0000000000e1','GA',25,80,'public'),
  ('ad100000-0000-0000-0000-0000000000e1','Comp',0,20,'hidden'),
  ('ad100000-0000-0000-0000-0000000000e2','Free',0,50,'public');
INSERT INTO public.exos_event_geo(event_id,query,status,lat,lng) VALUES
  ('ad100000-0000-0000-0000-0000000000e1','Hall, Brooklyn','ok',40.7181,-73.9571),
  ('ad100000-0000-0000-0000-0000000000e2','Somewhere','ok',40.7,-73.9);
-- A secret location (a draft: the publish checks don't apply): the public sees the area only.
UPDATE public.exos_events SET location_mode = 'secret_location', venue_name = NULL, venue_location = 'Bushwick'
 WHERE id = 'ad100000-0000-0000-0000-0000000000e2';

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.org(p int DEFAULT 1) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('ad100000-0000-0000-0000-00000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.org(int) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.ev(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('ad100000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.ev(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.state_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN others THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.state_of(text) TO anon, authenticated, service_role;
-- The service role's calls.
CREATE FUNCTION pg_temp.source(p_event uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  r := public.exos_ads_audience_source(pg_temp.org(), p_event, 'ad100000-0000-0000-0000-0000000000a1');
  RESET ROLE;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.cred(p_provider text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  r := public.exos_integration_secret(pg_temp.org(), p_provider);
  RESET ROLE;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.emails(p jsonb) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(x ->> 'email' ORDER BY x ->> 'email'), '{}') FROM jsonb_array_elements(p -> 'rows') x
$$;

-- AD1 ------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    ASSERT NOT has_function_privilege(r, 'public.exos_ads_audience_source(uuid,uuid,uuid)', 'EXECUTE'), 'AD1: ' || r || ' reads the audience source';
    ASSERT NOT has_function_privilege(r, 'public._exos_email_sha256_reddit(text)', 'EXECUTE'), 'AD1: ' || r || ' runs the Reddit hash';
    ASSERT NOT has_function_privilege(r, 'public._exos_tg_conversions_checkout_x()', 'EXECUTE'), 'AD1: ' || r || ' runs the X trigger';
    ASSERT NOT has_function_privilege(r, 'public._exos_tg_conversions_reddit_email()', 'EXECUTE'), 'AD1: ' || r || ' runs the Reddit trigger';
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    ASSERT NOT has_function_privilege(r, 'public._exos_ads_connected(uuid,text)', 'EXECUTE'), 'AD1: ' || r || ' runs the connected check';
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_ads_audience_source(uuid,uuid,uuid)', 'EXECUTE'), 'AD1: service role reads the source';
  ASSERT has_function_privilege('authenticated', 'public.exos_ads_campaign_context(uuid,uuid)', 'EXECUTE'), 'AD1: the context is signed in';
  ASSERT NOT has_function_privilege('anon', 'public.exos_ads_campaign_context(uuid,uuid)', 'EXECUTE'), 'AD1: anon has no context';
  RAISE NOTICE 'OK  AD1 the audience source is service role only; the context is signed in';
END $$;

-- AD2 ------------------------------------------------------------------------
DO $$
BEGIN
  -- Same constants as adapter_test.ts / ads_test.ts (normalizeEmailReddit).
  ASSERT public._exos_email_sha256_reddit(' J.o.e+tag@Example.com ') = '2481f36dfc515ca76451aaadf1399026942a01ee50c6d0a61988b43cef039bc2', 'AD2: +tag and dots dropped';
  ASSERT public._exos_email_sha256_reddit('joe@example.com') = '2481f36dfc515ca76451aaadf1399026942a01ee50c6d0a61988b43cef039bc2', 'AD2: a plain address';
  ASSERT public._exos_email_sha256('j.o.e+tag@example.com') = 'c80b0350166dc95925839c9a933d146f114df43e24c5179cab83ede4431754c3', 'AD2: the plain hash keeps them';
  ASSERT public._exos_email_sha256_reddit('nope') IS NULL AND public._exos_email_sha256_reddit('  ') IS NULL
     AND public._exos_email_sha256_reddit(NULL) IS NULL AND public._exos_email_sha256_reddit('+tag@x.com') IS NULL
     AND public._exos_email_sha256_reddit('abc@') IS NULL, 'AD2: nothing to hash';
END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT public.exos_set_ad_credential(pg_temp.org(), 'reddit', '{"pixel_id":"a2_adpixel1"}', 'reddit-token-ad1-0001', true, NULL);
SELECT public.exos_set_ad_credential(pg_temp.org(), 'meta', '{"pixel_id":"123456789012345"}', 'meta-token-ad1-0001', true, NULL);
RESET ROLE;
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,ad_ids) VALUES
  ('cs_test_ad1_r1',pg_temp.ev('e1'),pg_temp.org(),NULL,true,' A.D-Buyer+promo@X.com ',1,2500,'usd','pending','granted','{"rdt_cid":"rdt-ad1","twclid":"tw-ad1"}');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_test_ad1_r1';
DO $$
DECLARE p jsonb;
BEGIN
  SELECT payload INTO p FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_r1' AND platform = 'reddit';
  ASSERT p ->> 'em_reddit' = 'dfaab5ac66cffe1b1de44cf5b676defa353a7112d0dc510568eba0ba893ec1a1', 'AD2: reddit row em_reddit, got ' || coalesce(p::text, 'none');
  ASSERT p ->> 'em' = encode(extensions.digest('a.d-buyer+promo@x.com', 'sha256'), 'hex'), 'AD2: em unchanged';
  ASSERT position('@' in p::text) = 0, 'AD2: no raw email';
  SELECT payload INTO p FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_r1' AND platform = 'meta';
  ASSERT p IS NOT NULL AND NOT p ? 'em_reddit', 'AD2: only Reddit rows get em_reddit';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_r1' AND platform = 'x'), 'AD2: no X row without ads_x';
  RAISE NOTICE 'OK  AD2 Reddit''s email hash, on Reddit rows only';
END $$;

-- AD3 ------------------------------------------------------------------------
SELECT public._exos_integration_put(pg_temp.org(), 'ads_x', '{"token":"x-token-ad1","token_secret":"x-token-secret-ad1"}',
  '{"pixel_id":"o8z6j","event_id":"tw-o8z6j-o8z6k"}', 'X Ads', 'connected', NULL, '@adsorg', true);
SELECT public._exos_integration_put(pg_temp.org(2), 'ads_x', '{"token":"x-token-other","token_secret":"x-secret-other"}',
  '{"pixel_id":"o8z6j","event_id":"tw-o8z6j-o8z6k"}', 'X Ads', 'connected', NULL, NULL, false);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,ad_ids) VALUES
  ('cs_test_ad1_x1',pg_temp.ev('e1'),pg_temp.org(),true,'xbuyer@x.com',2,5000,'usd','pending','granted','{"twclid":"tw-click-1"}'),
  ('cs_test_ad1_x2',pg_temp.ev('e1'),pg_temp.org(),true,'xbuyer2@x.com',1,5000,'usd','pending','denied',NULL),
  ('cs_test_ad1_x3',pg_temp.ev('e1'),pg_temp.org(),true,'xbuyer3@x.com',1,0,'usd','pending','granted',NULL),
  ('cs_test_ad1_x9',pg_temp.ev('e9'),pg_temp.org(2),true,'xbuyer9@x.com',1,5000,'usd','pending','granted',NULL);
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id LIKE 'cs_test_ad1_x%';
DO $$
DECLARE p jsonb; c jsonb;
BEGIN
  SELECT payload INTO p FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_x1' AND platform = 'x';
  ASSERT p IS NOT NULL, 'AD3: an X row for a paid consented order';
  ASSERT p ->> 'em' = encode(extensions.digest('xbuyer@x.com', 'sha256'), 'hex') AND p -> 'ad_ids' ->> 'twclid' = 'tw-click-1'
     AND (p ->> 'quantity')::int = 2 AND NOT p ? 'em_reddit', 'AD3: X payload, got ' || p;
  ASSERT (SELECT event_name = 'Purchase' AND event_id_dedupe = 'cs_test_ad1_x1' AND value_cents = 5000 AND status = 'pending'
            FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_x1' AND platform = 'x'), 'AD3: X row fields';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE platform = 'x' AND session_id IN ('cs_test_ad1_x2', 'cs_test_ad1_x3', 'cs_test_ad1_x9')),
    'AD3: no X row without consent, for a free order, or with the org''s switch off';
  -- A replayed flip adds nothing.
  UPDATE public.exos_checkout_sessions SET status = 'failed' WHERE session_id = 'cs_test_ad1_x1';
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_test_ad1_x1';
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ad1_x1' AND platform = 'x') = 1, 'AD3: one X row';
  ASSERT pg_temp.state_of($q$INSERT INTO public.exos_marketing_conversions(org_id,platform,event_name,event_id_dedupe,occurred_at,value_cents,currency)
    VALUES (pg_temp.org(),'linkedin','Purchase','cs_ad1_li',now(),1,'USD')$q$) LIKE '23514%', 'AD3: the CHECK still refuses others';
  c := pg_temp.cred('ads_x');
  ASSERT c ->> 'source' = 'store' AND c ->> 'secret' LIKE '%x-token-secret-ad1%' AND c -> 'config' ->> 'event_id' = 'tw-o8z6j-o8z6k'
     AND (c ->> 'writes_enabled')::boolean, 'AD3: the service role reads ads_x from the store, got ' || coalesce(c::text, 'null');
  ASSERT pg_temp.cred('ads_meta_api') IS NULL AND pg_temp.cred('ads_reddit_api') IS NULL, 'AD3: nothing connected reads NULL';
  ASSERT public._exos_cred_managed('ads_x') AND public._exos_cred_managed('ads_meta_api') AND public._exos_cred_managed('ads_reddit_api'),
    'AD3: the new providers are managed';
  ASSERT 'ads_x' = ANY (public._exos_cred_providers()) AND 'pretix' = ANY (public._exos_cred_providers())
     AND 'ads_snap' = ANY (public._exos_cred_providers()), 'AD3: the provider list kept the old ones';
END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_save_integration(pg_temp.org(), 'ads_x', '{}', 'x123456789')$q$) LIKE '%unknown provider%', 'AD3: generic save refuses ads_x';
  ASSERT pg_temp.state_of($q$SELECT public.exos_save_integration(pg_temp.org(), 'ads_meta_api', '{}', 'x123456789')$q$) LIKE '%unknown provider%', 'AD3: generic save refuses ads_meta_api';
  ASSERT pg_temp.state_of($q$SELECT public.exos_remove_integration(pg_temp.org(), 'ads_x')$q$) LIKE '%disconnect it where%', 'AD3: generic remove refuses ads_x';
  ASSERT pg_temp.state_of($q$SELECT public.exos_integration_secret(pg_temp.org(), 'ads_x')$q$) LIKE '42501%', 'AD3: the owner can''t decrypt';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_list_integrations(pg_temp.org()) WHERE provider LIKE 'ads_%'), 'AD3: not listed in Integrations';
END $$;
RESET ROLE;
DO $$
DECLARE r record; n int := 0;
BEGIN
  SET LOCAL ROLE service_role;
  FOR r IN SELECT * FROM public.exos_conversions_claim_batch(200, 6, 10) LOOP
    IF r.platform = 'x' THEN
      n := n + 1;
      ASSERT NOT r.enabled AND r.secret IS NULL, 'AD3: the claim hands X over without a credential';
    END IF;
  END LOOP;
  RESET ROLE;
  ASSERT n = 1, 'AD3: one X row claimed, got ' || n;
  RAISE NOTICE 'OK  AD3 X rows from the store only; the new providers managed and service-role read';
END $$;

-- AD4 ------------------------------------------------------------------------
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$
DECLARE c jsonb;
BEGIN
  c := public.exos_ads_campaign_context(pg_temp.org(), pg_temp.ev('e1'));
  ASSERT c -> 'org' ->> 'name' = 'Ads Org', 'AD4: the org';
  ASSERT c -> 'event' ->> 'name' = 'Boost Night' AND c -> 'event' ->> 'slug' = 'boost-night-ad1'
     AND c -> 'event' ->> 'image_url' = 'https://img.example/boost.jpg'
     AND (c -> 'event' ->> 'min_price_cents')::int = 2500 AND NOT (c -> 'event' ->> 'free')::boolean
     AND NOT (c -> 'event' ->> 'hidden')::boolean, 'AD4: event facts, got ' || c;
  ASSERT (c -> 'event' ->> 'lat')::float = 40.7181 AND c -> 'event' -> 'venue_address' ->> 'postal' = '11211', 'AD4: the venue pin';
  ASSERT (c -> 'connected' ->> 'ads_reddit')::boolean AND (c -> 'connected' ->> 'ads_meta')::boolean
     AND (c -> 'connected' ->> 'ads_x')::boolean AND NOT (c -> 'connected' ->> 'ads_meta_api')::boolean
     AND NOT (c -> 'connected' ->> 'ads_google_ads')::boolean, 'AD4: connected booleans, got ' || (c -> 'connected');
  ASSERT c::text NOT LIKE '%token%' AND c::text NOT LIKE '%a2_adpixel1%' AND c::text NOT LIKE '%o8z6j%', 'AD4: no secret, no credential id';
  c := public.exos_ads_campaign_context(pg_temp.org(), pg_temp.ev('e2'));
  ASSERT NOT c -> 'event' ? 'lat' AND NOT c -> 'event' ? 'venue_address' AND (c -> 'event' ->> 'free')::boolean, 'AD4: a secret location has no pin';
  ASSERT public.exos_ads_campaign_context(pg_temp.org()) -> 'event' = 'null'::jsonb, 'AD4: the org only';
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_campaign_context(pg_temp.org(), pg_temp.ev('e9'))$q$) LIKE '22023%', 'AD4: another org''s event';
END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a3');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_campaign_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'AD4: finance refused';
END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a4');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_campaign_context(pg_temp.org(), pg_temp.ev('e1'))$q$) LIKE '42501%', 'AD4: scanner refused';
END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a5');
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_campaign_context(pg_temp.org(), NULL)$q$) LIKE '42501%', 'AD4: another org''s owner refused';
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_audience_source(pg_temp.org(), NULL, NULL)$q$) LIKE '42501%', 'AD4: a client can''t read the source';
END $$;
RESET ROLE;
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_campaign_context(pg_temp.org(), NULL)$q$) LIKE '42501%', 'AD4: anon refused';
  RAISE NOTICE 'OK  AD4 the planner''s context: owner / manager, facts and booleans only';
END $$;
RESET ROLE;

-- AD5 ------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  -- in: granted.
  ('cs_test_ad1_a1',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b1',false,'Buyer1@X.com',1,2500,'usd','pending','granted',now() - interval '3 days'),
  -- out: granted, then a later "no".
  ('cs_test_ad1_a2',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b2',false,'buyer2@x.com',1,2500,'usd','pending','granted',now() - interval '3 days'),
  ('cs_test_ad1_a2b',pg_temp.ev('e2'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b2',false,'buyer2@x.com',1,2500,'usd','pending','denied',now() - interval '1 day'),
  -- out: unsubscribed from marketing mail.
  ('cs_test_ad1_a3',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b3',false,'buyer3@x.com',1,2500,'usd','pending','granted',now() - interval '3 days'),
  -- in twice: the checkout email (buyer) and the account's fan profile (fan), event e2.
  ('cs_test_ad1_a4',pg_temp.ev('e2'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b4',false,'fan4-checkout@x.com',1,2500,'usd','pending','granted',now() - interval '2 days'),
  -- out: off the org's list.
  ('cs_test_ad1_a6',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b6',false,'buyer6@x.com',1,2500,'usd','pending','granted',now() - interval '3 days'),
  -- out: no advertising consent.
  ('cs_test_ad1_a7',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000b7',false,'buyer7@x.com',1,2500,'usd','pending',NULL,now() - interval '3 days'),
  -- out: another org's buyer.
  ('cs_test_ad1_a9',pg_temp.ev('e9'),pg_temp.org(2),NULL,true,'otherbuyer@x.com',1,2500,'usd','pending','granted',now() - interval '3 days');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now()
 WHERE session_id IN ('cs_test_ad1_a1','cs_test_ad1_a2','cs_test_ad1_a3','cs_test_ad1_a4','cs_test_ad1_a6','cs_test_ad1_a7','cs_test_ad1_a9');
INSERT INTO public.exos_mail_prefs(user_id, marketing_opt_out, opted_out_at) VALUES ('ad100000-0000-0000-0000-0000000000b3', true, now());
SELECT set_config('exos.fan_consent_action', 'on', true);
INSERT INTO public.exos_fans(org_id,email,user_id,source) VALUES
  (pg_temp.org(),'fan4@x.com','ad100000-0000-0000-0000-0000000000b4','manual'),
  (pg_temp.org(),'fan5@x.com',NULL,'signup')
ON CONFLICT (org_id, email) DO UPDATE SET user_id = EXCLUDED.user_id;
INSERT INTO public.exos_fans(org_id,email,source,email_opt_in_at,email_opt_out_at) VALUES
  (pg_temp.org(),'buyer6@x.com','order',now() - interval '5 days',now())
ON CONFLICT (org_id, email) DO UPDATE SET email_opt_out_at = now();
SELECT set_config('exos.fan_consent_action', '', true);
-- A discarded fan profile: left out of ads too (cs_test_ad1_r1's buyer, granted).
INSERT INTO public.exos_fans(org_id,email,source,discarded_at) VALUES (pg_temp.org(),'a.d-buyer+promo@x.com','order',now())
ON CONFLICT (org_id, email) DO UPDATE SET discarded_at = now();
DO $$
DECLARE r jsonb; e text[]; n0 int; row4 jsonb;
BEGIN
  SELECT count(*) INTO n0 FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
  r := pg_temp.source(NULL);
  e := pg_temp.emails(r);
  ASSERT 'buyer1@x.com' = ANY (e), 'AD5: a consenting buyer is in, got ' || e::text;
  ASSERT 'fan4-checkout@x.com' = ANY (e) AND 'fan4@x.com' = ANY (e), 'AD5: the buyer email and the account''s fan profile, got ' || e::text;
  ASSERT 'xbuyer@x.com' = ANY (e), 'AD5: AD3''s consenting buyer is in';
  ASSERT NOT ('buyer2@x.com' = ANY (e)), 'AD5: the latest choice was no';
  ASSERT NOT ('buyer3@x.com' = ANY (e)), 'AD5: unsubscribed from marketing mail';
  ASSERT NOT ('buyer6@x.com' = ANY (e)), 'AD5: off the org''s list';
  ASSERT NOT ('buyer7@x.com' = ANY (e)), 'AD5: no advertising consent';
  ASSERT NOT ('fan5@x.com' = ANY (e)), 'AD5: a signup is not advertising consent';
  ASSERT NOT ('a.d-buyer+promo@x.com' = ANY (e)), 'AD5: a discarded fan';
  ASSERT NOT ('xbuyer2@x.com' = ANY (e)) AND NOT ('otherbuyer@x.com' = ANY (e)), 'AD5: denied at checkout / another org''s buyer';
  ASSERT 'xbuyer3@x.com' = ANY (e), 'AD5: a $0 order with consent is still a consenting buyer';
  ASSERT (r ->> 'count')::int = array_length(e, 1), 'AD5: the count';
  SELECT x INTO row4 FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'email' = 'fan4@x.com';
  ASSERT row4 ->> 'source' = 'fan' AND row4 ->> 'ad_consent' = 'granted', 'AD5: the fan row, got ' || row4;
  ASSERT (SELECT count(*) FROM public.exos_audience_exports WHERE org_id = pg_temp.org()) = n0 + 1
     AND (SELECT exported_by FROM public.exos_audience_exports WHERE org_id = pg_temp.org() ORDER BY id DESC LIMIT 1) = 'ad100000-0000-0000-0000-0000000000a1',
    'AD5: logged with the actor';
  -- One event: its buyers only, no fans.
  e := pg_temp.emails(pg_temp.source(pg_temp.ev('e2')));
  ASSERT e = ARRAY['fan4-checkout@x.com'], 'AD5: event scope, got ' || e::text;
  ASSERT pg_temp.state_of($q$SELECT public.exos_ads_audience_source(pg_temp.org(), pg_temp.ev('e9'), NULL)$q$) LIKE '22023%', 'AD5: another org''s event';
  -- 20 a day.
  INSERT INTO public.exos_audience_exports (org_id, row_count) SELECT pg_temp.org(), 0 FROM generate_series(1, 20);
  ASSERT pg_temp.state_of($q$SELECT pg_temp.source(NULL)$q$) LIKE 'P0001%daily audience limit%', 'AD5: 20 a day';
  RAISE NOTICE 'OK  AD5 the audience source: advertising consent only, opt-outs out, logged, 20 a day';
END $$;

ROLLBACK;
