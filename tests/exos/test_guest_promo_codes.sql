-- ============================================================================
-- Guest promo codes (mig 20261121143700). Self-contained (6a prefix), rolled
-- back at the end.
--   G1 anon still can't call exos_check_voucher; only service_role may call
--      exos_check_voucher_guest; a signed-in caller and a bad hash are refused
--   G2 a guest's normal promo code checks out (percent off), case-insensitive,
--      and costs nothing (the reserved attempt is given back)
--   G3 a bypass code, a hidden-type code and a code made for one person
--      (reserved_email) say 'sign in required', and each costs an attempt (I1),
--      as do expired and already-used codes
--   G4 guest misses: 10 per network, then 'too many attempts'; another network
--      still checks; the service role's own bucket and an account are untouched
--   G5 30 misses per event for all guests pauses the guest path of that event
--      only; a network over its budget never spends the event's; signed-in
--      buyers and the server's own checks keep working
--   G6 an unknown, draft or cancelled event answers 'invalid code' and writes
--      no attempt row (S3)
--   (The SPA never checks a guest's link code on load (S1): VoucherField.test.tsx.
--    IPv6 /64 networks (S2): guestCheckout.test.ts. Concurrency (S4):
--    race_guest_codes.sh.)
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
  ('6a000000-0000-0000-0000-0000000000e2','6a000000-0000-0000-0000-000000000001','6A Other','6a-other','published',now() + interval '10 days','Hall',0,0),
  ('6a000000-0000-0000-0000-0000000000e3','6a000000-0000-0000-0000-000000000001','6A Draft','6a-draft','draft',now() + interval '10 days','Hall',0,0),
  ('6a000000-0000-0000-0000-0000000000e4','6a000000-0000-0000-0000-000000000001','6A Off','6a-off','cancelled',now() + interval '10 days','Hall',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('6a000000-0000-0000-0000-0000000000d1','6a000000-0000-0000-0000-0000000000e1','GA',40,500,0,'public'),
  ('6a000000-0000-0000-0000-0000000000d2','6a000000-0000-0000-0000-0000000000e1','Presale',30,50,0,'hidden'),
  ('6a000000-0000-0000-0000-0000000000d3','6a000000-0000-0000-0000-0000000000e2','GA',40,500,0,'public');
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,bypass_capacity,discount_percent,reserved_email) VALUES
  ('6a000000-0000-0000-0000-0000000000e1','SUMMER20',NULL,100,false,20,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','COMPUPGRADE',NULL,1,true,NULL,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','PRESALE01','6a000000-0000-0000-0000-0000000000d2',50,false,NULL,NULL),
  ('6a000000-0000-0000-0000-0000000000e1','JUSTFORFAN',NULL,1,false,NULL,'6a-fan@x.com'),
  ('6a000000-0000-0000-0000-0000000000e2','OTHER10',NULL,100,false,10,NULL),
  ('6a000000-0000-0000-0000-0000000000e3','DRAFT10',NULL,100,false,10,NULL),
  ('6a000000-0000-0000-0000-0000000000e4','GONE10',NULL,100,false,10,NULL);
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,used_count,bypass_capacity,valid_until) VALUES
  ('6a000000-0000-0000-0000-0000000000e2','USEDUP',NULL,1,1,false,NULL),
  ('6a000000-0000-0000-0000-0000000000e2','STALE1',NULL,5,0,false,now() - interval '1 day');

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

CREATE OR REPLACE FUNCTION pg_temp.spent(p_bucket text) RETURNS int LANGUAGE sql AS $$
  SELECT coalesce(sum(failures), 0)::int FROM public.exos_voucher_attempts WHERE bucket = p_bucket;
$$;

