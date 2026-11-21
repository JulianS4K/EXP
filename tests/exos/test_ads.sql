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
--       consent left out; event scope; each call logged; 20 a day; hashes
--       only (em, em_google, em_reddit, ph, ph_digits), never a raw email
--   AD6 whose "yes" counts (review of #138, B2 / S1 / S2), in the ads source
--       AND the live hashed export: a forged pending checkout doesn't make a
--       list-only fan a consenting one (P1a); a forged expired "yes" doesn't
--       override a real later "no" (P1b); a free RSVP whose proof was
--       cancelled isn't consent (P1c), a proven one is; a fully refunded
--       buyer's automatic fan row doesn't bring them back (P4); a "no" at
--       the same moment as a "yes" wins (S2); the phone hashed both ways
--   AD7 account deletion (B1): a deleted consenting buyer (fan row by
--       account, P3) and their earlier guest checkout under the same
--       email (P3b) leave both the source and the export; the fan rows go,
--       the guest checkout gets the tombstone address; a banned account is out
--   AD8 the Reddit hash's edges match normalizeEmailReddit (ads_test.ts,
--       same vectors): tabs / newlines trimmed, whitespace inside or two
--       "@" give no hash
--   AD9 the throttles: 3 a minute (shared with the export), the daily cap
--       counts both
--   AD10 B2': an SMS proof, an organizer's correction, a lost dispute and an
--       unconfirmed account make no "yes"; an email code does
--   AD11 T1: an account confirmed at sign-up with no confirmation mail makes
--       no "yes"; a provider-verified OAuth email or an answered confirmation
--       mail does. T2: open disputes don't count. T3: an SMS send doesn't
--       reopen the email code after 5 wrong codes; the phone code still proves
-- Self-contained (ad1 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- The fixture accounts below answered a confirmation mail, which counts only
-- while the operator says Supabase Auth's "Confirm email" is on
-- (auth_confirm_email_on). These suites model that; AD11 / A8 turn it off.
INSERT INTO public.exos_platform_settings (key, value) VALUES ('auth_confirm_email_on', 'true')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- As in prod, auth.users has confirmation_sent_at. The fixture accounts below
-- answered a confirmation mail (sent a minute before their confirmed time), so
-- their email counts as verified (_exos_account_email_verified, T1). AD11's
-- instantly-confirmed account (Confirm email off: no mail sent) sets it NULL.
-- Rolled back with the rest.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS confirmation_sent_at timestamptz;
ALTER TABLE auth.users ALTER COLUMN confirmation_sent_at SET DEFAULT now() - interval '1 minute';

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
-- Emails the test wrote that a later step erases (account deletion).
CREATE TEMP TABLE ad_seen (buyer_email text);
GRANT SELECT ON ad_seen TO service_role, authenticated;
-- The source sends hashes only: map each row's em back to the test's own
-- addresses (every email the test wrote anywhere) to read who is in.
CREATE FUNCTION pg_temp.emails(p jsonb) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(c.e ORDER BY c.e), '{}')
    FROM jsonb_array_elements(p -> 'rows') x
    JOIN (SELECT DISTINCT lower(btrim(z.e)) AS e
            FROM (SELECT u.email AS e FROM auth.users u
                  UNION SELECT s.buyer_email FROM public.exos_checkout_sessions s
                  UNION SELECT s.buyer_email FROM pg_temp.ad_seen s
                  UNION SELECT f.email FROM public.exos_fans f) z
           WHERE z.e IS NOT NULL) c ON public._exos_email_sha256(c.e) = x ->> 'em'
