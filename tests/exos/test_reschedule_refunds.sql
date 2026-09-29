-- ============================================================================
-- Optional refunds when the organizer changes the date (mig 20260929150000).
-- The Stripe call lives in exos-refund; every decision is one of these RPCs,
-- called here in the order the function calls them (claim -> finalize).
--   R1  roles and grants (RPC surface, service-role-only claim)
--   R2  pure rules: qualifying change, default deadline
--   R3  client guard on exos_events; a non-qualifying move needs no offer
--   R4  qualifying move with refunds: deadline default + validation, one mail
--       per address with the right links (payer / holder / marketplace)
--   R5  My Tickets offers: eligible, not-buyer, checked-in, marketplace, late buyer
--   R6  claims: transferred ticket (payer only), idempotent, finalize voids,
--       add-ons only with the order's last ticket, refund-issued mail
--   R7  mail-link tokens: only their own ticket and action; bad / unknown links
--   R8  comp release, checked-in, deadline passed, retry after a failure
--   R9  organizer summary
--   R10 a later move without refunds closes the offer; old links superseded
-- Self-contained ids 5c…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5c000000-0000-0000-0000-0000000000a1','rsown@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a2','rsmgr@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a3','rsfin@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a4','rsscan@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000a6','rsstranger@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b1','rsb1@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b2','rsb2@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b3','rsb3@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b4','rsb4@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b5','rsb5@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b6','rsb6@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b7','rsb7@x.com',now()),
  ('5c000000-0000-0000-0000-0000000000b8','rsb8@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5c000000-0000-0000-0000-000000000001','RS Org','rs-org-stub','5c000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a1','owner'),
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a2','manager'),
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a3','finance'),
  ('5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000a4','scanner');
-- 7pm New York time, 10 days out (a fixed local time so +1h never crosses midnight).
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by) VALUES
  ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','RS <Night>','rs-night-stub','published',
   (date_trunc('day', now() AT TIME ZONE 'America/New_York') + interval '10 days 19 hours') AT TIME ZONE 'America/New_York',
   'America/New_York', 100, 10, '5c000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-0000000000e1','GA',30,100,10,'public');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold) VALUES
  ('5c000000-0000-0000-0000-0000000000ad','5c000000-0000-0000-0000-0000000000e1','Parking',10,50,1);

