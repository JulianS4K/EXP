-- ============================================================================
-- PayPal / Venmo, Cash App opt-in and split with friends (mig 20261031220000).
-- Self-contained (ea prefix), rolled back.
--   Y1 schema, and who may call what (no client records a capture; anon
--      can't bulk-transfer or split)
--   Y2 processor-tagged ledger: a PayPal capture lands as provider 'paypal'
--      (ppcap_…) and fulfils; a Stripe payment stays 'stripe'
--   Y3 idempotent capture: replays add no row and no ticket; a late PENDING
--      never downgrades a succeeded payment
--   Y4 money that can't stand is flagged for refund: wrong amount, sold out at
--      fulfilment, session already expired; not once a refund is on file
--   Y5 the capture gate: no capture once the seat hold lapsed
--   Y6 a denied capture fails a pending order (holds back) and voids an
--      issued one
--   Y7 refund routing: an organizer refund on a PayPal order claims the
--      ppcap_ reference and records a 'paypal' refund row
--   Y8 owed to the org: application fee split on refunds, held on an open
--      dispute, nothing once lost; balances less hand payouts (idempotent)
--   Y9 payment-method opt-ins: owner / manager write, finance reads, others
--      nothing; the public view only shows published events
--   Y10 cross-org isolation on every new table and view
--   Y11 split with friends: shares + transfers + claim links, amounts capped,
--      only the host's tickets, on_paid sends on the tick, nudges counted,
--      nobody else reads or acts on it
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
ALTER TABLE public.exos_checkout_sessions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'exos_checkout_sel'
                   AND polrelid = 'public.exos_checkout_sessions'::regclass) THEN
    CREATE POLICY exos_checkout_sel ON public.exos_checkout_sessions FOR SELECT TO authenticated
      USING (buyer_uid = auth.uid() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
  END IF;
END $$;
REVOKE ALL ON public.exos_checkout_sessions FROM anon, authenticated;
GRANT SELECT ON public.exos_checkout_sessions TO authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ea000000-0000-0000-0000-0000000000a0','ea-owner@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000a1','ea-finance@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000a2','ea-scanner@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000a3','ea-manager@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000b0','ea-host@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000b1','ea-friend@x.com',now()),
  ('ea000000-0000-0000-0000-0000000000c0','ea-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ea000000-0000-0000-0000-000000000001','EA Org','ea-org','ea000000-0000-0000-0000-0000000000a0'),
  ('ea000000-0000-0000-0000-000000000002','EA Other','ea-other','ea000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000a0','owner',false),
  ('ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000a1','finance',false),
  ('ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000a2','scanner',false),
  ('ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000a3','manager',false),
  ('ea000000-0000-0000-0000-000000000002','ea000000-0000-0000-0000-0000000000c0','owner',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('ea000000-0000-0000-0000-0000000000e1','ea000000-0000-0000-0000-000000000001','EA Show','ea-show','published',now() + interval '10 days','Hall',0,0),
  ('ea000000-0000-0000-0000-0000000000e2','ea000000-0000-0000-0000-000000000001','EA Draft','ea-draft','draft',now() + interval '10 days','Hall',0,0),
  ('ea000000-0000-0000-0000-0000000000e3','ea000000-0000-0000-0000-000000000002','EA Other Show','ea-oshow','published',now() + interval '10 days','Hall',0,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('ea000000-0000-0000-0000-0000000000d1','ea000000-0000-0000-0000-0000000000e1','GA',20,50,0),
  ('ea000000-0000-0000-0000-0000000000d2','ea000000-0000-0000-0000-0000000000e1','Last one',20,1,1),
  ('ea000000-0000-0000-0000-0000000000d3','ea000000-0000-0000-0000-0000000000e3','GA',20,50,0);

-- A PayPal session as exos-checkout records it (4000 = 2 x 20.00; fee 120
-- Exos + 189 PayPal estimate = 309).
CREATE OR REPLACE FUNCTION pg_temp.pp_session(p_id text, p_order text, p_tier uuid, p_qty int,
                                              p_event uuid DEFAULT 'ea000000-0000-0000-0000-0000000000e1',
                                              p_org uuid DEFAULT 'ea000000-0000-0000-0000-000000000001') RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,
         amount_cents,currency,status,processor,paypal_order_id,
         application_fee_cents,exos_fee_cents,card_fee_est_cents,fee_bps,fee_free)
  VALUES (p_id,p_event,p_tier,p_org,'ea000000-0000-0000-0000-0000000000b0','ea-host@x.com',p_qty,
          2000*p_qty,'usd','pending','paypal',p_order,309,120,189,300,false);
$$;
CREATE OR REPLACE FUNCTION pg_temp.hold(p_session text, p_tier uuid, p_qty int, p_ttl interval) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_cart_holds(event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,status,checkout_session_id,expires_at)
  SELECT t.event_id, p_tier, e.org_id, 'ea000000-0000-0000-0000-0000000000b0', 'ea-host@x.com', p_qty, 'active', p_session, now() + p_ttl
    FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier;
$$;
CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text) TO PUBLIC;

-- Y1 -------------------------------------------------------------------------
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO missing FROM unnest(ARRAY[
    'exos_checkout_sessions.processor','exos_checkout_sessions.paypal_order_id','exos_checkout_sessions.payment_method',
    'exos_order_payments.processor_fee_cents','exos_order_payments.funding_source','exos_disputes.provider']) c
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = split_part(c, '.', 1)
                        AND column_name = split_part(c, '.', 2));
  ASSERT missing IS NULL, 'Y1: missing columns: ' || missing;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_paypal_record_capture(text,text,text,int,text,int,text,text)', 'EXECUTE'),
    'Y1: a client can record a capture';
  ASSERT NOT has_function_privilege('anon', 'public.exos_paypal_record_capture(text,text,text,int,text,int,text,text)', 'EXECUTE'),
    'Y1: anon can record a capture';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_paypal_capture_gate(text)', 'EXECUTE'), 'Y1: client can gate';
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_record_paypal_remittance(uuid,int,text,text,text,text,timestamptz,uuid)', 'EXECUTE'),
    'Y1: a client can record a hand payout';
  ASSERT NOT has_function_privilege('anon', 'public.exos_bulk_create_transfers(jsonb)', 'EXECUTE'), 'Y1: anon bulk transfer';
  ASSERT NOT has_function_privilege('anon', 'public.exos_split_save(text,jsonb,text,text,text,text)', 'EXECUTE'), 'Y1: anon split';
  ASSERT has_function_privilege('authenticated', 'public.exos_split_save(text,jsonb,text,text,text,text)', 'EXECUTE'), 'Y1: host can''t split';
  ASSERT NOT has_table_privilege('anon', 'public.exos_group_split_shares', 'SELECT'), 'Y1: anon reads shares';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_group_split_shares', 'INSERT'), 'Y1: client writes shares directly';
  ASSERT NOT has_table_privilege('anon', 'public.exos_paypal_org_balances', 'SELECT'), 'Y1: anon reads balances';
  ASSERT pg_temp.refused($q$UPDATE public.exos_checkout_sessions SET processor = 'venmo' WHERE false; INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,quantity,amount_cents,processor) VALUES ('ea-bad','ea000000-0000-0000-0000-0000000000e1','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000b0',1,100,'venmo')$q$),
    'Y1: unknown processor accepted';
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,quantity,amount_cents,paypal_order_id) VALUES ('ea-bad2','ea000000-0000-0000-0000-0000000000e1','ea000000-0000-0000-0000-000000000001','ea000000-0000-0000-0000-0000000000b0',1,100,'5O190127TN364715T')$q$),
    'Y1: a PayPal order id on a Stripe session accepted';
  RAISE NOTICE 'OK  Y1 columns exist; captures, gates and hand payouts are service-only; splits need an account';
