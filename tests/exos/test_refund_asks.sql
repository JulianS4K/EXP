-- ============================================================================
-- Buyer refund requests (mig 20261015090000).
--   A1 policy windows (none / until_7d / until_24h / until_start / unset)
--   A2 the payer asks (by account or confirmed email); not the holder of a
--      given ticket, not a stranger; one open ask per ticket (asking again
--      hands back the same one)
--   A3 can't ask: comp, marketplace, checked in, all sales final, too late
--   A4 organizer list (owner / finance yes, scanner no); decline with a note;
--      the buyer sees it; withdraw
--   A5 the organizer's refund (claim + finalize) closes the ask
--   A6 grants
-- Self-contained ids 5d…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('5d000000-0000-0000-0000-0000000000a1','raown@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000a3','rafin@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000a4','rascan@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000b1','rab1@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000b2','rab2@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000b3','raguest@x.com',now()),
  ('5d000000-0000-0000-0000-0000000000b9','rastranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('5d000000-0000-0000-0000-000000000001','RA Org','ra-org-stub','5d000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000a1','owner'),
  ('5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000a3','finance'),
  ('5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000a4','scanner');
-- e1: 10 days out, refunds until 7 days before. e2: 3 days out, until 7d (too late).
-- e3: all sales final.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by,refund_policy) VALUES
  ('5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','RA One','ra-one','published',now() + interval '10 days','America/New_York',100,6,'5d000000-0000-0000-0000-0000000000a1','until_7d'),
  ('5d000000-0000-0000-0000-0000000000e2','5d000000-0000-0000-0000-000000000001','RA Two','ra-two','published',now() + interval '3 days','America/New_York',100,1,'5d000000-0000-0000-0000-0000000000a1','until_7d'),
  ('5d000000-0000-0000-0000-0000000000e3','5d000000-0000-0000-0000-000000000001','RA Three','ra-three','published',now() + interval '10 days','America/New_York',100,1,'5d000000-0000-0000-0000-0000000000a1','none');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('5d000000-0000-0000-0000-0000000000d1','5d000000-0000-0000-0000-0000000000e1','GA',30,100,6,'public'),
  ('5d000000-0000-0000-0000-0000000000d2','5d000000-0000-0000-0000-0000000000e2','GA',30,100,1,'public'),
  ('5d000000-0000-0000-0000-0000000000d3','5d000000-0000-0000-0000-0000000000e3','GA',30,100,1,'public');
-- ra1: b1 two tickets (one given to b2). ra3: a guest order by raguest@x.com (no account on it).
-- ra4: b1, checked in. ra5 on e2, ra6 on e3.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,guest,created_at) VALUES
  ('cs_ra1','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-0000000000d1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000b1','rab1@x.com',2,6000,'fulfilled','pi_ra1',false,now() - interval '2 days'),
  ('cs_ra3','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-0000000000d1','5d000000-0000-0000-0000-000000000001',NULL,'raguest@x.com',1,3000,'fulfilled','pi_ra3',true,now() - interval '2 days'),
  ('cs_ra4','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-0000000000d1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000b1','rab1@x.com',1,3000,'fulfilled','pi_ra4',false,now() - interval '2 days'),
  ('cs_ra5','5d000000-0000-0000-0000-0000000000e2','5d000000-0000-0000-0000-0000000000d2','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000b1','rab1@x.com',1,3000,'fulfilled','pi_ra5',false,now() - interval '2 days'),
  ('cs_ra6','5d000000-0000-0000-0000-0000000000e3','5d000000-0000-0000-0000-0000000000d3','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000b1','rab1@x.com',1,3000,'fulfilled','pi_ra6',false,now() - interval '2 days');