-- Orders: rs1 (b1) 2 tickets + $10 parking = $70; rs2 (b2) 2 tickets, one given to b3;
-- rs3 guest (no account) parked on the owner; rs6 (b6) checked in; rs7 (b7) bought
-- after the change; rs8 (b8) a spare for the deadline test. Plus a comp (b4) and a
-- StubHub ticket (b5).
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,addons,guest,created_at) VALUES
  ('cs_rs1','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b1','rsb1@x.com',2,7000,'fulfilled','pi_rs1',
   '[{"addon_id":"5c000000-0000-0000-0000-0000000000ad","quantity":1,"unit_price_cents":1000,"name":"Parking"}]',false, now() - interval '2 days'),
  ('cs_rs2','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b2','rsb2@x.com',2,6000,'fulfilled','pi_rs2',NULL,false, now() - interval '2 days'),
  ('cs_rs3','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   NULL,'rsguest@x.com',1,3000,'fulfilled','pi_rs3',NULL,true, now() - interval '2 days'),
  ('cs_rs6','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b6','rsb6@x.com',1,3000,'fulfilled','pi_rs6',NULL,false, now() - interval '2 days'),
  ('cs_rs7','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b7','rsb7@x.com',1,3000,'fulfilled','pi_rs7',NULL,false, now() + interval '1 minute'),
  ('cs_rs8','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-0000000000d1','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b8','rsb8@x.com',1,3000,'fulfilled','pi_rs8',NULL,false, now() - interval '2 days');
SELECT public.exos_record_payment(s, 'pi_' || substr(s, 4), a, 'succeeded')
  FROM (VALUES ('cs_rs1',7000),('cs_rs2',6000),('cs_rs3',3000),('cs_rs6',3000),('cs_rs7',3000),('cs_rs8',3000)) v(s,a);

INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,check_in_at,created_at) VALUES
  ('5c000000-0000-0000-0000-000000000c11','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b1','5c000000-0000-0000-0000-0000000000b1','rsb1@x.com','active','sk11',30,'cs_rs1','stripe',NULL, now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c12','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b1','5c000000-0000-0000-0000-0000000000b1','rsb1@x.com','active','sk12',30,'cs_rs1','stripe',NULL, now() - interval '2 days' + interval '1 second'),
  ('5c000000-0000-0000-0000-000000000c21','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b2','5c000000-0000-0000-0000-0000000000b2','rsb2@x.com','active','sk21',30,'cs_rs2','stripe',NULL, now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c22','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b2','5c000000-0000-0000-0000-0000000000b3','rsb2@x.com','active','sk22',30,'cs_rs2','stripe',NULL, now() - interval '2 days' + interval '1 second'),
  ('5c000000-0000-0000-0000-000000000c31','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000a1','5c000000-0000-0000-0000-0000000000a1','rsguest@x.com','active','sk31',30,'cs_rs3','stripe',NULL, now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c41','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b4','5c000000-0000-0000-0000-0000000000b4','rsb4@x.com','active','sk41',0,'comp:5c','comp',NULL, now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c51','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b5','5c000000-0000-0000-0000-0000000000b5','rsb5@x.com','active','sk51',30,'stubhub:rs999','stubhub',NULL, now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c61','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b6','5c000000-0000-0000-0000-0000000000b6','rsb6@x.com','used','sk61',30,'cs_rs6','stripe',now() - interval '1 hour', now() - interval '2 days'),
  ('5c000000-0000-0000-0000-000000000c71','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b7','5c000000-0000-0000-0000-0000000000b7','rsb7@x.com','active','sk71',30,'cs_rs7','stripe',NULL, now() + interval '1 minute'),
  ('5c000000-0000-0000-0000-000000000c81','5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000d1','GA',
   '5c000000-0000-0000-0000-0000000000b8','5c000000-0000-0000-0000-0000000000b8','rsb8@x.com','active','sk81',30,'cs_rs8','stripe',NULL, now() - interval '2 days');
-- c22 was given to b3 (a completed transfer); c31 waits for the guest to claim it.
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status,event_id) VALUES
  ('5c000000-0000-0000-0000-0000000000f2','5c000000-0000-0000-0000-000000000c22','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000b2','rsb3@x.com','completed','5c000000-0000-0000-0000-0000000000e1'),
  ('5c000000-0000-0000-0000-0000000000f3','5c000000-0000-0000-0000-000000000c31','5c000000-0000-0000-0000-000000000001',
   '5c000000-0000-0000-0000-0000000000a1','rsguest@x.com','pending','5c000000-0000-0000-0000-0000000000e1');
UPDATE public.exos_tickets SET transfer_id = '5c000000-0000-0000-0000-0000000000f2' WHERE id = '5c000000-0000-0000-0000-000000000c22';
UPDATE public.exos_tickets SET pending_transfer_id = '5c000000-0000-0000-0000-0000000000f3' WHERE id = '5c000000-0000-0000-0000-000000000c31';
INSERT INTO public.exos_order_addons(event_id,org_id,addon_id,addon_name,buyer_id,owner_id,quantity,unit_price_paid,order_ref,status)
  VALUES ('5c000000-0000-0000-0000-0000000000e1','5c000000-0000-0000-0000-000000000001','5c000000-0000-0000-0000-0000000000ad','Parking',
          '5c000000-0000-0000-0000-0000000000b1','5c000000-0000-0000-0000-0000000000b1',1,10,'cs_rs1','active');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5c000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
-- 7pm New York, n days from today.
CREATE FUNCTION pg_temp.ny(n int, h int DEFAULT 19) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT (date_trunc('day', now() AT TIME ZONE 'America/New_York') + make_interval(days => n, hours => h)) AT TIME ZONE 'America/New_York'
$$;
GRANT EXECUTE ON FUNCTION pg_temp.ny(int, int) TO anon, authenticated;
-- One ticket's claim result from exos_request_reschedule_refund.
CREATE FUNCTION pg_temp.res(j jsonb, t text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(j->'results') x WHERE x->>'ticket_id' = ('5c000000-0000-0000-0000-' || t)
$$;
CREATE FUNCTION pg_temp.mail(p_to text, p_rid uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT payload FROM public.exos_mail WHERE template = 'event-rescheduled' AND to_email = p_to
     AND payload->>'reschedule_id' = p_rid::text
$$;

-- ---------------------------------------------------------------------------
-- R1. Who may call what.
-- ---------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_reschedule_event(uuid,timestamptz,timestamptz,timestamptz,text,text,boolean,timestamptz)',
    'public.exos_my_reschedule_offers()', 'public.exos_reschedule_release_mine(uuid[])',
    'public.exos_event_reschedule_summary(uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'R1: anon may not run ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'R1: authenticated runs ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'public.exos_request_reschedule_refund(uuid,uuid[],text)', 'public.exos_reschedule_release_svc(uuid,uuid[],text)',
    'public.exos_reschedule_link_info(text)', 'public._exos_resched_ticket_state(uuid)',
    'public._exos_resched_actor_ok(jsonb,uuid)', 'public._exos_reschedule_notify(uuid,uuid)',
    'public._exos_reschedule_release(uuid,uuid[],text)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'R1: no client grant on ' || f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_request_reschedule_refund(uuid,uuid[],text)', 'EXECUTE'), 'R1: service role claims';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_reschedule_links', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_reschedule_links', 'SELECT'), 'R1: links are service-role only';
  -- The old 6-argument version is gone (one function, no overload ambiguity).
  ASSERT to_regprocedure('public.exos_reschedule_event(uuid,timestamptz,timestamptz,timestamptz,text,text)') IS NULL, 'R1: old overload dropped';
  -- Definer functions pin search_path.
  ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.prosecdef
                        AND p.proname ~ 'resched' AND NOT coalesce(p.proconfig::text, '') ~ 'search_path'), 'R1: search_path pinned';
END $$;

DO $$
DECLARE who text;
BEGIN
  FOREACH who IN ARRAY ARRAY['a4', 'a3', 'a6', ''] LOOP     -- scanner, finance, stranger, signed out
    PERFORM pg_temp.act(CASE WHEN who = '' THEN NULL ELSE '5c000000-0000-0000-0000-0000000000' || who END);
    BEGIN
      PERFORM public.exos_reschedule_event(pg_temp.u('0000000000e1'), pg_temp.ny(20), p_offer_refunds => true);
      RAISE EXCEPTION 'R1: % moved the event', who;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  END LOOP;
  -- Service-role claim refuses a client role.
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000b1');
END $$;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_request_reschedule_refund(pg_temp.u('0000000000b1'), ARRAY[pg_temp.u('000000000c11')], NULL);
    RAISE EXCEPTION 'R1: a client ran the claim';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_event_reschedules WHERE event_id = pg_temp.u('0000000000e1')), 'R1: nothing recorded';
  RAISE NOTICE 'OK  R1 roles: owner / manager only, claim is service-role only, no anon surface';
