-- ============================================================================
-- Marketplace payout ledger (mig 20260929070000). Self-contained (8d prefix),
-- rolled back.
--   P1 an order isn't payable until tickets are delivered AND a CONFIRMED
--      remittance covers its proceeds (reported-only money doesn't count)
--   P2 planning makes one payout per org of organizer_net; one open payout
--      per org; an order is paid once
--   P3 payout state machine: planned -> sending -> sent (needs a transfer id);
--      failed -> planned; cancel frees the orders
--   P4 a marketplace cancellation after payout is clawed back from the next
--      payout; a negative balance carries forward (no payout)
--   P5 organizers read only their own payouts; remittances are service-only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('8d000000-0000-0000-0000-0000000000a0','8d-owner@x.com',now()),
  ('8d000000-0000-0000-0000-0000000000a1','8d-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('8d000000-0000-0000-0000-000000000001','8D Org','8d-org','8d000000-0000-0000-0000-0000000000a0'),
  ('8d000000-0000-0000-0000-000000000002','8D Other','8d-other','8d000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('8d000000-0000-0000-0000-000000000001','8d000000-0000-0000-0000-0000000000a0','owner',false),
  ('8d000000-0000-0000-0000-000000000002','8d000000-0000-0000-0000-0000000000a1','owner',false);
-- Past the free months: the 3% fee applies.
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day'
 WHERE org_id IN ('8d000000-0000-0000-0000-000000000001','8d000000-0000-0000-0000-000000000002');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('8d000000-0000-0000-0000-0000000000e1','8d000000-0000-0000-0000-000000000001','8D Show','published',now() - interval '10 days','Hall',100,0),
  ('8d000000-0000-0000-0000-0000000000e2','8d000000-0000-0000-0000-000000000002','8D Other Show','published',now() - interval '10 days','Hall',100,0);

-- Marketplace orders straight into the table (the sale path is tested elsewhere).
INSERT INTO public.exos_marketplace_orders(id,channel,external_order_id,event_id,org_id,quantity,proceeds,currency,sale_status,status) VALUES
  ('8d000000-0000-0000-0000-00000000f001','evo','8D-1','8d000000-0000-0000-0000-0000000000e1','8d000000-0000-0000-0000-000000000001',1,40.00,'usd','delivered','delivered'),
  ('8d000000-0000-0000-0000-00000000f002','evo','8D-2','8d000000-0000-0000-0000-0000000000e1','8d000000-0000-0000-0000-000000000001',2,80.00,'usd','delivered','delivered'),
  ('8d000000-0000-0000-0000-00000000f003','evo','8D-3','8d000000-0000-0000-0000-0000000000e1','8d000000-0000-0000-0000-000000000001',1,40.00,'usd','confirmed','received'),
  ('8d000000-0000-0000-0000-00000000f004','evo','8D-4','8d000000-0000-0000-0000-0000000000e2','8d000000-0000-0000-0000-000000000002',1,100.00,'usd','delivered','delivered');

CREATE OR REPLACE FUNCTION pg_temp.state(p text) RETURNS text LANGUAGE sql AS $$
  SELECT state FROM public.exos_marketplace_order_money WHERE external_order_id = p;
$$;

DO $$
DECLARE r jsonb; rid uuid; n int; p record; pid uuid;
BEGIN
  -- P1 -----------------------------------------------------------------------
  IF pg_temp.state('8D-1') <> 'awaiting_marketplace' OR pg_temp.state('8D-3') <> 'awaiting_delivery' THEN
    RAISE EXCEPTION 'P1 FAIL: start states % %', pg_temp.state('8D-1'), pg_temp.state('8D-3');
  END IF;
  r := public.exos_record_remittance(jsonb_build_object('channel','evo','external_id','evo-pay-1','amount',160,
         'source','marketplace_api','allocations', jsonb_build_array(
           jsonb_build_object('external_order_id','8D-1','amount',40),
           jsonb_build_object('external_order_id','8D-2','amount',80),
           jsonb_build_object('external_order_id','8D-3','amount',40),
           jsonb_build_object('external_order_id','NOPE','amount',1))));
  IF (r ->> 'allocated')::int <> 3 OR r -> 'unmatched' <> '["NOPE"]'::jsonb THEN RAISE EXCEPTION 'P1 FAIL: record %', r; END IF;
  IF pg_temp.state('8D-1') <> 'reported_unconfirmed' THEN RAISE EXCEPTION 'P1 FAIL: reported counted as paid (%)', pg_temp.state('8D-1'); END IF;
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts();
  IF n <> 0 THEN RAISE EXCEPTION 'P1 FAIL: paid out on unconfirmed money'; END IF;
  rid := (r ->> 'remittance_id')::uuid;
  PERFORM public.exos_confirm_remittance(rid, NULL);
  IF pg_temp.state('8D-1') <> 'payable' OR pg_temp.state('8D-2') <> 'payable' OR pg_temp.state('8D-3') <> 'awaiting_delivery' THEN
    RAISE EXCEPTION 'P1 FAIL: after confirm % % %', pg_temp.state('8D-1'), pg_temp.state('8D-2'), pg_temp.state('8D-3');
  END IF;
  -- A confirmed remittance can't be rewritten.
  r := public.exos_record_remittance(jsonb_build_object('channel','evo','external_id','evo-pay-1','amount',1,'source','manual'));
  IF (SELECT amount FROM public.exos_marketplace_remittances WHERE id = rid) <> 160 THEN RAISE EXCEPTION 'P1 FAIL: confirmed rewritten'; END IF;
  RAISE NOTICE 'P1 PASS: payable only when delivered and covered by confirmed money';

  -- P2 -----------------------------------------------------------------------
  -- 8D-1: 40 - 1.20 = 38.80; 8D-2: 80 - 2.40 = 77.60 -> 116.40 for org 1.
  SELECT * INTO p FROM public.exos_plan_org_payouts();
  IF p.org_id <> '8d000000-0000-0000-0000-000000000001' OR p.amount <> 116.40 OR p.sale_lines <> 2 OR p.currency <> 'USD' THEN
    RAISE EXCEPTION 'P2 FAIL: %', row_to_json(p);
  END IF;
  pid := p.payout_id;
  IF pg_temp.state('8D-1') <> 'in_payout' THEN RAISE EXCEPTION 'P2 FAIL: state %', pg_temp.state('8D-1'); END IF;
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts();
  IF n <> 0 THEN RAISE EXCEPTION 'P2 FAIL: second open payout / double pay'; END IF;
  RAISE NOTICE 'P2 PASS: one payout of organizer_net, one open per org, each order once';

  -- P3 -----------------------------------------------------------------------
  BEGIN
    PERFORM public.exos_mark_org_payout(pid, 'sent', 'tr_x');
    RAISE EXCEPTION 'P3 FAIL: skipped sending';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P3 FAIL%' THEN RAISE; END IF;
  END;
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  PERFORM public.exos_mark_org_payout(pid, 'failed', NULL, 'insufficient platform balance');
  PERFORM public.exos_mark_org_payout(pid, 'planned');
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  BEGIN
    PERFORM public.exos_mark_org_payout(pid, 'sent');
    RAISE EXCEPTION 'P3 FAIL: sent without a transfer id';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P3 FAIL%' THEN RAISE; END IF;
  END;
  PERFORM public.exos_mark_org_payout(pid, 'sent', 'tr_8d_1');
  IF pg_temp.state('8D-1') <> 'paid' OR (SELECT stripe_transfer_id FROM public.exos_org_payouts WHERE id = pid) <> 'tr_8d_1' THEN
    RAISE EXCEPTION 'P3 FAIL: sent state';
  END IF;
  IF public.exos_cancel_org_payout(pid) THEN RAISE EXCEPTION 'P3 FAIL: cancelled a sent payout'; END IF;
  RAISE NOTICE 'P3 PASS: planned -> sending -> sent, retry after failure, sent is final';

  -- P4 -----------------------------------------------------------------------
  -- The marketplace cancels 8D-2 after the organizer was paid 77.60.
  UPDATE public.exos_marketplace_orders SET status = 'cancelled', sale_status = 'cancelled' WHERE external_order_id = '8D-2';
  IF pg_temp.state('8D-2') <> 'clawback_due' THEN RAISE EXCEPTION 'P4 FAIL: state %', pg_temp.state('8D-2'); END IF;
  -- Nothing else payable: -77.60 carries forward, no payout.
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts();
  IF n <> 0 THEN RAISE EXCEPTION 'P4 FAIL: negative payout made'; END IF;
  -- 8D-3 delivered (covered by the confirmed remittance): 38.80 - 77.60 < 0, still nothing.
  UPDATE public.exos_marketplace_orders SET status = 'delivered' WHERE external_order_id = '8D-3';
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts();
  IF n <> 0 THEN RAISE EXCEPTION 'P4 FAIL: paid while the balance is negative'; END IF;
  -- A new 100.00 sale arrives and is paid: 97.00 + 38.80 - 77.60 = 58.20.
  INSERT INTO public.exos_marketplace_orders(id,channel,external_order_id,event_id,org_id,quantity,proceeds,currency,sale_status,status) VALUES
    ('8d000000-0000-0000-0000-00000000f005','evo','8D-5','8d000000-0000-0000-0000-0000000000e1','8d000000-0000-0000-0000-000000000001',1,100.00,'usd','delivered','delivered');
  r := public.exos_record_remittance(jsonb_build_object('channel','evo','external_id','evo-pay-2','amount',100,'source','statement',
         'allocations', jsonb_build_array(jsonb_build_object('external_order_id','8D-5','amount',100))));
  PERFORM public.exos_confirm_remittance((r ->> 'remittance_id')::uuid);
  SELECT * INTO p FROM public.exos_plan_org_payouts();
  IF p.amount <> 58.20 OR p.sale_lines <> 2 OR p.clawback_lines <> 1 THEN RAISE EXCEPTION 'P4 FAIL: %', row_to_json(p); END IF;
  IF pg_temp.state('8D-2') <> 'clawed_back' THEN RAISE EXCEPTION 'P4 FAIL: clawback state %', pg_temp.state('8D-2'); END IF;
  -- Cancelling the planned payout frees its orders and the clawback.
  IF NOT public.exos_cancel_org_payout(p.payout_id) THEN RAISE EXCEPTION 'P4 FAIL: cancel'; END IF;
  IF pg_temp.state('8D-5') <> 'payable' OR pg_temp.state('8D-2') <> 'clawback_due' THEN
    RAISE EXCEPTION 'P4 FAIL: after cancel % %', pg_temp.state('8D-5'), pg_temp.state('8D-2');
  END IF;
  RAISE NOTICE 'P4 PASS: clawbacks net against the next payout; negative balances carry';

  -- P5 -----------------------------------------------------------------------
  IF has_table_privilege('authenticated', 'public.exos_marketplace_remittances', 'SELECT')
     OR has_table_privilege('authenticated', 'public.exos_org_payouts', 'INSERT')
     OR has_function_privilege('authenticated', 'public.exos_plan_org_payouts(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_record_remittance(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.exos_mark_org_payout(uuid, text, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'P5 FAIL: app users can touch the books';
  END IF;
END $$;

-- P5: org scoping as a signed-in user.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', '8d000000-0000-0000-0000-0000000000a1', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exos_org_payouts WHERE org_id = '8d000000-0000-0000-0000-000000000001')
     OR EXISTS (SELECT 1 FROM public.exos_org_payout_lines WHERE org_id = '8d000000-0000-0000-0000-000000000001')
     OR EXISTS (SELECT 1 FROM public.exos_marketplace_order_money WHERE org_id = '8d000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'P5 FAIL: another org sees org 1''s payouts';
  END IF;
END $$;
SELECT set_config('app.uid', '8d000000-0000-0000-0000-0000000000a0', true);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_payouts WHERE org_id = '8d000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'P5 FAIL: the owner can''t see their payouts';
  END IF;
  RAISE NOTICE 'P5 PASS: organizers see only their own payouts; the books are service-only';
END $$;
RESET ROLE;
ROLLBACK;
