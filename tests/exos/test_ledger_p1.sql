-- ============================================================================
-- Ledger P1 fixes (mig 20261021160000; usage simulation 2026-10-19 round 2).
--   L1 exos_order_money: card fee charged (gross - Exos fee - card fee = net),
--      Stripe's fee kept apart; refunds that kept the application fee
--   L2 exos_record_payment_fee_currency: fee currency + rate, service only
--   L3 POS settlement: the Exos fee at each sale's time (sim s9_pos.sql)
--   L4 lost dispute: nothing left to refund (preview, list, claim)
--   L5 refund asks after an order-level partial: the ask amount is re-read and
--      the per-ticket refund is capped at what's left (sim s11)
--   L6 dispute status never moves backwards (sim s4)
-- Self-contained ids 1f…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- Prod's grant (mig 20260523170000, not in this chain), as test_checkout_records does.
REVOKE ALL ON public.exos_checkout_sessions FROM anon, authenticated;
GRANT SELECT ON public.exos_checkout_sessions TO authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('1f000000-0000-0000-0000-0000000000a1','lpown@x.com',now()),
  ('1f000000-0000-0000-0000-0000000000b1','lpb1@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('1f000000-0000-0000-0000-000000000001','LP Org','lp-org-stub','1f000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000a1','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,timezone,total_tickets,tickets_sold,created_by,refund_policy) VALUES
  ('1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','LP One','lp-one','published',now() + interval '10 days','America/New_York',100,6,'1f000000-0000-0000-0000-0000000000a1','until_7d');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('1f000000-0000-0000-0000-0000000000d1','1f000000-0000-0000-0000-0000000000e1','GA',45,100,6,'public');
-- lp1: 2 x 45.00 with the fee split (3% + card); lp2: 2 x 45.00, disputed; lp3: 2 x 45.00, asks.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,payment_intent,
                                          application_fee_cents,exos_fee_cents,card_fee_est_cents,fee_bps,fee_free,created_at) VALUES
  ('cs_lp1','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-0000000000d1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com',2,9000,'usd','fulfilled','pi_lp1',562,270,292,300,false,now() - interval '2 days'),
  ('cs_lp2','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-0000000000d1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com',2,9000,'usd','fulfilled','pi_lp2',562,270,292,300,false,now() - interval '2 days'),
  ('cs_lp3','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-0000000000d1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com',2,9000,'usd','fulfilled','pi_lp3',562,270,292,300,false,now() - interval '2 days');
SELECT public.exos_record_payment(s, 'pi_' || substr(s, 4), 9000, 'succeeded') FROM (VALUES ('cs_lp1'),('cs_lp2'),('cs_lp3')) v(s);
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source,created_at) VALUES
  ('1f000000-0000-0000-0000-000000000c11','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk11',45,'cs_lp1','stripe',now() - interval '2 days'),
  ('1f000000-0000-0000-0000-000000000c12','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk12',45,'cs_lp1','stripe',now() - interval '2 days' + interval '1 second'),
  ('1f000000-0000-0000-0000-000000000c21','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk21',45,'cs_lp2','stripe',now() - interval '2 days'),
  ('1f000000-0000-0000-0000-000000000c22','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk22',45,'cs_lp2','stripe',now() - interval '2 days' + interval '1 second'),
  ('1f000000-0000-0000-0000-000000000c31','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk31',45,'cs_lp3','stripe',now() - interval '2 days'),
  ('1f000000-0000-0000-0000-000000000c32','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000d1','GA','1f000000-0000-0000-0000-0000000000b1','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com','active','lk32',45,'cs_lp3','stripe',now() - interval '2 days' + interval '1 second');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;

