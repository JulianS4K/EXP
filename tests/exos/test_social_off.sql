-- ============================================================================
-- Social / "friends" features paused (operator 2026-11-17, mig
-- 20261117100000). Self-contained (cf5 prefix), rolled back. Runs after
-- test_matched_seats.sql, test_paypal_payments.sql and test_group_chat.sql,
-- which turn the switch on for themselves (rolled back with them).
--   SO1 off by default: the setting row is JSON false; a missing row or any
--       value but JSON true reads as off
--   SO2 grants: the helper is service role only; the setter is for signed-in
--       callers (it checks the admin itself) and the service role, never
--       anon; both definer with search_path pinned; each of the nine patched
--       functions carries the marker once
--   SO3 the setter: a platform admin or the service role only (an org owner
--       gets 42501); a reason is required; each change is one audit row
--       (platform.social_features, nil org, [old, new], the reason, the
--       actor); setting the same value again changes and logs nothing
--   SO4 split with friends, off: a new split and adding a friend raise XSOFF
--       before anything is written; the split made while on still works: the
--       host reads it, nudges, ticks paid (the 'on_paid' ticket is sent), and
--       the friend claims the ticket from the claim link
--   SO5 matched seats, off: a ticket type can't become matched (XSOFF, no
--       config); a stranger still gets 42501 first; a type matched before the
--       pause can still be edited and still shows on the event page
--   SO6 group chat, off: create, join (a new member), add member and texts
--       opt-in raise XSOFF; a member asking to join again is still "joined";
--       a member can still post, but nothing is relayed; the queued relay
--       and confirmation texts are skipped, keyword answers still go; an
--       inbound text isn't relayed or stored and gets one "paused" answer a
--       day; STOP still works
--   SO7 the refusals are the switch: on again, a group can be created
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('cf500000-0000-0000-0000-0000000000a0','cf5-owner@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000ad','cf5-admin@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000b0','cf5-host@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000b1','cf5-friend@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000c1','cf5-m1@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000c2','cf5-m2@x.com',now()),
  ('cf500000-0000-0000-0000-0000000000c9','cf5-out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cf500000-0000-0000-0000-000000000001','CF5 Org','cf5-org','cf500000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('cf500000-0000-0000-0000-000000000001','cf500000-0000-0000-0000-0000000000a0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold,timezone) VALUES
  ('cf500000-0000-0000-0000-0000000000e1','cf500000-0000-0000-0000-000000000001','CF5 Show','cf5-show','published',
   now() + interval '5 days','Hall',100,0,'America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('cf500000-0000-0000-0000-0000000000d1','cf500000-0000-0000-0000-0000000000e1','Table seat',20,50,0,'public'),
  ('cf500000-0000-0000-0000-0000000000d2','cf500000-0000-0000-0000-0000000000e1','GA',20,50,0,'public');
-- The host's paid order: three GA tickets.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status) VALUES
  ('cs_cf5_split','cf500000-0000-0000-0000-0000000000e1','cf500000-0000-0000-0000-0000000000d2','cf500000-0000-0000-0000-000000000001',
   'cf500000-0000-0000-0000-0000000000b0','cf5-host@x.com',3,6000,'fulfilled');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref)
SELECT ('cf500000-0000-0000-0000-00000000007' || n)::uuid, 'cf500000-0000-0000-0000-0000000000e1', 'cf500000-0000-0000-0000-000000000001',
       'cf500000-0000-0000-0000-0000000000d2', 'GA', 'cf500000-0000-0000-0000-0000000000b0', 'cf500000-0000-0000-0000-0000000000b0',
       'cf5-host@x.com', 'active', gen_random_uuid()::text, 20, 'cs_cf5_split'
  FROM generate_series(1, 3) n;
-- The platform's relay pool: one number.
INSERT INTO public.exos_sms_relay_numbers(id,provider,phone) VALUES
  ('cf500000-0000-0000-0000-0000000000f1','twilio','+13325550901');

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text, p_admin boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true),
         set_config('app.jwt', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('email', p_email,
                                    'app_metadata', json_build_object('admin', CASE WHEN p_admin THEN 'true' ELSE 'false' END))::text END, true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.audits() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.exos_org_audit WHERE action = 'platform.social_features';
$$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text, text, boolean) TO PUBLIC;

