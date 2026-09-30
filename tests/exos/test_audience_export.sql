-- ============================================================================
-- Hashed customer-list export (mig 20260930101000). Self-contained (ae
-- prefix), rolled back.
--   A1 the function and the export log exist; search_path pinned; anon can't
--      execute; the log has RLS
--   A2 only owner / manager: finance, scanner, another org, signed out are
--      refused; another org's event is refused
--   A3 who is on the list: checkout consent granted only (a follower
--      without it is left out); not denied, not unknown, not pending, not another
--      org; the latest choice wins; unsubscribed (by account or by the
--      account's email) and deleted accounts are left out; p_event_id narrows
--   A4 only hashes: every value is 64 hex chars, no raw email / phone
--      anywhere; email normalized (trimmed, lower-cased) before hashing;
--      phone as E.164 ("+") and digits-only (Meta's documented example)
--   A5 each export is logged (org, event, who, rows); owner / manager read
--      the log, a scanner doesn't
--   A6 throttles: 3 a minute per org, 20 a day per org
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- As in prod: follows (mig 20260520140000, not in this chain) and the
-- account phone column. Rolled back with the rest.
CREATE TABLE IF NOT EXISTS public.exos_org_follows (
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_uid, org_id)
);
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text;

INSERT INTO auth.users(id,email,email_confirmed_at,phone) VALUES
  ('ae000000-0000-0000-0000-0000000000a0','ae-owner@x.com',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000a1','ae-finance@x.com',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000a2','ae-scanner@x.com',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000a3','ae-manager@x.com',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000c0','ae-other@x.com',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000b1','ae-b1@x.com',now(),'+1 (650) 555-1212'),  -- granted, phone
  ('ae000000-0000-0000-0000-0000000000b4','ae-follower@x.com',now(),NULL),          -- follower, consent unknown
  ('ae000000-0000-0000-0000-0000000000b5','ae-nofollow@x.com',now(),NULL),          -- unknown, not following
  ('ae000000-0000-0000-0000-0000000000b6','ae-optout@x.com',now(),NULL),            -- granted, unsubscribed
  ('ae000000-0000-0000-0000-0000000000b7','ae-changed@x.com',now(),NULL),           -- granted, then denied
  ('ae000000-0000-0000-0000-0000000000b8','deleted+ae000000-0000-0000-0000-0000000000b8@deleted.invalid',now(),NULL),
  ('ae000000-0000-0000-0000-0000000000b9','ae-guest-optout@x.com',now(),NULL),      -- account unsubscribed; used as a guest
  ('ae000000-0000-0000-0000-0000000000ba','ae-followdenied@x.com',now(),NULL);      -- follower who said no
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ae000000-0000-0000-0000-000000000001','AE Org','ae-org','ae000000-0000-0000-0000-0000000000a0'),
  ('ae000000-0000-0000-0000-000000000002','AE Other','ae-other','ae000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a0','owner',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a1','finance',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a2','scanner',false),
  ('ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000a3','manager',false),
  ('ae000000-0000-0000-0000-000000000002','ae000000-0000-0000-0000-0000000000c0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','AE Show','published',now() + interval '10 days','Hall',100,0),
  ('ae000000-0000-0000-0000-0000000000e2','ae000000-0000-0000-0000-000000000001','AE Show 2','published',now() + interval '20 days','Hall',100,0),
  ('ae000000-0000-0000-0000-0000000000e9','ae000000-0000-0000-0000-000000000002','Other Show','published',now() + interval '10 days','Hall',100,0);
INSERT INTO public.exos_org_follows(follower_uid,org_id) VALUES
  ('ae000000-0000-0000-0000-0000000000b4','ae000000-0000-0000-0000-000000000001'),
  ('ae000000-0000-0000-0000-0000000000ba','ae000000-0000-0000-0000-000000000001'),
  ('ae000000-0000-0000-0000-0000000000b5','ae000000-0000-0000-0000-000000000002');   -- follows the OTHER org
INSERT INTO public.exos_mail_prefs(user_id,marketing_opt_out,opted_out_at) VALUES
  ('ae000000-0000-0000-0000-0000000000b6',true,now()),
  ('ae000000-0000-0000-0000-0000000000b9',true,now()),
  ('ae000000-0000-0000-0000-0000000000b1',false,NULL);

INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,guest,quantity,amount_cents,status,consent_marketing,created_at) VALUES
  -- on the list
  ('ae_b1','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b1','  AE-B1@X.com ',false,1,2000,'fulfilled','granted',now() - interval '5 days'),
  ('ae_g2','ae000000-0000-0000-0000-0000000000e2','ae000000-0000-0000-0000-000000000001',NULL,'Guest2@X.com',true,1,2000,'partially_refunded','granted',now() - interval '5 days'),
  ('ae_b4','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b4',NULL,false,1,2000,'fulfilled','unknown',now() - interval '5 days'),
  -- left out
  ('ae_g3','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',NULL,'denied@x.com',true,1,2000,'fulfilled','denied',now() - interval '5 days'),
  ('ae_g3n','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',NULL,'noconsent@x.com',true,1,2000,'fulfilled',NULL,now() - interval '5 days'),
  ('ae_b5','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b5','ae-nofollow@x.com',false,1,2000,'fulfilled','unknown',now() - interval '5 days'),
  ('ae_b6','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b6','ae-optout@x.com',false,1,2000,'fulfilled','granted',now() - interval '5 days'),
  ('ae_b7a','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b7','ae-changed@x.com',false,1,2000,'fulfilled','granted',now() - interval '5 days'),
  ('ae_b7b','ae000000-0000-0000-0000-0000000000e2','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b7','AE-Changed@x.com',false,1,2000,'expired','denied',now() - interval '1 day'),
  ('ae_b8','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000b8',NULL,false,1,2000,'fulfilled','granted',now() - interval '5 days'),
  ('ae_g9','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',NULL,'AE-Guest-Optout@x.com',true,1,2000,'fulfilled','granted',now() - interval '5 days'),
  ('ae_ba','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001','ae000000-0000-0000-0000-0000000000ba','ae-followdenied@x.com',false,1,2000,'fulfilled','denied',now() - interval '5 days'),
  ('ae_pend','ae000000-0000-0000-0000-0000000000e1','ae000000-0000-0000-0000-000000000001',NULL,'pending@x.com',true,1,2000,'pending','granted',now() - interval '5 days'),
  ('ae_oth','ae000000-0000-0000-0000-0000000000e9','ae000000-0000-0000-0000-000000000002',NULL,'otherorg@x.com',true,1,2000,'fulfilled','granted',now() - interval '5 days');

CREATE TEMP TABLE ae_h(k text PRIMARY KEY, h text);
INSERT INTO ae_h VALUES
  ('b1',  encode(sha256(convert_to('ae-b1@x.com','UTF8')),'hex')),
  ('g2',  encode(sha256(convert_to('guest2@x.com','UTF8')),'hex'));
GRANT SELECT ON ae_h TO authenticated;
CREATE TEMP TABLE ae_out(tag text, email_sha256 text, phone_sha256 text, phone_digits_sha256 text);
GRANT ALL ON ae_out TO authenticated;

-- A1 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT to_regprocedure('public.exos_org_audience_export(uuid,uuid)') IS NOT NULL, 'A1: function missing';
  ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.exos_org_audience_export(uuid,uuid)'::regprocedure), 'A1: not SECURITY DEFINER';
  ASSERT (SELECT proconfig::text FROM pg_proc WHERE oid = 'public.exos_org_audience_export(uuid,uuid)'::regprocedure) LIKE '%search_path=public, pg_temp%',
    'A1: search_path not pinned';
  ASSERT NOT has_function_privilege('anon', 'public.exos_org_audience_export(uuid,uuid)', 'EXECUTE'), 'A1: anon may execute';
  ASSERT has_function_privilege('authenticated', 'public.exos_org_audience_export(uuid,uuid)', 'EXECUTE'), 'A1: authenticated may not execute';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_audience_exports'::regclass), 'A1: log has no RLS';
  ASSERT NOT has_table_privilege('anon', 'public.exos_audience_exports', 'SELECT'), 'A1: anon reads the log';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_audience_exports', 'INSERT'), 'A1: clients write the log';
  RAISE NOTICE 'OK  A1 function + log exist, definer with pinned search_path, no anon';
END $$;

-- A2 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', '', true);
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A2: signed-out call allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a1', true);  -- finance
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A2: finance allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a2', true);  -- scanner
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A2: scanner allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000c0', true);  -- another org's owner
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A2: another org allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);  -- owner, other org's event
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001', 'ae000000-0000-0000-0000-0000000000e9');
  RAISE EXCEPTION 'A2: another org''s event allowed';