END $$;

-- Y2 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; p record;
BEGIN
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000001','EAORDER00000001','ea000000-0000-0000-0000-0000000000d1',2);
  PERFORM pg_temp.hold('pp_ea0000000000000000000000000001','ea000000-0000-0000-0000-0000000000d1',2,'30 minutes');
  r := public.exos_paypal_capture_gate('EAORDER00000001');
  ASSERT (r ->> 'ok')::boolean, 'Y2: live hold refused at the gate: ' || r::text;
  r := public.exos_paypal_record_capture('EAORDER00000001','EACAPTURE000001','COMPLETED',4000,'USD',146,'venmo','WH-EA-1');
  ASSERT r ->> 'session_status' = 'fulfilled' AND (r ->> 'tickets')::int = 2 AND NOT (r ->> 'needs_refund')::boolean,
    'Y2: capture didn''t fulfil: ' || r::text;
  SELECT * INTO p FROM public.exos_order_payments WHERE session_id = 'pp_ea0000000000000000000000000001';
  ASSERT p.provider = 'paypal' AND p.payment_intent = 'ppcap_EACAPTURE000001' AND p.status = 'succeeded'
     AND p.amount_cents = 4000 AND p.processor_fee_cents = 146 AND p.net_cents = 309 - 146 AND p.funding_source = 'venmo',
    'Y2: payment row wrong: ' || row_to_json(p)::text;
  ASSERT (SELECT payment_method FROM public.exos_checkout_sessions WHERE session_id = 'pp_ea0000000000000000000000000001') = 'venmo',
    'Y2: session payment method';
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE checkout_session_id = 'pp_ea0000000000000000000000000001') = 'consumed',
    'Y2: hold not consumed';
  -- A Stripe session through the same recorder is still 'stripe'.
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
  VALUES ('cs_test_ea1','ea000000-0000-0000-0000-0000000000e1','ea000000-0000-0000-0000-0000000000d1','ea000000-0000-0000-0000-000000000001',
          'ea000000-0000-0000-0000-0000000000b0','ea-host@x.com',1,2000,'fulfilled');
  PERFORM public.exos_record_payment('cs_test_ea1','pi_ea1',2000,'succeeded');
  PERFORM public.exos_record_refund('cs_test_ea1','re_ea1',500,'succeeded','pi_ea1');
  ASSERT (SELECT provider FROM public.exos_order_payments WHERE payment_intent = 'pi_ea1') = 'stripe', 'Y2: Stripe payment mis-tagged';
  ASSERT (SELECT provider FROM public.exos_order_refunds WHERE refund_id = 're_ea1') = 'stripe', 'Y2: Stripe refund mis-tagged';
  ASSERT (SELECT card_fee_actual_cents FROM public.exos_order_money WHERE session_id = 'pp_ea0000000000000000000000000001') = 146,
    'Y2: exos_order_money doesn''t show the PayPal fee';
  RAISE NOTICE 'OK  Y2 a PayPal capture lands as a paypal ledger row and fulfils; Stripe rows stay stripe';
