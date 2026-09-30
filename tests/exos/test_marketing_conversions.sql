-- ============================================================================
-- Server-side ad conversions (mig 20260930100000). Self-contained (ae prefix),
-- rolled back. Needs tests/exos/prereq_vault.sql (the Vault stub).
--   M1 objects exist; no client role reads the credentials, the outbox or
--      Vault, or runs the drain / internal functions
--   M2 exos_set_ad_credential / exos_list_ad_credentials: owner / manager
--      only; the list never returns the secret
--   M3 validation: ids per platform, test code, token shape; enabling needs
--      the required ids and a token; NULL keeps the token, '' removes it
--   M4 outbox rows only for a fulfilled paid checkout with consent granted,
--      per enabled platform; hashed email, no raw email
--   M5 dedupe: one row per (platform, event, dedupe id), whatever replays
--   M6 refunds: a GA4 Refund row per succeeded refund, only after a Purchase
--   M7 claim / lease / mark: leases, secret handed to the service role,
--      idempotent marks, retry backoff, release, lease expiry
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ae000000-0000-0000-0000-0000000000a0','ae-owner@x.com',now()),
  ('ae000000-0000-0000-0000-0000000000a1','ae-finance@x.com',now()),
  ('ae000000-0000-0000-0000-0000000000a2','ae-scanner@x.com',now()),
  ('ae000000-0000-0000-0000-0000000000a3','ae-manager@x.com',now()),
  ('ae000000-0000-0000-0000-0000000000b0','ae-buyer@x.com',now()),
  ('ae000000-0000-0000-0000-0000000000c0','ae-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ae000000-0000-0000-0000-000000000001','AE Org','ae-org','ae000000-0000-0000-0000-0000000000a0'),
  ('ae000000-0000-0000-0000-000000000002','AE Other','ae-other','ae000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a0','owner',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a1','finance',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a2','scanner',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a3','manager',false),
  ('ae000000-0000-0000-0000-000000000002','ae000000-0000-0000-0000-0000000000c0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','AE Show','ae-show','published',now() + interval '10 days','Hall',100,0);

-- The SQLSTATE a statement raises ('' when it succeeds).
CREATE OR REPLACE FUNCTION pg_temp.sqlstate_of(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.sqlstate_of(text) TO anon, authenticated;

-- M1 -------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  ASSERT to_regclass('public.exos_org_ad_credentials') IS NOT NULL, 'M1: credentials table missing';
  ASSERT to_regclass('public.exos_marketing_conversions') IS NOT NULL, 'M1: outbox missing';
  FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
    ASSERT NOT has_table_privilege(r, 'public.exos_org_ad_credentials', 'SELECT,INSERT,UPDATE,DELETE'), 'M1: ' || r || ' touches credentials';
    ASSERT NOT has_table_privilege(r, 'public.exos_marketing_conversions', 'SELECT,INSERT,UPDATE,DELETE'), 'M1: ' || r || ' touches the outbox';
    ASSERT NOT has_schema_privilege(r, 'vault', 'USAGE'), 'M1: ' || r || ' uses the vault schema';
    ASSERT NOT has_function_privilege(r, 'public.exos_conversions_claim_batch(integer,integer,integer)', 'EXECUTE'), 'M1: ' || r || ' claims';
    ASSERT NOT has_function_privilege(r, 'public.exos_conversions_mark(uuid,uuid,text,text,integer,jsonb,integer)', 'EXECUTE'), 'M1: ' || r || ' marks';
    ASSERT NOT has_function_privilege(r, 'public._exos_email_sha256(text)', 'EXECUTE'), 'M1: ' || r || ' runs the hash helper';
    ASSERT NOT has_function_privilege(r, 'public.exos_tg_conversions_checkout()', 'EXECUTE'), 'M1: ' || r || ' runs the trigger fn';
  END LOOP;
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_ad_credential(uuid,text,jsonb,text,boolean,text)', 'EXECUTE'), 'M1: anon sets credentials';
  ASSERT NOT has_function_privilege('anon', 'public.exos_list_ad_credentials(uuid)', 'EXECUTE'), 'M1: anon lists credentials';
  ASSERT has_function_privilege('service_role', 'public.exos_conversions_claim_batch(integer,integer,integer)', 'EXECUTE'), 'M1: service role cannot claim';
  -- Definer functions pin search_path.
  SELECT string_agg(p.proname, ', ') INTO r FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND p.proname IN ('exos_set_ad_credential','exos_list_ad_credentials','exos_tg_conversions_checkout',
                       'exos_tg_conversions_refund','exos_conversions_claim_batch','exos_conversions_mark')
     AND NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path=public, pg_temp%', false);
  ASSERT r IS NULL, 'M1: search_path not pinned: ' || r;
  RAISE NOTICE 'OK  M1 no client reads credentials, the outbox or Vault, or runs the drain';
END $$;

-- M2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a3', true);  -- manager
SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001', 'meta',
       '{"pixel_id":"123456789012345"}', 'EAAGmeta-token-0001', true, 'TEST123');
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);  -- owner
SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001', 'ga4',
       '{"measurement_id":"G-ABC123XYZ"}', 'ga4-api-secret-01', true, NULL);
SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001', 'tiktok',
       '{"pixel_code":"C4ABCDEFGHIJKLMNOPQR"}', 'tiktok-token-0001', false, NULL);
DO $$
DECLARE v record; n int;
BEGIN
  -- Direct reads are refused even for the owner.
  ASSERT pg_temp.sqlstate_of('SELECT 1 FROM public.exos_org_ad_credentials') = '42501', 'M2: owner read the credentials table';
  ASSERT pg_temp.sqlstate_of('SELECT 1 FROM vault.decrypted_secrets') = '42501', 'M2: owner read Vault';
  SELECT count(*) INTO n FROM public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001');
  ASSERT n = 3, 'M2: owner lists 3 platforms, got ' || n;
  SELECT * INTO v FROM public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001') WHERE platform = 'meta';
  ASSERT v.has_secret AND v.enabled AND v.test_event_code = 'TEST123'
     AND v.config = '{"pixel_id":"123456789012345"}'::jsonb, 'M2: meta row wrong';
  ASSERT position('EAAGmeta' in row_to_json(v)::text) = 0, 'M2: the list leaked the secret';
  SELECT * INTO v FROM public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001') WHERE platform = 'tiktok';
  ASSERT v.has_secret AND NOT v.enabled, 'M2: tiktok saved but disabled';
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a1', true);  -- finance
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001')$q$) = '42501', 'M2: finance listed';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001','snap','{}',NULL,false,NULL)$q$) = '42501', 'M2: finance wrote';
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a2', true);  -- scanner
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001')$q$) = '42501', 'M2: scanner listed';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001','snap','{}',NULL,false,NULL)$q$) = '42501', 'M2: scanner wrote';
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000c0', true);  -- another org's owner
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001')$q$) = '42501', 'M2: other org listed';
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001','meta','{"pixel_id":"999999999999"}','hijack-token-01',true,NULL)$q$) = '42501', 'M2: other org wrote';
END $$;
SELECT set_config('app.uid', '', true);  -- signed out
DO $$
BEGIN
  ASSERT pg_temp.sqlstate_of($q$SELECT public.exos_list_ad_credentials('ae000000-0000-0000-0000-000000000001')$q$) = '42501', 'M2: no-uid listed';
  RAISE NOTICE 'OK  M2 owner / manager only; the list has no secret';
END $$;

