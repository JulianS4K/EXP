-- ============================================================================
-- Account deletion privacy (mig 20261020090000). Self-contained (d9 prefix),
-- rolled back. Each case is checked before and after the deletion.
--   P1 the suppression list exists, RLS on, no client access; helpers internal
--   P2 audience export: an opted-out buyer with a guest-era checkout under the
--      same email stays off after deleting the account (the P0); a later
--      checkout with fresh consent counts again
--   P3 deletion clears the email (and name) on email-matched guest sessions
--      (tombstone), tickets and invoices, not only the account's own rows
--   P4 webhook payloads and ad conversions carrying the email are scrubbed;
--      the pending conversion is skipped
--   P5 SMS: the account's numbers (by account and by its phone) are gone from
--      the audience and their queued texts skipped; others untouched
--   P6 account-limit flag email cleared
--   P7 unsubscribe (token link / profile toggle) writes the suppression,
--      re-subscribe clears it; it outlives the account; marketing mail and
--      ad conversions check it
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- As in prod (not all in this chain). Rolled back with the rest.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text, ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb,
  ADD COLUMN IF NOT EXISTS banned_until timestamptz, ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (id bigserial, user_id varchar);
CREATE TABLE IF NOT EXISTS public.exos_org_invites (token uuid DEFAULT gen_random_uuid(), org_id uuid, email text, claimed_by uuid);
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY);
CREATE TABLE IF NOT EXISTS public.exos_event_saves (user_id uuid);
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (uid uuid);
CREATE TABLE IF NOT EXISTS public.exos_org_follows (follower_uid uuid, org_id uuid);

INSERT INTO auth.users(id,email,email_confirmed_at,phone) VALUES
  ('d9000000-0000-0000-0000-0000000000a0','d9-owner@x.test',now(),NULL),
  ('d9000000-0000-0000-0000-0000000000f1','fan1@d9.test',now(),'15551230001'),
  ('d9000000-0000-0000-0000-0000000000f2','fan2@d9.test',now(),NULL),
  ('d9000000-0000-0000-0000-0000000000f3','fan3@d9.test',now(),NULL);
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('d9000000-0000-0000-0000-000000000001','D9','d9-org','d9000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold) VALUES
  ('d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-000000000001','Past','d9-past','published',now()-interval '10 days','UTC',100,3);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-0000000000e0','GA',20,100,3);
INSERT INTO public.exos_webhooks(org_id,url) VALUES ('d9000000-0000-0000-0000-000000000001','https://hooks.example.com/d9');
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000a0', true);
SELECT public.exos_set_ad_credential('d9000000-0000-0000-0000-000000000001', 'meta',
       '{"pixel_id":"123456789012345"}', 'EAAGmeta-token-0009', true, NULL);
RESET ROLE;

-- fan1: guest checkout first (ad consent), then a signed-in one; opted out of
-- marketing mail; two SMS numbers; a limit flag. fan2: a control buyer.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,guest,consent_marketing,created_at) VALUES
  ('d9_g1','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-000000000001',NULL,' Fan1@D9.test',1,2000,'fulfilled',true,'granted',now()-interval '30 days'),
  ('d9_a1','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000f1','fan1@d9.test',1,2000,'fulfilled',false,'granted',now()-interval '20 days'),
  ('d9_g2','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-000000000001',NULL,'fan2@d9.test',1,2000,'fulfilled',true,'granted',now()-interval '20 days');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,attendee_name,status,order_ref) VALUES
  ('d9000000-0000-0000-0000-00000000c001','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000d0','GA',NULL,NULL,'FAN1@d9.test','Fan One','used','d9_g1'),
  ('d9000000-0000-0000-0000-00000000c002','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000d0','GA',NULL,NULL,'fan2@d9.test','Fan Two','used','d9_g2');
INSERT INTO public.exos_invoices(org_id,event_id,number,session_id,buyer_id,buyer_email,total_cents) VALUES
  ('d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000e0','D9-1','d9_g1',NULL,'fan1@d9.test',2000),
  ('d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000e0','D9-2','d9_g2',NULL,'fan2@d9.test',2000);