EXCEPTION WHEN invalid_parameter_value THEN
  RAISE NOTICE 'OK  A2 signed out / finance / scanner / other org / other org''s event refused';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A2: anon allowed';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

-- A3 / A4 --------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);  -- owner, whole org
INSERT INTO ae_out SELECT 'org', r ->> 'email_sha256', r ->> 'phone_sha256', r ->> 'phone_digits_sha256'
  FROM jsonb_array_elements(public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001') -> 'rows') r;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a3', true);  -- manager, event 1
CREATE TEMP TABLE ae_raw ON COMMIT DROP AS
  SELECT public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001', 'ae000000-0000-0000-0000-0000000000e1') AS j;
INSERT INTO ae_out SELECT 'e1', r ->> 'email_sha256', r ->> 'phone_sha256', r ->> 'phone_digits_sha256'
  FROM ae_raw, jsonb_array_elements(ae_raw.j -> 'rows') r;
RESET ROLE;
DO $$
DECLARE r record;
BEGIN
  ASSERT (SELECT (j ->> 'count')::int FROM ae_raw) = 1 AND (SELECT j::text FROM ae_raw) !~ '@',
    'A4: count wrong or an email in the raw result';
  ASSERT (SELECT array_agg(email_sha256 ORDER BY email_sha256) FROM ae_out WHERE tag = 'org')
       = (SELECT array_agg(h ORDER BY h) FROM ae_h),
    'A3: org list should be exactly b1 and guest2 (a follower without consent is out); got ' || (SELECT count(*) FROM ae_out WHERE tag = 'org');
  ASSERT (SELECT array_agg(email_sha256 ORDER BY email_sha256) FROM ae_out WHERE tag = 'e1')
       = (SELECT array_agg(h ORDER BY h) FROM ae_h WHERE k = 'b1'),
    'A3: event 1 list should be b1 only (guest2 bought event 2; the follower has no consent)';
  -- Every value is a hex SHA-256; no raw email or phone slipped through.
  FOR r IN SELECT * FROM ae_out LOOP
    ASSERT r.email_sha256 ~ '^[0-9a-f]{64}$', 'A4: email not a sha256';
    ASSERT r.phone_sha256 IS NULL OR r.phone_sha256 ~ '^[0-9a-f]{64}$', 'A4: phone not a sha256';
    ASSERT r.phone_digits_sha256 IS NULL OR r.phone_digits_sha256 ~ '^[0-9a-f]{64}$', 'A4: phone digits not a sha256';
    ASSERT position('@' in row_to_json(r)::text) = 0 AND row_to_json(r)::text !~ '650', 'A4: raw PII in the output';
  END LOOP;
  -- Phone: E.164 with "+" for Google / TikTok; digits only for Meta (Meta's
  -- own example: (650)555-1212 -> 16505551212 -> e323ec62…).
  SELECT * INTO r FROM ae_out WHERE tag = 'org' AND email_sha256 = (SELECT h FROM ae_h WHERE k = 'b1');
  ASSERT r.phone_digits_sha256 = 'e323ec626319ca94ee8bff2e4c87cf613be6ea19919ed1364124e16807ab3176',
    'A4: Meta phone hash wrong: ' || coalesce(r.phone_digits_sha256, 'null');
  ASSERT r.phone_sha256 = encode(sha256(convert_to('+16505551212','UTF8')),'hex'), 'A4: E.164 phone hash wrong';
  ASSERT (SELECT phone_sha256 FROM ae_out WHERE tag = 'org' AND email_sha256 = (SELECT h FROM ae_h WHERE k = 'g2')) IS NULL,
    'A4: a guest got a phone hash';
  RAISE NOTICE 'OK  A3 consent / follower / latest choice / unsubscribed / deleted / pending / other org / event filter';
  RAISE NOTICE 'OK  A4 hashes only; email trimmed + lower-cased; phone E.164 and digits-only';
