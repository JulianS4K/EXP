-- ============================================================================
-- Checkout records (mig 20260929131000). Self-contained (cc prefix), rolled back.
--   R1 the new columns, the fee recorder and the exos_order_money view exist
--   R2 anon can't read ad ids or fee columns; no client can record fees
--   R3 the table refuses malformed ad ids, consent, IP hash, user agent and
--      a fee split that doesn't add up
--   R4 exos_record_payment_fees: service only, idempotent, NULL never erases
--   R5 exos_order_money: the numbers for a paid, partially refunded order
--   R6 finance / owner / manager read it; a scanner, the buyer and another
--      org's finance don't (the buyer still reads their own session row)
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- The harness's prereq exos_checkout_sessions predates prod's RLS and grants
-- (mig 20260523170000, not in this chain): put them in place, as in prod.
-- Rolled back with the rest.
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
  ('cc000000-0000-0000-0000-0000000000a0','cc-owner@x.com',now()),
  ('cc000000-0000-0000-0000-0000000000a1','cc-finance@x.com',now()),
  ('cc000000-0000-0000-0000-0000000000a2','cc-scanner@x.com',now()),
  ('cc000000-0000-0000-0000-0000000000a3','cc-manager@x.com',now()),
  ('cc000000-0000-0000-0000-0000000000b0','cc-buyer@x.com',now()),
  ('cc000000-0000-0000-0000-0000000000c0','cc-other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cc000000-0000-0000-0000-000000000001','CC Org','cc-org','cc000000-0000-0000-0000-0000000000a0'),
  ('cc000000-0000-0000-0000-000000000002','CC Other','cc-other','cc000000-0000-0000-0000-0000000000c0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('cc000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-0000000000a0','owner',false),
  ('cc000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-0000000000a1','finance',false),
  ('cc000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-0000000000a2','scanner',false),
  ('cc000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-0000000000a3','manager',false),
  ('cc000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-0000000000c0','finance',false);
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,venue_name,total_tickets,tickets_sold) VALUES
  ('cc000000-0000-0000-0000-0000000000e1','cc000000-0000-0000-0000-000000000001','CC Show','published',now() + interval '10 days','Hall',100,0);

-- A paid order: 40.00 incl. 3.00 tax; application fee 2.66 = 1.20 Exos + 1.46 card estimate.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,
       tax_cents,status,ad_ids,consent_marketing,client_ip_hash,user_agent,
       application_fee_cents,exos_fee_cents,card_fee_est_cents,fee_bps,fee_free)
VALUES ('cs_test_cc1','cc000000-0000-0000-0000-0000000000e1','cc000000-0000-0000-0000-000000000001',
        'cc000000-0000-0000-0000-0000000000b0','cc-buyer@x.com',2,4000,300,'fulfilled',
        '{"gclid":"Cj0KCQjw-abc_123.x","ttclid":"E.C.P.abc","fbp":"fb.1.1690000000000.123456789","ga_client_id":"123456789.1690000000"}',
        'granted', encode(extensions.digest('exos-guest:salt:203.0.113.9','sha256'),'hex'),
        'Mozilla/5.0 (iPhone)', 266, 120, 146, 300, false);
SELECT public.exos_record_payment('cs_test_cc1', 'pi_cc1', 4000, 'succeeded');

-- R1 -------------------------------------------------------------------------
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO missing FROM unnest(ARRAY[
    'exos_checkout_sessions.ad_ids','exos_checkout_sessions.consent_marketing',
    'exos_checkout_sessions.client_ip_hash','exos_checkout_sessions.user_agent',
    'exos_checkout_sessions.application_fee_cents','exos_checkout_sessions.exos_fee_cents',
    'exos_checkout_sessions.card_fee_est_cents','exos_checkout_sessions.fee_bps','exos_checkout_sessions.fee_free',
    'exos_order_payments.stripe_fee_cents','exos_order_payments.net_cents','exos_order_payments.transfer_id',
    'exos_order_payments.balance_txn_id','exos_order_payments.application_fee_id',
    'exos_order_payments.application_fee_cents','exos_order_payments.fees_recorded_at']) c
   WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = split_part(c, '.', 1)
                        AND column_name = split_part(c, '.', 2));
  ASSERT missing IS NULL, 'R1: missing columns: ' || missing;
  ASSERT to_regclass('public.exos_order_money') IS NOT NULL, 'R1: view missing';
  ASSERT to_regprocedure('public.exos_record_payment_fees(text,text,text,int,text,int,text,int)') IS NOT NULL, 'R1: recorder missing';
  RAISE NOTICE 'OK  R1 columns, recorder and view exist';
END $$;