-- SO1 --------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT value FROM public.exos_platform_settings WHERE key = 'social_features_enabled') = 'false'::jsonb,
    'SO1 the setting is JSON false: ' || coalesce((SELECT value::text FROM public.exos_platform_settings WHERE key = 'social_features_enabled'), 'no row');
  ASSERT NOT public._exos_social_on(), 'SO1 off';
  DELETE FROM public.exos_platform_settings WHERE key = 'social_features_enabled';
  ASSERT NOT public._exos_social_on(), 'SO1 no row is off';
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('social_features_enabled', '"true"');
  ASSERT NOT public._exos_social_on(), 'SO1 the string "true" is off';
  UPDATE public.exos_platform_settings SET value = '1' WHERE key = 'social_features_enabled';
  ASSERT NOT public._exos_social_on(), 'SO1 1 is off';
  UPDATE public.exos_platform_settings SET value = 'true' WHERE key = 'social_features_enabled';
  ASSERT public._exos_social_on(), 'SO1 JSON true is on';
  UPDATE public.exos_platform_settings SET value = 'false' WHERE key = 'social_features_enabled';
  ASSERT NOT public._exos_social_on(), 'SO1 back off';
  RAISE NOTICE 'OK  SO1 off by default: JSON false; no row, a string or a number read as off';
END $$;

-- SO2 --------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public._exos_social_on()', 'EXECUTE'), 'SO2 anon helper';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_social_on()', 'EXECUTE'), 'SO2 authenticated helper';
  ASSERT has_function_privilege('service_role', 'public._exos_social_on()', 'EXECUTE'), 'SO2 service helper';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_social_features_enabled(boolean,text)', 'EXECUTE'), 'SO2 anon setter';
  ASSERT has_function_privilege('authenticated', 'public.exos_set_social_features_enabled(boolean,text)', 'EXECUTE'), 'SO2 authenticated setter';
  ASSERT has_function_privilege('service_role', 'public.exos_set_social_features_enabled(boolean,text)', 'EXECUTE'), 'SO2 service setter';
  FOREACH f IN ARRAY ARRAY['public._exos_social_on()', 'public.exos_set_social_features_enabled(boolean,text)'] LOOP
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure),
      'SO2 definer, search_path pinned: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_split_save(text,jsonb,text,text,text,text)', 'public.exos_match_set_config(uuid,jsonb)',
                           'public.exos_group_create(uuid,text,text,uuid,text,integer,integer)', 'public.exos_group_join(uuid)',
                           'public.exos_group_add_member(uuid,uuid,text)', 'public.exos_group_sms_opt_in(uuid,text,text)',
                           'public._exos_group_fanout(uuid)', 'public.exos_sms_relay_claim(integer)',
                           'public.exos_sms_relay_inbound(text,text,text,text,text,text)'] LOOP
    ASSERT (length(pg_get_functiondef(f::regprocedure)) - length(replace(pg_get_functiondef(f::regprocedure), '/* exos: social off */', '')))
           / length('/* exos: social off */') = 1, 'SO2 one marker in ' || f;
  END LOOP;
  -- Grants of the patched functions are unchanged (CREATE OR REPLACE keeps them).
  ASSERT NOT has_function_privilege('anon', 'public.exos_split_save(text,jsonb,text,text,text,text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_group_create(uuid,text,text,uuid,text,integer,integer)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_sms_relay_inbound(text,text,text,text,text,text)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public._exos_group_fanout(uuid)', 'EXECUTE'), 'SO2 patched grants';
  RAISE NOTICE 'OK  SO2 grants: helper service role only, setter authenticated (checked inside) + service role, never anon; nine markers once';
END $$;

-- SO3 --------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000a0', 'cf5-owner@x.com');
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_social_features_enabled(true, 'I own an org')$q$)
         LIKE '42501%platform admins only%', 'SO3 an org owner can''t turn it on';