-- L1 + L2 --------------------------------------------------------------------
DO $$
DECLARE m record; ok boolean;
BEGIN
  -- Stripe's actual fee differs from the estimate (an international card).
  ok := public.exos_record_payment_fees('pi_lp1', 'ch_lp1', 'txn_lp1', 371, 'fee_lp1', 562, 'tr_lp1', 191);
  ASSERT ok, 'L2: fees recorded';
  ASSERT public.exos_record_payment_fee_currency('pi_lp1', 'USD', NULL), 'L2: currency recorded';
  ASSERT NOT public.exos_record_payment_fee_currency('pi_lp_unknown', 'usd'), 'L2: unknown PaymentIntent reported as recorded';
  ASSERT public.exos_record_payment_fee_currency('pi_lp1', NULL, NULL), 'L2: NULLs accepted';
  ASSERT (SELECT stripe_fee_currency FROM public.exos_order_payments WHERE payment_intent = 'pi_lp1') = 'usd', 'L2: NULL erased the currency';
  BEGIN
    PERFORM public.exos_record_payment_fee_currency('pi_lp1', 'dollars');
    RAISE EXCEPTION 'L2: bad currency accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_record_payment_fee_currency('pi_lp1', 'usd', 0);
    RAISE EXCEPTION 'L2: zero rate accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_record_payment_fee_currency(text,text,numeric)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_record_payment_fee_currency(text,text,numeric)', 'EXECUTE')
     AND has_function_privilege('service_role', 'public.exos_record_payment_fee_currency(text,text,numeric)', 'EXECUTE'),
    'L2: grants';
  -- The 8-argument recorder is unchanged (stripe-webhook's call).
  ASSERT to_regprocedure('public.exos_record_payment_fees(text,text,text,int,text,int,text,int)') IS NOT NULL, 'L2: recorder signature changed';

  SELECT o.*, f.card_fee_charged_cents, f.stripe_fee_currency, f.refunded_fee_kept_cents INTO m
    FROM public.exos_order_money o JOIN public.exos_order_fee_details f ON f.session_id = o.session_id WHERE o.session_id = 'cs_lp1';
  ASSERT m.card_fee_charged_cents = 292, 'L1: card fee charged = application fee - Exos fee, got ' || m.card_fee_charged_cents;
  ASSERT m.gross_cents - m.exos_fee_cents - m.card_fee_charged_cents = m.organizer_net_cents, 'L1: gross - Exos fee - card fee <> net';
  ASSERT m.card_fee_actual_cents = 371 AND m.stripe_fee_currency = 'usd', 'L1: Stripe''s actual fee kept for the platform side';
  ASSERT m.refunded_fee_kept_cents = 0, 'L1: nothing refunded yet';
  RAISE NOTICE 'OK  L1/L2 card fee charged, fee currency recorder';
END $$;

-- L1 (G): a refund under EXOS_REFUND_KEEP_PLATFORM_FEE is counted apart.
DO $$
DECLARE c jsonb; m record;
BEGIN
  c := public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp1', 'nonce-lp1-keep', NULL, 2000, false, 'goodwill');
  UPDATE public.exos_refund_requests SET application_fee_refunded = false WHERE id = (c->>'request_id')::uuid;
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_lp1a', 'succeeded');
  c := public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp1', 'nonce-lp1-back', NULL, 1000, false, 'goodwill 2');
  UPDATE public.exos_refund_requests SET application_fee_refunded = true WHERE id = (c->>'request_id')::uuid;
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_lp1b', 'succeeded');
  SELECT o.*, f.card_fee_charged_cents, f.stripe_fee_currency, f.refunded_fee_kept_cents INTO m
    FROM public.exos_order_money o JOIN public.exos_order_fee_details f ON f.session_id = o.session_id WHERE o.session_id = 'cs_lp1';
  ASSERT m.refunded_cents = 3000, 'L1: refunded ' || m.refunded_cents;
  ASSERT m.refunded_fee_kept_cents = 2000, 'L1: refunds that kept the fee ' || m.refunded_fee_kept_cents;
  RAISE NOTICE 'OK  L1 refunds that kept the application fee';
END $$;

-- L1: exos_order_fee_details reads like exos_order_money (owner yes, buyer no, anon nothing).
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1f000000-0000-0000-0000-0000000000a1');
SELECT set_config('lp.own', (SELECT count(*) FROM public.exos_order_fee_details WHERE org_id = '1f000000-0000-0000-0000-000000000001')::text, true);
SELECT pg_temp.act('1f000000-0000-0000-0000-0000000000b1');
SELECT set_config('lp.buyer', (SELECT count(*) FROM public.exos_order_fee_details WHERE org_id = '1f000000-0000-0000-0000-000000000001')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('lp.own')::int = 3, 'L1: owner reads ' || current_setting('lp.own');
  ASSERT current_setting('lp.buyer')::int = 0, 'L1: the buyer reads the fee details';
  ASSERT NOT has_table_privilege('anon', 'public.exos_order_fee_details', 'SELECT'), 'L1: anon can read the fee details';
  RAISE NOTICE 'OK  L1 fee details access';
END $$;

-- L3 POS: the fee of a sale made inside the fee-free window stays 0 after it ends.
SELECT set_config('app.uid', '', true), set_config('app.jwt', '{"role":"service_role"}', true);
UPDATE public.exos_org_billing SET fee_free_until = now() + interval '30 days' WHERE org_id = '1f000000-0000-0000-0000-000000000001';
INSERT INTO public.exos_pos_items(id,org_id,event_id,category,name,price_cents,tier_id) VALUES
  ('1f000000-0000-0000-0000-000000000f41','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000e1','ticket','Door GA',4000,'1f000000-0000-0000-0000-0000000000d1');
INSERT INTO public.exos_pos_orders(id,event_id) VALUES ('1f000000-0000-0000-0000-000000000f42','1f000000-0000-0000-0000-0000000000e1');
INSERT INTO public.exos_pos_order_lines(order_id,item_id,category,name,quantity,unit_price_cents) VALUES
  ('1f000000-0000-0000-0000-000000000f42','1f000000-0000-0000-0000-000000000f41','ticket','x',5,1);
INSERT INTO public.exos_pos_payments(order_id,method,amount_cents,terminal_ref) VALUES ('1f000000-0000-0000-0000-000000000f42','card',20000,'pi_lppos1');
DO $$
DECLARE s1 jsonb; s2 jsonb; s3 jsonb;
BEGIN
  s1 := public.exos_pos_settlement_summary('1f000000-0000-0000-0000-0000000000e1');
  ASSERT (s1->>'orders')::int = 1 AND (s1->>'card_ticket_cents')::int > 0, 'L3: fixture ' || s1::text;
  ASSERT (s1->>'exos_fee_cents')::int = 0 AND (s1->>'fee_bps')::int = 0, 'L3: fee-free night ' || s1::text;
  -- The sale was 10 days ago; the window ended yesterday; finance looks again.
  UPDATE public.exos_pos_orders SET paid_at = now() - interval '10 days', created_at = now() - interval '10 days'
   WHERE id = '1f000000-0000-0000-0000-000000000f42';
  UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id = '1f000000-0000-0000-0000-000000000001';
  s2 := public.exos_pos_settlement_summary('1f000000-0000-0000-0000-0000000000e1');
  ASSERT (s2->>'exos_fee_cents')::int = 0, 'L3: fee recomputed at today''s rate ' || s2::text;
  ASSERT (s2->>'organizer_net_cents')::int = (s1->>'organizer_net_cents')::int, 'L3: net changed after the sale';
  ASSERT (s2->>'fee_bps')::int = 0 AND (s2->>'fee_bps_now')::int = 300, 'L3: rates ' || s2::text;
  -- A sale after the window pays the rate.
  UPDATE public.exos_pos_orders SET paid_at = now() - interval '1 hour', created_at = now() - interval '1 hour'
   WHERE id = '1f000000-0000-0000-0000-000000000f42';
  s3 := public.exos_pos_settlement_summary('1f000000-0000-0000-0000-0000000000e1');
  ASSERT (s3->>'exos_fee_cents')::int = ((s3->>'card_ticket_cents')::int * 300 + 5000) / 10000, 'L3: fee after the window ' || s3::text;
  RAISE NOTICE 'OK  L3 POS fee at sale time';
END $$;
SELECT set_config('app.jwt', '', true);

-- L4 lost dispute ------------------------------------------------------------
DO $$
DECLARE v text; p jsonb; n int;
BEGIN
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp2', p_dispute_id => 'du_lp2', p_status => 'needs_response',
    p_amount_cents => 9000, p_fee_cents => 1500, p_currency => 'usd');
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp2', p_dispute_id => 'du_lp2', p_status => 'lost',
    p_amount_cents => 9000, p_fee_cents => 1500, p_currency => 'usd');
  ASSERT v = 'lost', 'L4: lost ' || v;
  PERFORM public.exos_refund_checkout('cs_lp2', 'chargeback lost (fraudulent)');
  ASSERT public.exos_refund_lost_dispute_cents('cs_lp2') = 9000, 'L4: lost amount';
  ASSERT public.exos_refund_order_reserved('cs_lp2') = 9000, 'L4: lost dispute counts as returned';
  SELECT count(*) INTO n FROM public.exos_refund_event_orders_svc('1f000000-0000-0000-0000-0000000000a1', '1f000000-0000-0000-0000-0000000000e1')
   WHERE session_id = 'cs_lp2';
  ASSERT n = 0, 'L4: refund-everyone still lists the lost order';
  BEGIN
    PERFORM public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp2', 'nonce-lp2-all', NULL, NULL, true, NULL);
    RAISE EXCEPTION 'L4: claim on a lost dispute accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  L4 lost dispute: nothing left to refund (svc + claim)';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1f000000-0000-0000-0000-0000000000a1');