$$;
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT public._exos_email_sha256(p) $$;
-- The shared 3-a-minute bucket: every call in this transaction is in one minute.
CREATE FUNCTION pg_temp.fresh_minute() RETURNS void LANGUAGE sql AS $$
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audience:%'
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
    ASSERT NOT has_function_privilege(r, 'public.exos_ads_credential_meta(uuid,text)', 'EXECUTE'), 'AD1: ' || r || ' reads credential meta';
    ASSERT NOT has_function_privilege(r, 'public._exos_consent_grant_ok(text,text)', 'EXECUTE'), 'AD1: ' || r || ' runs the consent check';
    ASSERT NOT has_function_privilege(r, 'public._exos_account_email_verified(uuid,text)', 'EXECUTE'), 'AD1: ' || r || ' runs the verified-email check';
    ASSERT NOT has_function_privilege(r, 'public._exos_audience_daily_gate(uuid,text)', 'EXECUTE'), 'AD1: ' || r || ' runs the daily gate';
    ASSERT NOT has_function_privilege(r, 'public._exos_email_trim(text)', 'EXECUTE'), 'AD1: ' || r || ' runs the email trim';
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    ASSERT NOT has_function_privilege(r, 'public._exos_ads_connected(uuid,text)', 'EXECUTE'), 'AD1: ' || r || ' runs the connected check';
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_ads_audience_source(uuid,uuid,uuid)', 'EXECUTE'), 'AD1: service role reads the source';
  ASSERT has_function_privilege('service_role', 'public.exos_ads_credential_meta(uuid,text)', 'EXECUTE'), 'AD1: service role reads credential meta';
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
-- The consenting guests proved their address with the email code (B2': only
-- that makes a guest's "yes" count).
INSERT INTO public.exos_order_proofs(org_id,event_id,session_id,email,original_email,status,proven_via,proven_at,expires_at)
SELECT s.org_id, s.event_id, s.session_id, lower(btrim(s.buyer_email)), lower(btrim(s.buyer_email)), 'proven', 'email_code', now(), now() + interval '1 day'
  FROM public.exos_checkout_sessions s WHERE s.session_id IN ('cs_test_ad1_x1', 'cs_test_ad1_x3');
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
  -- The pinned dry run's read: the same row, has_secret instead of the secret (nothing decrypted).
  SET LOCAL ROLE service_role;
  c := public.exos_ads_credential_meta(pg_temp.org(), 'ads_x');
  ASSERT (c ->> 'has_secret')::boolean AND NOT c ? 'secret' AND c::text NOT LIKE '%x-token%' AND c -> 'config' ->> 'pixel_id' = 'o8z6j',
    'AD3: credential meta, got ' || coalesce(c::text, 'null');
  c := public.exos_ads_credential_meta(pg_temp.org(), 'ads_reddit');
  -- A conversions credential saved the old way (copied into the store by the core's trigger).
  ASSERT (c ->> 'has_secret')::boolean AND c -> 'config' ->> 'pixel_id' = 'a2_adpixel1'
     AND c::text NOT LIKE '%reddit-token%', 'AD3: credential meta for an old-style save, got ' || coalesce(c::text, 'null');
  ASSERT public.exos_ads_credential_meta(pg_temp.org(), 'ads_meta_api') IS NULL AND public.exos_ads_credential_meta(pg_temp.org(), 'dice') IS NULL,
    'AD3: nothing connected / not an ad provider';
  RESET ROLE;
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
-- fan4's checkout email isn't the account's: proven with the email code.
INSERT INTO public.exos_order_proofs(org_id,event_id,session_id,email,original_email,status,proven_via,proven_at,expires_at) VALUES
  (pg_temp.org(),pg_temp.ev('e2'),'cs_test_ad1_a4','fan4-checkout@x.com','fan4-checkout@x.com','proven','email_code',now(),now() + interval '1 day');
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
  SELECT x INTO row4 FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'em' = pg_temp.h('fan4@x.com');
  ASSERT row4 ->> 'source' = 'fan' AND row4 ->> 'ad_consent' = 'granted', 'AD5: the fan row, got ' || row4;
  -- S4: hashes only, every one 64 hex; nothing raw.
  ASSERT position('@' in r::text) = 0, 'AD5: no raw email leaves Postgres';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'rows') x, jsonb_each_text(x) kv
                      WHERE kv.key NOT IN ('source', 'ad_consent') AND kv.value !~ '^[0-9a-f]{64}$'), 'AD5: every identifier is a SHA-256 hex';
  ASSERT row4 ->> 'em_google' = public._exos_email_sha256_google('fan4@x.com')
     AND row4 ->> 'em_reddit' = public._exos_email_sha256_reddit('fan4@x.com'), 'AD5: the Google and Reddit forms, got ' || row4;
  ASSERT NOT (r ->> 'truncated')::boolean AND (r ->> 'total')::int = (r ->> 'count')::int, 'AD5: not truncated';
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

-- AD6 ------------------------------------------------------------------------
-- As in prod: the account columns exos_delete_my_account / the ban check read,
-- and the tables it touches that this chain lacks (rolled back with the rest).
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (user_id text);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid);
DELETE FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
-- The live hashed export (owner), and who is in it.
CREATE FUNCTION pg_temp.xp() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('ad100000-0000-0000-0000-0000000000a1');
  SET LOCAL ROLE authenticated;
  r := public.exos_org_audience_export(pg_temp.org(), NULL);
  RESET ROLE;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.xemails(p jsonb) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT pg_temp.emails(jsonb_build_object('rows',
           coalesce((SELECT jsonb_agg(jsonb_build_object('em', x ->> 'email_sha256')) FROM jsonb_array_elements(p -> 'rows') x), '[]'::jsonb)))
$$;