END $$;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000ad', 'cf5-admin@x.com', true);
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_social_features_enabled(true, NULL)$q$) LIKE '22023%reason%', 'SO3 no reason';
  ASSERT pg_temp.err($q$SELECT public.exos_set_social_features_enabled(true, '  ok  ')$q$) LIKE '22023%reason%', 'SO3 too short';
  ASSERT pg_temp.err($q$SELECT public.exos_set_social_features_enabled(NULL, 'on or off')$q$) LIKE '22023%', 'SO3 null';
  r := public.exos_set_social_features_enabled(true, 'SO3 admin turns it on');
  ASSERT r = '{"social_features_enabled": true, "changed": true}'::jsonb, 'SO3 on ' || r;
END $$;
RESET ROLE;
DO $$
DECLARE a public.exos_org_audit;
BEGIN
  ASSERT public._exos_social_on(), 'SO3 on';
  SELECT * INTO a FROM public.exos_org_audit WHERE action = 'platform.social_features' ORDER BY id DESC LIMIT 1;
  ASSERT a.org_id = '00000000-0000-0000-0000-000000000000' AND a.entity_type = 'platform_setting'
         AND a.entity_id = 'social_features_enabled' AND a.changes = '{"social_features_enabled": [false, true]}'::jsonb
         AND a.reason = 'SO3 admin turns it on' AND a.actor_uid = 'cf500000-0000-0000-0000-0000000000ad'
         AND a.actor_kind = 'user' AND a.actor_role = 'platform_admin' AND a.source = 'dashboard',
    'SO3 the audit row ' || row_to_json(a)::text;
END $$;
SET LOCAL ROLE service_role;
SELECT pg_temp.as_user(NULL, NULL);
DO $$
DECLARE v_n bigint := pg_temp.audits(); r jsonb;
BEGIN
  r := public.exos_set_social_features_enabled(true, 'already on');
  ASSERT r = '{"social_features_enabled": true, "changed": false}'::jsonb AND pg_temp.audits() = v_n, 'SO3 no-op ' || r;
  r := public.exos_set_social_features_enabled(false, 'service role off');
  ASSERT r ->> 'changed' = 'true' AND pg_temp.audits() = v_n + 1, 'SO3 the service role';
  ASSERT (SELECT actor_kind FROM public.exos_org_audit WHERE action = 'platform.social_features' ORDER BY id DESC LIMIT 1) = 'service'
         AND (SELECT changes FROM public.exos_org_audit WHERE action = 'platform.social_features' ORDER BY id DESC LIMIT 1)
             = '{"social_features_enabled": [true, false]}'::jsonb, 'SO3 the service row';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_social_features_enabled(true, 'anon tries')$q$) LIKE '42501%', 'SO3 anon';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT NOT public._exos_social_on(), 'SO3 off at the end';
  RAISE NOTICE 'OK  SO3 the setter: platform admin or service role, a reason, one audit row per change, a no-op logs nothing';
END $$;

-- What existed before the pause, made through the real functions with the
-- switch on: a split ('on_paid', one friend), a matched ticket type, and a
-- group chat with two members who opted in to texts and one queued relay.
SELECT public.exos_set_social_features_enabled(true, 'test_social_off.sql: before the pause');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000b0', 'cf5-host@x.com');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_split_save('cs_cf5_split',
         '[{"ticket_id":"cf500000-0000-0000-0000-000000000071","name":"Fran","email":"cf5-friend@x.com","amount_cents":2000}]'::jsonb,
         'cf5host', NULL, 'on_paid');
  ASSERT jsonb_array_length(r -> 'shares') = 1 AND r -> 'shares' -> 0 ->> 'transfer_id' IS NULL, 'setup split ' || r;
END $$;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000a0', 'cf5-owner@x.com');
SELECT public.exos_match_set_config('cf500000-0000-0000-0000-0000000000d1', '{"group_min":2,"group_target":4,"group_max":6}') IS NOT NULL AS matched;
CREATE TEMP TABLE cf5_g ON COMMIT DROP AS
  SELECT public.exos_group_create('cf500000-0000-0000-0000-000000000001', 'CF5 crew', 'event_attendees',
                                  'cf500000-0000-0000-0000-0000000000e1', 'open') AS id;