-- M3 -------------------------------------------------------------------------
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);  -- owner
DO $$
DECLARE o text := 'ae000000-0000-0000-0000-000000000001'; v record;
BEGIN
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'meta','{"pixel_id":"G-123"}',NULL,false,NULL)$q$, o)) = '22023', 'M3: bad meta id';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'meta','{"token":"x"}',NULL,false,NULL)$q$, o)) = '22023', 'M3: unknown key';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'x','{}',NULL,false,NULL)$q$, o)) = '22023', 'M3: unknown platform';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'snap','{"pixel_id":"not-a-uuid"}',NULL,false,NULL)$q$, o)) = '22023', 'M3: bad snap id';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'reddit','{"pixel_id":"a2_abc"}','has space in it',false,NULL)$q$, o)) = '22023', 'M3: token with spaces';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'reddit','{"pixel_id":"a2_abc"}','short',false,NULL)$q$, o)) = '22023', 'M3: short token';
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'reddit','{"pixel_id":"a2_abc"}',NULL,false,'bad code!')$q$, o)) = '22023', 'M3: bad test code';
  -- Enabling needs a token ...
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'reddit','{"pixel_id":"a2_abc"}',NULL,true,NULL)$q$, o)) = '22023', 'M3: enabled without token';
  -- ... and the required ids.
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'google_ads','{"customer_id":"1234567890"}','1//refresh-token',true,NULL)$q$, o)) = '22023', 'M3: google_ads enabled without conversion action';
  -- Saved, disabled, with an empty field dropped.
  PERFORM public.exos_set_ad_credential(o::uuid, 'google_ads', '{"customer_id":"1234567890","conversion_action_id":"987654","login_customer_id":""}', '1//refresh-token', false, NULL);
  SELECT * INTO v FROM public.exos_list_ad_credentials(o::uuid) WHERE platform = 'google_ads';
  ASSERT v.has_secret AND NOT v.enabled AND NOT v.config ? 'login_customer_id', 'M3: google_ads saved';
  -- NULL keeps the token (enable now works) ...
  PERFORM public.exos_set_ad_credential(o::uuid, 'google_ads', '{"customer_id":"1234567890","conversion_action_id":"987654"}', NULL, true, NULL);
  SELECT * INTO v FROM public.exos_list_ad_credentials(o::uuid) WHERE platform = 'google_ads';
  ASSERT v.has_secret AND v.enabled, 'M3: NULL kept the token';
  -- ... '' removes it, and then it can't stay enabled.
  ASSERT pg_temp.sqlstate_of(format($q$SELECT public.exos_set_ad_credential(%L,'google_ads','{"customer_id":"1234567890","conversion_action_id":"987654"}','',true,NULL)$q$, o)) = '22023', 'M3: enabled after removing the token';
  PERFORM public.exos_set_ad_credential(o::uuid, 'google_ads', '{"customer_id":"1234567890","conversion_action_id":"987654"}', '', false, NULL);
  SELECT * INTO v FROM public.exos_list_ad_credentials(o::uuid) WHERE platform = 'google_ads';
  ASSERT NOT v.has_secret AND NOT v.enabled, 'M3: token removed';
  RAISE NOTICE 'OK  M3 ids, token and enable rules';
END $$;
RESET ROLE;
DO $$
DECLARE n int; s text;
BEGIN
  -- The removed token is gone from Vault; the others live there, not in the table.
  SELECT count(*) INTO n FROM vault.secrets WHERE name LIKE 'exos_ad:ae000000-0000-0000-0000-000000000001:%';
  ASSERT n = 3, 'M3: 3 tokens in Vault (meta, ga4, tiktok), got ' || n;
  SELECT d.decrypted_secret INTO s FROM public.exos_org_ad_credentials c JOIN vault.decrypted_secrets d ON d.id = c.secret_id
   WHERE c.org_id = 'ae000000-0000-0000-0000-000000000001' AND c.platform = 'meta';
  ASSERT s = 'EAAGmeta-token-0001', 'M3: meta token in Vault';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_ad_credentials c WHERE row_to_json(c)::text LIKE '%token-0001%'), 'M3: a token in the table';