INSERT INTO auth.users(id,email,email_confirmed_at,phone) VALUES
  ('ad100000-0000-0000-0000-0000000000c4','p4@x.com',now(),'16505551212'),
  ('ad100000-0000-0000-0000-0000000000c7','del7@x.com',now(),NULL),
  ('ad100000-0000-0000-0000-0000000000c8','ban8@x.com',now(),NULL);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  -- P1a: a stranger's guest checkout, never paid, with a list-only fan's email.
  ('cs_test_ad1_p1a',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1a@x.com',1,2500,'usd','pending','granted',now() - interval '1 hour'),
  -- P1b: a real "yes", a real later "no", then a stranger's expired "yes".
  ('cs_test_ad1_p1b1',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1b@x.com',1,2500,'usd','pending','granted',now() - interval '3 days'),
  ('cs_test_ad1_p1b2',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1b@x.com',1,2500,'usd','pending','denied',now() - interval '2 days'),
  ('cs_test_ad1_p1b3',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1b@x.com',1,2500,'usd','expired','granted',now() - interval '1 day'),
  -- P1c: free RSVPs; one proof cancelled, one proven.
  ('cs_test_ad1_p1c',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1c@x.com',1,0,'usd','pending','granted',now() - interval '1 day'),
  ('cs_test_ad1_p1c2',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'p1c-ok@x.com',1,0,'usd','pending','granted',now() - interval '1 day'),
  -- P4: a buyer whose only order was fully refunded (phone on the account).
  ('cs_test_ad1_p4',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000c4',false,'p4@x.com',1,2500,'usd','pending','granted',now() - interval '2 days'),
  -- S2: a "no" and a "yes" at the same moment.
  ('cs_test_ad1_tie_a',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'tie@x.com',1,2500,'usd','pending','denied',now() - interval '2 days'),
  ('cs_test_ad1_tie_z',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'tie@x.com',1,2500,'usd','pending','granted',now() - interval '2 days'),
  -- AD7: an account that is deleted below (its order and an earlier guest
  -- checkout under the same email), and a banned account.
  ('cs_test_ad1_d7',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000c7',false,'del7@x.com',1,2500,'usd','pending','granted',now() - interval '2 days'),
  ('cs_test_ad1_d7g',pg_temp.ev('e1'),pg_temp.org(),NULL,true,' Del7@X.com',1,2500,'usd','pending','granted',now() - interval '9 days'),
  ('cs_test_ad1_b8',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000c8',false,'ban8@x.com',1,2500,'usd','pending','granted',now() - interval '2 days');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now()
 WHERE session_id IN ('cs_test_ad1_p1b1','cs_test_ad1_p1b2','cs_test_ad1_p1c','cs_test_ad1_p1c2','cs_test_ad1_p4',
                      'cs_test_ad1_tie_a','cs_test_ad1_tie_z','cs_test_ad1_d7','cs_test_ad1_d7g','cs_test_ad1_b8');
UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_test_ad1_p4';
INSERT INTO public.exos_order_proofs(org_id,event_id,session_id,email,original_email,status,proven_via,proven_at,expires_at) VALUES
  (pg_temp.org(),pg_temp.ev('e1'),'cs_test_ad1_p1c','p1c@x.com','p1c@x.com','cancelled',NULL,NULL,now() + interval '1 day'),
  (pg_temp.org(),pg_temp.ev('e1'),'cs_test_ad1_p1c2','p1c-ok@x.com','p1c-ok@x.com','proven','email_code',now(),now() + interval '1 day'),
  -- del7's earlier guest checkout, proven by code (so it is in until deletion).
  (pg_temp.org(),pg_temp.ev('e1'),'cs_test_ad1_d7g','del7@x.com','del7@x.com','proven','email_code',now(),now() + interval '1 day');
SELECT set_config('exos.fan_consent_action', 'on', true);
INSERT INTO public.exos_fans(org_id,email,user_id,source) VALUES
  (pg_temp.org(),'p1a@x.com',NULL,'signup'),
  (pg_temp.org(),'p4@x.com','ad100000-0000-0000-0000-0000000000c4','order'),
  (pg_temp.org(),'del7@x.com','ad100000-0000-0000-0000-0000000000c7','order')
ON CONFLICT (org_id, email) DO UPDATE SET user_id = EXCLUDED.user_id;
SELECT set_config('exos.fan_consent_action', '', true);
UPDATE auth.users SET banned_until = 'infinity' WHERE id = 'ad100000-0000-0000-0000-0000000000c8';
INSERT INTO pg_temp.ad_seen VALUES ('del7@x.com');
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[];
BEGIN
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT NOT ('p1a@x.com' = ANY (e)), 'AD6 P1a: a forged pending checkout made a list-only fan consenting';
  ASSERT NOT ('p1b@x.com' = ANY (e)) AND NOT ('p1b@x.com' = ANY (x)), 'AD6 P1b: a forged expired "yes" overrode the real later "no" (source ' || e::text || ', export ' || x::text || ')';
  ASSERT NOT ('p1c@x.com' = ANY (e)) AND NOT ('p1c@x.com' = ANY (x)), 'AD6 P1c: a free RSVP with its proof cancelled counted as consent';
  ASSERT 'p1c-ok@x.com' = ANY (e) AND 'p1c-ok@x.com' = ANY (x), 'AD6 P1c: a proven RSVP''s "yes" counts';
  ASSERT NOT ('p4@x.com' = ANY (e)) AND NOT ('p4@x.com' = ANY (x)), 'AD6 P4: a fully refunded buyer came back through their fan row';
  ASSERT NOT ('tie@x.com' = ANY (e)) AND NOT ('tie@x.com' = ANY (x)), 'AD6 S2: a "yes" at the same moment beat the "no"';
  -- The rest of AD5 still holds in the export as in the source.
  ASSERT 'buyer1@x.com' = ANY (x) AND 'xbuyer@x.com' = ANY (x), 'AD6: the export keeps consenting buyers, got ' || x::text;
  RAISE NOTICE 'OK  AD6 a "yes" counts only from a paid / issued order the person proved; refunds and ties (source and export)';
END $$;
-- The account's phone, hashed both ways (p4 is out, so a fresh consenting
-- account with a phone).
INSERT INTO auth.users(id,email,email_confirmed_at,phone) VALUES ('ad100000-0000-0000-0000-0000000000c5','ph5@x.com',now(),'16505551212');
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  ('cs_test_ad1_ph5',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000c5',false,'ph5@x.com',1,2500,'usd','pending','granted',now() - interval '2 days');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_test_ad1_ph5';
DO $$
DECLARE r jsonb; m jsonb;
BEGIN
  r := pg_temp.source(NULL);
  SELECT x INTO m FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'em' = pg_temp.h('ph5@x.com');
  ASSERT m ->> 'ph' = encode(extensions.digest('+16505551212', 'sha256'), 'hex')
     AND m ->> 'ph_digits' = encode(extensions.digest('16505551212', 'sha256'), 'hex'), 'AD6: the phone as E.164 and digits, hashed, got ' || coalesce(m::text, 'none');
  ASSERT position('6505551212' in r::text) = 0, 'AD6: no raw phone';
END $$;

-- AD7 ------------------------------------------------------------------------
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[];
BEGIN
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT 'del7@x.com' = ANY (e) AND 'del7@x.com' = ANY (x), 'AD7: before deletion the buyer is in, got ' || e::text;
  ASSERT NOT ('ban8@x.com' = ANY (e)) AND NOT ('ban8@x.com' = ANY (x)), 'AD7: a banned account is out';
END $$;
-- S-a: a tag on del7's fan profile; S-b: a guest checkout under del7's email
-- still pending when the account is deleted.
INSERT INTO public.exos_tags(id,org_id,name,scope) VALUES ('ad100000-0000-0000-0000-0000000000f7',pg_temp.org(),'VIP','fan');
INSERT INTO public.exos_tagged_items(org_id,tag_id,taggable_type,taggable_id)
SELECT f.org_id, 'ad100000-0000-0000-0000-0000000000f7', 'fan', f.id FROM public.exos_fans f WHERE f.org_id = pg_temp.org() AND f.email = 'del7@x.com';
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  ('cs_test_ad1_d7p',pg_temp.ev('e1'),pg_temp.org(),NULL,true,'del7@x.com',1,2500,'usd','pending','granted',now() - interval '1 hour');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_tagged_items WHERE tag_id = 'ad100000-0000-0000-0000-0000000000f7') = 1, 'AD7: tag set up'; END $$;
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000c7');
SET LOCAL ROLE authenticated;
SELECT public.exos_delete_my_account();
RESET ROLE;
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[];
BEGIN
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT NOT ('del7@x.com' = ANY (e)), 'AD7 P3: a deleted buyer is still in the ad audience, got ' || e::text;
  ASSERT NOT ('del7@x.com' = ANY (x)), 'AD7 P3b: a deleted buyer''s earlier guest checkout is still in the export, got ' || x::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_fans WHERE user_id = 'ad100000-0000-0000-0000-0000000000c7' OR email = 'del7@x.com'),
    'AD7: the fan profiles are deleted';
  ASSERT (SELECT buyer_email = 'deleted+ad100000-0000-0000-0000-0000000000c7@deleted.invalid' FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_ad1_d7g'),
    'AD7: the guest checkout has the tombstone address';
  ASSERT (SELECT buyer_email = 'deleted+ad100000-0000-0000-0000-0000000000c7@deleted.invalid' FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_ad1_d7p'),
    'AD7 S-b: a checkout still pending at deletion kept the email';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tagged_items WHERE tag_id = 'ad100000-0000-0000-0000-0000000000f7'),
    'AD7 S-a: the deleted fan profile''s tags are left dangling';
  ASSERT 'buyer1@x.com' = ANY (e), 'AD7: nobody else is touched';
  RAISE NOTICE 'OK  AD7 a deleted account (fan rows and their tags, every guest checkout, pending too) and a banned one stay out of the source and the export';
END $$;

-- AD8 ------------------------------------------------------------------------
DO $$
BEGIN
  -- The same vectors as ads_test.ts ("Reddit email: the SQL edges").
  ASSERT public._exos_email_sha256_reddit(E'\tJ.o.e+tag@Example.com\n') = '2481f36dfc515ca76451aaadf1399026942a01ee50c6d0a61988b43cef039bc2', 'AD8: tabs and newlines trimmed';
  ASSERT public._exos_email_sha256_reddit('jo e@example.com') IS NULL, 'AD8: whitespace inside';
  ASSERT public._exos_email_sha256_reddit(E'joe@exa\tmple.com') IS NULL, 'AD8: a tab inside';
  ASSERT public._exos_email_sha256_reddit('a@b@example.com') IS NULL, 'AD8: two @';
  ASSERT public._exos_email_sha256_reddit('@example.com') IS NULL AND public._exos_email_sha256_reddit('...@example.com') IS NULL, 'AD8: no local part';
  RAISE NOTICE 'OK  AD8 the Reddit hash''s edges (ASCII trim, one @, no whitespace inside) match hashedIds.ts';
END $$;

-- AD9 ------------------------------------------------------------------------
SELECT pg_temp.fresh_minute();
DELETE FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
DO $$
BEGIN
  PERFORM pg_temp.source(NULL);
  PERFORM pg_temp.source(NULL);
  PERFORM pg_temp.xp();
  ASSERT pg_temp.state_of($q$SELECT pg_temp.source(NULL)$q$) LIKE 'P0001%too many audience pulls%', 'AD9: 3 a minute, shared with the export';
  ASSERT pg_temp.state_of($q$SELECT pg_temp.xp()$q$) LIKE 'P0001%too many exports%', 'AD9: the export shares the minute';
  RAISE NOTICE 'OK  AD9 3 a minute per org, shared by the source and the export';
END $$;
SELECT pg_temp.fresh_minute();
DELETE FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
INSERT INTO public.exos_audience_exports (org_id, row_count) SELECT pg_temp.org(), 0 FROM generate_series(1, 19);
DO $$
BEGIN
  PERFORM pg_temp.source(NULL);   -- the 20th
  ASSERT pg_temp.state_of($q$SELECT pg_temp.xp()$q$) LIKE 'P0001%daily export limit%', 'AD9: the export counts the source''s pulls';
  ASSERT pg_temp.state_of($q$SELECT pg_temp.source(NULL)$q$) LIKE 'P0001%daily audience limit%', 'AD9: and the source the export''s';
  RAISE NOTICE 'OK  AD9 the 20 a day counts both';
END $$;

-- AD10 -----------------------------------------------------------------------
-- B2': only the person's own proof of the email makes a "yes".
SELECT pg_temp.fresh_minute();
DELETE FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
CREATE FUNCTION pg_temp.guest(p_id text, p_email text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at,proof_token_hash)
  VALUES (p_id, pg_temp.ev('e1'), pg_temp.org(), NULL, true, p_email, 1, 2500, 'usd', 'pending', 'granted', now() - interval '1 hour',
          encode(extensions.digest('tok-' || p_id || '-0123456789abcdef', 'sha256'), 'hex'));
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = p_id;
  SELECT public._exos_proof_open(p_id);
$$;
-- R1: a stranger checks out with the victim's email, ticks "yes", and proves
-- their OWN phone with the token the paying page holds (anon RPCs).
SELECT pg_temp.guest('cs_test_ad1_r1v', 'victim-r1@x.com');
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_order_proof_send('cs_test_ad1_r1v', 'tok-cs_test_ad1_r1v-0123456789abcdef', 'sms', '(212) 555-0177');
  ASSERT (j ->> 'ok')::boolean, 'AD10 R1: SMS code sent, got ' || j;
END $$;
RESET ROLE;
CREATE TEMP TABLE ad_code AS
  SELECT substring(body from '^([0-9]{6})') AS c FROM public.exos_rsvp_sms_outbox WHERE phone = '+12125550177' ORDER BY created_at DESC LIMIT 1;
GRANT SELECT ON ad_code TO anon;
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_order_proof_verify('cs_test_ad1_r1v', 'tok-cs_test_ad1_r1v-0123456789abcdef', (SELECT c FROM pg_temp.ad_code));
  ASSERT (j ->> 'ok')::boolean, 'AD10 R1: the phone proof went through, got ' || j;
END $$;
RESET ROLE;
-- R2: a typo corrected by the organizer: the original address stays on the
-- checkout, the corrected one on the proof (proven_via 'organizer').
SELECT pg_temp.guest('cs_test_ad1_r2t', 'typo-r2@x.com');
SELECT pg_temp.act('ad100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT public.exos_order_proof_resend('cs_test_ad1_r2t', 'right-r2@x.com');
RESET ROLE;
INSERT INTO pg_temp.ad_seen VALUES ('right-r2@x.com');
-- Control: the buyer proves the email with the code mailed to it.
SELECT pg_temp.guest('cs_test_ad1_r3c', 'coded-r3@x.com');
CREATE TEMP TABLE ad_mcode AS
  SELECT substring(html from 'letter-spacing:6px"><strong>([0-9]{6})</strong>') AS c FROM public.exos_mail
   WHERE to_email = 'coded-r3@x.com' AND template = 'rsvp-code' ORDER BY created_at DESC, id DESC LIMIT 1;
GRANT SELECT ON ad_mcode TO anon;
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_order_proof_verify('cs_test_ad1_r3c', 'tok-cs_test_ad1_r3c-0123456789abcdef', (SELECT c FROM pg_temp.ad_mcode));
  ASSERT (j ->> 'ok')::boolean, 'AD10: the email code went through, got ' || j;
END $$;
RESET ROLE;
-- A confirmed account's order lost to a dispute.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('ad100000-0000-0000-0000-0000000000c9','disp9@x.com',now());
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  ('cs_test_ad1_dp9',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000c9',false,'disp9@x.com',1,2500,'usd','pending','granted',now() - interval '1 hour');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now(), dispute_status = 'lost' WHERE session_id = 'cs_test_ad1_dp9';
-- An account buyer whose email isn't confirmed (a proof row is opened, never proven).
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('ad100000-0000-0000-0000-0000000000ca','unconf@x.com',NULL);
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at) VALUES
  ('cs_test_ad1_uc',pg_temp.ev('e1'),pg_temp.org(),'ad100000-0000-0000-0000-0000000000ca',false,'unconf@x.com',1,2500,'usd','pending','granted',now() - interval '1 hour');
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_test_ad1_uc';
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[];
BEGIN
  ASSERT (SELECT proven_via FROM public.exos_order_proofs WHERE session_id = 'cs_test_ad1_r1v') = 'sms', 'AD10 R1: set up as an SMS proof';
  ASSERT (SELECT proven_via = 'organizer' AND email = 'right-r2@x.com' FROM public.exos_order_proofs WHERE session_id = 'cs_test_ad1_r2t'), 'AD10 R2: set up as an organizer correction';
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT NOT ('victim-r1@x.com' = ANY (e)) AND NOT ('victim-r1@x.com' = ANY (x)),
    'AD10 R1: a stranger''s phone proof made the victim a consenting buyer (source ' || e::text || ', export ' || x::text || ')';
  ASSERT NOT ('typo-r2@x.com' = ANY (e)) AND NOT ('typo-r2@x.com' = ANY (x)), 'AD10 R2: the never-proven original address counted';
  ASSERT NOT ('right-r2@x.com' = ANY (e)) AND NOT ('right-r2@x.com' = ANY (x)), 'AD10 R2: the organizer''s correction counted as consent';
  ASSERT 'coded-r3@x.com' = ANY (e) AND 'coded-r3@x.com' = ANY (x), 'AD10: an email-code proof counts, got ' || e::text;
  ASSERT NOT ('disp9@x.com' = ANY (e)) AND NOT ('disp9@x.com' = ANY (x)), 'AD10: an order lost to a dispute counted';
  ASSERT NOT ('unconf@x.com' = ANY (e)) AND NOT ('unconf@x.com' = ANY (x)), 'AD10: an unconfirmed account''s "yes" counted';
  ASSERT 'ph5@x.com' = ANY (e) AND 'buyer1@x.com' = ANY (x), 'AD10: confirmed accounts still count';
  RAISE NOTICE 'OK  AD10 a "yes" needs the person''s own email proof: not an SMS proof, an organizer''s correction, a lost dispute or an unconfirmed account';
END $$;

-- AD11 -----------------------------------------------------------------------
-- T1: "confirmed" isn't "verified". With Supabase's "Confirm email" off,
-- GoTrue sets email_confirmed_at at sign-up and sends nothing
-- (confirmation_sent_at NULL): a stranger signs up as the victim's address,
-- buys signed in and ticks "yes". Verified means an OAuth identity whose
-- provider says email_verified, or a confirmation mail sent and answered.
-- T2: only a dispute payouts treat as settled (NULL, won, warning_closed)
-- keeps a "yes". T3: an SMS send doesn't reopen the email code's guesses.
SELECT pg_temp.fresh_minute();
DELETE FROM public.exos_audience_exports WHERE org_id = pg_temp.org();
ALTER TABLE auth.identities ADD COLUMN IF NOT EXISTS provider text, ADD COLUMN IF NOT EXISTS identity_data jsonb;
INSERT INTO auth.users(id,email,email_confirmed_at,confirmation_sent_at) VALUES
  ('ad100000-0000-0000-0000-0000000000d1','t1-victim@x.com',now(),NULL),            -- instant confirm, no mail: a stranger
  ('ad100000-0000-0000-0000-0000000000d2','t1-google@x.com',now(),NULL),            -- Google says email_verified (JSON true)
  ('ad100000-0000-0000-0000-0000000000d3','t1-apple@x.com',now(),NULL),             -- Apple says email_verified ("true")
  ('ad100000-0000-0000-0000-0000000000d4','t1-unverified@x.com',now(),NULL),        -- Google says NOT verified
  ('ad100000-0000-0000-0000-0000000000d5','t1-emailprov@x.com',now(),NULL),         -- an 'email' identity says verified: not enough
  ('ad100000-0000-0000-0000-0000000000d6','t1-mailed@x.com',now(),now() - interval '1 hour'), -- confirmation mail sent and answered
  ('ad100000-0000-0000-0000-0000000000d7','t1-otheraddr@x.com',now(),NULL),         -- Google verified a different address
  ('ad100000-0000-0000-0000-0000000000d9','u3-azure@x.com',now(),NULL),             -- Azure claims verified: not trusted (U3)
  ('ad100000-0000-0000-0000-0000000000da','u3-sso@x.com',now(),NULL),               -- an SSO IdP claims verified: not trusted (U3)
  ('ad100000-0000-0000-0000-0000000000f1','t2-needs@x.com',now(),now() - interval '1 hour'),
  ('ad100000-0000-0000-0000-0000000000f2','t2-review@x.com',now(),now() - interval '1 hour'),
  ('ad100000-0000-0000-0000-0000000000f3','t2-won@x.com',now(),now() - interval '1 hour'),
  ('ad100000-0000-0000-0000-0000000000f4','t2-wclosed@x.com',now(),now() - interval '1 hour');
INSERT INTO auth.identities(user_id,provider,identity_data) VALUES
  ('ad100000-0000-0000-0000-0000000000d2','google','{"email":"t1-google@x.com","email_verified":true}'),
  ('ad100000-0000-0000-0000-0000000000d3','apple','{"email":"T1-Apple@x.com","email_verified":"true"}'),
  ('ad100000-0000-0000-0000-0000000000d4','google','{"email":"t1-unverified@x.com","email_verified":false}'),
  ('ad100000-0000-0000-0000-0000000000d5','email','{"email":"t1-emailprov@x.com","email_verified":true}'),
  ('ad100000-0000-0000-0000-0000000000d7','google','{"email":"someone-else@x.com","email_verified":true}'),
  ('ad100000-0000-0000-0000-0000000000d9','azure','{"email":"u3-azure@x.com","email_verified":true}'),
  ('ad100000-0000-0000-0000-0000000000da','sso:7f1c0a2e-0000-0000-0000-000000000001','{"email":"u3-sso@x.com","email_verified":true}');
CREATE FUNCTION pg_temp.acct(p_id text, p_uid uuid, p_email text, p_dispute text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,guest,buyer_email,quantity,amount_cents,currency,status,consent_marketing,created_at)
  VALUES (p_id, pg_temp.ev('e1'), pg_temp.org(), p_uid, false, p_email, 1, 2500, 'usd', 'pending', 'granted', now() - interval '1 hour');
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now(), dispute_status = p_dispute WHERE session_id = p_id;
$$;
SELECT pg_temp.acct('cs_test_ad1_t1v', 'ad100000-0000-0000-0000-0000000000d1', 't1-victim@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1g', 'ad100000-0000-0000-0000-0000000000d2', 't1-google@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1a', 'ad100000-0000-0000-0000-0000000000d3', 't1-apple@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1u', 'ad100000-0000-0000-0000-0000000000d4', 't1-unverified@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1e', 'ad100000-0000-0000-0000-0000000000d5', 't1-emailprov@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1m', 'ad100000-0000-0000-0000-0000000000d6', 't1-mailed@x.com');
SELECT pg_temp.acct('cs_test_ad1_t1o', 'ad100000-0000-0000-0000-0000000000d7', 't1-otheraddr@x.com');
SELECT pg_temp.acct('cs_test_ad1_u3a', 'ad100000-0000-0000-0000-0000000000d9', 'u3-azure@x.com');
SELECT pg_temp.acct('cs_test_ad1_u3s', 'ad100000-0000-0000-0000-0000000000da', 'u3-sso@x.com');
SELECT pg_temp.acct('cs_test_ad1_t2n', 'ad100000-0000-0000-0000-0000000000f1', 't2-needs@x.com', 'needs_response');
SELECT pg_temp.acct('cs_test_ad1_t2r', 'ad100000-0000-0000-0000-0000000000f2', 't2-review@x.com', 'under_review');
SELECT pg_temp.acct('cs_test_ad1_t2w', 'ad100000-0000-0000-0000-0000000000f3', 't2-won@x.com', 'won');
SELECT pg_temp.acct('cs_test_ad1_t2c', 'ad100000-0000-0000-0000-0000000000f4', 't2-wclosed@x.com', 'warning_closed');
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[]; v text;
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_proofs WHERE session_id LIKE 'cs_test_ad1_t1%'),
    'AD11: set up as signed-in orders with no proof row (rule b)';
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT NOT ('t1-victim@x.com' = ANY (e)) AND NOT ('t1-victim@x.com' = ANY (x)),
    'AD11 T1: an instantly-confirmed account (no confirmation mail) made a "yes" (source ' || e::text || ', export ' || x::text || ')';
  FOREACH v IN ARRAY ARRAY['t1-unverified@x.com', 't1-emailprov@x.com', 't1-otheraddr@x.com', 't2-needs@x.com', 't2-review@x.com',
                           'u3-azure@x.com', 'u3-sso@x.com'] LOOP
    ASSERT NOT (v = ANY (e)) AND NOT (v = ANY (x)), 'AD11: ' || v || ' counted';
  END LOOP;
  FOREACH v IN ARRAY ARRAY['t1-google@x.com', 't1-apple@x.com', 't1-mailed@x.com', 't2-won@x.com', 't2-wclosed@x.com'] LOOP
    ASSERT v = ANY (e) AND v = ANY (x), 'AD11: ' || v || ' should count (source ' || e::text || ', export ' || x::text || ')';
  END LOOP;
  RAISE NOTICE 'OK  AD11 T1 a verified email only (OAuth verified / confirmation answered), T2 open disputes don''t count';
END $$;
-- T3: 5 wrong codes lock the email code; an SMS send to the guesser's own
-- phone gives the PHONE code 5 tries again, not the email code.
SELECT pg_temp.guest('cs_test_ad1_t3', 't3-guess@x.com');
CREATE TEMP TABLE ad_t3 AS
  SELECT substring(html from 'letter-spacing:6px"><strong>([0-9]{6})</strong>') AS c FROM public.exos_mail
   WHERE to_email = 't3-guess@x.com' AND template = 'rsvp-code' ORDER BY created_at DESC, id DESC LIMIT 1;
GRANT SELECT ON ad_t3 TO anon;
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb; c text := (SELECT c FROM pg_temp.ad_t3); w text; i int;
BEGIN
  ASSERT c ~ '^[0-9]{6}$', 'AD11 T3: the email code was mailed';
  w := CASE WHEN c = '000000' THEN '111111' ELSE '000000' END;
  FOR i IN 1..5 LOOP
    j := public.exos_order_proof_verify('cs_test_ad1_t3', 'tok-cs_test_ad1_t3-0123456789abcdef', w);
  END LOOP;
  ASSERT j ->> 'error' = 'locked', 'AD11 T3: 5 wrong codes lock, got ' || j::text;
  j := public.exos_order_proof_send('cs_test_ad1_t3', 'tok-cs_test_ad1_t3-0123456789abcdef', 'sms', '(212) 555-0199');
  ASSERT (j ->> 'ok')::boolean, 'AD11 T3: SMS code sent, got ' || j::text;
  j := public.exos_order_proof_verify('cs_test_ad1_t3', 'tok-cs_test_ad1_t3-0123456789abcdef', c);
  ASSERT NOT coalesce((j ->> 'ok')::boolean, false),
    'AD11 T3: after 5 wrong codes, an SMS send let the email code through, got ' || j::text;
END $$;
RESET ROLE;
CREATE TEMP TABLE ad_t3s AS
  SELECT substring(body from '^([0-9]{6})') AS c FROM public.exos_rsvp_sms_outbox WHERE phone = '+12125550199' ORDER BY created_at DESC LIMIT 1;
GRANT SELECT ON ad_t3s TO anon;
SET LOCAL ROLE anon;
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_order_proof_verify('cs_test_ad1_t3', 'tok-cs_test_ad1_t3-0123456789abcdef', (SELECT c FROM pg_temp.ad_t3s));
  ASSERT (j ->> 'ok')::boolean, 'AD11 T3: the phone code still proves on its own budget, got ' || j::text;
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT proven_via FROM public.exos_order_proofs WHERE session_id = 'cs_test_ad1_t3') = 'sms', 'AD11 T3: proven by the phone code';
  RAISE NOTICE 'OK  AD11 T3 an SMS send leaves the email code locked after 5 wrong codes; the phone code still proves';
END $$;
-- T1b (security review of ea13aaa): an answered mail proves the address it
-- went to. While "Confirm email" is off an email change applies at once,
-- with no mail to the new address, so the confirmation branch counts only
-- with auth_confirm_email_on. Off (the default, prod today): t1-mailed no
-- longer counts, nor does an account that answered a mail for its own
-- address and then switched to the victim's; a Google-verified one still does.
UPDATE public.exos_platform_settings SET value = 'false' WHERE key = 'auth_confirm_email_on';
INSERT INTO auth.users(id,email,email_confirmed_at,confirmation_sent_at) VALUES
  ('ad100000-0000-0000-0000-0000000000d8','t1b-own@x.com',now(),now() - interval '1 hour');
UPDATE auth.users SET email = 't1b-victim@x.com' WHERE id = 'ad100000-0000-0000-0000-0000000000d8';
SELECT pg_temp.acct('cs_test_ad1_t1b', 'ad100000-0000-0000-0000-0000000000d8', 't1b-victim@x.com');
SELECT pg_temp.fresh_minute();
DO $$
DECLARE e text[]; x text[];
BEGIN
  e := pg_temp.emails(pg_temp.source(NULL));
  x := pg_temp.xemails(pg_temp.xp());
  ASSERT NOT ('t1b-victim@x.com' = ANY (e)) AND NOT ('t1b-victim@x.com' = ANY (x)),
    'AD11 T1b: an answered mail for another address, then an email change, made a "yes" (source ' || e::text || ', export ' || x::text || ')';
  ASSERT NOT ('t1-mailed@x.com' = ANY (e)) AND NOT ('t1-mailed@x.com' = ANY (x)),
    'AD11 T1b: with auth_confirm_email_on off, an answered confirmation mail still counted';
  ASSERT 't1-google@x.com' = ANY (e) AND 't1-google@x.com' = ANY (x),
    'AD11 T1b: a Google-verified email should count with the setting off';
  ASSERT public._exos_setting_bool('auth_confirm_email_on', false) IS FALSE, 'AD11 T1b: the setting is off';
  RAISE NOTICE 'OK  AD11 T1b the confirmation branch counts only with auth_confirm_email_on (default off); OAuth-verified still does';
END $$;

ROLLBACK;