END $$;

-- Y3 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb; n int; v_sold int;
BEGIN
  SELECT t.sold INTO v_sold FROM public.exos_ticket_tiers t WHERE id = 'ea000000-0000-0000-0000-0000000000d1';
  r := public.exos_paypal_record_capture('EAORDER00000001','EACAPTURE000001','COMPLETED',4000,'usd',146,'venmo','WH-EA-1b');
  r := public.exos_paypal_record_capture('EAORDER00000001','EACAPTURE000001','PENDING',4000,'usd',NULL,NULL,'WH-EA-late');
  SELECT count(*) INTO n FROM public.exos_order_payments WHERE session_id = 'pp_ea0000000000000000000000000001';
  ASSERT n = 1, 'Y3: replay added a payment row';
  ASSERT (SELECT status FROM public.exos_order_payments WHERE payment_intent = 'ppcap_EACAPTURE000001') = 'succeeded',
    'Y3: late PENDING downgraded the payment';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'pp_ea0000000000000000000000000001') = 2, 'Y3: replay minted again';
  ASSERT (SELECT t.sold FROM public.exos_ticket_tiers t WHERE t.id = 'ea000000-0000-0000-0000-0000000000d1') = v_sold, 'Y3: replay moved sold';
  ASSERT r ->> 'payment_status' = 'succeeded' AND r ->> 'session_status' = 'fulfilled', 'Y3: replay result ' || r::text;
  -- PENDING first, then COMPLETED: no tickets until COMPLETED.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000002','EAORDER00000002','ea000000-0000-0000-0000-0000000000d1',1);
  r := public.exos_paypal_record_capture('EAORDER00000002','EACAPTURE000002','PENDING',2000,'usd');
  ASSERT r ->> 'session_status' = 'pending' AND r ->> 'payment_status' = 'processing' AND (r ->> 'tickets')::int = 0,
    'Y3: PENDING issued tickets: ' || r::text;
  r := public.exos_paypal_record_capture('EAORDER00000002','EACAPTURE000002','COMPLETED',2000,'usd',88,'paypal');
  ASSERT r ->> 'session_status' = 'fulfilled' AND (r ->> 'tickets')::int = 1, 'Y3: COMPLETED after PENDING: ' || r::text;
  ASSERT pg_temp.refused($q$SELECT public.exos_paypal_record_capture('NOSUCHORDER01','EACAPTURE000099','COMPLETED',100,'usd')$q$),
    'Y3: unknown order accepted';
  ASSERT pg_temp.refused($q$SELECT public.exos_paypal_record_capture('EAORDER00000002','bad id!','COMPLETED',100,'usd')$q$),
    'Y3: malformed capture id accepted';
  ASSERT pg_temp.refused($q$SELECT public.exos_paypal_record_capture('EAORDER00000002','EACAPTURE000002','VOIDED',100,'usd')$q$),
    'Y3: unknown capture status accepted';
  RAISE NOTICE 'OK  Y3 captures are idempotent; PENDING never issues tickets or downgrades';