INSERT INTO public.exos_mail_prefs(user_id, marketing_opt_out, opted_out_at) VALUES ('d9000000-0000-0000-0000-0000000000f1', true, now());
INSERT INTO public.exos_sms_subscribers(org_id,phone,user_id,source,consent_text) VALUES
  ('d9000000-0000-0000-0000-000000000001','+12125550133','d9000000-0000-0000-0000-0000000000f1','checkout','Text me about D9. Reply STOP to cancel.'),
  ('d9000000-0000-0000-0000-000000000001','+15551230001',NULL,'checkout','Text me about D9. Reply STOP to cancel.'),
  ('d9000000-0000-0000-0000-000000000001','+12125550199','d9000000-0000-0000-0000-0000000000f2','checkout','Text me about D9. Reply STOP to cancel.');
INSERT INTO public.exos_sms_campaigns(id,org_id,audience,body,provider) VALUES
  ('d9000000-0000-0000-0000-0000000000c9','d9000000-0000-0000-0000-000000000001','org','D9: hi Reply STOP to opt out.','twilio');
INSERT INTO public.exos_sms_outbox(campaign_id,org_id,phone,body,send_after)
SELECT 'd9000000-0000-0000-0000-0000000000c9','d9000000-0000-0000-0000-000000000001',p,'D9: hi',now()
  FROM unnest(ARRAY['+12125550133','+15551230001','+12125550199']) p;
INSERT INTO public.exos_account_limit_flags(event_id,org_id,user_id,email,held,max_per_account) VALUES
  ('d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-000000000001','d9000000-0000-0000-0000-0000000000f1','fan1@d9.test',6,4);

CREATE TEMP TABLE d9_res(k text PRIMARY KEY, j jsonb);
GRANT ALL ON d9_res TO authenticated;
CREATE FUNCTION pg_temp.d9_hash(p text) RETURNS text LANGUAGE sql IMMUTABLE AS
  $$ SELECT encode(sha256(convert_to(lower(btrim(p)),'UTF8')),'hex') $$;
CREATE FUNCTION pg_temp.d9_has(p_k text, p_email text) RETURNS boolean LANGUAGE sql AS
  $$ SELECT EXISTS (SELECT 1 FROM d9_res r, jsonb_array_elements(r.j -> 'rows') x
                     WHERE r.k = p_k AND x ->> 'email_sha256' = pg_temp.d9_hash(p_email)) $$;

-- P1 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_marketing_suppressions'::regclass), 'P1: no RLS';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_marketing_suppressions', 'SELECT'), 'P1: clients read it';
  ASSERT NOT has_table_privilege('anon', 'public.exos_marketing_suppressions', 'INSERT'), 'P1: anon writes it';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_suppress_email(text,text)', 'EXECUTE'), 'P1: clients suppress';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_marketing_suppressed(text,timestamptz)', 'EXECUTE'), 'P1: clients probe';
  RAISE NOTICE 'OK  P1 suppression list: RLS on, no client access';
END $$;

-- Before ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000a0', true);
INSERT INTO d9_res VALUES ('aud_before', public.exos_org_audience_export('d9000000-0000-0000-0000-000000000001'));
INSERT INTO d9_res VALUES ('sms_before', public.exos_sms_audience('d9000000-0000-0000-0000-000000000001', 'org'));
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT pg_temp.d9_has('aud_before', 'fan1@d9.test') AND pg_temp.d9_has('aud_before', 'fan2@d9.test'),
    'P2 before: fan1 (opted out) should be off, fan2 on';
  ASSERT (SELECT (j ->> 'reachable')::int FROM d9_res WHERE k = 'sms_before') = 3, 'P5 before: 3 numbers reachable';
  ASSERT (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'd9_g1') = ' Fan1@D9.test', 'P3 before: guest session email';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE payload::text ILIKE '%fan1@d9.test%') = 1, 'P4 before: webhook payload carries fan1';
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions
           WHERE session_id = 'd9_g1' AND status = 'pending' AND payload ->> 'em' = pg_temp.d9_hash('fan1@d9.test')) = 1,
    'P4 before: pending conversion with fan1''s hash';
  ASSERT (SELECT email FROM public.exos_account_limit_flags WHERE user_id = 'd9000000-0000-0000-0000-0000000000f1') = 'fan1@d9.test', 'P6 before';
  RAISE NOTICE 'OK  before: fan1 off the export, 3 SMS numbers, email on guest rows / webhook / conversion / flag';
END $$;

-- fan1 deletes the account ------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000f1', true);
SELECT public.exos_delete_my_account();
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000a0', true);
INSERT INTO d9_res VALUES ('aud_after', public.exos_org_audience_export('d9000000-0000-0000-0000-000000000001'));
INSERT INTO d9_res VALUES ('sms_after', public.exos_sms_audience('d9000000-0000-0000-0000-000000000001', 'org'));
RESET ROLE;