GRANT SELECT ON cf5_g TO PUBLIC;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c1', 'cf5-m1@x.com');
SELECT public.exos_group_join((SELECT id FROM cf5_g)) ->> 'group_id' IS NOT NULL AS m1_joined;
SELECT public.exos_group_sms_opt_in((SELECT id FROM cf5_g), '+12125550901',
  'Yes, text me this group''s messages. Reply STOP to cancel, HELP for help.') ->> 'sms_on' AS m1_sms;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c2', 'cf5-m2@x.com');
SELECT public.exos_group_join((SELECT id FROM cf5_g)) ->> 'group_id' IS NOT NULL AS m2_joined;
SELECT public.exos_group_sms_opt_in((SELECT id FROM cf5_g), '+12125550902',
  'Yes, text me this group''s messages. Reply STOP to cancel, HELP for help.') ->> 'sms_on' AS m2_sms;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c1', 'cf5-m1@x.com');
SELECT (public.exos_group_post((SELECT id FROM cf5_g), 'see you at 8', 'cf5-1') ->> 'sms_queued')::int AS queued_while_on;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox o JOIN cf5_g g ON g.id = o.group_id
           WHERE o.kind = 'relay' AND o.status = 'queued') = 1, 'setup: one relay queued for m2';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox o JOIN cf5_g g ON g.id = o.group_id
           WHERE o.kind = 'confirm' AND o.status = 'queued') = 2, 'setup: two confirmations queued';
END $$;
SELECT public.exos_set_social_features_enabled(false, 'test_social_off.sql: the pause');

-- SO4 --------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000b0', 'cf5-host@x.com');
DO $$
DECLARE r jsonb; sh jsonb;
BEGIN
  -- Adding a friend (the split exists): refused, nothing written.
  ASSERT pg_temp.err($q$SELECT public.exos_split_save('cs_cf5_split',
           '[{"ticket_id":"cf500000-0000-0000-0000-000000000072","name":"Gil","email":"gil@x.com","amount_cents":2000}]'::jsonb,
           NULL, NULL, 'now')$q$) = 'XSOFF Split with friends isn''t available', 'SO4 adding a friend';
  ASSERT (SELECT count(*) FROM public.exos_group_split_shares sh JOIN public.exos_group_splits g ON g.id = sh.split_id
           WHERE g.session_id = 'cs_cf5_split') = 1, 'SO4 no share added';
  ASSERT (SELECT pending_transfer_id FROM public.exos_tickets WHERE id = 'cf500000-0000-0000-0000-000000000072') IS NULL, 'SO4 no transfer';
  -- The existing split: readable, nudge counted, the tick sends the ticket.
  r := public.exos_split_get('cs_cf5_split');
  sh := r -> 'shares' -> 0;
  ASSERT r -> 'split' ->> 'venmo_handle' = 'cf5host' AND sh ->> 'transfer_id' IS NULL, 'SO4 get ' || r;
  ASSERT public.exos_split_nudged((sh ->> 'id')::uuid) = 1, 'SO4 nudge';
  r := public.exos_split_mark_paid((sh ->> 'id')::uuid, true);
  sh := r -> 'shares' -> 0;
  ASSERT (sh ->> 'paid')::boolean AND sh ->> 'transfer_status' = 'pending' AND sh ->> 'claim_path' LIKE '/claim/%?k=%',
    'SO4 a paid pay-back still settles: ' || sh;
END $$;
RESET ROLE;
-- A new split (another order, the same host): refused before any lock or row.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status) VALUES
  ('cs_cf5_new','cf500000-0000-0000-0000-0000000000e1','cf500000-0000-0000-0000-0000000000d2','cf500000-0000-0000-0000-000000000001',
   'cf500000-0000-0000-0000-0000000000b0','cf5-host@x.com',1,2000,'fulfilled');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000b0', 'cf5-host@x.com');
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_split_save('cs_cf5_new',
           '[{"ticket_id":"cf500000-0000-0000-0000-000000000073","name":"Hal","email":"hal@x.com","amount_cents":2000}]'::jsonb,
           'cf5host')$q$) = 'XSOFF Split with friends isn''t available', 'SO4 a new split';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_splits WHERE session_id = 'cs_cf5_new'), 'SO4 no split row';