END $$;

-- Y4 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  -- Wrong amount: never fulfilled, refund flagged, hold released.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000003','EAORDER00000003','ea000000-0000-0000-0000-0000000000d1',1);
  PERFORM pg_temp.hold('pp_ea0000000000000000000000000003','ea000000-0000-0000-0000-0000000000d1',1,'30 minutes');
  r := public.exos_paypal_record_capture('EAORDER00000003','EACAPTURE000003','COMPLETED',1999,'usd');
  ASSERT r ->> 'session_status' = 'failed' AND (r ->> 'needs_refund')::boolean AND (r ->> 'tickets')::int = 0,
    'Y4: wrong amount fulfilled: ' || r::text;
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE checkout_session_id = 'pp_ea0000000000000000000000000003') = 'released',
    'Y4: wrong-amount hold kept';
  -- Wrong currency too.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000004','EAORDER00000004','ea000000-0000-0000-0000-0000000000d1',1);
  r := public.exos_paypal_record_capture('EAORDER00000004','EACAPTURE000004','COMPLETED',2000,'eur');
  ASSERT (r ->> 'needs_refund')::boolean, 'Y4: wrong currency not flagged';
  -- Sold out at fulfilment.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000005','EAORDER00000005','ea000000-0000-0000-0000-0000000000d2',1);
  r := public.exos_paypal_record_capture('EAORDER00000005','EACAPTURE000005','COMPLETED',2000,'usd');
  ASSERT r ->> 'session_status' = 'failed' AND (r ->> 'needs_refund')::boolean, 'Y4: sold-out not flagged: ' || r::text;
  -- Once the auto-refund is on file, a replay doesn't ask again.
  PERFORM public.exos_record_refund('pp_ea0000000000000000000000000005','pprf_EAREFUND000005',2000,'succeeded','ppcap_EACAPTURE000005','auto-refund');
  r := public.exos_paypal_record_capture('EAORDER00000005','EACAPTURE000005','COMPLETED',2000,'usd');
  ASSERT NOT (r ->> 'needs_refund')::boolean, 'Y4: refund asked twice';
  ASSERT (SELECT provider FROM public.exos_order_refunds WHERE refund_id = 'pprf_EAREFUND000005') = 'paypal', 'Y4: refund mis-tagged';
  -- Paid after the session expired.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000006','EAORDER00000006','ea000000-0000-0000-0000-0000000000d1',1);
  UPDATE public.exos_checkout_sessions SET status = 'expired' WHERE session_id = 'pp_ea0000000000000000000000000006';
  r := public.exos_paypal_record_capture('EAORDER00000006','EACAPTURE000006','COMPLETED',2000,'usd');
  ASSERT r ->> 'session_status' = 'expired' AND (r ->> 'needs_refund')::boolean, 'Y4: paid-after-expiry not flagged: ' || r::text;
  RAISE NOTICE 'OK  Y4 wrong amount / currency, sold out and paid-after-expiry are flagged for one refund';
END $$;

-- Y5 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000007','EAORDER00000007','ea000000-0000-0000-0000-0000000000d1',1);
  PERFORM pg_temp.hold('pp_ea0000000000000000000000000007','ea000000-0000-0000-0000-0000000000d1',1,'-1 minute');
  r := public.exos_paypal_capture_gate('EAORDER00000007');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'hold_expired', 'Y5: lapsed hold passed the gate: ' || r::text;
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'pp_ea0000000000000000000000000007') = 'expired',
    'Y5: session not expired';
  r := public.exos_paypal_capture_gate('EAORDER00000001');
  ASSERT NOT (r ->> 'ok')::boolean AND r ->> 'reason' = 'not_pending', 'Y5: fulfilled order passed the gate';
  ASSERT pg_temp.refused($q$SELECT public.exos_paypal_capture_gate('NOSUCHORDER01')$q$), 'Y5: unknown order passed';
  RAISE NOTICE 'OK  Y5 no capture after the seat hold lapsed';
END $$;

