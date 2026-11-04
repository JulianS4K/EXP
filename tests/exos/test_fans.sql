-- ============================================================================
-- Fans, tags, signup forms, refund queue, fan export (mig 20261031120000).
--   F1  tables: RLS on, no client writes, anon reads nothing; internal
--       functions are service-role only
--   F2  a fulfilled order makes the buyer's profile (once per order; same
--       email in any case is one fan); a refund doesn't count again
--   F3  staff read: owner / finance yes, scanner / stranger no; another org's
--       owner can't reach this org's fans (cross-org)
--   F4  consent is read-only for staff: consent keys refused, direct writes
--       refused by the trigger; names edit; email can't change; manual add,
--       duplicate refused; discard hides, a new order brings it back
--   F5  tags: create, duplicate, scope rules, other org's records refused,
--       tag by name, ALL-tags filter, remove, delete; content reads only;
--       artists refused until exos_artists exists
--   F6  signup forms: staff CRUD (owner / manager), public config (active
--       only, no fan data), submit always answers the same, 3 a day per
--       address, double opt-in via the mailed token, texts need a signed-in
--       confirm and store the exact wording, unsubscribe by token
--   F7  export: owner / manager only, logged, no tokens in the rows
--   F8  refund queue: org-wide for owner / manager / finance; the fan's own
--       list; the API read is service-role only
--   F9  fan app: ticket bundles grouped by event, own tickets only
-- Self-contained ids fb…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('fb000000-0000-0000-0000-0000000000a1','f7own@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a2','f7mgr@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a3','f7fin@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a4','f7scan@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a5','f7content@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000a9','f7otherowner@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000b1','F7Fan@X.com',now()),
  ('fb000000-0000-0000-0000-0000000000b2','f7fan2@x.com',now()),
  ('fb000000-0000-0000-0000-0000000000b9','f7stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('fb000000-0000-0000-0000-000000000001','F7 Org','fb-org','fb000000-0000-0000-0000-0000000000a1'),
  ('fb000000-0000-0000-0000-000000000002','F7 Other','fb-other','fb000000-0000-0000-0000-0000000000a9');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a1','owner'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a2','manager'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a3','finance'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a4','scanner'),
  ('fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000a5','content'),
  ('fb000000-0000-0000-0000-000000000002','fb000000-0000-0000-0000-0000000000a9','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','F7 One','fb-one','published',now() + interval '10 days','America/New_York',100,3,'fb000000-0000-0000-0000-0000000000a1'),
  ('fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-000000000001','F7 Two','fb-two','published',now() + interval '20 days','America/New_York',100,1,'fb000000-0000-0000-0000-0000000000a1'),
  ('fb000000-0000-0000-0000-0000000000e9','fb000000-0000-0000-0000-000000000002','F7 Theirs','fb-theirs','published',now() + interval '10 days','America/New_York',100,0,'fb000000-0000-0000-0000-0000000000a9');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('fb000000-0000-0000-0000-0000000000d1','fb000000-0000-0000-0000-0000000000e1','GA',30,100,3,'public'),
  ('fb000000-0000-0000-0000-0000000000d2','fb000000-0000-0000-0000-0000000000e2','GA',30,100,1,'public');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('fb000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated, service_role;
-- Run a statement as a role and report the SQLSTATE it raised ('' = none).
CREATE FUNCTION pg_temp.fails(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN '';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.fails(text) TO anon, authenticated, service_role;

-- F1 ------------------------------------------------------------------------
DO $$
DECLARE t text; bad text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_fans','exos_tags','exos_tagged_items','exos_signup_forms','exos_signup_submissions',
                           'exos_fan_exports','exos_canonical_tags'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'F1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'F1: anon reads ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'F1: client writes ' || t;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_fans', 'SELECT'), 'F1: fans only through RPCs';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_signup_submissions', 'SELECT'), 'F1: submissions service only';
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('_exos_fans_page','_exos_fan_detail','_exos_fan_save','_exos_fan_discard','_exos_fan_touch',
                       '_exos_tag_save','_exos_tag_delete','_exos_tag_apply','_exos_tagged_item_delete',
                       '_exos_signup_submit','_exos_signup_by_token','exos_api_refund_asks','exos_signup_sweep',
                       '_exos_refund_asks_page','_exos_fans_consent_guard','exos_tg_checkout_fans')
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  ASSERT bad IS NULL, 'F1: internal functions callable by clients: ' || bad;
  ASSERT NOT has_function_privilege('anon', 'public.exos_org_fans(uuid,text,uuid[],text,integer,integer)', 'EXECUTE'), 'F1: anon fan list';
  ASSERT NOT has_function_privilege('anon', 'public.exos_signup_confirm_sms(text)', 'EXECUTE'), 'F1: anon sms confirm';
  ASSERT has_function_privilege('anon', 'public.exos_signup_confirm(text)', 'EXECUTE'), 'F1: anon confirm link';
  RAISE NOTICE 'OK  F1 tables and grants';
END $$;

-- F2 ------------------------------------------------------------------------
-- b1 buys twice (one email in mixed case, one via the account), a guest buys once.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,guest,created_at,consent_marketing) VALUES
  ('cs_f7a','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-0000000000d1','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000b1','F7FAN@x.com',2,6000,'pending',false,now() - interval '3 days','granted'),
  ('cs_f7b','fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-0000000000d2','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000b1',NULL,1,3000,'pending',false,now() - interval '1 day','denied'),
  ('cs_f7g','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-0000000000d1','fb000000-0000-0000-0000-000000000001',NULL,'guest.f7@x.com',1,3000,'fulfilled',true,now() - interval '2 days',NULL);
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = created_at WHERE session_id IN ('cs_f7a','cs_f7b');
UPDATE public.exos_checkout_sessions SET status = 'partially_refunded' WHERE session_id = 'cs_f7a';
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  ('fb000000-0000-0000-0000-000000000c11','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000d1','GA','fb000000-0000-0000-0000-0000000000b1','fb000000-0000-0000-0000-0000000000b1','f7fan@x.com','active','sek-f7-1',30,'cs_f7a','stripe'),
  ('fb000000-0000-0000-0000-000000000c12','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000d1','GA','fb000000-0000-0000-0000-0000000000b1','fb000000-0000-0000-0000-0000000000b1','f7fan@x.com','active','sek-f7-2',30,'cs_f7a','stripe'),
  ('fb000000-0000-0000-0000-000000000c21','fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000d2','GA','fb000000-0000-0000-0000-0000000000b1','fb000000-0000-0000-0000-0000000000b1','f7fan@x.com','active','sek-f7-3',30,'cs_f7b','stripe'),
  ('fb000000-0000-0000-0000-000000000c31','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-0000000000d1','GA',NULL,NULL,'guest.f7@x.com','active','sek-f7-4',30,'cs_f7g','stripe');