SELECT public.exos_record_payment(s, 'pi_' || substr(s, 4), a, 'succeeded')
  FROM (VALUES ('cs_ra1',6000),('cs_ra3',3000),('cs_ra4',3000),('cs_ra5',3000),('cs_ra6',3000)) v(s,a);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,check_in_at) VALUES
  ('5d000000-0000-0000-0000-000000000c11','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','active','k11',30,'cs_ra1','stripe',NULL),
  ('5d000000-0000-0000-0000-000000000c12','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b2','rab1@x.com','active','k12',30,'cs_ra1','stripe',NULL),
  ('5d000000-0000-0000-0000-000000000c31','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000a1','5d000000-0000-0000-0000-0000000000b3','raguest@x.com','active','k31',30,'cs_ra3','stripe',NULL),
  ('5d000000-0000-0000-0000-000000000c41','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','used','k41',30,'cs_ra4','stripe',now() - interval '1 hour'),
  ('5d000000-0000-0000-0000-000000000c42','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','active','k42',0,'comp:5d','comp',NULL),
  ('5d000000-0000-0000-0000-000000000c43','5d000000-0000-0000-0000-0000000000e1','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d1','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','active','k43',30,'stubhub:ra9','stubhub',NULL),
  ('5d000000-0000-0000-0000-000000000c51','5d000000-0000-0000-0000-0000000000e2','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d2','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','active','k51',30,'cs_ra5','stripe',NULL),
  ('5d000000-0000-0000-0000-000000000c61','5d000000-0000-0000-0000-0000000000e3','5d000000-0000-0000-0000-000000000001','5d000000-0000-0000-0000-0000000000d3','GA','5d000000-0000-0000-0000-0000000000b1','5d000000-0000-0000-0000-0000000000b1','rab1@x.com','active','k61',30,'cs_ra6','stripe',NULL);

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('5d000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.res(j jsonb, p text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT x FROM jsonb_array_elements(j) x WHERE x->>'ticket_id' = ('5d000000-0000-0000-0000-' || p)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.res(jsonb, text) TO anon, authenticated;

-- A1. Policy windows.
DO $$
DECLARE t timestamptz := '2026-11-20 19:00:00+00';
BEGIN
  ASSERT public.exos_refund_ask_window('none', t) IS NULL, 'A1: none';
  ASSERT public.exos_refund_ask_window('until_7d', t) = t - interval '7 days', 'A1: 7d';
  ASSERT public.exos_refund_ask_window('until_24h', t) = t - interval '24 hours', 'A1: 24h';
  ASSERT public.exos_refund_ask_window('until_start', t) = t, 'A1: start';
  ASSERT public.exos_refund_ask_window(NULL, t) = t, 'A1: unset = until the start';
END $$;

-- A2. The payer asks.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b1');
SELECT set_config('ra.j1', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c11'), pg_temp.u('000000000c12')], '  Can''t make it  ')::text, true);
SELECT set_config('ra.j2', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c11')])::text, true);
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b2');
SELECT set_config('ra.j3', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c12')])::text, true);
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b9');
SELECT set_config('ra.j4', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c31')])::text, true);
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b3');
SELECT set_config('ra.j5', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c31')])::text, true);
RESET ROLE;
DO $$
DECLARE j1 jsonb := current_setting('ra.j1')::jsonb; j2 jsonb := current_setting('ra.j2')::jsonb;
        j3 jsonb := current_setting('ra.j3')::jsonb; j4 jsonb := current_setting('ra.j4')::jsonb;
        j5 jsonb := current_setting('ra.j5')::jsonb;
BEGIN
  ASSERT (pg_temp.res(j1, '000000000c11')->>'ok')::boolean AND (pg_temp.res(j1, '000000000c12')->>'ok')::boolean, 'A2: payer asks for both ' || j1::text;
  ASSERT (pg_temp.res(j1, '000000000c11')->>'amount_cents')::int = 3000, 'A2: amount = the ticket''s share';
  ASSERT (SELECT reason FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c11')) = 'Can''t make it', 'A2: reason trimmed';
  ASSERT (pg_temp.res(j2, '000000000c11')->>'existing')::boolean
     AND pg_temp.res(j2, '000000000c11')->>'ask_id' = pg_temp.res(j1, '000000000c11')->>'ask_id', 'A2: same ask again';
  ASSERT (SELECT count(*) FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c11')) = 1, 'A2: one ask';
  ASSERT pg_temp.res(j3, '000000000c12')->>'reason' = 'not-buyer', 'A2: the holder of a given ticket isn''t the payer';
  ASSERT pg_temp.res(j4, '000000000c31')->>'reason' = 'not-buyer', 'A2: stranger';
  ASSERT (pg_temp.res(j5, '000000000c31')->>'ok')::boolean, 'A2: guest buyer by confirmed email ' || j5::text;
END $$;

-- A3. Can't ask.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b1');
SELECT set_config('ra.j6', public.exos_ask_refund(ARRAY[pg_temp.u('000000000c41'), pg_temp.u('000000000c42'), pg_temp.u('000000000c43'),
                                                        pg_temp.u('000000000c51'), pg_temp.u('000000000c61')])::text, true);
RESET ROLE;
DO $$
DECLARE j jsonb := current_setting('ra.j6')::jsonb;
BEGIN
  ASSERT pg_temp.res(j, '000000000c41')->>'reason' = 'checked-in', 'A3: checked in ' || j::text;
  -- Comp and marketplace tickets have no Exos order to be the payer of.
  ASSERT pg_temp.res(j, '000000000c42')->>'reason' = 'not-buyer', 'A3: comp';
  ASSERT pg_temp.res(j, '000000000c43')->>'reason' = 'not-buyer', 'A3: marketplace';
  ASSERT pg_temp.res(j, '000000000c51')->>'reason' = 'too-late', 'A3: past the 7-day window';
  ASSERT pg_temp.res(j, '000000000c61')->>'reason' = 'no-refunds', 'A3: all sales final';
  ASSERT (public._exos_refund_ask_state(pg_temp.u('000000000c43')))->>'reason' = 'marketplace', 'A3: state says marketplace';
END $$;

-- A4. Organizer list, decline, buyer view, withdraw.
SELECT set_config('ra.a31', (SELECT id::text FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c31')), true),
       set_config('ra.a12', (SELECT id::text FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c12')), true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000a3');
SELECT set_config('ra.n', (SELECT count(*)::text FROM public.exos_event_refund_asks(pg_temp.u('0000000000e1')) WHERE status = 'open'), true);
SELECT set_config('ra.dec', public.exos_decline_refund_ask(
  current_setting('ra.a31')::uuid, 'Doors are in a week, sorry')::text, true);
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b3');
SELECT set_config('ra.mine', (SELECT row_to_json(m)::text FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1')) m
                                WHERE m.ticket_id = pg_temp.u('000000000c31')), true);
SELECT pg_temp.act('5d000000-0000-0000-0000-0000000000b1');
SELECT set_config('ra.w', public.exos_withdraw_refund_ask(current_setting('ra.a12')::uuid)::text, true);
SELECT set_config('ra.mine1', (SELECT count(*)::text FROM public.exos_my_refund_asks(pg_temp.u('0000000000e1'))), true);
RESET ROLE;
DO $$
DECLARE m jsonb := current_setting('ra.mine')::jsonb; ok boolean;
BEGIN
  ASSERT current_setting('ra.n')::int = 3, 'A4: three open asks for finance, got ' || current_setting('ra.n');
  ASSERT current_setting('ra.dec')::boolean, 'A4: declined';
  ASSERT m->>'ask_status' = 'declined' AND m->>'decline_note' = 'Doors are in a week, sorry', 'A4: the buyer sees the note ' || m::text;
  ASSERT (m->>'can_ask')::boolean, 'A4: may ask again after a decline';
  ASSERT current_setting('ra.w')::boolean
     AND (SELECT status FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c12')) = 'withdrawn', 'A4: withdrawn';
  -- b1 paid for c11, c12 (cs_ra1) and c41 (cs_ra4) on e1; comp / StubHub aren't orders.
  ASSERT current_setting('ra.mine1')::int = 3, 'A4: my tickets on e1, got ' || current_setting('ra.mine1');
  BEGIN
    PERFORM set_config('app.uid', '5d000000-0000-0000-0000-0000000000a4', true);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.exos_event_refund_asks(pg_temp.u('0000000000e1'));
    ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  RESET ROLE;
  ASSERT ok, 'A4: a scanner can''t see asks';
END $$;

-- A5. The organizer's refund closes the ask.
DO $$
DECLARE c jsonb; v_ask uuid;
BEGIN
  SELECT id INTO v_ask FROM public.exos_refund_asks WHERE ticket_id = pg_temp.u('000000000c11') AND status = 'open';
  c := public.exos_refund_claim(pg_temp.u('0000000000a1'), 'cs_ra1', 'ask:' || v_ask,
         jsonb_build_array(jsonb_build_object('ticket_id', pg_temp.u('000000000c11'))), NULL, false, 'Refund request', NULL);
  ASSERT (SELECT status FROM public.exos_refund_asks WHERE id = v_ask) = 'open', 'A5: still open while claimed';
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_ra_11', 'succeeded');
  ASSERT (SELECT status FROM public.exos_refund_asks WHERE id = v_ask) = 'refunded', 'A5: refunded';
  ASSERT (SELECT refund_request_id FROM public.exos_refund_asks WHERE id = v_ask) = (c->>'request_id')::uuid, 'A5: linked';
  ASSERT (SELECT status FROM public.exos_tickets WHERE id = pg_temp.u('000000000c11')) = 'voided', 'A5: ticket voided';
  ASSERT (public._exos_refund_ask_state(pg_temp.u('000000000c11')))->>'reason' = 'voided', 'A5: can''t ask again';
END $$;

-- A6. Grants.
DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'public.exos_ask_refund(uuid[], text)', 'EXECUTE'), 'A6: anon ask';
  ASSERT NOT has_function_privilege('anon', 'public.exos_event_refund_asks(uuid)', 'EXECUTE'), 'A6: anon list';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_refund_ask_state(uuid)', 'EXECUTE'), 'A6: state is internal';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_refund_asks', 'SELECT'), 'A6: table via RPCs only';
END $$;

\echo 'test_refund_asks: all passed'
ROLLBACK;