DO $$
BEGIN
  -- P2
  ASSERT NOT pg_temp.d9_has('aud_after', 'fan1@d9.test'), 'P2: deleted opted-out buyer is back on the audience export';
  ASSERT pg_temp.d9_has('aud_after', 'fan2@d9.test'), 'P2: fan2 dropped';
  ASSERT EXISTS (SELECT 1 FROM public.exos_marketing_suppressions
                  WHERE email_sha256 = pg_temp.d9_hash('fan1@d9.test') AND reason = 'account_deleted'), 'P2: no suppression written';
  RAISE NOTICE 'OK  P2 deleted opted-out buyer stays off the audience export';
  -- P3
  ASSERT (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'd9_g1')
       = 'deleted+d9000000-0000-0000-0000-0000000000f1@deleted.invalid', 'P3: guest session keeps the email';
  ASSERT (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'd9_a1') IS NULL, 'P3: account session email';
  ASSERT (SELECT buyer_email IS NULL AND attendee_name IS NULL FROM public.exos_tickets
           WHERE id = 'd9000000-0000-0000-0000-00000000c001'), 'P3: guest ticket keeps email / name';
  ASSERT (SELECT buyer_email FROM public.exos_invoices WHERE number = 'D9-1') IS NULL, 'P3: guest invoice keeps the email';
  ASSERT (SELECT total_cents FROM public.exos_invoices WHERE number = 'D9-1') = 2000, 'P3: invoice amounts changed';
  ASSERT (SELECT buyer_email FROM public.exos_checkout_sessions WHERE session_id = 'd9_g2') = 'fan2@d9.test'
     AND (SELECT buyer_email FROM public.exos_tickets WHERE id = 'd9000000-0000-0000-0000-00000000c002') = 'fan2@d9.test'
     AND (SELECT buyer_email FROM public.exos_invoices WHERE number = 'D9-2') = 'fan2@d9.test', 'P3: fan2 touched';
  RAISE NOTICE 'OK  P3 email-matched guest session (tombstone), ticket, invoice cleared; others untouched';
  -- P4
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE payload::text ILIKE '%fan1@d9.test%') = 0, 'P4: webhook payload keeps fan1';
  ASSERT (SELECT count(*) FROM public.exos_webhook_deliveries WHERE payload::text ILIKE '%fan2@d9.test%') = 1, 'P4: fan2 payload touched';
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions
           WHERE payload ->> 'em' = pg_temp.d9_hash('fan1@d9.test') OR payload ? 'em_google' AND session_id IN ('d9_g1','d9_a1')) = 0,
    'P4: conversion keeps fan1''s hash';
  ASSERT (SELECT status FROM public.exos_marketing_conversions WHERE session_id = 'd9_g1') = 'skipped', 'P4: pending conversion not skipped';
  ASSERT (SELECT status FROM public.exos_marketing_conversions WHERE session_id = 'd9_g2') = 'pending', 'P4: fan2 conversion touched';
  RAISE NOTICE 'OK  P4 webhook payloads + ad conversions scrubbed; pending conversion skipped';
  -- P5
  ASSERT (SELECT (j ->> 'reachable')::int FROM d9_res WHERE k = 'sms_after') = 1, 'P5: deleted user''s numbers still reachable';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_subscribers WHERE phone IN ('+12125550133','+15551230001')), 'P5: subscriber rows kept';
  ASSERT (SELECT array_agg(phone || '=' || status ORDER BY phone) FROM public.exos_sms_outbox WHERE campaign_id = 'd9000000-0000-0000-0000-0000000000c9')
       = ARRAY['+12125550133=skipped','+12125550199=queued','+15551230001=skipped'], 'P5: queued texts not skipped';
  RAISE NOTICE 'OK  P5 SMS numbers (account + account phone) unsubscribed, queued texts skipped';
  -- P6
  ASSERT (SELECT email FROM public.exos_account_limit_flags WHERE user_id = 'd9000000-0000-0000-0000-0000000000f1') IS NULL, 'P6: flag email kept';
  RAISE NOTICE 'OK  P6 limit-flag email cleared';
END $$;

DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audience:%';  -- 3 exports a minute
-- P2 (cont.): a checkout after the deletion with fresh consent counts again.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,guest,consent_marketing,created_at) VALUES
  ('d9_g1b','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-000000000001',NULL,'fan1@d9.test',1,2000,'fulfilled',true,'granted',now()+interval '1 minute');
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000a0', true);
INSERT INTO d9_res VALUES ('aud_fresh', public.exos_org_audience_export('d9000000-0000-0000-0000-000000000001'));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.d9_has('aud_fresh', 'fan1@d9.test'), 'P2: fresh consent after deletion ignored';
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions WHERE session_id = 'd9_g1b') = 1, 'P2: fresh conversion blocked';
  RAISE NOTICE 'OK  P2 fresh consent after the deletion counts';
END $$;

-- P7 -------------------------------------------------------------------------
-- Profile toggle: off writes it, on clears it.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000f3', true);
SELECT public.exos_set_marketing_emails(false);
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_marketing_suppressions WHERE email_sha256 = pg_temp.d9_hash('fan3@d9.test') AND reason = 'unsubscribe'),
    'P7: toggle off wrote nothing';
END $$;
SET LOCAL ROLE authenticated;
SELECT public.exos_set_marketing_emails(true);
RESET ROLE;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_marketing_suppressions WHERE email_sha256 = pg_temp.d9_hash('fan3@d9.test')),
    'P7: toggle on kept the suppression';
  ASSERT public.exos_mail_enqueue('event-announcement', 'fan3@d9.test', '{}', NULL, 'd9000000-0000-0000-0000-0000000000f3', true, NULL) IS NOT NULL,
    'P7: subscribed fan3 got no marketing mail';
END $$;
-- Mail link (signed out): writes it.
SELECT set_config('d9.tok', unsubscribe_token, true) FROM public.exos_mail_prefs WHERE user_id = 'd9000000-0000-0000-0000-0000000000f3';
SET LOCAL ROLE anon;
SELECT public.exos_mail_unsubscribe(current_setting('d9.tok'));
RESET ROLE;
-- The marketing mail check: an address on the list gets nothing even with prefs on.
UPDATE public.exos_mail_prefs SET marketing_opt_out = false WHERE user_id = 'd9000000-0000-0000-0000-0000000000f3';
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM public.exos_marketing_suppressions WHERE email_sha256 = pg_temp.d9_hash('fan3@d9.test') AND reason = 'unsubscribe'),
    'P7: unsubscribe link wrote nothing';
  ASSERT public.exos_mail_enqueue('event-announcement', 'fan3@d9.test', '{}', NULL, 'd9000000-0000-0000-0000-0000000000f3', true, NULL) IS NULL,
    'P7: suppressed address got marketing mail';
  ASSERT public.exos_mail_enqueue('event-announcement', 'fan2@d9.test', '{}', NULL, 'd9000000-0000-0000-0000-0000000000f2', true, NULL) IS NOT NULL,
    'P7: fan2 got no marketing mail';
END $$;
UPDATE public.exos_mail_prefs SET marketing_opt_out = true WHERE user_id = 'd9000000-0000-0000-0000-0000000000f3';
DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'audience:%';  -- 3 exports a minute
-- fan3 deletes the account, then checks out as a guest with fresh consent: the
-- unsubscribe still holds (export and ad conversions).
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000f3', true);
SELECT public.exos_delete_my_account();
RESET ROLE;
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,guest,consent_marketing,created_at) VALUES
  ('d9_g3','d9000000-0000-0000-0000-0000000000e0','d9000000-0000-0000-0000-0000000000d0','d9000000-0000-0000-0000-000000000001',NULL,'Fan3@d9.test',1,2000,'fulfilled',true,'granted',now()+interval '1 minute');
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'd9000000-0000-0000-0000-0000000000a0', true);
INSERT INTO d9_res VALUES ('aud_unsub', public.exos_org_audience_export('d9000000-0000-0000-0000-000000000001'));
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT pg_temp.d9_has('aud_unsub', 'fan3@d9.test'), 'P7: unsubscribed + deleted buyer back on the export';
  ASSERT pg_temp.d9_has('aud_unsub', 'fan2@d9.test'), 'P7: fan2 dropped';
  ASSERT (SELECT count(*) FROM public.exos_marketing_conversions WHERE session_id = 'd9_g3') = 0, 'P7: conversion sent for a suppressed address';
  RAISE NOTICE 'OK  P7 unsubscribe writes / re-subscribe clears the suppression; it outlives the account; mail + conversions check it';
END $$;

ROLLBACK;
