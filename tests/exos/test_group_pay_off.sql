-- ============================================================================
-- Group pay v2 paused (operator 2026-11-09, mig 20261111120000). Self-
-- contained (c7d prefix), rolled back. Runs after test_group_pay.sql and
-- test_security_hygiene.sql, which turn the switch on for themselves and off
-- again.
--   O1 off by default: the setting row is JSON false; a missing row or any
--      value but JSON true reads as off
--   O2 grants: the helper is service role only; the setter is for signed-in
--      callers (it checks the admin itself) and the service role, never anon;
--      both definer with search_path pinned
--   O3 the setter: a platform admin or the service role only (42501
--      otherwise); a reason is required; each change is one audit row
--      (platform.group_pay, nil org, [old, new], the reason, the actor);
--      setting the same value again changes and logs nothing
--   O4 while off every entry point refuses: start, claim and exos-checkout's
--      context raise XGOFF "Group pay isn't available" (no hold, no claim);
--      the seat page answers NULL (anon and signed in)
--   O5 while off a group that exists stays readable and cancellable: get /
--      mine for its host, the tables for platform admins; cancel releases
--   O6 the same seat link answers again once the switch is on (the NULL is
--      the switch, not the link)
-- exos-checkout's 403 group_pay_off (EXOS_GROUP_PAY unset, before the rate
-- gate, the claim and Stripe): supabase/functions/_shared/groupGate_test.ts.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c7d00000-0000-0000-0000-0000000000a0','c7d-owner@x.com',now()),
  ('c7d00000-0000-0000-0000-0000000000b0','c7d-host@x.com',now()),
  ('c7d00000-0000-0000-0000-0000000000b1','c7d-f1@x.com',now()),
  ('c7d00000-0000-0000-0000-0000000000ad','c7d-admin@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c7d00000-0000-0000-0000-000000000001','C7D Org','c7d-org','c7d00000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('c7d00000-0000-0000-0000-000000000001','c7d00000-0000-0000-0000-0000000000a0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('c7d00000-0000-0000-0000-0000000000e1','c7d00000-0000-0000-0000-000000000001','C7D Show','c7d-show','published',now() + interval '10 days','Hall',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('c7d00000-0000-0000-0000-0000000000d1','c7d00000-0000-0000-0000-0000000000e1','GA',25,20,0);

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
  SELECT count(*) FROM public.exos_org_audit WHERE action = 'platform.group_pay';
$$;
GRANT EXECUTE ON FUNCTION pg_temp.err(text) TO PUBLIC;

-- O1 ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT (SELECT value FROM public.exos_platform_settings WHERE key = 'group_pay_enabled') = 'false'::jsonb,
    'O1 the setting is JSON false: ' || coalesce((SELECT value::text FROM public.exos_platform_settings WHERE key = 'group_pay_enabled'), 'no row');
  ASSERT NOT public._exos_group_pay_on(), 'O1 off';
  -- No row: off.
  DELETE FROM public.exos_platform_settings WHERE key = 'group_pay_enabled';
  ASSERT NOT public._exos_group_pay_on(), 'O1 no row is off';
  -- Anything but JSON true: off.
  INSERT INTO public.exos_platform_settings (key, value) VALUES ('group_pay_enabled', '"true"');
  ASSERT NOT public._exos_group_pay_on(), 'O1 the string "true" is off';
  UPDATE public.exos_platform_settings SET value = '1' WHERE key = 'group_pay_enabled';
  ASSERT NOT public._exos_group_pay_on(), 'O1 1 is off';
  UPDATE public.exos_platform_settings SET value = 'true' WHERE key = 'group_pay_enabled';
  ASSERT public._exos_group_pay_on(), 'O1 JSON true is on';
  UPDATE public.exos_platform_settings SET value = 'false' WHERE key = 'group_pay_enabled';
  ASSERT NOT public._exos_group_pay_on(), 'O1 back off';
  RAISE NOTICE 'OK  O1 off by default: JSON false; no row, a string or a number read as off';
END $$;

-- O2 ---------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public._exos_group_pay_on()', 'EXECUTE'), 'O2 anon helper';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_group_pay_on()', 'EXECUTE'), 'O2 authenticated helper';
  ASSERT has_function_privilege('service_role', 'public._exos_group_pay_on()', 'EXECUTE'), 'O2 service helper';
  ASSERT NOT has_function_privilege('anon', 'public.exos_set_group_pay_enabled(boolean,text)', 'EXECUTE'), 'O2 anon setter';
  ASSERT has_function_privilege('authenticated', 'public.exos_set_group_pay_enabled(boolean,text)', 'EXECUTE'), 'O2 authenticated setter';
  ASSERT has_function_privilege('service_role', 'public.exos_set_group_pay_enabled(boolean,text)', 'EXECUTE'), 'O2 service setter';
  FOREACH f IN ARRAY ARRAY['public._exos_group_pay_on()', 'public.exos_set_group_pay_enabled(boolean,text)'] LOOP
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure),
      'O2 definer, search_path pinned: ' || f;
  END LOOP;
  -- Every entry point carries the marker once.
  FOREACH f IN ARRAY ARRAY['public.exos_group_buy_start(uuid,uuid,integer,text)', 'public.exos_group_claim(text,uuid,uuid,text,uuid,uuid,integer)',
                           'public.exos_group_checkout_ctx(text,uuid,uuid)', 'public.exos_group_seat_view(text)'] LOOP
    ASSERT (length(pg_get_functiondef(f::regprocedure)) - length(replace(pg_get_functiondef(f::regprocedure), '/* exos: group pay off */', '')))
           / length('/* exos: group pay off */') = 1, 'O2 one marker in ' || f;
  END LOOP;
  RAISE NOTICE 'OK  O2 grants: helper service role only, setter authenticated (checked inside) + service role, never anon; markers once';