END $$;

-- ---------------------------------------------------------------------------
-- R2. Pure rules (same cases as src/lib/rescheduleRefunds.test.ts).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT public.exos_reschedule_qualifies('2026-10-10T23:00Z', '2026-10-11T01:00Z', 'America/New_York'), 'R2: +2h same local day';
  ASSERT public.exos_reschedule_qualifies('2026-10-10T23:00Z', '2026-10-11T02:30Z', 'America/New_York'), 'R2: +3h30 qualifies';
  ASSERT NOT public.exos_reschedule_qualifies('2026-10-10T23:00Z', '2026-10-11T02:00Z', 'America/New_York'), 'R2: exactly 3h does not';
  ASSERT public.exos_reschedule_qualifies('2026-10-11T03:30Z', '2026-10-11T04:30Z', 'America/New_York'), 'R2: 11:30pm -> 12:30am local is another day';
  ASSERT NOT public.exos_reschedule_qualifies('2026-10-11T03:30Z', '2026-10-11T04:30Z', 'UTC'), 'R2: same UTC day';
  ASSERT public.exos_reschedule_qualifies('2026-10-11T03:30Z', '2026-10-11T04:30Z', 'Not/AZone') = false, 'R2: bad zone falls back to UTC';
  ASSERT NOT public.exos_reschedule_qualifies(NULL, '2026-10-11T04:30Z', 'UTC'), 'R2: no old date';
  ASSERT public.exos_reschedule_default_deadline('2026-10-01T12:00Z', '2026-11-01T12:00Z') = '2026-10-15T12:00Z', 'R2: change + 14 days';
  ASSERT public.exos_reschedule_default_deadline('2026-10-01T12:00Z', '2026-10-05T12:00Z') = '2026-10-04T12:00Z', 'R2: new start - 24h';
  ASSERT public.exos_reschedule_default_deadline('2026-10-01T12:00Z', '2026-10-02T06:00Z') = '2026-10-02T06:00Z', 'R2: < 1 day away: until the start';
  ASSERT public.exos_reschedule_default_deadline('2026-10-01T12:00Z', '2026-10-01T11:00Z') IS NULL, 'R2: new start in the past: none';
  RAISE NOTICE 'OK  R2 qualifying change and default deadline';
END $$;

-- ---------------------------------------------------------------------------
-- R3. The client guard, and a small move (no offer needed, holders told).
-- ---------------------------------------------------------------------------
CREATE POLICY rs_test_upd ON public.exos_events FOR UPDATE TO authenticated USING (true);
CREATE POLICY rs_test_sel ON public.exos_events FOR SELECT TO authenticated USING (true);
GRANT SELECT, UPDATE ON public.exos_events TO authenticated;
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    UPDATE public.exos_events SET starts_at = starts_at + interval '2 days' WHERE id = pg_temp.u('0000000000e1');
    RAISE EXCEPTION 'R3: a plain save moved a sold event by two days';
  EXCEPTION WHEN insufficient_privilege THEN
    ASSERT SQLERRM LIKE '%exos_reschedule_event%', 'R3: refused by the guard, got ' || SQLERRM;
  END;
  UPDATE public.exos_events SET starts_at = starts_at + interval '30 minutes' WHERE id = pg_temp.u('0000000000e1');
  UPDATE public.exos_events SET starts_at = starts_at - interval '30 minutes' WHERE id = pg_temp.u('0000000000e1');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT starts_at FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) = pg_temp.ny(10), 'R3: event unchanged';