SELECT set_config('lp.p', public.exos_refund_preview('cs_lp2')::text, true);
RESET ROLE;
DO $$
DECLARE p jsonb := current_setting('lp.p')::jsonb;
BEGIN
  ASSERT (p->>'refundable_cents')::int = 0, 'L4: preview still refundable ' || p::text;
  ASSERT (p->>'lost_dispute_cents')::int = 9000, 'L4: preview lost amount ' || p::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p->'tickets') t WHERE (t->>'refundable_cents')::int > 0), 'L4: a ticket still refundable';
  RAISE NOTICE 'OK  L4 lost dispute: preview';
END $$;

-- L5 refund asks after an order-level partial (sim s11) ------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('1f000000-0000-0000-0000-0000000000b1');
SELECT public.exos_ask_refund(ARRAY['1f000000-0000-0000-0000-000000000c31','1f000000-0000-0000-0000-000000000c32']::uuid[], 'sick');
RESET ROLE;
DO $$
DECLARE c jsonb;
BEGIN
  -- The organizer first gives a 35.00 goodwill partial, not tied to tickets.
  c := public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp3', 'nonce-lp3-part', NULL, 3500, false, 'goodwill');
  PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_lp3a', 'succeeded');
END $$;
-- The organizer refunds each ask from the panel (items [ticket], no amount),
-- reading the list again after each refund as the panel does.
CREATE FUNCTION pg_temp.open_ask() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act('1f000000-0000-0000-0000-0000000000a1');
  SET LOCAL ROLE authenticated;
  SELECT to_jsonb(x) INTO r FROM public.exos_event_refund_asks('1f000000-0000-0000-0000-0000000000e1') x
   WHERE x.session_id = 'cs_lp3' AND x.status = 'open' ORDER BY x.ticket_id LIMIT 1;
  RESET ROLE;
  RETURN r;