-- G2 / G3 --------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  PERFORM pg_temp.as_service();
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'summer20', pg_temp.net(1));
  IF NOT r.is_valid OR r.discount_percent IS DISTINCT FROM 20 OR r.can_bypass OR r.restrict_tier_id IS NOT NULL THEN
    RAISE EXCEPTION 'G2 FAIL: promo code for a guest: % % %', r.is_valid, r.discount_percent, r.reason;
  END IF;
  IF pg_temp.spent('g:' || pg_temp.net(1)) <> 0 OR pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1') <> 0 THEN
    RAISE EXCEPTION 'G2 FAIL: a usable code cost an attempt';
  END IF;
  RAISE NOTICE 'G2 ok: a guest''s promo code checks out with its discount, at no cost';

  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'COMPUPGRADE', pg_temp.net(1));
  IF r.is_valid OR r.reason <> 'sign in required' OR r.voucher_id IS NOT NULL THEN RAISE EXCEPTION 'G3 FAIL: bypass code for a guest (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'PRESALE01', pg_temp.net(1));
  IF r.is_valid OR r.reason <> 'sign in required' THEN RAISE EXCEPTION 'G3 FAIL: hidden-type code for a guest (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'JUSTFORFAN', pg_temp.net(1));
  IF r.is_valid OR r.reason IS DISTINCT FROM 'sign in required' THEN RAISE EXCEPTION 'G3 FAIL: reserved code for a guest (%)', r.reason; END IF;
  -- I1: each "a code exists" answer costs the attempt.
  IF pg_temp.spent('g:' || pg_temp.net(1)) <> 3 OR pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1') <> 3 THEN
    RAISE EXCEPTION 'G3 FAIL: sign-in answers cost % / %', pg_temp.spent('g:' || pg_temp.net(1)), pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1');
  END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e2', 'USEDUP', pg_temp.net(4));
  IF r.reason IS DISTINCT FROM 'already used' THEN RAISE EXCEPTION 'G3 FAIL: used-up code said %', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e2', 'STALE1', pg_temp.net(4));
  IF r.reason IS DISTINCT FROM 'expired' THEN RAISE EXCEPTION 'G3 FAIL: expired code said %', r.reason; END IF;
  IF pg_temp.spent('g:' || pg_temp.net(4)) <> 2 THEN RAISE EXCEPTION 'G3 FAIL: expired / used answers were free'; END IF;
  RAISE NOTICE 'G3 ok: bypass, hidden-type and one-person codes say sign in; those, expired and used-up codes each cost an attempt';
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
  IF pg_temp.spent('g:' || pg_temp.net(2)) <> 10 THEN RAISE EXCEPTION 'G4 FAIL: refused tries counted: %', pg_temp.spent('g:' || pg_temp.net(2)); END IF;
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
DECLARE r record; i int; v_before int;
BEGIN
  PERFORM pg_temp.as_service();
  -- So far on e1's guest budget: 3 sign-in answers (net 1) + 10 misses (net 2) = 13.
  IF pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1') <> 13 THEN
    RAISE EXCEPTION 'G5 FAIL: event budget at % (expected 13)', pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1');
  END IF;
  -- A network over its own budget doesn't spend the event's.
  v_before := pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1');
  FOR i IN 1..5 LOOP PERFORM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'MORE' || i, pg_temp.net(2)); END LOOP;
  IF pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1') <> v_before THEN RAISE EXCEPTION 'G5 FAIL: a blocked network spent the event budget'; END IF;
  -- Fresh networks fill the rest (17), then everyone waits.
  FOR i IN 1..30 LOOP
    PERFORM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SWEEP' || i, pg_temp.net(100 + i));
  END LOOP;
  IF pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1') <> 30 THEN
    RAISE EXCEPTION 'G5 FAIL: event budget at % (cap 30)', pg_temp.spent('ge:6a000000-0000-0000-0000-0000000000e1');
  END IF;
  -- The refused tries gave their network attempt back.
  IF pg_temp.spent('g:' || pg_temp.net(130)) <> 0 THEN RAISE EXCEPTION 'G5 FAIL: a refused try kept its network attempt'; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', pg_temp.net(999));
  IF r.reason IS DISTINCT FROM 'too many attempts' THEN RAISE EXCEPTION 'G5 FAIL: event guest budget not enforced (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e2', 'OTHER10', pg_temp.net(999));
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: another event''s guests were blocked (%)', r.reason; END IF;
  SELECT * INTO r FROM public.exos_check_voucher('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', NULL);
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: the server check was blocked by guests (%)', r.reason; END IF;
  PERFORM pg_temp.as_user('6a000000-0000-0000-0000-0000000000b1', '6a-fan@x.com');
  SELECT * INTO r FROM public.exos_check_voucher('6a000000-0000-0000-0000-0000000000e1', 'SUMMER20', NULL);
  IF NOT r.is_valid THEN RAISE EXCEPTION 'G5 FAIL: a signed-in buyer was blocked by guests (%)', r.reason; END IF;
  RAISE NOTICE 'G5 ok: 30 guest misses per event pause that event''s guest path only; a blocked network spends nothing';
END $$;

-- G6 -------------------------------------------------------------------------
DO $$
DECLARE r record; n0 int; ev text;
BEGIN
  PERFORM pg_temp.as_service();
  SELECT count(*) INTO n0 FROM public.exos_voucher_attempts;
  FOREACH ev IN ARRAY ARRAY['6a000000-0000-0000-0000-00000000dead', '6a000000-0000-0000-0000-0000000000e3', '6a000000-0000-0000-0000-0000000000e4'] LOOP
    SELECT * INTO r FROM public.exos_check_voucher_guest(ev::uuid, CASE ev WHEN '6a000000-0000-0000-0000-0000000000e3' THEN 'DRAFT10' ELSE 'GONE10' END, pg_temp.net(7));
    IF r.is_valid OR r.reason IS DISTINCT FROM 'invalid code' THEN RAISE EXCEPTION 'G6 FAIL: event % said % / %', ev, r.is_valid, r.reason; END IF;
  END LOOP;
  SELECT * INTO r FROM public.exos_check_voucher_guest('6a000000-0000-0000-0000-0000000000e1', '   ', pg_temp.net(7));
  IF r.reason IS DISTINCT FROM 'invalid code' THEN RAISE EXCEPTION 'G6 FAIL: an empty code said %', r.reason; END IF;
  IF (SELECT count(*) FROM public.exos_voucher_attempts) <> n0 THEN RAISE EXCEPTION 'G6 FAIL: a non-event wrote attempt rows'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'exos_voucher_attempts_window_idx') THEN
    RAISE EXCEPTION 'G6 FAIL: no window_start index for the sweep';
  END IF;
  RAISE NOTICE 'G6 ok: unknown, draft and cancelled events (and an empty code) answer invalid and write nothing';
END $$;

ROLLBACK;