-- R2 -------------------------------------------------------------------------
DO $$
BEGIN
  ASSERT NOT has_table_privilege('anon', 'public.exos_checkout_sessions', 'SELECT'), 'R2: anon reads sessions';
  ASSERT NOT has_column_privilege('anon', 'public.exos_checkout_sessions', 'ad_ids', 'SELECT'), 'R2: anon reads ad_ids';
  ASSERT NOT has_column_privilege('anon', 'public.exos_checkout_sessions', 'client_ip_hash', 'SELECT'), 'R2: anon reads ip hash';
  ASSERT NOT has_column_privilege('anon', 'public.exos_checkout_sessions', 'application_fee_cents', 'SELECT'), 'R2: anon reads fees';
  ASSERT NOT has_column_privilege('anon', 'public.exos_order_payments', 'stripe_fee_cents', 'SELECT'), 'R2: anon reads stripe fee';
  ASSERT NOT has_table_privilege('anon', 'public.exos_order_money', 'SELECT'), 'R2: anon reads the money view';
  ASSERT NOT has_function_privilege('anon', 'public.exos_record_payment_fees(text,text,text,int,text,int,text,int)', 'EXECUTE')
     AND NOT has_function_privilege('authenticated', 'public.exos_record_payment_fees(text,text,text,int,text,int,text,int)', 'EXECUTE'),
    'R2: a client can record fees';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_checkout_sessions', 'UPDATE')
     AND NOT has_table_privilege('authenticated', 'public.exos_order_payments', 'UPDATE'), 'R2: clients write money rows';
END $$;
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM ad_ids FROM public.exos_checkout_sessions LIMIT 1;
    RAISE EXCEPTION 'R2: anon read exos_checkout_sessions.ad_ids';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_order_money LIMIT 1;
    RAISE EXCEPTION 'R2: anon read exos_order_money';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  R2 anon reads no ad ids or fees; no client records fees';
END $$;
RESET ROLE;

-- R3 -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN check_violation THEN
  RETURN true;
END $$;
DO $$
DECLARE base text := $q$INSERT INTO public.exos_checkout_sessions(session_id,event_id,org_id,buyer_uid,quantity,amount_cents,status,%s)
  VALUES ('cs_test_cc_bad','cc000000-0000-0000-0000-0000000000e1','cc000000-0000-0000-0000-000000000001',
          'cc000000-0000-0000-0000-0000000000b0',1,1000,'pending',%s)$q$;
BEGIN
  ASSERT pg_temp.refused(format(base, 'ad_ids', quote_literal('{"evil":"x"}'))), 'R3: unknown ad id key accepted';
  ASSERT pg_temp.refused(format(base, 'ad_ids', quote_literal('{"gclid":"<script>"}'))), 'R3: bad click id accepted';
  ASSERT pg_temp.refused(format(base, 'ad_ids', quote_literal(json_build_object('gclid', repeat('a', 257))::text))), 'R3: 257-char click id accepted';
  ASSERT pg_temp.refused(format(base, 'ad_ids', quote_literal('{"gclid":42}'))), 'R3: non-string click id accepted';
  ASSERT pg_temp.refused(format(base, 'ad_ids', quote_literal('["gclid"]'))), 'R3: non-object ad_ids accepted';
  ASSERT pg_temp.refused(format(base, 'consent_marketing', quote_literal('yes'))), 'R3: bad consent accepted';
  ASSERT pg_temp.refused(format(base, 'client_ip_hash', quote_literal('203.0.113.9'))), 'R3: raw IP accepted';
  ASSERT pg_temp.refused(format(base, 'user_agent', quote_literal(repeat('u', 513)))), 'R3: 513-char UA accepted';
  ASSERT pg_temp.refused(format(base, 'application_fee_cents,exos_fee_cents,card_fee_est_cents', '100,30,60')), 'R3: split not adding up accepted';
  ASSERT pg_temp.refused(format(base, 'application_fee_cents', '1001')), 'R3: fee above the order accepted';
  ASSERT pg_temp.refused(format(base, 'fee_bps', '10001')), 'R3: fee_bps > 100% accepted';
  -- The good shapes go in (and the row is removed again).
  ASSERT NOT pg_temp.refused(format(base, 'ad_ids,consent_marketing,application_fee_cents,exos_fee_cents,card_fee_est_cents,fee_bps,fee_free',
    quote_literal(json_build_object('msclkid', repeat('a', 256), 'rdt_cid', '1a2b', 'ScCid', 'x-y', 'twclid', 'q', 'wbraid', 'w', 'gbraid', 'g', 'fbclid', 'IwAR0', 'fbc', 'fb.1.1690000000000.IwAR0')::text)
    || ',''unknown'',59,0,59,0,true')), 'R3: a valid row was refused';
  DELETE FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_cc_bad';
  RAISE NOTICE 'OK  R3 malformed ad ids / consent / IP / UA / fee split refused';
END $$;