END $$;
DO $$
DECLARE a jsonb; c jsonb; total int := 0; shown int[] := '{}'; got int[] := '{}';
BEGIN
  FOR i IN 1..2 LOOP
    a := pg_temp.open_ask();
    ASSERT a IS NOT NULL, 'L5: no open ask ' || i;
    shown := shown || (a->>'amount_cents')::int;
    c := public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp3', 'ask:' || (a->>'ask_id'),
           jsonb_build_array(jsonb_build_object('ticket_id', a->>'ticket_id')), NULL, false, 'Buyer asked: sick');
    got := got || (c->>'amount_cents')::int;
    total := total + (c->>'amount_cents')::int;
    PERFORM public.exos_refund_finalize((c->>'request_id')::uuid, 're_lp3_' || i, 'succeeded');
  END LOOP;
  ASSERT pg_temp.open_ask() IS NULL, 'L5: an ask is still open';
  ASSERT 3500 + total = 9000, 'L5: refunded ' || (3500 + total) || ' of 9000';
  ASSERT shown = got, format('L5: asks showed %s, refunded %s', shown, got);
  ASSERT got = ARRAY[4500, 1000], format('L5: refunded %s', got);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref = 'cs_lp3' AND status = 'voided') = 2, 'L5: tickets not voided';
  RAISE NOTICE 'OK  L5 refund asks re-read and capped at what''s left (% + %)', got[1], got[2];