-- Y6 -------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000008','EAORDER00000008','ea000000-0000-0000-0000-0000000000d1',1);
  PERFORM pg_temp.hold('pp_ea0000000000000000000000000008','ea000000-0000-0000-0000-0000000000d1',1,'30 minutes');
  r := public.exos_paypal_record_capture('EAORDER00000008','EACAPTURE000008','DECLINED',2000,'usd');
  ASSERT r ->> 'session_status' = 'failed' AND r ->> 'payment_status' = 'failed' AND NOT (r ->> 'needs_refund')::boolean,
    'Y6: declined: ' || r::text;
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE checkout_session_id = 'pp_ea0000000000000000000000000008') = 'released',
    'Y6: declined hold kept';
  -- Denied after it was issued (EAORDER00000002 is fulfilled): tickets voided.
  r := public.exos_paypal_record_capture('EAORDER00000002','EACAPTURE000002','DENIED',2000,'usd');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'pp_ea0000000000000000000000000002' AND status = 'active'),
    'Y6: denied capture left valid tickets';
  RAISE NOTICE 'OK  Y6 a denied capture fails the order or voids what was issued';
END $$;

-- Y7 -------------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb;
BEGIN
  c := public.exos_refund_claim('ea000000-0000-0000-0000-0000000000a1','pp_ea0000000000000000000000000001','nonce-ea-y7-part',
                                NULL, 1000, false, 'partial', NULL);
  ASSERT c ->> 'payment_intent' = 'ppcap_EACAPTURE000001', 'Y7: claim doesn''t carry the PayPal capture: ' || c::text;
  f := public.exos_refund_finalize((c ->> 'request_id')::uuid, 'pprf_EAREFUND000001', 'succeeded', NULL);
  ASSERT (SELECT provider FROM public.exos_order_refunds WHERE refund_id = 'pprf_EAREFUND000001') = 'paypal',
    'Y7: organizer refund not a paypal row';
  ASSERT (SELECT payment_id FROM public.exos_order_refunds WHERE refund_id = 'pprf_EAREFUND000001')
       = (SELECT id FROM public.exos_order_payments WHERE payment_intent = 'ppcap_EACAPTURE000001'),
    'Y7: refund not linked to its PayPal payment';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'pp_ea0000000000000000000000000001') = 'partially_refunded',
    'Y7: session not partially refunded';
  RAISE NOTICE 'OK  Y7 organizer refunds on PayPal orders route by the ppcap_ reference and land as paypal rows';
END $$;