END $$;

-- A 1-hour move through the RPC (as the SPA would, role authenticated).
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
SELECT set_config('rs.r3', (SELECT reschedule_id::text FROM public.exos_reschedule_event(
  pg_temp.u('0000000000e1'), pg_temp.ny(10, 20), p_reason => 'Band <late> & co')), true);
RESET ROLE;
DO $$
DECLARE r public.exos_event_reschedules%ROWTYPE; p jsonb;
BEGIN
  SELECT * INTO r FROM public.exos_event_reschedules WHERE id = current_setting('rs.r3')::uuid;
  ASSERT r.old_starts_at = pg_temp.ny(10) AND r.new_starts_at = pg_temp.ny(10, 20), 'R3: old -> new recorded';
  ASSERT NOT r.qualifying AND NOT r.refunds_offered AND r.refund_deadline IS NULL, 'R3: small move, no offer';
  ASSERT r.rescheduled_by = pg_temp.u('0000000000a2') AND r.notified_at IS NOT NULL, 'R3: who + notified';
  ASSERT r.recipient_count = 9, 'R3: 9 addresses told, got ' || r.recipient_count;
  ASSERT (SELECT starts_at FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) = pg_temp.ny(10, 20), 'R3: event moved';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-rescheduled' AND to_email = 'rsown@x.com'),
    'R3: the owner holding a parked ticket is not mailed';
  p := pg_temp.mail('rsguest@x.com', r.id);
  ASSERT p IS NOT NULL AND NOT (p->>'refunds_offered')::boolean AND jsonb_array_length(p->'refunds') = 0, 'R3: guest told, no links';
  ASSERT p->>'reason' = 'Band <late> & co' AND p->'event'->>'name' = 'RS <Night>', 'R3: raw text in payload (renderer escapes)';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'event-rescheduled' AND payload->>'reschedule_id' = r.id::text AND html = '') = 9,
    'R3: payload rows';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_reschedule_links WHERE reschedule_id = r.id), 'R3: no links without an offer';
  -- Same start again: refused.
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000a2');
  BEGIN
    PERFORM public.exos_reschedule_event(pg_temp.u('0000000000e1'), pg_temp.ny(10, 20));
    RAISE EXCEPTION 'R3: an unchanged start was recorded';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  RAISE NOTICE 'OK  R3 client guard; small move needs no offer, 9 addresses told';
END $$;

-- ---------------------------------------------------------------------------
-- R4. Moved by 20 days with refunds: default deadline, validation, mails.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000a1');
  BEGIN
    PERFORM public.exos_reschedule_event(pg_temp.u('0000000000e1'), pg_temp.ny(30), p_offer_refunds => true,
                                         p_refund_deadline => pg_temp.ny(31));
    RAISE EXCEPTION 'R4: deadline after the new start accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_reschedule_event(pg_temp.u('0000000000e1'), pg_temp.ny(30), p_offer_refunds => true,
                                         p_refund_deadline => now() - interval '1 minute');
    RAISE EXCEPTION 'R4: past deadline accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT set_config('rs.r4', (SELECT reschedule_id::text FROM public.exos_reschedule_event(
  pg_temp.u('0000000000e1'), pg_temp.ny(30), pg_temp.ny(30, 18), NULL, NULL, NULL, true, NULL)), true);
