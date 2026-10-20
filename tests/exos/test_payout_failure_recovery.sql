-- ============================================================================
-- Payout failure recovery (mig 20261020120000). Self-contained (b5 prefix),
-- rolled back.
--   F1 a failed payout's orders are re-planned into a new payout (no
--      duplicate line), the failed one is cancelled with its error kept, and
--      another org planned in the same run isn't blocked
--   F2 a failed payout's clawback is re-planned too; the total is net of it
--   F3 one org's error is reported in the result and the others are planned
--   F4 'sending' can be re-claimed only once it's 15 minutes stale; the
--      idempotency key is unchanged; nothing is planned beside it
--   F5 the report RPC is service-only
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('b5000000-0000-0000-0000-0000000000a1','b5-one@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a2','b5-two@x.com',now()),
  ('b5000000-0000-0000-0000-0000000000a3','b5-three@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('b5000000-0000-0000-0000-000000000001','B5 One','b5-one','b5000000-0000-0000-0000-0000000000a1'),
  ('b5000000-0000-0000-0000-000000000002','B5 Two','b5-two','b5000000-0000-0000-0000-0000000000a2'),
  ('b5000000-0000-0000-0000-000000000003','B5 Three','b5-three','b5000000-0000-0000-0000-0000000000a3');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('b5000000-0000-0000-0000-0000000000e1','b5000000-0000-0000-0000-000000000001','B5 One Show','published',now() - interval '10 days','Hall',100,0),
  ('b5000000-0000-0000-0000-0000000000e2','b5000000-0000-0000-0000-000000000002','B5 Two Show','published',now() - interval '10 days','Hall',100,0),
  ('b5000000-0000-0000-0000-0000000000e3','b5000000-0000-0000-0000-000000000003','B5 Three Show','published',now() - interval '10 days','Hall',100,0);

-- Orders paid by the marketplace and confirmed (the sale path is tested elsewhere).
CREATE OR REPLACE FUNCTION pg_temp.sale(p_id text, p_org int, p_amt numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  INSERT INTO public.exos_marketplace_orders(channel,external_order_id,event_id,org_id,quantity,proceeds,currency,sale_status,status)
  VALUES ('evo', p_id, ('b5000000-0000-0000-0000-0000000000e' || p_org)::uuid, ('b5000000-0000-0000-0000-00000000000' || p_org)::uuid,
          1, p_amt, 'usd', 'delivered', 'delivered');
  r := public.exos_record_remittance(jsonb_build_object('channel','evo','external_id','b5-pay-' || p_id,'amount',p_amt,
         'source','statement','allocations', jsonb_build_array(jsonb_build_object('external_order_id',p_id,'amount',p_amt))));
  PERFORM public.exos_confirm_remittance((r ->> 'remittance_id')::uuid);
END $$;
CREATE OR REPLACE FUNCTION pg_temp.state(p text) RETURNS text LANGUAGE sql AS $$
  SELECT state FROM public.exos_marketplace_order_money WHERE external_order_id = p;
$$;
CREATE OR REPLACE FUNCTION pg_temp.net(p text) RETURNS numeric LANGUAGE sql AS $$
  SELECT organizer_net FROM public.exos_marketplace_order_money WHERE external_order_id = p;
$$;
CREATE OR REPLACE FUNCTION pg_temp.open_payout(p_org int) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.exos_org_payouts
   WHERE org_id = ('b5000000-0000-0000-0000-00000000000' || p_org)::uuid AND status IN ('planned', 'sending');
$$;

DO $$
DECLARE rep jsonb; pid uuid; pid2 uuid; n int; k text;
BEGIN
  -- F1 -----------------------------------------------------------------------
  PERFORM pg_temp.sale('B5-1', 1, 40);
  PERFORM public.exos_plan_org_payouts('b5000000-0000-0000-0000-000000000001');
  pid := pg_temp.open_payout(1);
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  PERFORM public.exos_mark_org_payout(pid, 'failed', NULL, 'account restricted');
  IF pg_temp.state('B5-1') <> 'payable' THEN RAISE EXCEPTION 'F1 FAIL: state after failure %', pg_temp.state('B5-1'); END IF;
  PERFORM pg_temp.sale('B5-2', 2, 50);
  rep := public.exos_plan_org_payouts_report(NULL);
  IF jsonb_array_length(rep -> 'errors') <> 0 THEN RAISE EXCEPTION 'F1 FAIL: errors %', rep; END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(rep -> 'planned') e
   WHERE e ->> 'org_id' LIKE 'b5000000-%' ;
  IF n <> 2 THEN RAISE EXCEPTION 'F1 FAIL: planned %', rep; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(rep -> 'planned') e
                  WHERE e ->> 'org_id' = 'b5000000-0000-0000-0000-000000000001'
                    AND (e ->> 'amount')::numeric = pg_temp.net('B5-1') AND (e ->> 'released')::int = 1) THEN
    RAISE EXCEPTION 'F1 FAIL: org 1 payout %', rep;
  END IF;
  IF (SELECT status || '/' || error FROM public.exos_org_payouts WHERE id = pid) <> 'cancelled/account restricted'
     OR EXISTS (SELECT 1 FROM public.exos_org_payout_lines WHERE payout_id = pid) THEN
    RAISE EXCEPTION 'F1 FAIL: the failed payout wasn''t released';
  END IF;
  IF pg_temp.state('B5-1') <> 'in_payout' OR pg_temp.state('B5-2') <> 'in_payout' THEN
    RAISE EXCEPTION 'F1 FAIL: states % %', pg_temp.state('B5-1'), pg_temp.state('B5-2');
  END IF;
  -- Nothing left to plan; the next run is a no-op.
  rep := public.exos_plan_org_payouts_report(NULL);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(rep -> 'planned') e WHERE e ->> 'org_id' LIKE 'b5000000-%') THEN
    RAISE EXCEPTION 'F1 FAIL: re-planned twice %', rep;
  END IF;
  RAISE NOTICE 'F1 PASS: a failed payout''s orders are re-planned; the other org is planned in the same run';

  -- F2 -----------------------------------------------------------------------
  -- Org 1's payout goes out; then B5-1 is cancelled (clawback) and B5-3 sells.
  pid := pg_temp.open_payout(1);
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  PERFORM public.exos_mark_org_payout(pid, 'sent', 'tr_b5_1');
  UPDATE public.exos_marketplace_orders SET status = 'cancelled', sale_status = 'cancelled' WHERE external_order_id = 'B5-1';
  PERFORM pg_temp.sale('B5-3', 1, 100);
  PERFORM public.exos_plan_org_payouts('b5000000-0000-0000-0000-000000000001');
  pid := pg_temp.open_payout(1);
  IF (SELECT amount FROM public.exos_org_payouts WHERE id = pid) <> pg_temp.net('B5-3') - pg_temp.net('B5-1') THEN
    RAISE EXCEPTION 'F2 FAIL: first amount';
  END IF;
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  PERFORM public.exos_mark_org_payout(pid, 'failed', NULL, 'insufficient platform balance');
  rep := public.exos_plan_org_payouts_report('b5000000-0000-0000-0000-000000000001');
  IF jsonb_array_length(rep -> 'planned') <> 1
     OR (rep -> 'planned' -> 0 ->> 'amount')::numeric <> pg_temp.net('B5-3') - pg_temp.net('B5-1')
     OR (rep -> 'planned' -> 0 ->> 'sale_lines')::int <> 1 OR (rep -> 'planned' -> 0 ->> 'clawback_lines')::int <> 1 THEN
    RAISE EXCEPTION 'F2 FAIL: %', rep;
  END IF;
  IF pg_temp.state('B5-1') <> 'clawed_back' THEN RAISE EXCEPTION 'F2 FAIL: clawback state %', pg_temp.state('B5-1'); END IF;
  RAISE NOTICE 'F2 PASS: a failed payout''s clawback is re-planned with it';

  -- F3 -----------------------------------------------------------------------
  -- Org 3's payout row can't be written; org 2 still gets planned.
  PERFORM public.exos_mark_org_payout(pg_temp.open_payout(2), 'sending');
  PERFORM public.exos_mark_org_payout(pg_temp.open_payout(2), 'sent', 'tr_b5_2');
  PERFORM pg_temp.sale('B5-4', 2, 20);
  PERFORM pg_temp.sale('B5-5', 3, 30);
  CREATE FUNCTION public.b5_boom() RETURNS trigger LANGUAGE plpgsql AS $f$
  BEGIN
    IF NEW.org_id = 'b5000000-0000-0000-0000-000000000003' THEN RAISE EXCEPTION 'b5 boom'; END IF;
    RETURN NEW;
  END $f$;
  CREATE TRIGGER b5_boom BEFORE INSERT ON public.exos_org_payouts FOR EACH ROW EXECUTE FUNCTION public.b5_boom();
  rep := public.exos_plan_org_payouts_report(NULL);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(rep -> 'errors') e
                  WHERE e ->> 'org_id' = 'b5000000-0000-0000-0000-000000000003' AND e ->> 'error' = 'b5 boom')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(rep -> 'planned') e
                     WHERE e ->> 'org_id' = 'b5000000-0000-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'F3 FAIL: %', rep;
  END IF;
  IF pg_temp.open_payout(3) IS NOT NULL OR pg_temp.state('B5-5') <> 'payable' THEN
    RAISE EXCEPTION 'F3 FAIL: org 3 half planned';
  END IF;
  DROP TRIGGER b5_boom ON public.exos_org_payouts;
  DROP FUNCTION public.b5_boom();
  -- The table form still returns the planned rows.
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts('b5000000-0000-0000-0000-000000000003');
  IF n <> 1 THEN RAISE EXCEPTION 'F3 FAIL: org 3 not planned after the fault cleared'; END IF;
  RAISE NOTICE 'F3 PASS: one org''s error is reported and doesn''t stop the others';

  -- F4 -----------------------------------------------------------------------
  pid := pg_temp.open_payout(3);
  k := (SELECT idempotency_key FROM public.exos_org_payouts WHERE id = pid);
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  BEGIN
    PERFORM public.exos_mark_org_payout(pid, 'sending');
    RAISE EXCEPTION 'F4 FAIL: re-claimed a live send';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'F4 FAIL%' THEN RAISE; END IF;
  END;
  -- The run died after the claim; 20 minutes on, nothing is planned beside it.
  UPDATE public.exos_org_payouts SET updated_at = now() - interval '20 minutes' WHERE id = pid;
  PERFORM pg_temp.sale('B5-6', 3, 10);
  SELECT count(*) INTO n FROM public.exos_plan_org_payouts('b5000000-0000-0000-0000-000000000003');
  IF n <> 0 THEN RAISE EXCEPTION 'F4 FAIL: planned beside a sending payout'; END IF;
  PERFORM public.exos_mark_org_payout(pid, 'sending');
  IF (SELECT status FROM public.exos_org_payouts WHERE id = pid) <> 'sending'
     OR (SELECT updated_at FROM public.exos_org_payouts WHERE id = pid) < now() - interval '1 minute'
     OR (SELECT idempotency_key FROM public.exos_org_payouts WHERE id = pid) <> k THEN
    RAISE EXCEPTION 'F4 FAIL: stale re-claim';
  END IF;
  PERFORM public.exos_mark_org_payout(pid, 'sent', 'tr_b5_3');
  IF pg_temp.state('B5-5') <> 'paid' THEN RAISE EXCEPTION 'F4 FAIL: state %', pg_temp.state('B5-5'); END IF;
  BEGIN
    PERFORM public.exos_mark_org_payout(pid, 'sending');
    RAISE EXCEPTION 'F4 FAIL: re-sent a sent payout';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'F4 FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'F4 PASS: a stale send can be re-claimed with the same key; a live one can''t';

  -- F5 -----------------------------------------------------------------------
  IF has_function_privilege('authenticated', 'public.exos_plan_org_payouts_report(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.exos_plan_org_payouts_report(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.exos_plan_org_payouts_report(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'F5 FAIL: report grants';
  END IF;
  RAISE NOTICE 'F5 PASS: the planner is service-only';
END $$;
ROLLBACK;