-- Y8 -------------------------------------------------------------------------
DO $$
DECLARE o record; b record; rid uuid; rid2 uuid;
BEGIN
  -- Order 1: 4000 gross, fee 309, 1000 refunded -> 3691 - (1000 - round(309*1000/4000)=77) = 2768.
  SELECT * INTO o FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000001';
  ASSERT o.owed_cents = 2768 AND o.state = 'owed' AND o.refunded_cents = 1000, 'Y8: owed wrong: ' || row_to_json(o)::text;
  -- A failed order with its money refunded owes nothing.
  ASSERT (SELECT owed_cents FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000005') = 0,
    'Y8: refunded sold-out order owes something';
  -- An open dispute holds the order; a lost one owes nothing.
  PERFORM public.exos_record_dispute_event('pp_ea0000000000000000000000000001','ppdsp_PPD000EA1','needs_response','merchandise',4000,
                                           'WH-EA-D1',NULL,'ppcap_EACAPTURE000001');
  ASSERT (SELECT provider FROM public.exos_disputes WHERE dispute_id = 'ppdsp_PPD000EA1') = 'paypal', 'Y8: dispute mis-tagged';
  SELECT * INTO o FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000001';
  ASSERT o.state = 'held' AND o.owed_cents = 0 AND o.held_cents = 2768, 'Y8: open dispute not held: ' || row_to_json(o)::text;
  PERFORM public.exos_record_dispute_event('pp_ea0000000000000000000000000001','ppdsp_PPD000EA1','won');
  ASSERT (SELECT owed_cents FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000001') = 2768,
    'Y8: won dispute not owed again';
  -- Hand payouts: idempotent on reference, subtracted from the balance.
  rid := public.exos_record_paypal_remittance('ea000000-0000-0000-0000-000000000001', 1000, 'PAYOUT-EA-1');
  rid2 := public.exos_record_paypal_remittance('ea000000-0000-0000-0000-000000000001', 1000, 'PAYOUT-EA-1', 'usd', 'manual', 'again');
  ASSERT rid = rid2, 'Y8: a hand payout recorded twice';
  SELECT * INTO b FROM public.exos_paypal_org_balances WHERE org_id = 'ea000000-0000-0000-0000-000000000001' AND currency = 'usd';
  ASSERT b.remitted_cents = 1000 AND b.balance_cents = b.owed_cents - 1000 AND b.owed_cents >= 2768,
    'Y8: balance wrong: ' || row_to_json(b)::text;
  ASSERT pg_temp.refused($q$SELECT public.exos_record_paypal_remittance('ea000000-0000-0000-0000-000000000001', 0, 'PAYOUT-EA-0')$q$),
    'Y8: zero payout accepted';
  -- Lost: nothing owed.
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000009','EAORDER00000009','ea000000-0000-0000-0000-0000000000d1',1);
  PERFORM public.exos_paypal_record_capture('EAORDER00000009','EACAPTURE000009','COMPLETED',2000,'usd',88,'paypal');
  PERFORM public.exos_record_dispute_event('pp_ea0000000000000000000000000009','ppdsp_PPD000EA9','lost');
  SELECT * INTO o FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000009';
  ASSERT o.state = 'lost' AND o.owed_cents = 0 AND o.held_cents = 0, 'Y8: lost dispute still owed: ' || row_to_json(o)::text;
  RAISE NOTICE 'OK  Y8 owed = net of refunds (fee share back), held while disputed, 0 once lost; balances less hand payouts';
END $$;

-- Y9 + Y10 -------------------------------------------------------------------
-- Org two has a PayPal order too, for isolation.
DO $$
BEGIN
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000010','EAORDER00000010','ea000000-0000-0000-0000-0000000000d3',1,
                             'ea000000-0000-0000-0000-0000000000e3','ea000000-0000-0000-0000-000000000002');
  PERFORM public.exos_paypal_record_capture('EAORDER00000010','EACAPTURE000010','COMPLETED',2000,'usd',88,'paypal');
  PERFORM public.exos_record_paypal_remittance('ea000000-0000-0000-0000-000000000002', 500, 'PAYOUT-EA-2');
END $$;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000a0', true);  -- owner
DO $$
BEGIN
  INSERT INTO public.exos_org_payment_methods(org_id, paypal_enabled, cashapp_enabled)
  VALUES ('ea000000-0000-0000-0000-000000000001', true, true);
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_org_payment_methods(org_id, paypal_enabled) VALUES ('ea000000-0000-0000-0000-000000000002', true)$q$),
    'Y10: owner switched on PayPal for another org';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_order_owed WHERE org_id = 'ea000000-0000-0000-0000-000000000002'), 'Y10: owner sees other org owed';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_org_balances WHERE org_id = 'ea000000-0000-0000-0000-000000000002'), 'Y10: other org balance';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_org_remittances WHERE org_id = 'ea000000-0000-0000-0000-000000000002'), 'Y10: other org payouts';
  ASSERT EXISTS (SELECT 1 FROM public.exos_paypal_org_balances WHERE org_id = 'ea000000-0000-0000-0000-000000000001'), 'Y9: owner can''t read own balance';
END $$;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000a3', true);  -- manager
DO $$
BEGIN
  UPDATE public.exos_org_payment_methods SET cashapp_enabled = false WHERE org_id = 'ea000000-0000-0000-0000-000000000001';
  ASSERT NOT (SELECT cashapp_enabled FROM public.exos_org_payment_methods WHERE org_id = 'ea000000-0000-0000-0000-000000000001'),
    'Y9: manager can''t switch Cash App';
END $$;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000a1', true);  -- finance
DO $$
DECLARE n int;
BEGIN
  ASSERT (SELECT paypal_enabled FROM public.exos_org_payment_methods WHERE org_id = 'ea000000-0000-0000-0000-000000000001'),
    'Y9: finance can''t read the switches';
  UPDATE public.exos_org_payment_methods SET paypal_enabled = false WHERE org_id = 'ea000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Y9: finance switched PayPal off';
  ASSERT EXISTS (SELECT 1 FROM public.exos_paypal_order_owed WHERE session_id = 'pp_ea0000000000000000000000000001'), 'Y9: finance can''t read owed';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_order_owed WHERE org_id = 'ea000000-0000-0000-0000-000000000002'), 'Y10: finance sees other org';
END $$;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000a2', true);  -- scanner
DO $$
DECLARE n int;
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_payment_methods), 'Y10: scanner reads payment switches';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_order_owed), 'Y10: scanner reads owed';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_org_balances), 'Y10: scanner reads balances';
  UPDATE public.exos_org_payment_methods SET paypal_enabled = false;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Y10: scanner wrote';