END $$;
-- Replacing a token updates the same Vault row.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);
SELECT public.exos_set_ad_credential('ae000000-0000-0000-0000-000000000001', 'meta',
       '{"pixel_id":"123456789012345"}', 'EAAGmeta-token-0002', true, 'TEST123');
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_ad:ae000000-0000-0000-0000-000000000001:meta') = 1, 'M3: one meta secret';
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'exos_ad:ae000000-0000-0000-0000-000000000001:meta') = 'EAAGmeta-token-0002', 'M3: token replaced';
END $$;

-- M4 -------------------------------------------------------------------------
-- Enabled: meta, ga4. Saved but disabled: tiktok, google_ads.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,
       status,ad_ids,consent_marketing,user_agent) VALUES
  ('cs_test_ae_granted','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',
   'ae000000-0000-0000-0000-0000000000b0',' AE-Buyer@X.com ',2,5000,'usd','pending',
   '{"fbp":"fb.1.1690000000000.123456789","fbclid":"IwAR0abc","ga_client_id":"123456789.1690000000","gclid":"Cj0KCQ"}',
   'granted','Mozilla/5.0 (iPhone)'),
  ('cs_test_ae_denied','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',
   'ae000000-0000-0000-0000-0000000000b0','ae-buyer@x.com',1,2500,'usd','pending',NULL,'denied',NULL),
  ('cs_test_ae_unknown','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',
   'ae000000-0000-0000-0000-0000000000b0','ae-buyer@x.com',1,2500,'usd','pending',NULL,NULL,NULL),
  ('cs_test_ae_free','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',
   'ae000000-0000-0000-0000-0000000000b0','ae-buyer@x.com',1,0,'usd','pending',NULL,'granted',NULL),
  ('cs_test_ae_other','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000002',
   'ae000000-0000-0000-0000-0000000000b0','ae-buyer@x.com',1,2500,'usd','pending',NULL,'granted',NULL);
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now()
 WHERE session_id LIKE 'cs_test_ae_%';
DO $$
DECLARE n int; p jsonb;
BEGIN
  SELECT count(*) INTO n FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_granted';
  ASSERT n = 2, 'M4: granted checkout -> meta + ga4 rows, got ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_granted' AND platform IN ('tiktok','google_ads')),
    'M4: a disabled platform got a row';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE session_id IN ('cs_test_ae_denied','cs_test_ae_unknown')),
    'M4: a row without consent';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_free'), 'M4: a row for a free order';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_other'), 'M4: a row for an org with nothing enabled';
  SELECT payload INTO p FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_granted' AND platform = 'meta';
  -- sha256('ae-buyer@x.com'): trimmed + lower-cased first.
  ASSERT p->>'em' = encode(extensions.digest('ae-buyer@x.com', 'sha256'), 'hex'), 'M4: email hash';
  ASSERT p->>'transaction_id' = 'cs_test_ae_granted' AND p->'event'->>'slug' = 'ae-show'
     AND (p->>'quantity')::int = 2 AND p->'ad_ids'->>'fbp' = 'fb.1.1690000000000.123456789'
     AND p->>'user_agent' = 'Mozilla/5.0 (iPhone)', 'M4: payload fields';
  ASSERT position('@' in p::text) = 0, 'M4: raw email in the payload';
  ASSERT (SELECT value_cents = 5000 AND currency = 'USD' AND event_name = 'Purchase' AND event_id_dedupe = 'cs_test_ae_granted' AND status = 'pending'
            FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_granted' AND platform = 'ga4'), 'M4: ga4 row';
  -- Google's normalization drops the dots of a gmail local part; the plain one doesn't.
  ASSERT public._exos_email_sha256_google(' J.O.E@Gmail.com') = '62b1ab5bc982e80ecf47618d6c3e96368906bbcd6bf3c82b0d872ba80329e363', 'M4: google gmail hash';
  ASSERT public._exos_email_sha256('J.O.E@gmail.com') = '32eb0a4c90c82fa16fdd4fd35787f97ec43da56ca6576ed8bdeacb490ffe551c', 'M4: plain gmail hash';
  ASSERT public._exos_email_sha256(NULL) IS NULL AND public._exos_email_sha256('  ') IS NULL, 'M4: no email, no hash';
  RAISE NOTICE 'OK  M4 rows only with consent + enabled platform, hashed email';
END $$;

-- M5 -------------------------------------------------------------------------
-- A replayed status flip (refunded -> fulfilled again) and a direct duplicate.
UPDATE public.exos_checkout_sessions SET status = 'failed' WHERE session_id = 'cs_test_ae_granted';
UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_test_ae_granted';
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions WHERE session_id = 'cs_test_ae_granted') = 2, 'M5: replay duplicated rows';
  ASSERT pg_temp.sqlstate_of($q$INSERT INTO public.exos_marketing_conversions(org_id,platform,event_name,event_id_dedupe,occurred_at,value_cents,currency)
    VALUES ('ae000000-0000-0000-0000-000000000001','meta','Purchase','cs_test_ae_granted',now(),1,'USD')$q$) = '23505', 'M5: duplicate accepted';
  RAISE NOTICE 'OK  M5 one row per platform, event and dedupe id';