INSERT INTO public.exos_order_refunds(session_id,org_id,amount_cents,currency,status) VALUES ('cs_f7a','fb000000-0000-0000-0000-000000000001',1000,'usd','succeeded');
DO $$
DECLARE f public.exos_fans%ROWTYPE;
BEGIN
  SELECT * INTO f FROM public.exos_fans WHERE org_id = pg_temp.u('000000000001') AND email = 'f7fan@x.com';
  ASSERT FOUND, 'F2: profile from the order';
  ASSERT f.orders_count = 2, 'F2: two orders, refund not counted again: ' || f.orders_count;
  ASSERT f.user_id = pg_temp.u('0000000000b1'), 'F2: linked to the account';
  ASSERT f.source = 'order' AND f.email_opt_in_at IS NULL, 'F2: no consent from buying';
  ASSERT (SELECT count(*) FROM public.exos_fans WHERE org_id = pg_temp.u('000000000001')) = 2, 'F2: buyer + guest, one row each';
  ASSERT EXISTS (SELECT 1 FROM public.exos_fans WHERE email = 'guest.f7@x.com' AND user_id IS NULL), 'F2: guest profile';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_fans WHERE org_id = pg_temp.u('000000000002')), 'F2: other org untouched';
  RAISE NOTICE 'OK  F2 profiles from orders';
END $$;
SELECT set_config('f7.fan', (SELECT id::text FROM public.exos_fans WHERE email = 'f7fan@x.com'), true),
       set_config('f7.guest', (SELECT id::text FROM public.exos_fans WHERE email = 'guest.f7@x.com'), true);