END $$;

-- O3 ---------------------------------------------------------------------------
-- A signed-in non-admin (the org's own owner): refused.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('c7d00000-0000-0000-0000-0000000000a0', 'c7d-owner@x.com');
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_group_pay_enabled(true, 'I own an org')$q$)
         LIKE '42501%platform admins only%', 'O3 an org owner can''t turn it on';
END $$;
-- A platform admin: allowed, with a reason, logged.
SELECT pg_temp.as_user('c7d00000-0000-0000-0000-0000000000ad', 'c7d-admin@x.com', true);
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_group_pay_enabled(true, NULL)$q$) LIKE '22023%reason%', 'O3 no reason';
  ASSERT pg_temp.err($q$SELECT public.exos_set_group_pay_enabled(true, '  ok  ')$q$) LIKE '22023%reason%', 'O3 too short';
  ASSERT pg_temp.err($q$SELECT public.exos_set_group_pay_enabled(NULL, 'on or off')$q$) LIKE '22023%', 'O3 null';
  r := public.exos_set_group_pay_enabled(true, 'O3 admin turns it on');
  ASSERT r = '{"group_pay_enabled": true, "changed": true}'::jsonb, 'O3 on ' || r;
END $$;
RESET ROLE;
DO $$
DECLARE a public.exos_org_audit;
BEGIN
  ASSERT public._exos_group_pay_on(), 'O3 on';
  ASSERT pg_temp.audits() >= 1, 'O3 logged';
  SELECT * INTO a FROM public.exos_org_audit WHERE action = 'platform.group_pay' ORDER BY id DESC LIMIT 1;
  ASSERT a.org_id = '00000000-0000-0000-0000-000000000000' AND a.entity_type = 'platform_setting'
         AND a.entity_id = 'group_pay_enabled' AND a.changes = '{"group_pay_enabled": [false, true]}'::jsonb
         AND a.reason = 'O3 admin turns it on' AND a.actor_uid = 'c7d00000-0000-0000-0000-0000000000ad'
         AND a.actor_kind = 'user' AND a.actor_role = 'platform_admin' AND a.source = 'dashboard',
    'O3 the audit row ' || row_to_json(a)::text;
  PERFORM public.exos_set_group_pay_enabled(false, 'O3 off again (direct session)');