END $$;

-- M6 -------------------------------------------------------------------------
INSERT INTO public.exos_order_refunds(id,session_id,org_id,refund_id,amount_cents,currency,status,is_partial) VALUES
  ('ae000000-0000-0000-0000-0000000000f1','cs_test_ae_granted','ae000000-0000-0000-0000-000000000001','re_ae_1',2000,'usd','pending',true),
  ('ae000000-0000-0000-0000-0000000000f2','cs_test_ae_denied','ae000000-0000-0000-0000-000000000001','re_ae_2',2500,'usd','succeeded',false);
UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE id = 'ae000000-0000-0000-0000-0000000000f1';
UPDATE public.exos_order_refunds SET status = 'succeeded', updated_at = now() WHERE id = 'ae000000-0000-0000-0000-0000000000f1';
DO $$
DECLARE r record;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions WHERE event_name = 'Refund') = 1, 'M6: one Refund row';
  SELECT * INTO r FROM public.exos_marketing_conversions WHERE event_name = 'Refund';
  ASSERT r.platform = 'ga4' AND r.value_cents = 2000 AND r.currency = 'USD'
     AND r.event_id_dedupe = 'refund:ae000000-0000-0000-0000-0000000000f1'
     AND r.payload->>'transaction_id' = 'cs_test_ae_granted' AND (r.payload->>'partial')::boolean, 'M6: refund row';
  RAISE NOTICE 'OK  M6 GA4 Refund row per succeeded refund, none without a Purchase';
END $$;

-- M7 -------------------------------------------------------------------------
DO $$
DECLARE
  a record; b int; st text; tok uuid; n int;