END $$;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000c0', true);  -- other org owner
DO $$
DECLARE n int;
BEGIN
  UPDATE public.exos_org_payment_methods SET paypal_enabled = false WHERE org_id = 'ea000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Y10: other org owner switched PayPal off';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_paypal_order_owed WHERE org_id = 'ea000000-0000-0000-0000-000000000001'), 'Y10: other org reads owed';
  ASSERT EXISTS (SELECT 1 FROM public.exos_paypal_org_balances WHERE org_id = 'ea000000-0000-0000-0000-000000000002'), 'Y9: other owner can''t read own';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT (SELECT paypal FROM public.exos_public_payment_methods WHERE event_id = 'ea000000-0000-0000-0000-0000000000e1'),
    'Y9: public view doesn''t show PayPal';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_public_payment_methods WHERE event_id = 'ea000000-0000-0000-0000-0000000000e2'),
    'Y9: public view shows a draft event';
  ASSERT NOT (SELECT paypal FROM public.exos_public_payment_methods WHERE event_id = 'ea000000-0000-0000-0000-0000000000e3'),
    'Y9: opted-out org shows PayPal';
  ASSERT pg_temp.refused('SELECT * FROM public.exos_org_payment_methods'), 'Y10: anon reads the switches';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  Y9 payment-method opt-ins: owner / manager write, finance reads, public view published-only'; END $$;
DO $$ BEGIN RAISE NOTICE 'OK  Y10 other orgs, scanners and anon see none of the payment switches, owed or balances'; END $$;

-- Y11 ------------------------------------------------------------------------
-- The host's order: 3 tickets, 6000.
DO $$
BEGIN
  PERFORM pg_temp.pp_session('pp_ea0000000000000000000000000011','EAORDER00000011','ea000000-0000-0000-0000-0000000000d1',3);
  PERFORM public.exos_paypal_record_capture('EAORDER00000011','EACAPTURE000011','COMPLETED',6000,'usd',88,'venmo');
END $$;
CREATE TEMP TABLE ea_tix ON COMMIT DROP AS
  SELECT id, row_number() OVER (ORDER BY created_at, id) AS n FROM public.exos_tickets
   WHERE order_ref = 'pp_ea0000000000000000000000000011';