RESET ROLE;
DO $$
DECLARE r public.exos_event_reschedules%ROWTYPE; p jsonb; v_rid uuid := current_setting('rs.r4')::uuid;
BEGIN
  SELECT * INTO r FROM public.exos_event_reschedules WHERE id = v_rid;
  ASSERT r.qualifying AND r.refunds_offered, 'R4: qualifying, offered';
  ASSERT r.refund_deadline = now() + interval '14 days', 'R4: default deadline = change + 14 days, got ' || r.refund_deadline;
  ASSERT (SELECT doors_at FROM public.exos_events WHERE id = pg_temp.u('0000000000e1')) = pg_temp.ny(30, 18), 'R4: doors moved too';
  ASSERT r.recipient_count = 9, 'R4: 9 addresses, got ' || r.recipient_count;

  -- b1: holder + payer of both tickets.
  p := pg_temp.mail('rsb1@x.com', v_rid);
  ASSERT jsonb_array_length(p->'refunds') = 2 AND (p->>'tickets')::int = 2, 'R4: b1 two refund links ' || p::text;
  ASSERT (SELECT bool_and(x->>'token' ~ '^[0-9a-f]{64}$') FROM jsonb_array_elements(p->'refunds') x), 'R4: 64-hex tokens';
  ASSERT (p->'refunds'->0->>'amount_cents')::int = 3000, 'R4: first ticket share, not the add-on';
  -- b2 paid for both of rs2's tickets but holds one; b3 holds the other.
  p := pg_temp.mail('rsb2@x.com', v_rid);
  ASSERT jsonb_array_length(p->'refunds') = 2 AND (p->>'tickets')::int = 1 AND (p->>'not_buyer')::int = 0, 'R4: b2 ' || p::text;
  p := pg_temp.mail('rsb3@x.com', v_rid);
  ASSERT jsonb_array_length(p->'refunds') = 0 AND (p->>'not_buyer')::int = 1 AND (p->>'tickets')::int = 1, 'R4: b3 gets no link ' || p::text;
  ASSERT position('rsb2' in p::text) = 0, 'R4: nothing about the payer in the holder''s mail';
  -- Guest (no account): refund link for the parked ticket.
  p := pg_temp.mail('rsguest@x.com', v_rid);
  ASSERT jsonb_array_length(p->'refunds') = 1 AND p->'refunds'->0->>'ticket_id' = pg_temp.u('000000000c31')::text, 'R4: guest link';
  -- Comp: release link. Marketplace: told to go to the marketplace. Checked in / late buyer: no link.
  p := pg_temp.mail('rsb4@x.com', v_rid);
  ASSERT jsonb_array_length(p->'releases') = 1 AND jsonb_array_length(p->'refunds') = 0, 'R4: comp release link';
  p := pg_temp.mail('rsb5@x.com', v_rid);
  ASSERT (p->>'marketplace')::int = 1 AND jsonb_array_length(p->'refunds') = 0, 'R4: marketplace note';
  ASSERT jsonb_array_length(pg_temp.mail('rsb6@x.com', v_rid)->'refunds') = 0, 'R4: checked in, no link';
  ASSERT jsonb_array_length(pg_temp.mail('rsb7@x.com', v_rid)->'refunds') = 0, 'R4: bought after the change, no link';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'event-rescheduled' AND to_email = 'rsown@x.com'), 'R4: owner not mailed';
  ASSERT (SELECT count(*) FROM public.exos_reschedule_links WHERE reschedule_id = v_rid) = 7, 'R4: 7 links (6 refunds + 1 release)';

  -- Dedupe: notifying again queues nothing.
  ASSERT public._exos_reschedule_notify(v_rid) = 0, 'R4: once per address';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'event-rescheduled' AND payload->>'reschedule_id' = v_rid::text) = 9, 'R4: still 9';
  RAISE NOTICE 'OK  R4 offer recorded, deadline defaulted, one mail per address with the right links';
END $$;

-- ---------------------------------------------------------------------------
-- R5. My Tickets offers.
-- ---------------------------------------------------------------------------
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b1');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE rs_o1 AS SELECT * FROM public.exos_my_reschedule_offers();
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b2');
CREATE TEMP TABLE rs_o2 AS SELECT * FROM public.exos_my_reschedule_offers();
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b3');
CREATE TEMP TABLE rs_o3 AS SELECT * FROM public.exos_my_reschedule_offers();
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b5');
CREATE TEMP TABLE rs_o5 AS SELECT * FROM public.exos_my_reschedule_offers();
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b6');
CREATE TEMP TABLE rs_o6 AS SELECT * FROM public.exos_my_reschedule_offers();
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b7');
CREATE TEMP TABLE rs_o7 AS SELECT * FROM public.exos_my_reschedule_offers();
RESET ROLE;
-- The guest signs up later with the checkout email: the parked ticket is theirs to refund.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('5c000000-0000-0000-0000-0000000000b9','rsguest@x.com',now());
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b9');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE rs_o9 AS SELECT * FROM public.exos_my_reschedule_offers();
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM rs_o1 WHERE ok AND kind = 'refund' AND amount_cents = 3000) = 2, 'R5: b1 two refundable';
  ASSERT (SELECT count(*) FROM rs_o2 WHERE ok) = 2, 'R5: b2 (payer) sees both, incl. the one given away';
  ASSERT (SELECT mine FROM rs_o2 WHERE ticket_id = pg_temp.u('000000000c22')) = false, 'R5: ... marked not held';
  ASSERT (SELECT reason FROM rs_o3 WHERE ticket_id = pg_temp.u('000000000c22')) = 'not-buyer'
     AND NOT (SELECT ok FROM rs_o3 WHERE ticket_id = pg_temp.u('000000000c22')), 'R5: b3 holds it but did not pay';
  ASSERT (SELECT reason FROM rs_o5) = 'marketplace', 'R5: marketplace';
  ASSERT (SELECT reason FROM rs_o6) = 'checked-in', 'R5: checked in';
  ASSERT (SELECT reason FROM rs_o7) = 'bought-after-change', 'R5: bought after the change';
  ASSERT (SELECT ok AND mine AND kind = 'refund' FROM rs_o9 WHERE ticket_id = pg_temp.u('000000000c31')), 'R5: guest account, parked ticket';
  ASSERT (SELECT count(*) FROM rs_o9) = 1, 'R5: the guest sees only their ticket';
  RAISE NOTICE 'OK  R5 My Tickets offers';
END $$;