END $$;
-- The friend claims the ticket from the claim link (looked up here: the
-- friend reads neither the host's ticket nor the share).
RESET ROLE;
CREATE TEMP TABLE cf5_tr ON COMMIT DROP AS
  SELECT sh.transfer_id AS id, public.exos_test_claim_key(sh.transfer_id) AS k
    FROM public.exos_group_split_shares sh WHERE sh.ticket_id = 'cf500000-0000-0000-0000-000000000071';
GRANT SELECT ON cf5_tr TO PUBLIC;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000b1', 'cf5-friend@x.com');
DO $$
BEGIN
  ASSERT (SELECT id FROM cf5_tr) IS NOT NULL, 'SO4 the ticket is in transfer';
  PERFORM public.exos_claim_transfer((SELECT id FROM cf5_tr), (SELECT k FROM cf5_tr));
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = 'cf500000-0000-0000-0000-000000000071')
         = 'cf500000-0000-0000-0000-0000000000b1', 'SO4 the friend holds the ticket';
  RAISE NOTICE 'OK  SO4 split off: a new split and a new friend raise XSOFF, nothing written; the existing split reads, nudges, the paid tick sends the ticket and the claim link works';
END $$;

-- SO5 --------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c9', 'cf5-out@x.com');
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_match_set_config('cf500000-0000-0000-0000-0000000000d2', '{}')$q$) LIKE '42501%',
    'SO5 a stranger still gets 42501';
END $$;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000a0', 'cf5-owner@x.com');
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_match_set_config('cf500000-0000-0000-0000-0000000000d2', '{}')$q$)
         = 'XSOFF Matched seats aren''t available', 'SO5 a new matched type';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_match_configs WHERE tier_id = 'cf500000-0000-0000-0000-0000000000d2'), 'SO5 no config';
  r := public.exos_match_set_config('cf500000-0000-0000-0000-0000000000d1', '{"quiz_tags":["jazz"]}');
  ASSERT r ->> 'quiz_tags' = '["jazz"]' AND (r ->> 'group_max')::int = 6, 'SO5 the existing type is still editable ' || r;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_match_public('cf500000-0000-0000-0000-0000000000e1')) = 1
     AND (SELECT tier_id FROM public.exos_match_public('cf500000-0000-0000-0000-0000000000e1')) = 'cf500000-0000-0000-0000-0000000000d1',
    'SO5 the event page still says the existing type is matched';
  RAISE NOTICE 'OK  SO5 matched seats off: no new matched type (XSOFF, no config; 42501 first for strangers); the existing one edits and shows';
END $$;
RESET ROLE;

-- SO6 --------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000a0', 'cf5-owner@x.com');
DO $$
DECLARE v_n bigint := (SELECT count(*) FROM public.exos_social_groups WHERE org_id = 'cf500000-0000-0000-0000-000000000001');
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_group_create('cf500000-0000-0000-0000-000000000001', 'CF5 new', 'custom',
                       'cf500000-0000-0000-0000-0000000000e1')$q$) = 'XSOFF Group chat isn''t available', 'SO6 create';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_add_member(%L, 'cf500000-0000-0000-0000-0000000000c9')$q$, (SELECT id FROM cf5_g)))
         = 'XSOFF Group chat isn''t available', 'SO6 add member';
  ASSERT (SELECT count(*) FROM public.exos_social_groups WHERE org_id = 'cf500000-0000-0000-0000-000000000001') = v_n, 'SO6 no group';
END $$;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c9', 'cf5-out@x.com');
DO $$
BEGIN
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_join(%L)$q$, (SELECT id FROM cf5_g))) = 'XSOFF Group chat isn''t available', 'SO6 join';
  ASSERT pg_temp.err(format($q$SELECT public.exos_group_sms_opt_in(%L, '+12125550909', 'Yes, text me. Reply STOP to cancel, HELP for help.')$q$,
                     (SELECT id FROM cf5_g))) = 'XSOFF Group texts aren''t available', 'SO6 opt in';