END $$;
-- The same value again: nothing changes, nothing logged. The service role may set it.
SET LOCAL ROLE service_role;
SELECT pg_temp.as_user(NULL, NULL);
DO $$
DECLARE v_n bigint := pg_temp.audits(); r jsonb;
BEGIN
  r := public.exos_set_group_pay_enabled(false, 'already off');
  ASSERT r = '{"group_pay_enabled": false, "changed": false}'::jsonb AND pg_temp.audits() = v_n, 'O3 no-op ' || r;
  r := public.exos_set_group_pay_enabled(true, 'service role on');
  ASSERT r ->> 'changed' = 'true' AND pg_temp.audits() = v_n + 1, 'O3 the service role';
  r := public.exos_set_group_pay_enabled(false, 'service role off');
  ASSERT r ->> 'changed' = 'true' AND pg_temp.audits() = v_n + 2, 'O3 off, logged';
  ASSERT (SELECT actor_kind FROM public.exos_org_audit WHERE action = 'platform.group_pay' ORDER BY id DESC LIMIT 1) = 'service'
         AND (SELECT changes FROM public.exos_org_audit WHERE action = 'platform.group_pay' ORDER BY id DESC LIMIT 1)
             = '{"group_pay_enabled": [true, false]}'::jsonb, 'O3 the service row';
END $$;
RESET ROLE;
-- anon: no EXECUTE at all.
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_set_group_pay_enabled(true, 'anon tries')$q$) LIKE '42501%', 'O3 anon';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT NOT public._exos_group_pay_on(), 'O3 off at the end';
  RAISE NOTICE 'OK  O3 the setter: platform admin or service role, a reason, one audit row per change, a no-op logs nothing';
END $$;

-- A group made while it was on (seats by hand, as test_security_hygiene S7 does;
-- the holds don't matter here).
INSERT INTO public.exos_group_buys(id, org_id, event_id, tier_id, host_uid, quantity, deadline)
VALUES ('c7d00000-0000-0000-0000-0000000000f1', 'c7d00000-0000-0000-0000-000000000001', 'c7d00000-0000-0000-0000-0000000000e1',
        'c7d00000-0000-0000-0000-0000000000d1', 'c7d00000-0000-0000-0000-0000000000b0', 2, now() + interval '20 minutes');
INSERT INTO public.exos_group_buy_seats(group_id, org_id, seat_no, token, status) VALUES
  ('c7d00000-0000-0000-0000-0000000000f1', 'c7d00000-0000-0000-0000-000000000001', 1, 'c7d0000000000000000000000000aa01', 'waiting'),
  ('c7d00000-0000-0000-0000-0000000000f1', 'c7d00000-0000-0000-0000-000000000001', 2, 'c7d0000000000000000000000000aa02', 'waiting');

-- O4 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('c7d00000-0000-0000-0000-0000000000b1', 'c7d-f1@x.com');
DO $$
DECLARE v_holds bigint := (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = 'c7d00000-0000-0000-0000-0000000000e1');
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_group_buy_start('c7d00000-0000-0000-0000-0000000000e1','c7d00000-0000-0000-0000-0000000000d1',2)$q$)
         = 'XGOFF Group pay isn''t available', 'O4 start: ' || coalesce(pg_temp.err($q$SELECT public.exos_group_buy_start('c7d00000-0000-0000-0000-0000000000e1','c7d00000-0000-0000-0000-0000000000d1',2)$q$), 'started');
  ASSERT (SELECT count(*) FROM public.exos_cart_holds WHERE event_id = 'c7d00000-0000-0000-0000-0000000000e1') = v_holds, 'O4 no hold taken';
  ASSERT public.exos_group_seat_view('c7d0000000000000000000000000aa01') IS NULL, 'O4 seat page, signed in';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT public.exos_group_seat_view('c7d0000000000000000000000000aa01') IS NULL, 'O4 seat page, anon';