-- ---------------------------------------------------------------------------
-- R6. Claims: payer only, idempotent, finalize, add-ons with the last ticket.
-- ---------------------------------------------------------------------------
DO $$
DECLARE j jsonb; c jsonb; c2 jsonb; f jsonb; v_sold int;
BEGIN
  -- The holder of a transferred ticket can't refund it (the money is b2's).
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b3'), ARRAY[pg_temp.u('000000000c22')]);
  ASSERT pg_temp.res(j, '000000000c22')->>'reason' = 'not-authorized', 'R6: b3 refused ' || j::text;
  -- A stranger can't either.
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000a6'), ARRAY[pg_temp.u('000000000c11')]);
  ASSERT pg_temp.res(j, '000000000c11')->>'reason' = 'not-authorized', 'R6: stranger refused';
  -- The payer can; a double click returns the same request.
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b2'), ARRAY[pg_temp.u('000000000c22')]);
  c := pg_temp.res(j, '000000000c22')->'claim';
  ASSERT c->>'scope' = 'reschedule' AND (c->>'amount_cents')::int = 3000 AND c->>'payment_intent' = 'pi_rs2'
     AND NOT (c->>'existing')::boolean, 'R6: claim ' || j::text;
  ASSERT c->>'idempotency_key' = 'exos_refund_' || (c->>'request_id'), 'R6: key from the request';
  ASSERT (SELECT nonce FROM public.exos_refund_requests WHERE id = (c->>'request_id')::uuid)
         = 'rsr:' || current_setting('rs.r4') || ':' || pg_temp.u('000000000c22'), 'R6: nonce per ticket + reschedule';
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b2'), ARRAY[pg_temp.u('000000000c22'), pg_temp.u('000000000c22')]);
  c2 := pg_temp.res(j, '000000000c22')->'claim';
  ASSERT c2->>'request_id' = c->>'request_id' AND (c2->>'existing')::boolean, 'R6: same request again';
  ASSERT (SELECT count(*) FROM public.exos_refund_requests WHERE reschedule_id = current_setting('rs.r4')::uuid) = 1, 'R6: one request';

  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1');
  f := public.exos_refund_finalize((c->>'request_id')::uuid, 're_rs_22', 'succeeded');
  ASSERT (f->>'voided')::int = 1, 'R6: voided ' || f::text;
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('000000000c22')) = 'voided', 'R6: b3''s ticket voided';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = pg_temp.u('0000000000d1')) = v_sold - 1, 'R6: sold decremented';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'refund-issued' AND to_email = 'rsb2@x.com'
            AND (payload->>'amount_cents')::int = 3000) = 1, 'R6: refund-issued to the payer';
  -- After it succeeded, asking again is still the same request.
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b2'), ARRAY[pg_temp.u('000000000c22')]);
  ASSERT pg_temp.res(j, '000000000c22')->'claim'->>'request_id' = c->>'request_id', 'R6: idempotent after success';

  -- b1: the first ticket is its share; the last one takes the add-on with it.
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b1'), ARRAY[pg_temp.u('000000000c11')]);
  c := pg_temp.res(j, '000000000c11')->'claim';
  ASSERT (c->>'amount_cents')::int = 3000, 'R6: first ticket 3000 ' || j::text;
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_rs_11', 'succeeded');
  ASSERT (SELECT status FROM public.exos_order_addons WHERE order_ref = 'cs_rs1') = 'active', 'R6: add-on kept while a ticket remains';
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b1'), ARRAY[pg_temp.u('000000000c12')]);
  c := pg_temp.res(j, '000000000c12')->'claim';
  ASSERT (c->>'amount_cents')::int = 4000, 'R6: last ticket + parking = 4000 ' || j::text;
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_rs_12', 'succeeded');
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_rs1') = 'refunded', 'R6: order refunded';
  ASSERT (SELECT status FROM public.exos_order_addons WHERE order_ref = 'cs_rs1') <> 'active', 'R6: add-on voided with the order';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_rs1' AND status = 'active') = 0, 'R6: both tickets voided';
  RAISE NOTICE 'OK  R6 payer-only claims, idempotent, voids on success, add-ons with the last ticket';
END $$;