BEGIN
  -- Disable ga4 so its rows come back with enabled = false.
  UPDATE public.exos_org_ad_credentials SET enabled = false
   WHERE org_id = 'ae000000-0000-0000-0000-000000000001' AND platform = 'ga4';
  CREATE TEMP TABLE ae_claim ON COMMIT DROP AS SELECT * FROM public.exos_conversions_claim_batch(50, 6, 10);
  SELECT count(*) INTO n FROM ae_claim;
  ASSERT n = 3, 'M7: claimed meta + ga4 purchase + ga4 refund, got ' || n;
  SELECT * INTO a FROM ae_claim WHERE platform = 'meta';
  ASSERT a.enabled AND a.secret = 'EAAGmeta-token-0002' AND a.config->>'pixel_id' = '123456789012345'
     AND a.test_event_code = 'TEST123' AND a.attempts = 1, 'M7: meta claim carries the credential';
  ASSERT (SELECT bool_and(NOT enabled) FROM ae_claim WHERE platform = 'ga4'), 'M7: disabled platform flagged';
  -- Leased: a second run gets nothing.
  SELECT count(*) INTO b FROM public.exos_conversions_claim_batch(50, 6, 10);
  ASSERT b = 0, 'M7: leased rows claimed twice';
  -- Mark sent; the same mark again (or with a wrong token) is a no-op.
  st := public.exos_conversions_mark(a.id, a.claim_token, 'sent', NULL, 200, '{"url":"https://graph.facebook.com/x"}');
  ASSERT st = 'sent', 'M7: sent';
  ASSERT public.exos_conversions_mark(a.id, a.claim_token, 'failed', 'late', 500) IS NULL, 'M7: second mark landed';
  ASSERT (SELECT status = 'sent' AND sent_at IS NOT NULL AND payload_planned->>'url' LIKE 'https://graph%' AND claim_token IS NULL
            FROM public.exos_marketing_conversions WHERE id = a.id), 'M7: sent row';
  ASSERT public.exos_conversions_mark(a.id, gen_random_uuid(), 'sent') IS NULL, 'M7: wrong token landed';
  -- ga4 purchase: retry -> pending later; ga4 refund: skipped.
  SELECT * INTO a FROM ae_claim WHERE platform = 'ga4' AND event_name = 'Purchase';
  ASSERT public.exos_conversions_mark(a.id, a.claim_token, 'retry', 'http 503', 503) = 'pending', 'M7: retry';
  ASSERT (SELECT next_attempt_at > now() AND last_status_code = 503 AND attempts = 1
            FROM public.exos_marketing_conversions WHERE id = a.id), 'M7: backoff';
  SELECT * INTO a FROM ae_claim WHERE platform = 'ga4' AND event_name = 'Refund';
  ASSERT public.exos_conversions_mark(a.id, a.claim_token, 'skipped', 'platform disabled') = 'skipped', 'M7: skipped';
  -- Release undoes the attempt; retry at the cap fails for good.
  UPDATE public.exos_marketing_conversions SET next_attempt_at = now() - interval '1 minute'
   WHERE platform = 'ga4' AND event_name = 'Purchase';
  SELECT * INTO a FROM public.exos_conversions_claim_batch(50, 6, 10);
  ASSERT a.attempts = 2, 'M7: second attempt';
  ASSERT public.exos_conversions_mark(a.id, a.claim_token, 'release') = 'pending', 'M7: release';
  ASSERT (SELECT attempts FROM public.exos_marketing_conversions WHERE id = a.id) = 1, 'M7: release undid the attempt';
  SELECT * INTO a FROM public.exos_conversions_claim_batch(50, 2, 10);
  ASSERT public.exos_conversions_mark(a.id, a.claim_token, 'retry', 'http 500', 500, NULL, 2) = 'failed', 'M7: retry at the cap';
  -- An expired lease is reclaimed; one that expired on the last attempt fails.
  UPDATE public.exos_marketing_conversions SET status = 'pending', attempts = 0, next_attempt_at = now() - interval '1 minute'
   WHERE id = a.id;
  SELECT claim_token INTO tok FROM public.exos_conversions_claim_batch(50, 2, 10);
  UPDATE public.exos_marketing_conversions SET claimed_at = now() - interval '11 minutes' WHERE id = a.id;
  SELECT count(*) INTO n FROM public.exos_conversions_claim_batch(50, 2, 10);
  ASSERT n = 1, 'M7: expired lease reclaimed';
  ASSERT public.exos_conversions_mark(a.id, tok, 'sent') IS NULL, 'M7: the old lease still marked';
  UPDATE public.exos_marketing_conversions SET claimed_at = now() - interval '11 minutes' WHERE id = a.id;
  SELECT count(*) INTO n FROM public.exos_conversions_claim_batch(50, 2, 10);
  ASSERT n = 0 AND (SELECT status FROM public.exos_marketing_conversions WHERE id = a.id) = 'failed', 'M7: final lease expiry fails';
  RAISE NOTICE 'OK  M7 claim / lease / mark are idempotent';
END $$;

ROLLBACK;