END $$;

-- A5 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_audience_exports WHERE org_id = 'ae000000-0000-0000-0000-000000000001') = 2, 'A5: exports not logged';
  ASSERT EXISTS (SELECT 1 FROM public.exos_audience_exports WHERE org_id = 'ae000000-0000-0000-0000-000000000001'
                  AND event_id = 'ae000000-0000-0000-0000-0000000000e1'
                  AND exported_by = 'ae000000-0000-0000-0000-0000000000a3' AND row_count = 1), 'A5: manager export log row wrong';
  ASSERT EXISTS (SELECT 1 FROM public.exos_audience_exports WHERE event_id IS NULL
                  AND exported_by = 'ae000000-0000-0000-0000-0000000000a0' AND row_count = 2), 'A5: owner export log row wrong';
END $$;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a3', true);  -- manager reads the log
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_audience_exports) = 2, 'A5: manager can''t read the log'; END $$;
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a2', true);  -- scanner doesn't
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_audience_exports) = 0, 'A5: scanner reads the log';
  RAISE NOTICE 'OK  A5 each export logged; owner / manager read the log, scanner doesn''t';
END $$;

-- A6 -------------------------------------------------------------------------
-- Two calls so far this minute; the third passes, the fourth is refused.
SELECT set_config('app.uid', 'ae000000-0000-0000-0000-0000000000a0', true);
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  BEGIN
    PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'A6: fourth export in a minute allowed';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%try again in a minute%', 'A6: wrong refusal: ' || SQLERRM;
  END;
END $$;
RESET ROLE;
DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audience:%';
INSERT INTO public.exos_audience_exports (org_id, exported_by, row_count)
  SELECT 'ae000000-0000-0000-0000-000000000001', 'ae000000-0000-0000-0000-0000000000a0', 0 FROM generate_series(1, 17);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM public.exos_org_audience_export('ae000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'A6: 21st export in a day allowed';
EXCEPTION WHEN raise_exception THEN
  ASSERT SQLERRM LIKE '%daily export limit%', 'A6: wrong refusal: ' || SQLERRM;
  RAISE NOTICE 'OK  A6 3 a minute and 20 a day per org';
END $$;
RESET ROLE;
ROLLBACK;