END $$;
RESET ROLE;
-- exos-checkout's calls (service role).
SET LOCAL ROLE service_role;
SELECT pg_temp.as_user(NULL, NULL);
DO $$
BEGIN
  ASSERT pg_temp.err($q$SELECT public.exos_group_checkout_ctx('c7d0000000000000000000000000aa01', NULL, 'c7d00000-0000-0000-0000-0000000000b1')$q$)
         = 'XGOFF Group pay isn''t available', 'O4 the seat context';
  ASSERT pg_temp.err($q$SELECT public.exos_group_checkout_ctx(NULL, 'c7d00000-0000-0000-0000-0000000000f1', 'c7d00000-0000-0000-0000-0000000000b0')$q$)
         = 'XGOFF Group pay isn''t available', 'O4 the cover context';
  ASSERT pg_temp.err($q$SELECT public.exos_group_claim('c7d0000000000000000000000000aa01', NULL, 'c7d00000-0000-0000-0000-0000000000b1',
                       'c7d-f1@x.com', 'c7d00000-0000-0000-0000-0000000000e1', 'c7d00000-0000-0000-0000-0000000000d1', 1)$q$)
         = 'XGOFF Group pay isn''t available', 'O4 the claim';
  ASSERT pg_temp.err($q$SELECT public.exos_group_claim(NULL, 'c7d00000-0000-0000-0000-0000000000f1', 'c7d00000-0000-0000-0000-0000000000b0',
                       'c7d-host@x.com', 'c7d00000-0000-0000-0000-0000000000e1', 'c7d00000-0000-0000-0000-0000000000d1', 2)$q$)
         = 'XGOFF Group pay isn''t available', 'O4 the cover claim';
  ASSERT (SELECT count(*) FROM public.exos_group_buy_seats WHERE group_id = 'c7d00000-0000-0000-0000-0000000000f1'
            AND (claim_uid IS NOT NULL OR claim_email IS NOT NULL OR cover)) = 0, 'O4 nothing claimed';
  RAISE NOTICE 'OK  O4 off: start, claim and both checkout contexts raise XGOFF; the seat page is NULL; nothing held or claimed';
END $$;
RESET ROLE;

-- O5 ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('c7d00000-0000-0000-0000-0000000000b0', 'c7d-host@x.com');
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_group_buy_get('c7d00000-0000-0000-0000-0000000000f1');
  ASSERT (r ->> 'id')::uuid = 'c7d00000-0000-0000-0000-0000000000f1' AND jsonb_array_length(r -> 'seats') = 2, 'O5 the host reads the group ' || r;
  r := public.exos_group_buy_mine('c7d00000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(r) = 1, 'O5 mine ' || r;
  r := public.exos_group_buy_cancel('c7d00000-0000-0000-0000-0000000000f1');
  ASSERT r ->> 'status' = 'cancelled', 'O5 the host can still end it ' || r;
END $$;
SELECT pg_temp.as_user('c7d00000-0000-0000-0000-0000000000ad', 'c7d-admin@x.com', true);
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_group_buys WHERE id = 'c7d00000-0000-0000-0000-0000000000f1') = 1, 'O5 an admin reads the group';
  ASSERT (SELECT count(*) FROM public.exos_group_buy_seats WHERE group_id = 'c7d00000-0000-0000-0000-0000000000f1') = 2, 'O5 an admin reads the seats';
  RAISE NOTICE 'OK  O5 off: a group that exists stays readable (host get / mine, admin tables) and the host can end it';
END $$;
RESET ROLE;

-- O6 ---------------------------------------------------------------------------
SELECT public.exos_set_group_pay_enabled(true, 'test_group_pay_off.sql: O6');
SET LOCAL ROLE anon;
SELECT pg_temp.as_user(NULL, NULL);
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_group_seat_view('c7d0000000000000000000000000aa02');
  ASSERT r IS NOT NULL AND (r ->> 'seat_no')::int = 2, 'O6 the link answers with the switch on ' || coalesce(r::text, 'NULL');
END $$;
RESET ROLE;
SELECT public.exos_set_group_pay_enabled(false, 'test_group_pay_off.sql: done');
DO $$ BEGIN
  ASSERT NOT public._exos_group_pay_on(), 'O6 off at the end';
  RAISE NOTICE 'OK  O6 the same link answers once the switch is on: the NULL is the switch';
END $$;

ROLLBACK;