END $$;

-- L5b: the amount the organizer is shown for an open ask is the current one.
DO $$
DECLARE st jsonb;
BEGIN
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_lp1';
  -- cs_lp1 has 30.00 refunded (L1), 60.00 left; a ticket's share is 45.00.
  st := public._exos_refund_ask_state('1f000000-0000-0000-0000-000000000c11');
  ASSERT (st->>'amount_cents')::int = 4500, 'L5b: ticket rest ' || st::text;
  PERFORM public.exos_refund_finalize((public.exos_refund_claim('1f000000-0000-0000-0000-0000000000a1', 'cs_lp1', 'nonce-lp1-more',
            NULL, 3000, false, 'more')->>'request_id')::uuid, 're_lp1c', 'succeeded');
  st := public._exos_refund_ask_state('1f000000-0000-0000-0000-000000000c11');
  ASSERT (st->>'amount_cents')::int = 3000, 'L5b: capped at the order''s 30.00 left ' || st::text;
  RAISE NOTICE 'OK  L5b ask amount re-read';
END $$;

-- L6 dispute status never moves backwards (sim s4) -----------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,currency,status,payment_intent,created_at) VALUES
  ('cs_lp6','1f000000-0000-0000-0000-0000000000e1','1f000000-0000-0000-0000-0000000000d1','1f000000-0000-0000-0000-000000000001','1f000000-0000-0000-0000-0000000000b1','lpb1@x.com',1,4500,'usd','fulfilled','pi_lp6',now() - interval '2 days');
SELECT public.exos_record_payment('cs_lp6', 'pi_lp6', 4500, 'succeeded');
DO $$
DECLARE v text;
BEGIN
  -- .updated (under_review) arrives before .created (needs_response).
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp6', p_dispute_id => 'du_lp6', p_status => 'under_review', p_amount_cents => 4500);
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp6', p_dispute_id => 'du_lp6', p_status => 'needs_response', p_amount_cents => 4500);
  ASSERT v = 'under_review', 'L6: stored status stepped back to ' || v;
  ASSERT (SELECT dispute_status FROM public.exos_checkout_sessions WHERE session_id = 'cs_lp6') = 'under_review', 'L6: session stepped back';
  ASSERT (SELECT status FROM public.exos_disputes WHERE dispute_id = 'du_lp6') = 'under_review', 'L6: dispute row stepped back';
  -- Forward still moves; closed stays closed.
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp6', p_dispute_id => 'du_lp6', p_status => 'won', p_amount_cents => 4500);
  v := public.exos_record_dispute_event(p_session_id => 'cs_lp6', p_dispute_id => 'du_lp6', p_status => 'under_review', p_amount_cents => 4500);
  ASSERT v = 'won' AND (SELECT status FROM public.exos_disputes WHERE dispute_id = 'du_lp6') = 'won', 'L6: closed dispute reopened';
  -- An inquiry escalating to a dispute is forward.
  ASSERT public._exos_dispute_rank('warning_under_review') < public._exos_dispute_rank('needs_response'), 'L6: rank order';
  ASSERT public._exos_dispute_rank('something_new') = 0, 'L6: unknown status rank';
  RAISE NOTICE 'OK  L6 dispute status never moves backwards';
END $$;

\echo test_ledger_p1: all passed
ROLLBACK;