-- F3 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
SELECT set_config('f7.list', public.exos_org_fans(pg_temp.u('000000000001'))::text, true);
SELECT set_config('f7.detail', public.exos_org_fan(pg_temp.u('000000000001'), current_setting('f7.fan')::uuid)::text, true);
SELECT set_config('f7.search', public.exos_org_fans(pg_temp.u('000000000001'), 'GUEST')::text, true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a4');
SELECT set_config('f7.scan', pg_temp.fails('SELECT public.exos_org_fans(pg_temp.u(''000000000001''))'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b9');
SELECT set_config('f7.stranger', pg_temp.fails('SELECT public.exos_org_fan(pg_temp.u(''000000000001''), ''' || current_setting('f7.fan') || '''::uuid)'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a9');
SELECT set_config('f7.xorg1', pg_temp.fails('SELECT public.exos_org_fan(pg_temp.u(''000000000001''), ''' || current_setting('f7.fan') || '''::uuid)'), true);
SELECT set_config('f7.xorg2', pg_temp.fails('SELECT public.exos_org_fan(pg_temp.u(''000000000002''), ''' || current_setting('f7.fan') || '''::uuid)'), true);
SELECT set_config('f7.xorg3', public.exos_org_fans(pg_temp.u('000000000002'))::text, true);
RESET ROLE;
DO $$
DECLARE l jsonb := current_setting('f7.list')::jsonb; d jsonb := current_setting('f7.detail')::jsonb;
BEGIN
  ASSERT (l->>'total')::int = 2, 'F3: finance lists two fans ' || l::text;
  ASSERT NOT (l->'rows'->0 ? 'unsubscribe_token'), 'F3: no token in the list';
  ASSERT (current_setting('f7.search')::jsonb->>'total')::int = 1, 'F3: search is case-insensitive';
  ASSERT d->'stats'->>'orders' = '2' AND (d->'stats'->>'tickets')::int = 3, 'F3: stats ' || (d->'stats')::text;
  ASSERT d->'stats'->'money'->0->>'paid_cents' = '9000' AND d->'stats'->'money'->0->>'refunded_cents' = '1000', 'F3: money from the ledger';
  ASSERT jsonb_array_length(d->'orders') = 2, 'F3: both orders, by account and by email';
  ASSERT d->'consent'->>'ad_consent' = 'denied', 'F3: the latest ad choice wins';
  ASSERT d->'consent'->'email_list'->>'status' = 'none' AND d->'consent'->'sms'->>'status' = 'none', 'F3: no list yet';
  ASSERT NOT (d ? 'unsubscribe_token') AND d::text NOT LIKE '%sek-f7%', 'F3: no token, no barcode secret';
  ASSERT current_setting('f7.scan') = '42501', 'F3: scanner refused';
  ASSERT current_setting('f7.stranger') = '42501', 'F3: stranger refused';
  ASSERT current_setting('f7.xorg1') = '42501', 'F3: other org''s owner refused on this org';
  ASSERT current_setting('f7.xorg2') = 'P0002', 'F3: this org''s fan is not found under the other org';
  ASSERT (current_setting('f7.xorg3')::jsonb->>'total')::int = 0, 'F3: the other org has no fans';
  RAISE NOTICE 'OK  F3 staff reads and cross-org isolation';
END $$;

-- F4 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
SELECT set_config('f7.c1', pg_temp.fails('SELECT public.exos_org_fan_save(pg_temp.u(''000000000001''), ''' || current_setting('f7.fan') || '''::uuid, ''{"email_opt_in_at":"2026-01-01"}'')'), true);
SELECT set_config('f7.c2', pg_temp.fails('SELECT public.exos_org_fan_save(pg_temp.u(''000000000001''), ''' || current_setting('f7.fan') || '''::uuid, ''{"subscribe_to_marketing_email":true}'')'), true);
SELECT set_config('f7.c3', pg_temp.fails('SELECT public.exos_org_fan_save(pg_temp.u(''000000000001''), ''' || current_setting('f7.fan') || '''::uuid, ''{"email":"new@x.com"}'')'), true);
SELECT public.exos_org_fan_save(pg_temp.u('000000000001'), current_setting('f7.fan')::uuid, '{"first_name":" Dana ","last_name":"Lee"}');
SELECT set_config('f7.manual', (public.exos_org_fan_save(pg_temp.u('000000000001'), NULL, '{"email":"Walkin@X.com","first_name":"Walk"}')->>'id'), true);
SELECT set_config('f7.dup', pg_temp.fails('SELECT public.exos_org_fan_save(pg_temp.u(''000000000001''), NULL, ''{"email":"walkin@x.com"}'')'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
SELECT set_config('f7.finsave', pg_temp.fails('SELECT public.exos_org_fan_save(pg_temp.u(''000000000001''), NULL, ''{"email":"z@x.com"}'')'), true);
RESET ROLE;
-- Even the service role (or a script) can't move consent outside a fan action.
SELECT set_config('f7.c4', pg_temp.fails('UPDATE public.exos_fans SET email_opt_in_at = now() WHERE id = ''' || current_setting('f7.fan') || '''::uuid'), true);
SELECT set_config('f7.c5', pg_temp.fails('INSERT INTO public.exos_fans (org_id, email, email_opt_in_at) VALUES (pg_temp.u(''000000000001''), ''sneaky@x.com'', now())'), true);
DO $$
DECLARE f public.exos_fans%ROWTYPE;
BEGIN
  ASSERT current_setting('f7.c1') = '22023' AND current_setting('f7.c2') = '22023', 'F4: consent keys refused';
  ASSERT current_setting('f7.c3') = '22023', 'F4: email can''t change';
  ASSERT current_setting('f7.c4') = '42501' AND current_setting('f7.c5') = '42501', 'F4: trigger guards consent';
  ASSERT current_setting('f7.dup') = '23505', 'F4: duplicate email refused';
  ASSERT current_setting('f7.finsave') = '42501', 'F4: finance can''t add fans';
  SELECT * INTO f FROM public.exos_fans WHERE id = current_setting('f7.fan')::uuid;
  ASSERT f.first_name = 'Dana' AND f.last_name = 'Lee', 'F4: names saved trimmed';
  SELECT * INTO f FROM public.exos_fans WHERE id = current_setting('f7.manual')::uuid;
  ASSERT f.email = 'walkin@x.com' AND f.source = 'manual' AND f.email_opt_in_at IS NULL, 'F4: manual contact, no consent';
  RAISE NOTICE 'OK  F4 consent read-only, contact edits';
END $$;
-- Discard the guest, then the guest buys again: back.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a1');
SELECT public.exos_org_fan_discard(pg_temp.u('000000000001'), current_setting('f7.guest')::uuid);
SELECT set_config('f7.after', (public.exos_org_fans(pg_temp.u('000000000001'))->>'total'), true);
RESET ROLE;
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,guest)
VALUES ('cs_f7g2','fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-0000000000d2','fb000000-0000-0000-0000-000000000001',NULL,'guest.f7@x.com',1,3000,'fulfilled',true);
DO $$
BEGIN
  ASSERT current_setting('f7.after') = '2', 'F4: discarded fan hidden (fan + manual)';
  ASSERT (SELECT discarded_at IS NULL AND orders_count = 2 FROM public.exos_fans WHERE id = current_setting('f7.guest')::uuid), 'F4: revived by a new order';
  RAISE NOTICE 'OK  F4 discard and revive';
END $$;

-- F5 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
SELECT set_config('f7.vip', (public.exos_tag_save(pg_temp.u('000000000001'), NULL, '{"name":"VIP","color":"#aa00ff","canonical_tag_id":"vip"}')->>'id'), true);
SELECT set_config('f7.rock', (public.exos_tag_save(pg_temp.u('000000000001'), NULL, '{"name":"Rock nights","scope":"event"}')->>'id'), true);
SELECT set_config('f7.tdup', pg_temp.fails('SELECT public.exos_tag_save(pg_temp.u(''000000000001''), NULL, ''{"name":"vip"}'')'), true);
SELECT set_config('f7.tcolor', pg_temp.fails('SELECT public.exos_tag_save(pg_temp.u(''000000000001''), NULL, ''{"name":"x","color":"red"}'')'), true);
SELECT public.exos_tag_apply(pg_temp.u('000000000001'), current_setting('f7.vip')::uuid, NULL, 'fan', current_setting('f7.fan')::uuid);
SELECT set_config('f7.again', public.exos_tag_apply(pg_temp.u('000000000001'), current_setting('f7.vip')::uuid, NULL, 'fan', current_setting('f7.fan')::uuid)::text, true);
SELECT public.exos_tag_apply(pg_temp.u('000000000001'), current_setting('f7.vip')::uuid, NULL, 'fan', current_setting('f7.guest')::uuid);
SELECT public.exos_tag_apply(pg_temp.u('000000000001'), NULL, 'Regular', 'fan', current_setting('f7.fan')::uuid);
SELECT public.exos_tag_apply(pg_temp.u('000000000001'), current_setting('f7.rock')::uuid, NULL, 'event', pg_temp.u('0000000000e1'));
SELECT public.exos_tag_apply(pg_temp.u('000000000001'), current_setting('f7.vip')::uuid, NULL, 'event', pg_temp.u('0000000000e2'));
SELECT set_config('f7.scope', pg_temp.fails('SELECT public.exos_tag_apply(pg_temp.u(''000000000001''), ''' || current_setting('f7.rock') || '''::uuid, NULL, ''fan'', ''' || current_setting('f7.fan') || '''::uuid)'), true);
SELECT set_config('f7.xev', pg_temp.fails('SELECT public.exos_tag_apply(pg_temp.u(''000000000001''), ''' || current_setting('f7.vip') || '''::uuid, NULL, ''event'', pg_temp.u(''0000000000e9''))'), true);
SELECT set_config('f7.art', pg_temp.fails('SELECT public.exos_tag_apply(pg_temp.u(''000000000001''), ''' || current_setting('f7.vip') || '''::uuid, NULL, ''artist'', gen_random_uuid())'), true);
SELECT set_config('f7.filter', array_to_string(public.exos_org_tag_filter(pg_temp.u('000000000001'), 'fan',
  ARRAY[current_setting('f7.vip')::uuid, (SELECT id FROM public.exos_tags WHERE name = 'Regular')]), ','), true);
SELECT set_config('f7.vipfans', (public.exos_org_fans(pg_temp.u('000000000001'), NULL, ARRAY[current_setting('f7.vip')::uuid])->>'total'), true);
SELECT set_config('f7.evtags', (SELECT count(*)::text FROM public.exos_org_tagged(pg_temp.u('000000000001'), 'event', ARRAY[pg_temp.u('0000000000e1'), pg_temp.u('0000000000e2')])), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a5');
SELECT set_config('f7.cread', (jsonb_array_length(public.exos_org_tags(pg_temp.u('000000000001'))))::text, true);
SELECT set_config('f7.cwrite', pg_temp.fails('SELECT public.exos_tag_save(pg_temp.u(''000000000001''), NULL, ''{"name":"nope"}'')'), true);
SELECT set_config('f7.csel', (SELECT count(*)::text FROM public.exos_tags), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a9');
SELECT set_config('f7.xsel', (SELECT count(*)::text FROM public.exos_tags), true);
SELECT set_config('f7.xapply', pg_temp.fails('SELECT public.exos_tag_apply(pg_temp.u(''000000000001''), ''' || current_setting('f7.vip') || '''::uuid, NULL, ''fan'', ''' || current_setting('f7.fan') || '''::uuid)'), true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('f7.tdup') = '23505', 'F5: duplicate name (any case)';
  ASSERT current_setting('f7.tcolor') = '22023', 'F5: color format';
  ASSERT (current_setting('f7.again')::jsonb->>'created')::boolean = false, 'F5: tagging twice is one item';
  ASSERT EXISTS (SELECT 1 FROM public.exos_tags WHERE name = 'Regular' AND scope = 'fan'), 'F5: tag by name made a fan tag';
  ASSERT current_setting('f7.scope') = '22023', 'F5: an event tag can''t go on a fan';
  ASSERT current_setting('f7.xev') = 'P0002', 'F5: another org''s event refused';
  ASSERT current_setting('f7.art') = 'P0002', 'F5: artists refused without exos_artists';
  ASSERT current_setting('f7.filter') = current_setting('f7.fan'), 'F5: ALL-tags filter: ' || current_setting('f7.filter');
  ASSERT current_setting('f7.vipfans') = '2', 'F5: fan list filtered by tag';
  ASSERT current_setting('f7.evtags') = '2', 'F5: tags on events';
  ASSERT current_setting('f7.cread') = '3' AND current_setting('f7.csel') = '3', 'F5: content reads tags';
  ASSERT current_setting('f7.cwrite') = '42501', 'F5: content can''t write';
  ASSERT current_setting('f7.xsel') = '0', 'F5: RLS: the other org sees none';
  ASSERT current_setting('f7.xapply') = '42501', 'F5: the other org can''t tag here';
  RAISE NOTICE 'OK  F5 tags';
END $$;
-- Remove one item, delete a tag (items go with it).
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a1');
SELECT public.exos_tag_remove(pg_temp.u('000000000001'), (SELECT id FROM public.exos_tagged_items WHERE taggable_id = pg_temp.u('0000000000e2')));
SELECT public.exos_tag_delete(pg_temp.u('000000000001'), current_setting('f7.rock')::uuid);
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tagged_items WHERE taggable_type = 'event'), 'F5: removed and cascaded';
  RAISE NOTICE 'OK  F5 remove and delete';
END $$;

-- F6 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
SELECT set_config('f7.form', public.exos_signup_form_save(pg_temp.u('000000000001'), NULL,
  jsonb_build_object('name', 'Footer', 'title', 'Join the list', 'offer_sms', true,
                     'default_tag_ids', jsonb_build_array(current_setting('f7.vip'))))::text, true);
SELECT set_config('f7.form2', public.exos_signup_form_save(pg_temp.u('000000000001'), NULL,
  '{"name":"Paused","title":"Later","status":"paused"}')::text, true);
SELECT set_config('f7.badtag', pg_temp.fails('SELECT public.exos_signup_form_save(pg_temp.u(''000000000001''), NULL, ''{"name":"x","title":"y","default_tag_ids":["' || gen_random_uuid() || '"]}'')'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
SELECT set_config('f7.finform', pg_temp.fails('SELECT public.exos_signup_forms_list(pg_temp.u(''000000000001''))'), true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
SELECT set_config('f7.pub', coalesce(public.exos_signup_form_public(current_setting('f7.form')::uuid)::text, 'null'), true);
SELECT set_config('f7.pub2', coalesce(public.exos_signup_form_public(current_setting('f7.form2')::uuid)::text, 'null'), true);
SELECT set_config('f7.anonsubmit', pg_temp.fails('SELECT public._exos_signup_submit(''' || current_setting('f7.form') || '''::uuid, ''a@x.com'')'), true);
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT set_config('f7.s1', public._exos_signup_submit(current_setting('f7.form')::uuid, ' New.Fan@X.com ', 'New', 'Fan', true, true, '(212) 555-0100', repeat('a', 64))::text, true);
SELECT set_config('f7.s2', public._exos_signup_submit(current_setting('f7.form')::uuid, 'f7fan@x.com', 'Ignored', NULL, true, false, NULL, repeat('a', 64))::text, true);
SELECT set_config('f7.bademail', pg_temp.fails('SELECT public._exos_signup_submit(''' || current_setting('f7.form') || '''::uuid, ''nope'')'), true);
SELECT set_config('f7.nophone', pg_temp.fails('SELECT public._exos_signup_submit(''' || current_setting('f7.form') || '''::uuid, ''p@x.com'', NULL, NULL, true, true, ''123'')'), true);
SELECT set_config('f7.paused', pg_temp.fails('SELECT public._exos_signup_submit(''' || current_setting('f7.form2') || '''::uuid, ''p@x.com'')'), true);
SELECT public._exos_signup_submit(current_setting('f7.form')::uuid, 'spam@x.com') FROM generate_series(1, 5);
RESET ROLE;
DO $$
DECLARE p jsonb := current_setting('f7.pub')::jsonb; f public.exos_fans%ROWTYPE;
BEGIN
  ASSERT current_setting('f7.badtag') = '22023', 'F6: form tags must be the org''s fan tags';
  ASSERT current_setting('f7.finform') = '42501', 'F6: finance can''t manage forms';
  ASSERT p->>'title' = 'Join the list' AND p->>'org_name' = 'F7 Org', 'F6: public config ' || p::text;
  ASSERT p->>'sms_consent_text' = public.exos_sms_consent_text('F7 Org') AND p->>'sms_consent_text' LIKE '%Reply STOP%', 'F6: SMS wording';
  ASSERT NOT (p ? 'org_id') AND NOT (p ? 'default_tag_ids') AND p::text NOT LIKE '%@%', 'F6: no internals, no fan data';
  ASSERT current_setting('f7.pub2') = 'null', 'F6: a paused form isn''t public';
  ASSERT current_setting('f7.anonsubmit') = '42501', 'F6: anon can''t call the submit directly';
  ASSERT current_setting('f7.s1') = current_setting('f7.s2'), 'F6: same answer for a new and a known address';
  ASSERT current_setting('f7.s1')::jsonb = '{"ok": true, "status": "check_email"}'::jsonb, 'F6: answer ' || current_setting('f7.s1');
  ASSERT current_setting('f7.bademail') = '22023' AND current_setting('f7.nophone') = '22023', 'F6: input checked';
  ASSERT current_setting('f7.paused') = 'P0002', 'F6: paused form takes nothing';
  ASSERT (SELECT count(*) FROM public.exos_signup_submissions s JOIN public.exos_fans ff ON ff.id = s.fan_id WHERE ff.email = 'spam@x.com') = 3,
         'F6: 3 submissions a day per address';
  SELECT * INTO f FROM public.exos_fans WHERE org_id = pg_temp.u('000000000001') AND email = 'new.fan@x.com';
  ASSERT f.source = 'signup' AND f.first_name = 'New' AND f.email_opt_in_at IS NULL, 'F6: profile made, not subscribed yet';
  ASSERT (SELECT first_name FROM public.exos_fans WHERE id = current_setting('f7.fan')::uuid) = 'Dana', 'F6: a name is never overwritten';
  ASSERT EXISTS (SELECT 1 FROM public.exos_tagged_items WHERE taggable_id = f.id AND tag_id = current_setting('f7.vip')::uuid), 'F6: form tag applied';
  ASSERT (SELECT sms_phone FROM public.exos_signup_submissions WHERE fan_id = f.id) = '+12125550100', 'F6: number normalized';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_subscribers WHERE phone = '+12125550100'), 'F6: not texted before a signed-in confirm';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'signup-confirm' AND to_email = 'new.fan@x.com') = 1, 'F6: confirm mail queued';
  ASSERT (SELECT payload->>'token' FROM public.exos_mail WHERE template = 'signup-confirm' AND to_email = 'new.fan@x.com') ~ '^[0-9a-f]{64}$', 'F6: token in the mail';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_signup_submissions s, public.exos_mail m
                      WHERE m.template = 'signup-confirm' AND s.confirm_token_hash = m.payload->>'token'), 'F6: only the hash is stored';
  RAISE NOTICE 'OK  F6 forms and submissions';
END $$;
SELECT set_config('f7.tok', (SELECT payload->>'token' FROM public.exos_mail WHERE template = 'signup-confirm' AND to_email = 'new.fan@x.com'), true);
SET LOCAL ROLE anon;
SELECT pg_temp.act(NULL);
SELECT set_config('f7.conf', public.exos_signup_confirm(current_setting('f7.tok'))::text, true);
SELECT set_config('f7.conf2', public.exos_signup_confirm(current_setting('f7.tok'))::text, true);
SELECT set_config('f7.confbad', public.exos_signup_confirm(repeat('0', 64))::text, true);
SELECT set_config('f7.smsanon', pg_temp.fails('SELECT public.exos_signup_confirm_sms(''' || current_setting('f7.tok') || ''')'), true);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b2');
SELECT set_config('f7.sms', public.exos_signup_confirm_sms(current_setting('f7.tok'))::text, true);
SELECT set_config('f7.smsbad', pg_temp.fails('SELECT public.exos_signup_confirm_sms(repeat(''1'', 64))'), true);
RESET ROLE;
DO $$
DECLARE c jsonb := current_setting('f7.conf')::jsonb; f public.exos_fans%ROWTYPE; ss public.exos_sms_subscribers%ROWTYPE;
BEGIN
  ASSERT (c->>'ok')::boolean AND c->>'org_name' = 'F7 Org' AND (c->>'sms_pending')::boolean, 'F6: confirm ' || c::text;
  ASSERT c::text NOT LIKE '%@%' AND NOT (c ? 'fan_id'), 'F6: confirm returns no fan data';
  ASSERT (current_setting('f7.conf2')::jsonb->>'already')::boolean, 'F6: confirming twice is fine';
  ASSERT current_setting('f7.confbad')::jsonb = '{"ok": false}'::jsonb, 'F6: bad token';
  ASSERT current_setting('f7.smsanon') = '42501', 'F6: texts need sign-in';
  ASSERT current_setting('f7.smsbad') = 'P0002', 'F6: bad token for texts';
  SELECT * INTO f FROM public.exos_fans WHERE email = 'new.fan@x.com';
  ASSERT f.email_opt_in_at IS NOT NULL AND f.email_opt_in_source = 'signup_form:' || current_setting('f7.form'), 'F6: on the list';
  SELECT * INTO ss FROM public.exos_sms_subscribers WHERE phone = '+12125550100';
  ASSERT ss.org_id = pg_temp.u('000000000001') AND ss.user_id = pg_temp.u('0000000000b2') AND ss.source = 'signup_form', 'F6: texts confirmed';
  ASSERT ss.consent_text = public.exos_sms_consent_text('F7 Org'), 'F6: exact wording stored';
  ASSERT current_setting('f7.sms')::jsonb->>'phone_hint' = '…0100', 'F6: masked number';
  RAISE NOTICE 'OK  F6 double opt-in and texts';
END $$;
-- The org can see it but not change it; the fan unsubscribes by token.
SELECT set_config('f7.newid', (SELECT id::text FROM public.exos_fans WHERE email = 'new.fan@x.com'), true),
       set_config('f7.newtok', (SELECT unsubscribe_token FROM public.exos_fans WHERE email = 'new.fan@x.com'), true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a1');
SELECT set_config('f7.newdetail', public.exos_org_fan(pg_temp.u('000000000001'), current_setting('f7.newid')::uuid)::text, true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('f7.unsub', public.exos_signup_unsubscribe(current_setting('f7.newtok'))::text, true);
RESET ROLE;
DO $$
DECLARE d jsonb := current_setting('f7.newdetail')::jsonb;
BEGIN
  ASSERT d->'consent'->'email_list'->>'status' = 'subscribed', 'F6: staff see subscribed';
  ASSERT d->'consent'->'sms'->>'status' = 'subscribed' AND d->'consent'->'sms'->>'phone_hint' = '…0100', 'F6: staff see texts, masked';
  ASSERT (current_setting('f7.unsub')::jsonb->>'ok')::boolean, 'F6: unsubscribed';
  ASSERT (SELECT email_opt_out_at IS NOT NULL FROM public.exos_fans WHERE email = 'new.fan@x.com'), 'F6: opt-out stored';
  RAISE NOTICE 'OK  F6 staff view and unsubscribe';
END $$;

-- F7 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a2');
SELECT set_config('f7.exp', public.exos_org_fans_export(pg_temp.u('000000000001'), NULL, ARRAY[current_setting('f7.vip')::uuid])::text, true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
SELECT set_config('f7.expfin', pg_temp.fails('SELECT public.exos_org_fans_export(pg_temp.u(''000000000001''))'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a9');
SELECT set_config('f7.expx', pg_temp.fails('SELECT public.exos_org_fans_export(pg_temp.u(''000000000001''))'), true);
SELECT set_config('f7.explog', (SELECT count(*)::text FROM public.exos_fan_exports), true);
RESET ROLE;
DO $$
DECLARE e jsonb := current_setting('f7.exp')::jsonb;
BEGIN
  ASSERT (e->>'count')::int = 4, 'F7: four VIP fans (two buyers, two from the form) ' || e::text;
  ASSERT e::text NOT LIKE '%' || current_setting('f7.newtok') || '%' AND e::text NOT LIKE '%unsubscribe_token%' AND e::text NOT LIKE '%sek-f7%' AND e::text NOT LIKE '%+1212%', 'F7: no tokens, secrets or numbers';
  ASSERT current_setting('f7.expfin') = '42501' AND current_setting('f7.expx') = '42501', 'F7: owner / manager only';
  ASSERT (SELECT row_count FROM public.exos_fan_exports WHERE org_id = pg_temp.u('000000000001')) = 4, 'F7: logged';
  ASSERT (SELECT exported_by FROM public.exos_fan_exports WHERE org_id = pg_temp.u('000000000001')) = pg_temp.u('0000000000a2'), 'F7: who';
  ASSERT current_setting('f7.explog') = '0', 'F7: the log is the org''s own';
  RAISE NOTICE 'OK  F7 export';
END $$;

-- F8 ------------------------------------------------------------------------
INSERT INTO public.exos_refund_asks(ticket_id,event_id,org_id,session_id,asked_by,reason,amount_cents,currency,status) VALUES
  ('fb000000-0000-0000-0000-000000000c11','fb000000-0000-0000-0000-0000000000e1','fb000000-0000-0000-0000-000000000001','cs_f7a','fb000000-0000-0000-0000-0000000000b1','Sick',3000,'usd','open'),
  ('fb000000-0000-0000-0000-000000000c21','fb000000-0000-0000-0000-0000000000e2','fb000000-0000-0000-0000-000000000001','cs_f7b','fb000000-0000-0000-0000-0000000000b1',NULL,3000,'usd','declined');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a3');
SELECT set_config('f7.q', public.exos_org_refund_asks(pg_temp.u('000000000001'))::text, true);
SELECT set_config('f7.qall', public.exos_org_refund_asks(pg_temp.u('000000000001'), NULL)::text, true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a4');
SELECT set_config('f7.qscan', pg_temp.fails('SELECT public.exos_org_refund_asks(pg_temp.u(''000000000001''))'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000a9');
SELECT set_config('f7.qx', pg_temp.fails('SELECT public.exos_org_refund_asks(pg_temp.u(''000000000001''))'), true);
SELECT set_config('f7.qapi', pg_temp.fails('SELECT public.exos_api_refund_asks(pg_temp.u(''000000000001''))'), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b1');
SELECT set_config('f7.mine', (SELECT count(*)::text FROM public.exos_my_refund_asks_all()), true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b9');
SELECT set_config('f7.notmine', (SELECT count(*)::text FROM public.exos_my_refund_asks_all()), true);
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT set_config('f7.api', public.exos_api_refund_asks(pg_temp.u('000000000001'), 'open', pg_temp.u('0000000000e1'))::text, true);
SELECT set_config('f7.apix', public.exos_api_refund_asks(pg_temp.u('000000000002'))::text, true);
RESET ROLE;
DO $$
DECLARE q jsonb := current_setting('f7.q')::jsonb;
BEGIN
  ASSERT (q->>'total')::int = 1 AND q->'rows'->0->>'event_name' = 'F7 One' AND q->'rows'->0->>'buyer_email' = 'F7FAN@x.com', 'F8: open queue ' || q::text;
  ASSERT (current_setting('f7.qall')::jsonb->>'total')::int = 2, 'F8: every status across events';
  ASSERT current_setting('f7.qscan') = '42501' AND current_setting('f7.qx') = '42501', 'F8: scanner / other org refused';
  ASSERT current_setting('f7.qapi') = '42501', 'F8: the API read is service-role only';
  ASSERT current_setting('f7.mine') = '2' AND current_setting('f7.notmine') = '0', 'F8: the fan''s own asks';
  ASSERT (current_setting('f7.api')::jsonb->>'total')::int = 1, 'F8: API filters';
  ASSERT (current_setting('f7.apix')::jsonb->>'total')::int = 0, 'F8: API is per org';
  RAISE NOTICE 'OK  F8 refund queue';
END $$;

-- F9 ------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b1');
SELECT set_config('f7.b', public.exos_my_ticket_bundles()::text, true);
SELECT set_config('f7.b1', public.exos_my_ticket_bundles(pg_temp.u('0000000000e1'))::text, true);
SELECT pg_temp.act('fb000000-0000-0000-0000-0000000000b9');
SELECT set_config('f7.bx', public.exos_my_ticket_bundles()::text, true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('f7.banon', pg_temp.fails('SELECT public.exos_my_ticket_bundles()'), true);
RESET ROLE;
DO $$
DECLARE b jsonb := current_setting('f7.b')::jsonb;
BEGIN
  ASSERT jsonb_array_length(b) = 2 AND (b->0->>'count')::int = 2 AND b->0->'event'->>'name' = 'F7 One', 'F9: grouped ' || b::text;
  ASSERT b::text NOT LIKE '%sek-f7%' AND b::text NOT LIKE '%barcode%', 'F9: no barcode secret';
  ASSERT jsonb_array_length(current_setting('f7.b1')::jsonb) = 1, 'F9: one event';
  ASSERT current_setting('f7.bx')::jsonb = '[]'::jsonb, 'F9: a stranger has none';
  ASSERT current_setting('f7.banon') = '42501', 'F9: anon refused';
  RAISE NOTICE 'OK  F9 ticket bundles';
END $$;

ROLLBACK;