-- R4 -------------------------------------------------------------------------
DO $$
DECLARE p record; ok boolean;
BEGIN
  ok := public.exos_record_payment_fees('pi_cc1', 'ch_cc1', 'txn_cc1', 146, 'fee_cc1', 266, 'tr_cc1', 120);
  ASSERT ok, 'R4: recorder did not find the payment';
  SELECT * INTO p FROM public.exos_order_payments WHERE payment_intent = 'pi_cc1';
  ASSERT p.charge_id = 'ch_cc1' AND p.balance_txn_id = 'txn_cc1' AND p.stripe_fee_cents = 146
     AND p.application_fee_id = 'fee_cc1' AND p.application_fee_cents = 266 AND p.transfer_id = 'tr_cc1'
     AND p.net_cents = 120 AND p.fees_recorded_at IS NOT NULL, 'R4: values not stored: ' || row_to_json(p)::text;
  -- A replay with less information keeps what's there.
  ok := public.exos_record_payment_fees('pi_cc1', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
  SELECT * INTO p FROM public.exos_order_payments WHERE payment_intent = 'pi_cc1';
  ASSERT ok AND p.stripe_fee_cents = 146 AND p.transfer_id = 'tr_cc1' AND p.net_cents = 120, 'R4: NULL erased a value';
  ASSERT NOT public.exos_record_payment_fees('pi_cc_unknown'), 'R4: unknown PaymentIntent reported as recorded';
  BEGIN
    PERFORM public.exos_record_payment_fees('pi_cc1', 'ch_''; drop');
    RAISE EXCEPTION 'R4: malformed id accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_record_payment_fees('pi_cc1', NULL, NULL, -1);
    RAISE EXCEPTION 'R4: negative fee accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  R4 fee recorder stores, replays idempotently, validates';
END $$;

-- Refunds: 10.00 succeeded, 5.00 pending, 2.00 failed -> 10.00 refunded.
SELECT public.exos_record_refund('cs_test_cc1', 're_cc1', 1000, 'succeeded', 'pi_cc1');
SELECT public.exos_record_refund('cs_test_cc1', 're_cc2', 500, 'pending', 'pi_cc1');
SELECT public.exos_record_refund('cs_test_cc1', 're_cc3', 200, 'failed', 'pi_cc1');

-- R5 -------------------------------------------------------------------------
DO $$
DECLARE m record;
BEGIN
  SELECT * INTO m FROM public.exos_order_money WHERE session_id = 'cs_test_cc1';
  ASSERT m.gross_cents = 4000 AND m.tax_cents = 300 AND m.application_fee_cents = 266
     AND m.exos_fee_cents = 120 AND m.card_fee_est_cents = 146 AND m.card_fee_actual_cents = 146
     AND m.organizer_net_cents = 3734 AND m.platform_net_cents = 120 AND m.refunded_cents = 1000
     AND m.fee_bps = 300 AND m.fee_free = false AND m.transfer_id = 'tr_cc1' AND m.payment_intent = 'pi_cc1',
    'R5: wrong numbers: ' || row_to_json(m)::text;
  RAISE NOTICE 'OK  R5 exos_order_money: gross 40.00, fee 2.66 (1.20 + 1.46), organizer 37.34, refunded 10.00';
END $$;

-- R6 -------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000a1', true);  -- finance
DO $$
DECLARE m record;
BEGIN
  SELECT * INTO m FROM public.exos_order_money WHERE session_id = 'cs_test_cc1';
  ASSERT FOUND AND m.organizer_net_cents = 3734 AND m.refunded_cents = 1000 AND m.card_fee_actual_cents = 146,
    'R6: finance can''t read the order money';
END $$;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000a0', true);  -- owner
DO $$ BEGIN ASSERT EXISTS (SELECT 1 FROM public.exos_order_money WHERE session_id = 'cs_test_cc1'), 'R6: owner can''t read'; END $$;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000a3', true);  -- manager
DO $$ BEGIN ASSERT EXISTS (SELECT 1 FROM public.exos_order_money WHERE session_id = 'cs_test_cc1'), 'R6: manager can''t read'; END $$;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000a2', true);  -- scanner
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_money WHERE session_id = 'cs_test_cc1'), 'R6: scanner reads the order money';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_cc1'), 'R6: scanner reads the session (ad ids)';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_payments WHERE payment_intent = 'pi_cc1'), 'R6: scanner reads the payment fees';
END $$;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000c0', true);  -- another org's finance
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_money WHERE session_id = 'cs_test_cc1'), 'R6: another org reads it'; END $$;
SELECT set_config('app.uid', 'cc000000-0000-0000-0000-0000000000b0', true);  -- the buyer
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_order_money WHERE session_id = 'cs_test_cc1'), 'R6: the buyer reads the order money';
  -- Their own session row stays readable (as attribution always was).
  ASSERT (SELECT ad_ids ->> 'gclid' FROM public.exos_checkout_sessions WHERE session_id = 'cs_test_cc1') = 'Cj0KCQjw-abc_123.x',
    'R6: buyer lost their own session row';
  RAISE NOTICE 'OK  R6 owner / manager / finance read exos_order_money; scanner, buyer, other org don''t';
END $$;
RESET ROLE;
ROLLBACK;
