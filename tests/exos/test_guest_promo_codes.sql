-- ============================================================================
-- Guest promo codes (mig 20261121143700). Self-contained (6a prefix), rolled
-- back at the end.
--   G1 anon still can't call exos_check_voucher; only service_role may call
--      exos_check_voucher_guest; a signed-in caller and a bad hash are refused
--   G2 a guest's normal promo code checks out (percent off), case-insensitive
--   G3 a bypass code, a hidden-type code and a code made for one person
--      (reserved_email) say 'sign in required'; real codes never count as misses
--   G4 guest misses: 10 per network, then 'too many attempts'; another network
--      still checks; the service role's own bucket and an account are untouched
--   G5 30 misses per event for all guests pauses the guest path of that event
--      only; signed-in buyers and the server's own checks keep working
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('6a000000-0000-0000-0000-0000000000a0','6a-owner@x.com',now()),
  ('6a000000-0000-0000-0000-0000000000b1','6a-fan@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('6a000000-0000-0000-0000-000000000001','6A Org','6a-org','6a000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('6a000000-0000-0000-0000-000000000001','6a000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('6a000000-0000-0000-0000-0000000000e1','6a000000-0000-0000-0000-000000000001','6A Show','6a-show','published',now() + interval '10 days','Hall',0,0),
  ('6a000000-0000-0000-0000-0000000000e2','6a000000-0000-0000-0000-000000000001','6A Other','6a-other','published',now() + interval '10 days','Hall',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('6a000000-0000-0000-0000-0000000000d1','6a000000-0000-0000-0000-0000000000e1','GA',40,500,0,'public'),
  ('6a000000-0000-0000-0000-0000000000d2','6a000000-0000-0000-0000-0000000000e1','Presale',30,50,0,'hidden'),
  ('6a000000-0000-0000-0000-0000000000d3','6a000000-0000-0000-0000-0000000000e2','GA',40,500,0,'public');
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,bypass_capacity,discount_percent,reserved_email) VALUES
  ('6a000000-0000-0000-0000-0000000000e1','SUMMER20',NULL,100,false,20,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','COMPUPGRADE',NULL,1,true,NULL,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','PRESALE01','6a000000-0000-0000-0000-0000000000d2',50,false,NULL,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','JUSTFORFAN',NULL,1,false,NULL,'6a-fan@x.com'),
  ('6a000000-0000-0000-0000-0000000000e2','OTHER10',NULL,100,false,10,NULL);

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid text, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', json_build_object('email', p_email)::text, true),
         set_config('request.jwt.claims', '', true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.as_service() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', '', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
CREATE OR REPLACE FUNCTION pg_temp.net(n int) RETURNS text LANGUAGE sql AS $$
  SELECT encode(sha256(('6a-net-' || n)::bytea), 'hex');
$$;

-- G1 -------------------------------------------------------------------------
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.exos_check_voucher(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'G1 FAIL: anon can call exos_check_voucher';
  END IF;
  IF has_function_privilege('anon', 'public.exos_check_voucher_guest(uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_check_voucher_guest(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'G1 FAIL: a client can call exos_check_voucher_guest';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.exos_check_voucher_guest(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'G1 FAIL: service_role cannot call exos_check_voucher_guest';
  END IF;
END $$;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM pg_temp.as_service();
  BEGIN
    PERFORM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', 'not-a-hash');
  EXCEPTION WHEN invalid_parameter_value THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'G1 FAIL: a bad network hash was accepted'; END IF;
  refused := false;
  PERFORM set_config('app.uid', '6a000000-0000-0000-0000-0000000000b1', true);
  BEGIN
    PERFORM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', pg_temp.net(1));
  EXCEPTION WHEN insufficient_privilege THEN refused := true;
  END;
  IF NOT refused THEN RAISE EXCEPTION 'G1 FAIL: a signed-in caller used the guest path'; END IF;
  RAISE NOTICE 'G1 ok: guest check is service-role only, needs a network hash, refuses accounts';
END $$;

-- G2 / G3 --------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  PERFORM pg_temp.as_service();
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'summer20', pg_temp.net(1));
  IF NOT r.is_valid OR r.discount_percent IS DISTINCT FROM 20 OR r.can_bypass OR r.restrict_tier_id IS NOT NULL THEN
    RAISE EXCEPTION 'G2 FAIL: promo code for a guest: % % %', r.is_valid, r.discount_percent, r.reason;
  END IF;
  RAISE NOTICE 'G2 ok: a guest''s promo code checks out with its discount';

  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'COMPUPGRADE', pg_temp.net(1));
  IF r.is_valid OR r.reason <> 'sign in required' OR r.voucher_id IS NOT NULL THEN RAISE EXCEPTION 'G3 FAIL: bypass code for a guest (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'PRESALE01', pg_temp.net(1));
  IF r.is_valid OR r.reason <> 'sign in required' THEN RAISE EXCEPTION 'G3 FAIL: hidden-type code for a guest (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'JUSTFORFAN', pg_temp.net(1));
  IF r.is_valid OR r.reason IS DISTINCT FROM 'sign in required' THEN RAISE EXCEPTION 'G3 FAIL: reserved code for a guest (%)', r.reason; END IF;
  -- Valid answers never counted as misses.
  IF EXISTS (SELECT 1 FROM public.exos_voucher_attempts WHERE bucket = 'g:' || pg_temp.net(1)) THEN
    RAISE EXCEPTION 'G3 FAIL: a real code counted as a miss';
  END IF;
  RAISE NOTICE 'G3 ok: bypass, hidden-type and one-person codes say sign in';
END $$;

-- G4 -------------------------------------------------------------------------
DO $$
DECLARE r record; i int;
BEGIN
  PERFORM pg_temp.as_service();
  FOR i IN 1..10 LOOP
    SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'GUESS' || i, pg_temp.net(2));
    IF r.reason <> 'invalid code' THEN RAISE EXCEPTION 'G4 FAIL: miss % said %', i, r.reason; END IF;
  END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', pg_temp.net(2));
  IF r.is_valid OR r.reason <> 'too many attempts' THEN RAISE EXCEPTION 'G4 FAIL: network not throttled (%)', r.reason; END IF;
  -- Per network across events.
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e2', 'OTHER10', pg_temp.net(2));
  IF r.reason IS DISTINCT FROM 'too many attempts' THEN RAISE EXCEPTION 'G4 FAIL: the network budget is per event'; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', pg_temp.net(3));
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G4 FAIL: another network was blocked (%)', r.reason; END IF;
  IF EXISTS (SELECT 1 FROM public.exos_voucher_attempts WHERE bucket = 's:6a000000-0000-0000-0000-0000000000e1') THEN
    RAISE EXCEPTION 'G4 FAIL: guest misses landed on the server bucket';
  END IF;
  -- After the guest call, the server's own checks are back on their own bucket.
  SELECT * INTO r FROM public.exos_check_voucher('6a000000-0000-0000-0000-0000000000e1', 'NOPE01', NULL);
  IF NOT EXISTS (SELECT 1 FROM public.exos_voucher_attempts WHERE bucket = 's:6a000000-0000-0000-0000-0000000000e1') THEN
    RAISE EXCEPTION 'G4 FAIL: the guest key leaked into a later server check';
  END IF;
  RAISE NOTICE 'G4 ok: 10 guest misses per network (all events), other networks and the server bucket unaffected';
END $$;

-- G5 -------------------------------------------------------------------------
DO $$
DECLARE r record; i int;
BEGIN
  PERFORM pg_temp.as_service();
  -- 10 guest misses on e1 so far (net 2; its 11th try was refused before
  -- counting). Fresh networks fill the event's guest budget of 30.
  FOR i IN 1..30 LOOP
    PERFORM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SWEEP' || i, pg_temp.net(100 + i));
  END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', pg_temp.net(999));
  IF r.reason IS DISTINCT FROM 'too many attempts' THEN RAISE EXCEPTION 'G5 FAIL: event guest budget not enforced (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e2', 'OTHER10', pg_temp.net(999));
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: another event''s guests were blocked (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', NULL);
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: the server check was blocked by guests (%)', r.reason; END IF;
  PERFORM pg_temp.as_user('6a000000-0000-0000-0000-0000000000b1', '6a-fan@x.com');
  SELECT * INTO r FROM public.exos_check_voucher('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', NULL);
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: a signed-in buyer was blocked by guests (%)', r.reason; END IF;
  RAISE NOTICE 'G5 ok: 30 guest misses per event pause that event''s guest path only';
END $$;

ROLLBACK;