-- ---------------------------------------------------------------------------
-- R7. Mail-link tokens.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_tok text; v_rel text; j jsonb; i jsonb;
BEGIN
  SELECT token INTO v_tok FROM public.exos_reschedule_links WHERE ticket_id = pg_temp.u('000000000c31') AND kind = 'refund';
  SELECT token INTO v_rel FROM public.exos_reschedule_links WHERE ticket_id = pg_temp.u('000000000c41') AND kind = 'release';
  i := public.exos_reschedule_link_info(v_tok);
  ASSERT (i->>'ok')::boolean AND i->>'kind' = 'refund' AND (i->>'amount_cents')::int = 3000, 'R7: link info ' || i::text;
  ASSERT position('@' in i::text) = 0, 'R7: no email addresses in link info';
  ASSERT public.exos_reschedule_link_info(repeat('0', 64)) IS NULL AND public.exos_reschedule_link_info('x') IS NULL, 'R7: unknown link';

  -- The guest's link can't refund b8's ticket, even when asked to.
  j := public.exos_request_reschedule_refund(NULL, ARRAY[pg_temp.u('000000000c81')], v_tok);
  ASSERT pg_temp.res(j, '000000000c81')->>'reason' = 'not-authorized', 'R7: token on another ticket ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_refund_request_items WHERE ticket_id = pg_temp.u('000000000c81')), 'R7: nothing claimed';
  -- A release link can't be used as a refund link (and vice versa).
  j := public.exos_request_reschedule_refund(NULL, NULL, v_rel);
  ASSERT pg_temp.res(j, '000000000c41')->>'reason' = 'not-authorized', 'R7: release link refused for a refund';
  j := public.exos_reschedule_release_svc(NULL, NULL, v_tok);
  ASSERT pg_temp.res(j, '000000000c31')->>'reason' = 'not-authorized', 'R7: refund link refused for a release';
  -- Bad and unknown tokens.
  BEGIN
    PERFORM public.exos_request_reschedule_refund(NULL, NULL, 'not-a-token');
    RAISE EXCEPTION 'R7: bad token accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.exos_request_reschedule_refund(NULL, NULL, repeat('ab', 32));
    RAISE EXCEPTION 'R7: unknown token accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.exos_request_reschedule_refund(NULL, ARRAY[pg_temp.u('000000000c81')], NULL);
    RAISE EXCEPTION 'R7: neither account nor link accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  -- The guest's own link works, with no account; twice is one request.
  j := public.exos_request_reschedule_refund(NULL, NULL, v_tok);
  ASSERT (pg_temp.res(j, '000000000c31')->>'ok')::boolean AND (pg_temp.res(j, '000000000c31')->'claim'->>'amount_cents')::int = 3000,
    'R7: guest claim ' || j::text;
  ASSERT (SELECT requested_by FROM public.exos_refund_requests
           WHERE id = (pg_temp.res(j, '000000000c31')->'claim'->>'request_id')::uuid) IS NULL, 'R7: no account on the request';
  ASSERT (pg_temp.res(public.exos_request_reschedule_refund(NULL, NULL, v_tok), '000000000c31')->'claim'->>'existing')::boolean,
    'R7: again = same request';
  ASSERT public.exos_reschedule_link_info(v_tok)->>'reason' = 'in-progress', 'R7: link shows it is in progress';
  RAISE NOTICE 'OK  R7 tokens act only on their own ticket and action';
END $$;

-- ---------------------------------------------------------------------------
-- R8. Comp release, checked in, deadline, retry after a failure.
-- ---------------------------------------------------------------------------
DO $$
DECLARE j jsonb;
BEGIN
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b4'), ARRAY[pg_temp.u('000000000c41')]);
  ASSERT pg_temp.res(j, '000000000c41')->>'reason' = 'not-refundable', 'R8: a comp has no money ' || j::text;
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b6'), ARRAY[pg_temp.u('000000000c61')]);
  ASSERT pg_temp.res(j, '000000000c61')->>'reason' = 'checked-in', 'R8: checked in ' || j::text;
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b5'), ARRAY[pg_temp.u('000000000c51')]);
  ASSERT pg_temp.res(j, '000000000c51')->>'ok' = 'false', 'R8: marketplace refused';