END $$;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000c1', 'cf5-m1@x.com');
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT (public.exos_group_join((SELECT id FROM cf5_g)) ->> 'joined')::boolean, 'SO6 a member asking again is joined';
  r := public.exos_group_post((SELECT id FROM cf5_g), 'running late', 'cf5-2');
  ASSERT r ->> 'message_id' IS NOT NULL AND (r ->> 'sms_queued')::int = 0, 'SO6 a post works, nothing relayed ' || r;
END $$;
RESET ROLE;
DO $$
DECLARE v_g uuid := (SELECT id FROM cf5_g);
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_social_group_members WHERE group_id = v_g AND status = 'active') = 2, 'SO6 no new member';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments a WHERE a.group_id = v_g
                      AND a.user_id = 'cf500000-0000-0000-0000-0000000000c9'), 'SO6 no relay for the outsider';
END $$;
-- exos-sms-relay (service role).
SET LOCAL ROLE service_role;
SELECT pg_temp.as_user(NULL, NULL);
DO $$
DECLARE v_g uuid := (SELECT id FROM cf5_g); r jsonb; v_claimed int;
BEGIN
  -- An inbound text from m2: not relayed, not stored, one answer.
  r := public.exos_sms_relay_inbound('twilio', '+12125550902', '+13325550901', 'where are you', NULL, 'SM-cf5-1');
  ASSERT r ->> 'action' = 'paused', 'SO6 inbound ' || r;
  r := public.exos_sms_relay_inbound('twilio', '+12125550902', '+13325550901', 'hello?', NULL, 'SM-cf5-2');
  ASSERT r ->> 'action' = 'paused', 'SO6 inbound again ' || r;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_messages WHERE group_id = v_g AND source = 'sms'), 'SO6 nothing stored';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox WHERE group_id = v_g AND kind = 'reply'
           AND body LIKE 'Exos: group texts are paused%') = 1, 'SO6 one paused answer a day';
  -- The drain: the queued relay and confirmations are skipped; the answer goes.
  SELECT count(*) INTO v_claimed FROM public.exos_sms_relay_claim(50) c WHERE c.body LIKE 'Exos: group texts are paused%';
  ASSERT v_claimed = 1, 'SO6 the answer is sent: ' || v_claimed;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE group_id = v_g AND kind <> 'reply'
                      AND status IN ('queued', 'sending')), 'SO6 nothing else claimable';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox WHERE group_id = v_g AND kind IN ('relay', 'confirm')
           AND status = 'skipped' AND error = 'group texts paused') = 3, 'SO6 relay + confirmations skipped';
  -- STOP still works.
  r := public.exos_sms_relay_inbound('twilio', '+12125550902', '+13325550901', 'STOP', 'stop', 'SM-cf5-3');
  ASSERT r ->> 'action' = 'stopped', 'SO6 STOP ' || r;
  ASSERT (SELECT sms_stopped_at FROM public.exos_sms_relay_assignments WHERE group_id = v_g
           AND user_id = 'cf500000-0000-0000-0000-0000000000c2' AND released_at IS NULL) IS NOT NULL, 'SO6 stopped';
  RAISE NOTICE 'OK  SO6 group chat off: create / join / add / texts opt-in XSOFF; a member re-joins and posts, nothing relayed; queued texts skipped, answers sent; inbound paused once a day; STOP works';
END $$;
RESET ROLE;

-- SO7 --------------------------------------------------------------------------
SELECT public.exos_set_social_features_enabled(true, 'test_social_off.sql: SO7');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('cf500000-0000-0000-0000-0000000000a0', 'cf5-owner@x.com');
DO $$
BEGIN
  ASSERT public.exos_group_create('cf500000-0000-0000-0000-000000000001', 'CF5 again', 'custom', 'cf500000-0000-0000-0000-0000000000e1') IS NOT NULL,
    'SO7 on: a group is created';
END $$;
RESET ROLE;
SELECT public.exos_set_social_features_enabled(false, 'test_social_off.sql: done');
DO $$ BEGIN
  ASSERT NOT public._exos_social_on(), 'SO7 off at the end';
  RAISE NOTICE 'OK  SO7 the refusals are the switch: on again, a group is created';
END $$;

ROLLBACK;