GRANT SELECT ON ea_tix TO PUBLIC;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000b0', true);
SELECT set_config('app.jwt', '{"email":"ea-host@x.com"}', true);
DO $$
DECLARE r jsonb; t1 uuid; t2 uuid; t3 uuid; sh jsonb;
BEGIN
  SELECT id INTO t1 FROM ea_tix WHERE n = 1;
  SELECT id INTO t2 FROM ea_tix WHERE n = 2;
  SELECT id INTO t3 FROM ea_tix WHERE n = 3;
  -- More than the order: refused, nothing kept.
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"%s","name":"Ann","email":"ann@x.com","amount_cents":4000},{"ticket_id":"%s","name":"Bo","email":"bo@x.com","amount_cents":2500}]',
      'host_venmo')$q$, t1, t2)), 'Y11: shares above the order accepted';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"%s","name":"Ann","email":"ann@x.com","amount_cents":2000}]')$q$, t1)), 'Y11: split with no Venmo or Cash App accepted';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"%s","name":"Ann","email":"not-an-email","amount_cents":2000}]','host_venmo')$q$, t1)), 'Y11: bad email accepted';
  ASSERT pg_temp.refused($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"ea000000-0000-0000-0000-00000000ffff","name":"Ann","email":"ann@x.com","amount_cents":2000}]','host_venmo')$q$),
    'Y11: a ticket not in the order accepted';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_split_shares), 'Y11: a refused split left rows';
  -- Two friends, sent now: each gets a transfer and a claim link.
  r := public.exos_split_save('pp_ea0000000000000000000000000011',
         format('[{"ticket_id":"%s","name":"Ann","email":"Ann@X.com","phone":"+1 (212) 555-0100","amount_cents":2000},
                  {"ticket_id":"%s","name":"Bo","email":"bo@x.com","amount_cents":2000}]', t1, t2)::jsonb,
         '@host_venmo', '$hostcash', 'now', 'EA Show tickets');
  ASSERT jsonb_array_length(r -> 'shares') = 2, 'Y11: shares not saved: ' || r::text;
  sh := (SELECT x FROM jsonb_array_elements(r -> 'shares') x WHERE x ->> 'name' = 'Ann');
  ASSERT sh ->> 'email' = 'ann@x.com' AND sh ->> 'phone' = '+12125550100' AND sh ->> 'transfer_status' = 'pending'
     AND sh ->> 'claim_path' LIKE '/claim/%?k=%', 'Y11: share 1: ' || sh::text;
  ASSERT r -> 'split' ->> 'venmo_handle' = 'host_venmo' AND r -> 'split' ->> 'cashapp_tag' = 'hostcash', 'Y11: handles: ' || r::text;
  ASSERT (SELECT (x ->> 'pending_transfer')::boolean FROM jsonb_array_elements(r -> 'tickets') x WHERE (x ->> 'ticket_id')::uuid = t1),
    'Y11: ticket not in transfer';
  -- The same ticket again: refused (in transfer / already shared).
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"%s","name":"Cy","email":"cy@x.com","amount_cents":10}]')$q$, t1)), 'Y11: a ticket shared twice';
  -- Ticking paid and nudging.
  PERFORM public.exos_split_mark_paid((sh ->> 'id')::uuid, true);
  ASSERT (SELECT paid FROM public.exos_group_split_shares WHERE id = (sh ->> 'id')::uuid), 'Y11: paid tick lost';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_nudged('%s')$q$, sh ->> 'id')), 'Y11: nudged a friend who paid';
  ASSERT public.exos_split_nudged((SELECT (x ->> 'id')::uuid FROM jsonb_array_elements(r -> 'shares') x WHERE x ->> 'name' = 'Bo')) = 1, 'Y11: nudge not counted';
  -- on_paid: the third friend's ticket waits for the tick.
  r := public.exos_split_save('pp_ea0000000000000000000000000011',
         format('[{"ticket_id":"%s","name":"Cy","email":"cy@x.com","amount_cents":1500}]', t3)::jsonb, NULL, NULL, 'on_paid');
  sh := (SELECT x FROM jsonb_array_elements(r -> 'shares') x WHERE x ->> 'name' = 'Cy');
  ASSERT sh ->> 'transfer_id' IS NULL
     AND NOT (SELECT (x ->> 'pending_transfer')::boolean FROM jsonb_array_elements(r -> 'tickets') x WHERE (x ->> 'ticket_id')::uuid = t3),
    'Y11: on_paid sent before the tick: ' || sh::text;
  r := public.exos_split_mark_paid((sh ->> 'id')::uuid, true);
  sh := (SELECT x FROM jsonb_array_elements(r -> 'shares') x WHERE x ->> 'name' = 'Cy');
  ASSERT sh ->> 'transfer_status' = 'pending' AND sh ->> 'claim_path' IS NOT NULL, 'Y11: tick didn''t send: ' || sh::text;
END $$;
RESET ROLE;
CREATE TEMP TABLE ea_share ON COMMIT DROP AS SELECT id FROM public.exos_group_split_shares WHERE NOT paid LIMIT 1;
GRANT SELECT ON ea_share TO PUBLIC;
-- Anyone else: nothing.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000a0', true);  -- the org's owner
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_split_shares), 'Y11: org owner reads friends'' contacts';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_splits), 'Y11: org owner reads the split';
  ASSERT pg_temp.refused($q$SELECT public.exos_split_get('pp_ea0000000000000000000000000011')$q$), 'Y11: org owner gets the split';
END $$;
SELECT set_config('app.uid', 'ea000000-0000-0000-0000-0000000000b1', true);  -- a friend
DO $$
DECLARE sid uuid := (SELECT id FROM ea_share);
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_split_shares), 'Y11: a friend reads the shares';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_mark_paid('%s', true)$q$, sid)), 'Y11: a friend ticked paid';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_nudged('%s')$q$, sid)), 'Y11: a friend nudged';
  ASSERT pg_temp.refused(format($q$SELECT public.exos_split_save('pp_ea0000000000000000000000000011',
      '[{"ticket_id":"%s","name":"Me","email":"ea-friend@x.com","amount_cents":0}]','x_venmo')$q$, (SELECT id FROM ea_tix WHERE n = 1))),
    'Y11: a friend split the order';
  ASSERT pg_temp.refused($q$SELECT public.exos_split_get('pp_ea0000000000000000000000000011')$q$), 'Y11: a friend gets the split';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  Y11 split with friends: transfers + claim links, amounts capped, host-only, on_paid waits for the tick'; END $$;
ROLLBACK;
