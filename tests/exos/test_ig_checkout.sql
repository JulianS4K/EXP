-- ============================================================================
-- Instagram / Facebook in-app browser checkout (mig 20261105140000):
--   IG1 grants: the classifier and the trigger function have no client
--       grant; the report is authenticated only (not anon, not PUBLIC)
--   IG2 _exos_in_app_browser_from_ua classifies the same user agents as
--       src/lib/inAppBrowser.test.ts (apps on iOS and Android, generic
--       webviews, real browsers, link-preview bots)
--   IG3 the column refuses anything off the list
--   IG4 the insert trigger fills a missing value from user_agent, keeps the
--       value exos-checkout sent, and leaves a session with no user agent
--       unrecorded
--   IG5 the report: started / paid / tickets / gross per browser, the
--       "opened in the browser from Instagram" rows apart, refunds still
--       count as paid, pending and expired only as started
--   IG6 who may read it: owner, manager, finance; not a scanner, not a fan,
--       not another org's owner, not for an unknown event; anon can't call
-- Self-contained (BEGIN / ROLLBACK), prefix 1ab0.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('1ab00000-0000-0000-0000-0000000000a1', 'iab-owner@x.com', now()),
  ('1ab00000-0000-0000-0000-0000000000a2', 'iab-manager@x.com', now()),
  ('1ab00000-0000-0000-0000-0000000000a3', 'iab-scanner@x.com', now()),
  ('1ab00000-0000-0000-0000-0000000000a4', 'iab-finance@x.com', now()),
  ('1ab00000-0000-0000-0000-0000000000b1', 'iab-other@x.com', now()),
  ('1ab00000-0000-0000-0000-0000000000f1', 'iab-fan@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('1ab00000-0000-0000-0000-000000000001', 'IAB Org', 'iab-org', '1ab00000-0000-0000-0000-0000000000a1'),
  ('1ab00000-0000-0000-0000-000000000002', 'IAB Other', 'iab-other', '1ab00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('1ab00000-0000-0000-0000-000000000001', '1ab00000-0000-0000-0000-0000000000a1', 'owner'),
  ('1ab00000-0000-0000-0000-000000000001', '1ab00000-0000-0000-0000-0000000000a2', 'manager'),
  ('1ab00000-0000-0000-0000-000000000001', '1ab00000-0000-0000-0000-0000000000a3', 'scanner'),
  ('1ab00000-0000-0000-0000-000000000001', '1ab00000-0000-0000-0000-0000000000a4', 'finance'),
  ('1ab00000-0000-0000-0000-000000000002', '1ab00000-0000-0000-0000-0000000000b1', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by) VALUES
  ('1ab00000-0000-0000-0000-0000000000e1', '1ab00000-0000-0000-0000-000000000001', 'IAB Party', 'iab-party', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', '1ab00000-0000-0000-0000-0000000000a1'),
  ('1ab00000-0000-0000-0000-0000000000e9', '1ab00000-0000-0000-0000-000000000002', 'IAB Elsewhere', 'iab-else', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', '1ab00000-0000-0000-0000-0000000000b1');

CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
-- The report as a signed-in user, or the SQLSTATE it raised.
CREATE FUNCTION pg_temp.report_as(p_uid uuid, p_event uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(p_uid);
  SET LOCAL ROLE authenticated;
  r := public.exos_event_in_app_report(p_event);
  RESET ROLE;
  RETURN r::text;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.report_as(uuid, uuid) TO authenticated;
-- One checkout session for the event (service role / exos-checkout's insert).
CREATE FUNCTION pg_temp.sess(p_id text, p_status text, p_qty int, p_cents int, p_ua text, p_kind text,
                              p_attr jsonb DEFAULT NULL, p_event uuid DEFAULT '1ab00000-0000-0000-0000-0000000000e1')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, buyer_email, quantity, amount_cents,
                                             currency, status, user_agent, in_app_browser, attribution)
  SELECT p_id, p_event, e.org_id, '1ab00000-0000-0000-0000-0000000000f1', 'iab-fan@x.com', p_qty, p_cents, 'usd',
         p_status, p_ua, p_kind, p_attr
    FROM public.exos_events e WHERE e.id = p_event;
$$;

-- IG1 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public._exos_in_app_browser_from_ua(text)', 'EXECUTE'), 'IG1: classifier not anon';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_in_app_browser_from_ua(text)', 'EXECUTE'), 'IG1: classifier not authenticated';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_tg_checkout_in_app_browser()', 'EXECUTE'), 'IG1: trigger fn not authenticated';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_in_app_report(uuid)', 'EXECUTE'), 'IG1: report not anon';
  ASSERT has_function_privilege('authenticated', 'public.exos_event_in_app_report(uuid)', 'EXECUTE'), 'IG1: report for authenticated';
  ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.exos_event_in_app_report(uuid)'::regprocedure), 'IG1: report is definer';
  ASSERT (SELECT proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = 'public.exos_event_in_app_report(uuid)'::regprocedure),
    'IG1: report pins search_path';
  ASSERT NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public._exos_tg_checkout_in_app_browser()'::regprocedure), 'IG1: trigger fn is not definer';
  RAISE NOTICE 'OK  IG1 grants';
END $$;

-- IG2 ------------------------------------------------------------------------
DO $$
DECLARE r record; got text; bad text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('instagram', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)'),
    ('instagram', 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 Instagram 338.0.0.40.95 Android'),
    ('facebook', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/470.0.0.40.108;FBBV/620000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBLC/en_US;FBOP/5]'),
    ('facebook', 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/471.0.0.35.80;]'),
    ('messenger', 'Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 [FB_IAB/MESSENGER;FBAV/460.0.0.49.109;]'),
    ('messenger', 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0 Mobile Safari/537.36 [FB_IAB/Orca-Android;FBAV/440.0.0.29.109;]'),
    ('messenger', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/MessengerForiOS;FBAV/458.0.0.38.108;FBBV/600000000;FBDV/iPhone15,2;FBMD/iPhone;FBSN/iOS;FBSV/17.5;FBSS/3;FBLC/en_US;FBOP/5]'),
    ('threads', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Barcelona 340.0.0.22.109 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 620000000)'),
    ('threads', 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 Barcelona 340.0.0.22.109 Android (34/14; 420dpi; 1080x2400; Google; Pixel 8; shiba; shiba; en_US; 620000000)'),
    ('tiktok', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 musical_ly_35.0.0 JsSdk/2.0 NetType/WIFI Channel/App Store ByteLocale/en Region/US'),
    ('tiktok', 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 trill_350003 JsSdk/1.0 NetType/WIFI Channel/googleplay AppName/musical_ly app_version/35.0.3 ByteLocale/en Region/US BytedanceWebview/d8a21c6'),
    ('snapchat', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Snapchat/13.0.0.40 (like Safari/8618.2.12.10.4, panda)'),
    ('snapchat', 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 Snapchat/13.0.0.40 (SM-S918U; Android 14; gzip)'),
    ('x', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Twitter for iPhone/10.50'),
    ('x', 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 TwitterAndroid'),
    ('linkedin', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.30.1234'),
    ('linkedin', 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 [LinkedInApp]/4.1.900'),
    ('webview', 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36'),
    -- iOS WebKit without Safari/: only the page can tell a webview from a home-screen app.
    ('none', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'),
    ('none', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    ('none', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.6478.54 Mobile/15E148 Safari/604.1'),
    ('none', 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.71 Mobile Safari/537.36'),
    ('none', 'Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-S918U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36'),
    ('none', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'),
    ('none', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0'),
    ('none', 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)'),
    ('none', 'Twitterbot/1.0'),
    ('none', 'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.126 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)')
  ) AS t(want, ua) LOOP
    got := public._exos_in_app_browser_from_ua(r.ua);
    IF got IS DISTINCT FROM r.want THEN bad := bad || format(E'\n  want %s got %s: %s', r.want, got, left(r.ua, 90)); END IF;
  END LOOP;
  ASSERT bad = '', 'IG2: classifier disagrees with the TS patterns:' || bad;
  ASSERT public._exos_in_app_browser_from_ua(NULL) IS NULL AND public._exos_in_app_browser_from_ua('') IS NULL, 'IG2: no UA, no answer';
  RAISE NOTICE 'OK  IG2 the SQL classifier matches the shared TS patterns (28 user agents)';
END $$;

-- IG3 ------------------------------------------------------------------------
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM pg_temp.sess('cs_iab_bad', 'pending', 1, 1000, NULL, 'Instagram');
  EXCEPTION WHEN check_violation THEN refused := true;
  END;
  ASSERT refused, 'IG3: a value off the list is refused';
  RAISE NOTICE 'OK  IG3 the column takes the list only';
END $$;

-- IG4 ------------------------------------------------------------------------
SELECT pg_temp.sess('cs_iab_trig', 'pending', 1, 2000,
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108', NULL);
-- exos-checkout's value (the page probed an iOS webview) stands.
SELECT pg_temp.sess('cs_iab_keep', 'pending', 1, 2000,
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148', 'webview');
SELECT pg_temp.sess('cs_iab_noua', 'pending', 1, 2000, NULL, NULL);
DO $$
BEGIN
  ASSERT (SELECT in_app_browser FROM public.exos_checkout_sessions WHERE session_id = 'cs_iab_trig') = 'instagram', 'IG4: filled from the UA';
  ASSERT (SELECT in_app_browser FROM public.exos_checkout_sessions WHERE session_id = 'cs_iab_keep') = 'webview', 'IG4: the sent value stays';
  ASSERT (SELECT in_app_browser FROM public.exos_checkout_sessions WHERE session_id = 'cs_iab_noua') IS NULL, 'IG4: no UA, not recorded';
  RAISE NOTICE 'OK  IG4 insert trigger';
END $$;
DELETE FROM public.exos_checkout_sessions WHERE session_id IN ('cs_iab_trig', 'cs_iab_keep', 'cs_iab_noua');

-- IG5 ------------------------------------------------------------------------
-- Instagram webview: 4 started, 2 paid (one later refunded), 1 pending, 1 expired.
SELECT pg_temp.sess('cs_iab_1', 'fulfilled', 2, 5000, NULL, 'instagram');
SELECT pg_temp.sess('cs_iab_2', 'refunded', 1, 2500, NULL, 'instagram');
SELECT pg_temp.sess('cs_iab_3', 'pending', 1, 2500, NULL, 'instagram');
SELECT pg_temp.sess('cs_iab_4', 'expired', 3, 7500, NULL, 'instagram');
-- Left Instagram through the escape link, paid in Safari.
SELECT pg_temp.sess('cs_iab_5', 'fulfilled', 2, 5000, NULL, 'none', '{"utm_source":"instagram","iab_from":"instagram"}');
-- A junk iab_from (never written by exos-checkout) is not an escape row.
SELECT pg_temp.sess('cs_iab_6', 'expired', 1, 2500, NULL, 'none', '{"iab_from":"<b>"}');
-- Plain browser, partially refunded (still a paid order).
SELECT pg_temp.sess('cs_iab_7', 'partially_refunded', 1, 2500, NULL, 'none');
-- Facebook on Android.
SELECT pg_temp.sess('cs_iab_8', 'fulfilled', 4, 10000, NULL, 'facebook');
-- Before this migration: not recorded.
SELECT pg_temp.sess('cs_iab_9', 'fulfilled', 1, 2500, NULL, NULL);
-- Another org's event: never in this report.
SELECT pg_temp.sess('cs_iab_x', 'fulfilled', 9, 99900, NULL, 'instagram', NULL, '1ab00000-0000-0000-0000-0000000000e9');
DO $$
DECLARE r jsonb; ig jsonb; esc jsonb; br jsonb; fb jsonb; nr jsonb;
BEGIN
  r := pg_temp.report_as('1ab00000-0000-0000-0000-0000000000a1', '1ab00000-0000-0000-0000-0000000000e1')::jsonb;
  ASSERT r ->> 'currency' = 'usd', 'IG5: currency ' || r::text;
  ASSERT jsonb_array_length(r -> 'rows') = 5, 'IG5: five groups ' || (r -> 'rows')::text;
  SELECT x INTO ig FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'in_app_browser' = 'instagram';
  SELECT x INTO esc FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'in_app_browser' = 'none' AND x ->> 'escaped_from' = 'instagram';
  SELECT x INTO br FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'in_app_browser' = 'none' AND x -> 'escaped_from' = 'null'::jsonb;
  SELECT x INTO fb FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'in_app_browser' = 'facebook';
  SELECT x INTO nr FROM jsonb_array_elements(r -> 'rows') x WHERE x -> 'in_app_browser' = 'null'::jsonb;
  ASSERT ig = '{"in_app_browser":"instagram","escaped_from":null,"started":4,"paid":2,"tickets":3,"gross_cents":7500}'::jsonb, 'IG5: instagram ' || ig::text;
  ASSERT esc = '{"in_app_browser":"none","escaped_from":"instagram","started":1,"paid":1,"tickets":2,"gross_cents":5000}'::jsonb, 'IG5: escaped ' || esc::text;
  ASSERT br = '{"in_app_browser":"none","escaped_from":null,"started":2,"paid":1,"tickets":1,"gross_cents":2500}'::jsonb, 'IG5: browser ' || br::text;
  ASSERT fb ->> 'started' = '1' AND fb ->> 'paid' = '1' AND fb ->> 'gross_cents' = '10000', 'IG5: facebook ' || fb::text;
  ASSERT nr ->> 'started' = '1' AND nr ->> 'paid' = '1', 'IG5: not recorded ' || nr::text;
  ASSERT (r -> 'rows' -> 0 ->> 'in_app_browser') = 'instagram', 'IG5: most started first';
  ASSERT r::text NOT LIKE '%99900%', 'IG5: another org''s sessions stay out';
  RAISE NOTICE 'OK  IG5 report: started / paid / tickets / gross per browser and escape source';
END $$;

-- IG6 ------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000a2', '1ab00000-0000-0000-0000-0000000000e1') LIKE '{%', 'IG6: manager reads';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000a4', '1ab00000-0000-0000-0000-0000000000e1') LIKE '{%', 'IG6: finance reads';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000a3', '1ab00000-0000-0000-0000-0000000000e1') = '42501', 'IG6: scanner refused';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000f1', '1ab00000-0000-0000-0000-0000000000e1') = '42501', 'IG6: a buyer refused';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000b1', '1ab00000-0000-0000-0000-0000000000e1') = '42501', 'IG6: another org refused';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000b1', '1ab00000-0000-0000-0000-0000000000e9') LIKE '%"started": 1%', 'IG6: that org reads its own';
  ASSERT pg_temp.report_as('1ab00000-0000-0000-0000-0000000000a1', '1ab00000-0000-0000-0000-0000000000ee') = '42501', 'IG6: unknown event refused';
  RAISE NOTICE 'OK  IG6 report access: owner / manager / finance of the event''s org only';
END $$;
SELECT pg_temp.act(NULL);
SET LOCAL ROLE anon;
DO $$
DECLARE refused boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_event_in_app_report('1ab00000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  ASSERT refused, 'IG6: anon can''t call the report';
  RAISE NOTICE 'OK  IG6 anon refused';
END $$;
RESET ROLE;

ROLLBACK;