END $$;
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b4');
SET LOCAL ROLE authenticated;
SELECT set_config('rs.rel', public.exos_reschedule_release_mine(ARRAY[pg_temp.u('000000000c41')])::text, true);
SELECT set_config('rs.rel2', public.exos_reschedule_release_mine(ARRAY[pg_temp.u('000000000c41')])::text, true);
SELECT pg_temp.act('5c000000-0000-0000-0000-0000000000b8');
SELECT set_config('rs.rel3', public.exos_reschedule_release_mine(ARRAY[pg_temp.u('000000000c81')])::text, true);
RESET ROLE;
DO $$
DECLARE j jsonb; c jsonb; c2 jsonb; v_sold int;
BEGIN
  ASSERT (pg_temp.res(current_setting('rs.rel')::jsonb, '000000000c41')->>'ok')::boolean, 'R8: comp released ' || current_setting('rs.rel');
  ASSERT (pg_temp.res(current_setting('rs.rel2')::jsonb, '000000000c41')->>'existing')::boolean, 'R8: release twice = done';
  ASSERT pg_temp.res(current_setting('rs.rel3')::jsonb, '000000000c81')->>'reason' = 'paid-ticket', 'R8: a paid ticket needs a refund';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('000000000c41')) = 'voided', 'R8: comp voided';
  ASSERT (SELECT via FROM public.exos_reschedule_releases WHERE ticket_id = pg_temp.u('000000000c41')) = 'account', 'R8: release logged';

  -- Deadline passed.
  UPDATE public.exos_event_reschedules SET refund_deadline = now() - interval '1 second' WHERE id = current_setting('rs.r4')::uuid;
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b8'), ARRAY[pg_temp.u('000000000c81')]);
  ASSERT pg_temp.res(j, '000000000c81')->>'reason' = 'deadline-passed', 'R8: deadline ' || j::text;
  UPDATE public.exos_event_reschedules SET refund_deadline = now() + interval '14 days' WHERE id = current_setting('rs.r4')::uuid;

  -- Stripe refused the first attempt: the next one is a new request (new key).
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b2'), ARRAY[pg_temp.u('000000000c21')]);
  c := pg_temp.res(j, '000000000c21')->'claim';
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, NULL, 'failed', 'card closed');
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('000000000c21')) = 'active', 'R8: failed refund keeps the ticket';
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b2'), ARRAY[pg_temp.u('000000000c21')]);
  c2 := pg_temp.res(j, '000000000c21')->'claim';
  ASSERT c2->>'request_id' <> c->>'request_id' AND NOT (c2->>'existing')::boolean, 'R8: retry is a new request';
  ASSERT (SELECT nonce FROM public.exos_refund_requests WHERE id = (c2->>'request_id')::uuid) LIKE 'rsr:%:2', 'R8: nonce :2';
  ASSERT (c2->>'amount_cents')::int = 3000, 'R8: the last ticket of rs2 (no add-ons) is its share';
  RAISE NOTICE 'OK  R8 comp release, checked in, marketplace, deadline, retry after failure';
END $$;

-- ---------------------------------------------------------------------------
-- R9. Organizer summary.
-- ---------------------------------------------------------------------------
DO $$
DECLARE s jsonb;
BEGIN
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000a3');   -- finance may read
  s := public.exos_event_reschedule_summary(pg_temp.u('0000000000e1'));
  ASSERT jsonb_array_length(s->'reschedules') = 2, 'R9: history ' || s::text;
  ASSERT (s->'reschedules'->0->>'id') = current_setting('rs.r4'), 'R9: newest first';
  -- c22, c11, c12 succeeded; c31 and c21 (second try) in flight.
  ASSERT (s->'latest'->>'refunds_requested')::int = 5, 'R9: requested ' || s::text;
  ASSERT (s->'latest'->>'refunds_succeeded')::int = 3 AND (s->'latest'->>'refunded_cents')::int = 10000, 'R9: returned';
  ASSERT (s->'latest'->>'in_flight_cents')::int = 6000, 'R9: in flight';
  ASSERT (s->'latest'->>'released')::int = 1, 'R9: released';
  ASSERT (s->'latest'->>'remaining_eligible')::int = 1, 'R9: only b8''s ticket can still ask';
  ASSERT position('@' in s::text) = 0, 'R9: no buyer emails';
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000a4');
  BEGIN
    PERFORM public.exos_event_reschedule_summary(pg_temp.u('0000000000e1'));
    RAISE EXCEPTION 'R9: scanner read the summary';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  RAISE NOTICE 'OK  R9 organizer summary';
END $$;

-- ---------------------------------------------------------------------------
-- R10. Another move, refunds not offered (an old client that doesn't pass
--      the option): the offer closes and the old links stop working.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r record; j jsonb; v_tok text;
BEGIN
  PERFORM pg_temp.act('5c000000-0000-0000-0000-0000000000a2');
  SELECT * INTO r FROM public.exos_reschedule_event(pg_temp.u('0000000000e1'), pg_temp.ny(40), NULL, NULL, NULL, 'again');
  ASSERT r.qualifying AND NOT r.refunds_offered AND r.refund_deadline IS NULL, 'R10: no offer by default';
  j := public.exos_request_reschedule_refund(pg_temp.u('0000000000b8'), ARRAY[pg_temp.u('000000000c81')]);
  ASSERT pg_temp.res(j, '000000000c81')->>'reason' = 'refunds-not-offered', 'R10: closed ' || j::text;
  SELECT token INTO v_tok FROM public.exos_reschedule_links
   WHERE ticket_id = pg_temp.u('000000000c81') AND kind = 'refund' AND reschedule_id = current_setting('rs.r4')::uuid;
  j := public.exos_request_reschedule_refund(NULL, NULL, v_tok);
  ASSERT pg_temp.res(j, '000000000c81')->>'reason' = 'link-superseded', 'R10: old link ' || j::text;
  ASSERT public.exos_reschedule_link_info(v_tok)->>'reason' = 'link-superseded', 'R10: link info says so';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'event-rescheduled' AND payload->>'reschedule_id' = r.reschedule_id::text
            AND NOT (payload->>'refunds_offered')::boolean) = r.recipient_count AND r.recipient_count > 0, 'R10: holders still told';
  RAISE NOTICE 'OK  R10 later move without refunds closes the offer';
END $$;

ROLLBACK;
