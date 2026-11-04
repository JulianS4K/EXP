-- ============================================================================
-- Four ways to fund promoter commissions (mig 20261104190000): settings and
-- the picker, resolution + fallbacks, method locking, accrual per method,
-- the holdback, split at sale (shares, refunds before / after the transfer,
-- organizer true-ups), commissions inside the Exos fee (quote, held cap),
-- netting (per funder, overdue), the transfer lease / fence / reconcile /
-- cancel machinery, idempotent planning, the settle gate, RLS, grants and
-- cross-org isolation. Self-contained (ids 0d0d…, slugs cm-*), rolled back.
-- Users: org A owner …a1, manager …a2, finance …a3, stranger …a4, buyer …a5;
--        org B owner …b1.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('0d0d0000-0000-0000-0000-0000000000a1','cmowner@x.com',now()),
  ('0d0d0000-0000-0000-0000-0000000000a2','cmmanager@x.com',now()),
  ('0d0d0000-0000-0000-0000-0000000000a3','cmfinance@x.com',now()),
  ('0d0d0000-0000-0000-0000-0000000000a4','cmstranger@x.com',now()),
  ('0d0d0000-0000-0000-0000-0000000000a5','cmbuyer@x.com',now()),
  ('0d0d0000-0000-0000-0000-0000000000b1','cmbowner@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('0d0d0000-0000-0000-0000-000000000001','CM Org','cm-org','0d0d0000-0000-0000-0000-0000000000a1'),
  ('0d0d0000-0000-0000-0000-000000000002','CM Other','cm-other','0d0d0000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('0d0d0000-0000-0000-0000-000000000001','0d0d0000-0000-0000-0000-0000000000a1','owner'),
  ('0d0d0000-0000-0000-0000-000000000001','0d0d0000-0000-0000-0000-0000000000a2','manager'),
  ('0d0d0000-0000-0000-0000-000000000001','0d0d0000-0000-0000-0000-0000000000a3','finance'),
  ('0d0d0000-0000-0000-0000-000000000002','0d0d0000-0000-0000-0000-0000000000b1','owner');
-- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets(org_id,payments) VALUES
  ('0d0d0000-0000-0000-0000-000000000001','{"connectedAccountId":"acct_cmOrgA","chargesEnabled":true}'),
  ('0d0d0000-0000-0000-0000-000000000002','{"connectedAccountId":"acct_cmOrgB","chargesEnabled":true}');
-- e1 split (ended), e2 split (next week), e3 fee (ended), e4 manual (ended),
-- e5 unsold (ended), eb org B (next week).
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,currency) VALUES
  ('0d0d0000-0000-0000-0000-0000000000e1','0d0d0000-0000-0000-0000-000000000001','CM Split Night','published',now()-interval '10 days','usd'),
  ('0d0d0000-0000-0000-0000-0000000000e2','0d0d0000-0000-0000-0000-000000000001','CM Next Week','published',now()+interval '7 days','usd'),
  ('0d0d0000-0000-0000-0000-0000000000e3','0d0d0000-0000-0000-0000-000000000001','CM Fee Night','published',now()-interval '10 days','usd'),
  ('0d0d0000-0000-0000-0000-0000000000e4','0d0d0000-0000-0000-0000-000000000001','CM Manual Night','published',now()-interval '10 days','usd'),
  ('0d0d0000-0000-0000-0000-0000000000e5','0d0d0000-0000-0000-0000-000000000001','CM Unsold','published',now()-interval '10 days','usd'),
  ('0d0d0000-0000-0000-0000-0000000000eb','0d0d0000-0000-0000-0000-000000000002','CM Other Night','published',now()+interval '7 days','usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('0d0d0000-0000-0000-0000-0000000000d1','0d0d0000-0000-0000-0000-0000000000e1','GA',20,0,0),
  ('0d0d0000-0000-0000-0000-0000000000d2','0d0d0000-0000-0000-0000-0000000000e2','GA',20,0,0),
  ('0d0d0000-0000-0000-0000-0000000000d3','0d0d0000-0000-0000-0000-0000000000e3','GA',20,0,0),
  ('0d0d0000-0000-0000-0000-0000000000d4','0d0d0000-0000-0000-0000-0000000000e4','GA',20,0,0),
  ('0d0d0000-0000-0000-0000-0000000000d5','0d0d0000-0000-0000-0000-0000000000e5','GA',20,0,0),
  ('0d0d0000-0000-0000-0000-0000000000db','0d0d0000-0000-0000-0000-0000000000eb','GA',20,0,0);

-- Promoters: P and Q in org A (10%), R in org B (10%). P has a ready payout
-- account; Q gets one later.
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a1',false);
SELECT public.exos_upsert_promoter('0d0d0000-0000-0000-0000-000000000001','cm-p','Promoter P');
SELECT public.exos_upsert_promoter('0d0d0000-0000-0000-0000-000000000001','cm-q','Promoter Q');
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000b1',false);
SELECT public.exos_upsert_promoter('0d0d0000-0000-0000-0000-000000000002','cm-r','Promoter R');
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE p uuid; q uuid; r uuid;
BEGIN
  SELECT id INTO p FROM public.exos_promoters WHERE code='cm-p';
  SELECT id INTO q FROM public.exos_promoters WHERE code='cm-q';
  SELECT id INTO r FROM public.exos_promoters WHERE code='cm-r';
  PERFORM public.exos_set_promoter_terms(p, 1000, 0);
  PERFORM public.exos_set_promoter_terms(q, 1000, 0);
  PERFORM set_config('test.p', p::text, false);
  PERFORM set_config('test.q', q::text, false);
  PERFORM set_config('test.r', r::text, false);
END $$;
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000b1',false);
SELECT public.exos_set_promoter_terms(current_setting('test.r')::uuid, 1000, 0);
SELECT set_config('app.uid','',false);
SELECT public.exos_record_promoter_stripe(current_setting('test.p')::uuid, 'acct_cmP', true, true, true);

-- An order the way exos-checkout + stripe-webhook leave it: session row,
-- the commission plan (p_plan, from exos_commission_checkout_plan), fulfilment,
-- the payment (charge id for split orders, a transfer id for destination ones).
CREATE FUNCTION pg_temp.ord(p_sid text, p_tier uuid, p_code text, p_qty integer, p_fee integer, p_plan jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_ev uuid; v_org uuid; v_split boolean := coalesce(p_plan ->> 'charge_model', 'destination') = 'split';
BEGIN
  SELECT t.event_id, e.org_id INTO v_ev, v_org FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = p_tier;
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id,application_fee_cents,exos_fee_cents,card_fee_est_cents)
  VALUES (p_sid, v_ev, p_tier, v_org, '0d0d0000-0000-0000-0000-0000000000a5', 'cmbuyer@x.com', p_qty, p_qty * 2000, 'pending', p_code, p_fee, p_fee, 0);
  IF p_plan IS NOT NULL THEN
    ASSERT public.exos_record_commission_plan(p_sid, p_plan), 'record plan ' || p_sid;
  END IF;
  PERFORM public.exos_fulfill_checkout(p_sid);
  INSERT INTO public.exos_order_payments(session_id,org_id,event_id,payment_intent,charge_id,amount_cents,currency,status,transfer_id)
  VALUES (p_sid, v_org, v_ev, 'pi_' || replace(p_sid, '-', ''), 'ch_' || replace(p_sid, '-', ''), p_qty * 2000, 'usd', 'succeeded',
          CASE WHEN v_split THEN NULL ELSE 'tr_' || replace(p_sid, '-', '') END);
END $$;
CREATE FUNCTION pg_temp.plan(p_tier uuid, p_code text, p_qty integer, p_fee integer, p_split boolean, p_fee_on boolean, p_proc text DEFAULT 'stripe')
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.exos_commission_checkout_plan((SELECT event_id FROM public.exos_ticket_tiers WHERE id = p_tier), p_tier, p_code,
                                              p_qty, p_qty * 2000, 0, 0, p_fee, p_proc, p_split, p_fee_on)
$$;
CREATE FUNCTION pg_temp.ids(p_sid text) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT array_agg(id ORDER BY accrued_at, id) FROM public.exos_promoter_commissions WHERE session_id = p_sid
$$;
CREATE FUNCTION pg_temp.void1(p_sid text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.exos_tickets SET status = 'voided', voided_at = now(), voided_reason = 'refunded'
   WHERE id = (SELECT id FROM public.exos_tickets WHERE order_ref = p_sid AND status = 'active' ORDER BY id LIMIT 1)
$$;
CREATE FUNCTION pg_temp.org_owed(p_org uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT -coalesce(sum(amount_cents), 0) FROM public.exos_commission_netting
   WHERE org_id = p_org AND party = 'organizer' AND applied_payout_id IS NULL AND applied_transfer_id IS NULL AND voided_at IS NULL
$$;

-- CM1. Settings: defaults, who may change what, ranges.
DO $$
DECLARE a uuid := '0d0d0000-0000-0000-0000-000000000001'; s jsonb; ok boolean;
BEGIN
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a3',false);
  s := public.exos_get_commission_settings(a);
  ASSERT s->>'default_method' = 'manual' AND (s->>'holdback_days')::int = 3 AND NOT (s->>'configured')::boolean
     AND NOT (s->>'split_at_sale_enabled')::boolean AND (s->>'organizer_account')::boolean,
     'CM1: defaults are manual, 3 days, split off: ' || s::text;
  ok := false;
  BEGIN PERFORM public.exos_set_commission_settings(a, 'clawback', 3);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM1: finance cannot change settings';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  ok := false;
  BEGIN PERFORM public.exos_set_commission_settings(a, 'manual', 3, NULL, true);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM1: a manager cannot turn split at sale on';
  ok := false;
  BEGIN PERFORM public.exos_set_commission_settings(a, 'manual', 31);
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM1: holdback over 30 days refused';
  ok := false;
  BEGIN PERFORM public.exos_set_commission_settings(a, 'venmo', 3);
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM1: unknown method refused';
  s := public.exos_set_commission_settings(a, 'manual', 3, 30);
  ASSERT s->>'default_method' = 'manual', 'CM1: manager saves the default';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a1',false);
  s := public.exos_set_commission_settings(a, 'manual', 3, 30, true);
  ASSERT (s->>'split_at_sale_enabled')::boolean, 'CM1: owner turns split at sale on';
  -- Leaving the switch NULL keeps it.
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  s := public.exos_set_commission_settings(a, 'manual', 3);
  ASSERT (s->>'split_at_sale_enabled')::boolean, 'CM1: a NULL switch leaves it on';
  ASSERT (SELECT count(*) FROM public.exos_commission_method_changes WHERE org_id = a AND scope = 'split_switch') = 1,
         'CM1: the switch change is logged';
  PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e1', 'split_at_sale');
  PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e2', 'split_at_sale');
  PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e3', 'platform_fee');
  RAISE NOTICE 'OK  CM1 settings: defaults, roles, ranges, log';
END $$;
SELECT set_config('app.uid','',false);

-- CM2. Resolution (promoter > event > org > manual) and checkout fallbacks.
DO $$
DECLARE d1 uuid := '0d0d0000-0000-0000-0000-0000000000d1'; d3 uuid := '0d0d0000-0000-0000-0000-0000000000d3';
        d4 uuid := '0d0d0000-0000-0000-0000-0000000000d4'; x jsonb;
BEGIN
  x := pg_temp.plan(d1, 'cm-p', 2, 200, true, false);
  ASSERT x->>'method' = 'split_at_sale' AND x->>'charge_model' = 'split' AND x->>'source' = 'event'
     AND x->>'transfer_group' ~ '^exos-order-' AND (x->>'commission_fee_cents')::int = 0,
     'CM2: event override gives split: ' || x::text;
  x := pg_temp.plan(d1, 'cm-p', 2, 200, false, false);
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'fallback' AND x->>'charge_model' = 'destination' AND x->'transfer_group' = 'null'::jsonb,
     'CM2: EXOS_SPLIT_AT_SALE off falls back to manual: ' || x::text;
  x := pg_temp.plan(d1, 'cm-p', 2, 200, true, false, 'paypal');
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'fallback', 'CM2: PayPal orders fall back';
  x := pg_temp.plan(d3, 'cm-p', 2, 200, false, true);
  ASSERT x->>'method' = 'platform_fee' AND x->>'charge_model' = 'destination' AND (x->>'commission_fee_cents')::int = 400
     AND jsonb_array_length(x->'quote') = 2, 'CM2: platform fee quotes 2 x 10%: ' || x::text;
  x := pg_temp.plan(d3, 'cm-p', 2, 200, false, false);
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'fallback', 'CM2: EXOS_PLATFORM_FEE_COMMISSIONS off falls back';
  x := pg_temp.plan(d3, 'cm-p', 2, 3700, false, true);
  ASSERT x->>'method' = 'manual' AND (x->>'commission_fee_cents')::int = 0, 'CM2: fee + commission over the charge falls back';
  x := pg_temp.plan(d3, NULL, 2, 200, false, true);
  ASSERT x->>'method' = 'platform_fee' AND (x->>'commission_fee_cents')::int = 0, 'CM2: no promoter, no commission in the fee';
  x := pg_temp.plan(d4, 'cm-p', 1, 100, true, true);
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'org', 'CM2: no override -> the org default';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_promoter_commission_method(current_setting('test.q')::uuid, 'manual');
  PERFORM set_config('app.uid','',false);
  x := pg_temp.plan(d1, 'cm-q', 1, 100, true, false);
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'promoter', 'CM2: the promoter override wins: ' || x::text;
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_promoter_commission_method(current_setting('test.q')::uuid, NULL);
  PERFORM set_config('app.uid','',false);
  -- The org switch: off means split falls back even with the platform switch on.
  UPDATE public.exos_org_commission_settings SET split_at_sale_enabled = false WHERE org_id = '0d0d0000-0000-0000-0000-000000000001';
  x := pg_temp.plan(d1, 'cm-p', 1, 100, true, false);
  ASSERT x->>'method' = 'manual' AND x->>'source' = 'fallback', 'CM2: the org switch gates split';
  UPDATE public.exos_org_commission_settings SET split_at_sale_enabled = true WHERE org_id = '0d0d0000-0000-0000-0000-000000000001';
  RAISE NOTICE 'OK  CM2 resolution and checkout fallbacks';
END $$;

-- CM3. Accrual per method; split orders; the event locks at its first sale.
DO $$
DECLARE d1 uuid := '0d0d0000-0000-0000-0000-0000000000d1'; n int;
BEGIN
  PERFORM pg_temp.ord('cm-s1', d1, 'cm-p', 2, 200, pg_temp.plan(d1, 'cm-p', 2, 200, true, false));
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE session_id = 'cm-s1' AND method = 'split_at_sale'
            AND method_source = 'event' AND commission_cents = 200) = 2, 'CM3: split order accrues 2 x 200 as split_at_sale';
  ASSERT (SELECT locked_method FROM public.exos_event_commission_settings WHERE event_id = '0d0d0000-0000-0000-0000-0000000000e1') = 'split_at_sale',
         'CM3: the first sale locks the event';
  -- A ticket with no checkout plan at a split event (staff-minted) falls back to manual.
  INSERT INTO public.exos_tickets(event_id,org_id,buyer_id,owner_id,status,price_paid,order_ref,channel_source,promoter_id,barcode_secret)
  VALUES ('0d0d0000-0000-0000-0000-0000000000e1','0d0d0000-0000-0000-0000-000000000001',
          '0d0d0000-0000-0000-0000-0000000000a5','0d0d0000-0000-0000-0000-0000000000a5','active',20,'staff:cm','staff','cm-q','s');
  SELECT count(*) INTO n FROM public.exos_promoter_commissions
   WHERE promoter_id = current_setting('test.q')::uuid AND session_id IS NULL AND method = 'manual' AND method_source = 'fallback';
  ASSERT n = 1, 'CM3: a sale not charged the split way is manual (fallback)';
  RAISE NOTICE 'OK  CM3 accrual records its method; first sale locks the event';
END $$;

-- CM4. Method locking: an org default change doesn't move a sold event; an
-- event change needs "future sales only" and reaches only later sales.
DO $$
DECLARE a uuid := '0d0d0000-0000-0000-0000-000000000001'; d4 uuid := '0d0d0000-0000-0000-0000-0000000000d4'; s jsonb; ok boolean := false; x jsonb;
BEGIN
  PERFORM pg_temp.ord('cm-m1', d4, 'cm-p', 1, 100, pg_temp.plan(d4, 'cm-p', 1, 100, true, true));
  ASSERT (SELECT method FROM public.exos_promoter_commissions WHERE session_id = 'cm-m1') = 'manual', 'CM4: e4 sells manual';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_commission_settings(a, 'clawback', 3);
  s := public.exos_get_commission_settings(a);
  ASSERT (SELECT e->>'effective' FROM jsonb_array_elements(s->'events') e WHERE e->>'event_id' = '0d0d0000-0000-0000-0000-0000000000e4') = 'manual',
         'CM4: the sold event keeps manual after the default changed';
  ASSERT (SELECT e->>'effective' FROM jsonb_array_elements(s->'events') e WHERE e->>'event_id' = '0d0d0000-0000-0000-0000-0000000000e5') = 'clawback',
         'CM4: an unsold event follows the new default';
  BEGIN PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e4', 'platform_fee');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM4: a sold event refuses a change without future-sales-only';
  s := public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e4', 'platform_fee', true);
  ASSERT s->>'effective' = 'platform_fee', 'CM4: future-only change accepted';
  PERFORM set_config('app.uid','',false);
  x := pg_temp.plan(d4, 'cm-p', 1, 100, false, true);
  ASSERT x->>'method' = 'platform_fee' AND x->>'source' = 'event_locked', 'CM4: later sales use the new method';
  ASSERT (SELECT method FROM public.exos_promoter_commissions WHERE session_id = 'cm-m1') = 'manual', 'CM4: earlier sales keep theirs';
  -- A recorded method is never rewritten.
  UPDATE public.exos_promoter_commissions SET method = 'clawback' WHERE session_id = 'cm-m1';
  ASSERT (SELECT method FROM public.exos_promoter_commissions WHERE session_id = 'cm-m1') = 'manual', 'CM4: method is immutable';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e4', 'manual', true);
  PERFORM public.exos_set_commission_settings(a, 'manual', 3);
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  CM4 method locking';
END $$;

-- CM5. Holdback: configured org can't settle before event end + N days; an
-- org that never saved settings keeps today's behaviour.
DO $$
DECLARE d2 uuid := '0d0d0000-0000-0000-0000-0000000000d2'; db uuid := '0d0d0000-0000-0000-0000-0000000000db';
        ids uuid[]; ok boolean := false; r jsonb; x record;
BEGIN
  -- e2 is split; an order on it without a plan (switch off) is manual.
  PERFORM pg_temp.ord('cm-h1', d2, 'cm-q', 1, 100, NULL);
  ids := pg_temp.ids('cm-h1');
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  SELECT * INTO x FROM public.exos_commission_payable(current_setting('test.q')::uuid) WHERE id = ids[1];
  ASSERT NOT x.payable AND x.settle_here AND x.payable_at > now() + interval '9 days', 'CM5: held until event end + 3 days';
  BEGIN PERFORM public.exos_settle_promoter(current_setting('test.q')::uuid, ids, 200, 'Venmo', 'cm-hold-0001');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM5: settle refused during the holdback';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(current_setting('test.q')::uuid, ids, 200, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM5: the legacy record path is held too';
  -- Holdback 0 still waits for the event to end.
  PERFORM public.exos_set_commission_settings('0d0d0000-0000-0000-0000-000000000001', 'manual', 0);
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(current_setting('test.q')::uuid, ids, 200, 'Venmo', 'cm-hold-0002');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM5: holdback 0 still waits for the event to end';
  PERFORM public.exos_set_commission_settings('0d0d0000-0000-0000-0000-000000000001', 'manual', 3);
  -- Org B never saved settings: its manual settle works as before.
  PERFORM set_config('app.uid','',false);
  PERFORM pg_temp.ord('cm-b1', db, 'cm-r', 1, 100, NULL);
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000b1',false);
  r := public.exos_settle_promoter(current_setting('test.r')::uuid, pg_temp.ids('cm-b1'), 200, 'Venmo', 'cm-legacy-001');
  ASSERT (r->>'amount_cents')::int = 200, 'CM5: an unconfigured org settles as before';
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  CM5 holdback';
END $$;

-- CM6. Split at sale: plan after the holdback, shares, idempotent planning,
-- the promoter without an account waits, disputes and future events wait.
DO $$
DECLARE d1 uuid := '0d0d0000-0000-0000-0000-0000000000d1'; d2 uuid := '0d0d0000-0000-0000-0000-0000000000d2';
        r jsonb; o record; pr record; n int;
BEGIN
  PERFORM pg_temp.ord('cm-s6', d2, 'cm-p', 1, 100, pg_temp.plan(d2, 'cm-p', 1, 100, true, false));
  PERFORM pg_temp.ord('cm-s5', d1, 'cm-p', 1, 100, pg_temp.plan(d1, 'cm-p', 1, 100, true, false));
  UPDATE public.exos_checkout_sessions SET dispute_status = 'needs_response' WHERE session_id = 'cm-s5';
  r := public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000001');
  SELECT * INTO o FROM public.exos_commission_transfers WHERE session_id = 'cm-s1' AND kind = 'split_org';
  SELECT * INTO pr FROM public.exos_commission_transfers WHERE session_id = 'cm-s1' AND kind = 'split_promoter';
  ASSERT o.gross_cents = 3400 AND o.amount_cents = 3400 AND o.status = 'planned' AND o.destination = 'acct_cmOrgA'
     AND o.source_charge_id = 'ch_cms1' AND o.transfer_group ~ '^exos-order-', 'CM6: organizer share 4000 - 200 fee - 400 commission: ' || row_to_json(o)::text;
  ASSERT pr.amount_cents = 400 AND pr.destination = 'acct_cmP' AND pr.transfer_group = o.transfer_group
     AND (SELECT via FROM public.exos_promoter_payouts WHERE id = pr.payout_id) = 'split',
     'CM6: promoter commission 400 from the same charge';
  ASSERT (SELECT bool_and(status = 'paid' AND payout_id = pr.payout_id) FROM public.exos_promoter_commissions WHERE session_id = 'cm-s1'),
         'CM6: the rows are paid by the split payout';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers WHERE session_id IN ('cm-s5', 'cm-s6')),
         'CM6: an open dispute and a future event wait';
  SELECT count(*) INTO n FROM public.exos_commission_transfers;
  r := public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000001');
  ASSERT (r->>'planned')::int = 0 AND (SELECT count(*) FROM public.exos_commission_transfers) = n, 'CM6: planning again plans nothing';
  -- Refund before the transfer: shares shrink.
  PERFORM pg_temp.ord('cm-s4', d1, 'cm-p', 2, 200, pg_temp.plan(d1, 'cm-p', 2, 200, true, false));
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,currency,status,is_partial)
  VALUES ('cm-s4','0d0d0000-0000-0000-0000-000000000001','re_cms4',2000,'usd','succeeded',true);
  PERFORM pg_temp.void1('cm-s4');
  r := public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000001');
  ASSERT (SELECT amount_cents FROM public.exos_commission_transfers WHERE session_id = 'cm-s4' AND kind = 'split_org') = 1700
     AND (SELECT amount_cents FROM public.exos_commission_transfers WHERE session_id = 'cm-s4' AND kind = 'split_promoter') = 200,
     'CM6: refund before transfer: organizer 2000 - 100 - 200, promoter 200';
  -- Q has no payout account: the organizer is planned, Q waits.
  PERFORM pg_temp.ord('cm-s2', d1, 'cm-q', 3, 300, pg_temp.plan(d1, 'cm-q', 3, 300, true, false));
  RAISE NOTICE 'OK  CM6 split planning';
END $$;

-- CM7. The transfer machinery (exos_ct_*): claim, lease, mark, dry run,
-- reconcile after a crash, 'sent' idempotent; the wedge's clawback functions
-- refuse these payouts.
DO $$
DECLARE o uuid; pr uuid; c jsonb; c2 jsonb; tok uuid; ok boolean;
BEGIN
  SELECT id INTO o FROM public.exos_commission_transfers WHERE session_id = 'cm-s1' AND kind = 'split_org';
  SELECT id INTO pr FROM public.exos_commission_transfers WHERE session_id = 'cm-s1' AND kind = 'split_promoter';
  c := public.exos_ct_claim(o, 'send', '0d0d0000-0000-0000-0000-0000000000a4');
  ASSERT c->>'error' = 'not_found', 'CM7: a stranger cannot claim';
  c := public.exos_ct_claim(o, 'send', '0d0d0000-0000-0000-0000-0000000000a2');
  ASSERT (c->>'ok')::boolean AND c->>'state' = 'sending' AND (c->>'amount_cents')::int = 3400, 'CM7: manager claims';
  tok := (c->>'lease_token')::uuid;
  c2 := public.exos_ct_claim(o, 'send');
  ASSERT c2->>'error' = 'busy', 'CM7: a second claim is busy';
  c2 := public.exos_ct_claim(o, 'cancel');
  ASSERT c2->>'error' = 'busy', 'CM7: cancel waits for the lease';
  ASSERT public.exos_ct_lease_ok(o, tok) AND NOT public.exos_ct_lease_ok(o, gen_random_uuid()), 'CM7: lease check';
  ASSERT NOT public.exos_ct_mark(o, 'failed', NULL, 'x', gen_random_uuid()), 'CM7: a stale token cannot fail it';
  ASSERT public.exos_ct_mark(o, 'dry_run', NULL, NULL, tok), 'CM7: dry run recorded';
  ASSERT o IN (SELECT public.exos_ct_due('0d0d0000-0000-0000-0000-000000000001', 25)), 'CM7: a dry run is due again';
  -- A send that crashed mid-way: the next send must reconcile first.
  c := public.exos_ct_claim(o, 'send');
  UPDATE public.exos_commission_transfers SET lease_until = now() - interval '1 second',
         send_started_at = now() - interval '11 minutes', reconciled_at = now() - interval '12 minutes' WHERE id = o;
  c := public.exos_ct_claim(o, 'send');
  ASSERT c->>'error' = 'needs_reconcile', 'CM7: an unreconciled send blocks a new one';
  c := public.exos_ct_claim(o, 'reconcile');
  ASSERT (c->>'ok')::boolean, 'CM7: reconcile claim';
  ASSERT public.exos_ct_reconcile(o, (c->>'lease_token')::uuid, NULL) = 'reconciled', 'CM7: nothing at Stripe';
  ASSERT (SELECT status FROM public.exos_commission_transfers WHERE id = o) = 'failed', 'CM7: reconciled -> failed';
  c := public.exos_ct_claim(o, 'send');
  ASSERT (c->>'ok')::boolean, 'CM7: send again after reconcile';
  ASSERT public.exos_ct_mark(o, 'sent', 'tr_cmOrg1'), 'CM7: sent';
  ASSERT public.exos_ct_mark(o, 'sent', 'tr_cmOrg1') AND NOT public.exos_ct_mark(o, 'sent', 'tr_cmOther'), 'CM7: sent is idempotent';
  c := public.exos_ct_claim(o, 'send');
  ASSERT c->>'error' = 'sent', 'CM7: a sent transfer is done';
  -- The promoter's: reconcile finds it at Stripe.
  c := public.exos_ct_claim(pr, 'send');
  UPDATE public.exos_commission_transfers SET lease_until = now() - interval '1 second', send_started_at = now() - interval '11 minutes' WHERE id = pr;
  c := public.exos_ct_claim(pr, 'reconcile');
  ASSERT public.exos_ct_reconcile(pr, (c->>'lease_token')::uuid, 'tr_cmP1') = 'sent', 'CM7: reconcile finds the transfer';
  ASSERT (SELECT transfer_status = 'sent' AND stripe_transfer_id = 'tr_cmP1' FROM public.exos_promoter_payouts
           WHERE id = (SELECT payout_id FROM public.exos_commission_transfers WHERE id = pr)), 'CM7: payout mirrors sent';
  c := public.exos_promoter_transfer_claim((SELECT payout_id FROM public.exos_commission_transfers WHERE id = pr), '0d0d0000-0000-0000-0000-0000000000a1');
  ASSERT c->>'error' IN ('manual', 'sent'), 'CM7: the clawback machinery leaves split payouts alone: ' || c::text;
  RAISE NOTICE 'OK  CM7 transfer lease, fence, reconcile';
END $$;

-- CM8. Refund after the transfer: the organizer is trued up and the
-- promoter gets a negative line; both are netted from later transfers.
DO $$
DECLARE a uuid := '0d0d0000-0000-0000-0000-000000000001'; d1 uuid := '0d0d0000-0000-0000-0000-0000000000d1';
        r jsonb; o record; v bigint;
BEGIN
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,currency,status,is_partial)
  VALUES ('cm-s1',a,'re_cms1',2000,'usd','succeeded',true);
  ASSERT pg_temp.org_owed(a) = 1900, 'CM8: half refunded, tickets valid: organizer owes 3400 - (2000 - 100 - 400): ' || pg_temp.org_owed(a);
  PERFORM pg_temp.void1('cm-s1');
  ASSERT pg_temp.org_owed(a) = 1700, 'CM8: one ticket voided: its commission goes back to the organizer side (1700)';
  ASSERT (SELECT amount_cents FROM public.exos_commission_netting WHERE party = 'promoter' AND kind = 'clawback'
            AND promoter_id = current_setting('test.p')::uuid AND session_id = 'cm-s1') = -200,
         'CM8: the promoter owes 200 back (a negative line)';
  ASSERT (SELECT funder FROM public.exos_commission_netting WHERE party = 'promoter' AND session_id = 'cm-s1') = 'platform',
         'CM8: owed to Exos, which paid it';
  -- Replaying the refund row changes nothing.
  UPDATE public.exos_order_refunds SET status = 'succeeded' WHERE refund_id = 're_cms1';
  ASSERT pg_temp.org_owed(a) = 1700, 'CM8: true-up is idempotent';
  -- The organizer's next split share (cm-s2: 6000 - 300 - 600 = 5100) nets the 1700.
  r := public.exos_commission_plan_due(a);
  SELECT * INTO o FROM public.exos_commission_transfers WHERE session_id = 'cm-s2' AND kind = 'split_org';
  ASSERT o.gross_cents = 5100 AND o.netted_cents = 1700 AND o.amount_cents = 3400, 'CM8: next share netted: ' || row_to_json(o)::text;
  ASSERT pg_temp.org_owed(a) = 0, 'CM8: nothing owed after netting';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers WHERE session_id = 'cm-s2' AND kind = 'split_promoter'),
         'CM8: Q waits for a payout account';
  -- P's next split commission (cm-s3, 200) is fully netted by the 200 owed.
  PERFORM pg_temp.ord('cm-s3', d1, 'cm-p', 1, 100, pg_temp.plan(d1, 'cm-p', 1, 100, true, false));
  r := public.exos_commission_plan_due(a);
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_commission_transfers WHERE session_id = 'cm-s3' AND kind = 'split_promoter'),
         'CM8: nothing to transfer to P';
  ASSERT (SELECT po.via = 'manual' AND po.method = 'Netted against refunds' AND po.amount_cents = 0 AND po.clawback_cents = 200
            FROM public.exos_promoter_payouts po JOIN public.exos_promoter_commissions c ON c.payout_id = po.id
           WHERE c.session_id = 'cm-s3'), 'CM8: P''s commission netted against the refund';
  ASSERT (SELECT applied_payout_id IS NOT NULL FROM public.exos_commission_netting WHERE party = 'promoter' AND session_id = 'cm-s1'),
         'CM8: the line is applied';
  -- A large organizer debt carries forward when a share can't cover it.
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,currency,status,is_partial)
  VALUES ('cm-s2',a,'re_cms2',6000,'usd','succeeded',false);
  v := pg_temp.org_owed(a);
  ASSERT v = 5100, 'CM8: full refund after transfer: organizer owes its whole planned share: ' || v;
  PERFORM pg_temp.ord('cm-s7', d1, NULL, 1, 100, pg_temp.plan(d1, NULL, 1, 100, true, false));
  r := public.exos_commission_plan_due(a);
  SELECT * INTO o FROM public.exos_commission_transfers WHERE session_id = 'cm-s7' AND kind = 'split_org';
  ASSERT o.gross_cents = 1900 AND o.amount_cents = 0 AND o.status = 'netted', 'CM8: a share fully netted moves nothing';
  ASSERT pg_temp.org_owed(a) = 3200, 'CM8: the rest (5100 - 1900) is carried forward';
  ASSERT EXISTS (SELECT 1 FROM public.exos_commission_netting WHERE kind = 'carry' AND carried_from = o.id AND amount_cents = -3200),
         'CM8: a carry line';
  RAISE NOTICE 'OK  CM8 refunds after transfer: true-up, negative lines, netting, carry';
END $$;

-- CM9. Inside the Exos fee: the commission is what checkout charged, a
-- re-price leaves it, the held cap after a partial refund, one transfer.
DO $$
DECLARE d3 uuid := '0d0d0000-0000-0000-0000-0000000000d3'; x jsonb; r jsonb; t record; po record;
BEGIN
  x := pg_temp.plan(d3, 'cm-p', 2, 200, false, true);
  PERFORM pg_temp.ord('cm-f1', d3, 'cm-p', 2, 200, x);
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE session_id = 'cm-f1' AND method = 'platform_fee' AND commission_cents = 200) = 2,
         'CM9: accrued at the quote';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_promoter_terms(current_setting('test.p')::uuid, 2000, 0, NULL, true);
  PERFORM set_config('app.uid','',false);
  ASSERT (SELECT sum(commission_cents) FROM public.exos_promoter_commissions WHERE session_id = 'cm-f1') = 400,
         'CM9: a re-price leaves what the fee collected';
  ASSERT (SELECT commission_cents FROM public.exos_promoter_commissions WHERE session_id = 'cm-m1') = 400,
         'CM9: a manual sale is re-priced as before';
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_promoter_terms(current_setting('test.p')::uuid, 1000, 0, NULL, true);
  PERFORM set_config('app.uid','',false);
  -- A partial refund that keeps the tickets: Stripe gave back a quarter of the fee.
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,currency,status,is_partial)
  VALUES ('cm-f1','0d0d0000-0000-0000-0000-000000000001','re_cmf1',1000,'usd','succeeded',true);
  r := public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000001');
  SELECT * INTO t FROM public.exos_commission_transfers WHERE kind = 'fee_promoter' AND promoter_id = current_setting('test.p')::uuid;
  SELECT * INTO po FROM public.exos_promoter_payouts WHERE id = t.payout_id;
  ASSERT t.amount_cents = 300 AND t.source_charge_id IS NULL AND t.transfer_group ~ '^exos-fee-' AND po.via = 'platform_fee'
     AND po.commission_cents = 400 AND po.clawback_cents = 100 AND po.amount_cents = 300,
     'CM9: 400 commission, 100 shortfall, 300 sent: ' || row_to_json(t)::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_commission_netting WHERE kind = 'shortfall' AND applied_payout_id = po.id AND amount_cents = -100),
         'CM9: the shortfall is a ledger line';
  r := public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000001');
  ASSERT (SELECT count(*) FROM public.exos_commission_transfers WHERE kind = 'fee_promoter') = 1, 'CM9: planning is idempotent';
  PERFORM set_config('test.fee_ct', t.id::text, false);
  RAISE NOTICE 'OK  CM9 platform fee: quote, re-price lock, held cap';
END $$;

-- CM10. Cancel a transfer that never went out: sales unpaid again, the
-- shortfall voided; a late 'sent' still wins (restores and alerts).
DO $$
DECLARE ct uuid := current_setting('test.fee_ct')::uuid; c jsonb; po uuid;
BEGIN
  SELECT payout_id INTO po FROM public.exos_commission_transfers WHERE id = ct;
  c := public.exos_ct_claim(ct, 'cancel', '0d0d0000-0000-0000-0000-0000000000a2');
  ASSERT (c->>'ok')::boolean AND NOT (c->>'needs_reconcile')::boolean, 'CM10: cancel claim';
  ASSERT public.exos_ct_cancel(ct, (c->>'lease_token')::uuid), 'CM10: cancelled';
  ASSERT public.exos_ct_cancel(ct, (c->>'lease_token')::uuid), 'CM10: cancel is idempotent';
  ASSERT (SELECT bool_and(status = 'accrued' AND payout_id IS NULL) FROM public.exos_promoter_commissions WHERE session_id = 'cm-f1'),
         'CM10: sales unpaid again';
  ASSERT (SELECT transfer_status = 'cancelled' AND cancelled_at IS NOT NULL FROM public.exos_promoter_payouts WHERE id = po), 'CM10: payout cancelled';
  ASSERT (SELECT voided_at IS NOT NULL FROM public.exos_commission_netting WHERE kind = 'shortfall' AND applied_payout_id = po), 'CM10: shortfall voided';
  ASSERT public.exos_ct_mark(ct, 'sent', 'tr_cmLate'), 'CM10: a late sent is recorded';
  ASSERT (SELECT status = 'sent' AND alert LIKE '%after it was cancelled%' FROM public.exos_commission_transfers WHERE id = ct), 'CM10: with an alert';
  ASSERT (SELECT bool_and(status = 'paid' AND payout_id = po) FROM public.exos_promoter_commissions WHERE session_id = 'cm-f1'),
         'CM10: sales restored to the payout that went out';
  ASSERT (SELECT transfer_status FROM public.exos_promoter_payouts WHERE id = po) = 'sent', 'CM10: payout sent';
  RAISE NOTICE 'OK  CM10 cancel, late sent wins';
END $$;

-- CM11. Netting stays with the party that paid: a refund Exos absorbed is
-- not netted from the organizer's own payout, and vice versa; overdue shows.
DO $$
DECLARE a uuid := '0d0d0000-0000-0000-0000-000000000001'; d4 uuid := '0d0d0000-0000-0000-0000-0000000000d4';
        p uuid := current_setting('test.p')::uuid; r jsonb; b jsonb; row jsonb; ok boolean := false;
BEGIN
  -- cm-f1 (fee, sent) fully refunded: P owes Exos 400.
  PERFORM pg_temp.void1('cm-f1'); PERFORM pg_temp.void1('cm-f1');
  ASSERT (SELECT -sum(amount_cents) FROM public.exos_commission_netting WHERE promoter_id = p AND funder = 'platform'
            AND applied_payout_id IS NULL AND voided_at IS NULL) = 400, 'CM11: 400 owed to Exos';
  -- P's manual sale cm-m1 (200) is settled by the organizer at the full 200.
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a2',false);
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(p, pg_temp.ids('cm-m1'), 0, 'Venmo', 'cm-wrongnet1');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM11: the organizer doesn''t net what Exos is owed';
  r := public.exos_settle_promoter(p, pg_temp.ids('cm-m1'), 200, 'Venmo', 'cm-manual-001');
  ASSERT (r->>'amount_cents')::int = 200, 'CM11: manual settle at 200';
  -- Exos-paid sales can't be settled here.
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(current_setting('test.q')::uuid, pg_temp.ids('cm-s2'), 600, 'Venmo', 'cm-wrongway1');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'CM11: split sales are paid by Exos, not settled here';
  PERFORM set_config('app.uid','',false);
  -- cm-m1 refunded after the manual payout: owed to the organizer.
  PERFORM pg_temp.void1('cm-m1');
  ASSERT (SELECT funder FROM public.exos_commission_netting WHERE session_id = 'cm-m1') = 'organizer', 'CM11: owed to the organizer';
  -- Overdue after the alert days.
  UPDATE public.exos_commission_netting SET created_at = now() - interval '40 days' WHERE promoter_id = p AND funder = 'platform' AND voided_at IS NULL AND applied_payout_id IS NULL;
  PERFORM set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a3',false);
  b := public.exos_commission_balances(a);
  SELECT e INTO row FROM jsonb_array_elements(b->'promoters') e WHERE e->>'promoter_id' = p::text AND e->>'currency' = 'usd';
  ASSERT (row->>'netting_owed_to_exos_cents')::int = 400 AND (row->>'netting_owed_to_you_cents')::int = 200
     AND (row->>'netting_overdue')::boolean, 'CM11: balances show both, overdue: ' || row::text;
  ASSERT jsonb_array_length(b->'transfers') >= 5, 'CM11: recent transfers listed';
  ASSERT (SELECT (e->>'owed_to_exos_cents')::int FROM jsonb_array_elements(b->'organizer') e) = 3200, 'CM11: organizer balance owed';
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  CM11 netting per funder, balances, overdue';
END $$;

-- CM12. Q connects: Q's split commission is planned, and a dispute lost
-- after a transfer trues the organizer up to nothing.
DO $$
DECLARE a uuid := '0d0d0000-0000-0000-0000-000000000001'; r jsonb; before bigint;
BEGIN
  PERFORM public.exos_record_promoter_stripe(current_setting('test.q')::uuid, 'acct_cmQ', true, true, true);
  r := public.exos_commission_plan_due(a);
  -- cm-s2 was fully refunded (tickets still valid): Q's 600 still stands but
  -- nothing is left in the charge for it.
  ASSERT (SELECT po.amount_cents = 0 AND po.clawback_cents = 600 FROM public.exos_promoter_payouts po
           JOIN public.exos_promoter_commissions c ON c.payout_id = po.id WHERE c.session_id = 'cm-s2' LIMIT 1),
         'CM12: Q''s commission on a fully refunded order is a shortfall, not a transfer';
  ASSERT (SELECT amount_cents FROM public.exos_commission_transfers WHERE session_id = 'cm-s4' AND kind = 'split_org') = 1700, 'CM12: cm-s4 unchanged';
  before := pg_temp.org_owed(a);
  UPDATE public.exos_checkout_sessions SET dispute_status = 'lost' WHERE session_id = 'cm-s4';
  ASSERT pg_temp.org_owed(a) = before + 1700, 'CM12: a lost dispute: the organizer owes their whole share';
  RAISE NOTICE 'OK  CM12 late account, lost dispute';
END $$;

-- CM13. RLS, grants and cross-org isolation.
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000a3',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_commission_transfers) >= 5, 'CM13: finance reads transfers';
  ASSERT (SELECT count(*) FROM public.exos_commission_netting) >= 3, 'CM13: finance reads netting';
  ASSERT (SELECT count(*) FROM public.exos_checkout_commission_plans) >= 5, 'CM13: finance reads plans';
  ok := false;
  BEGIN PERFORM public.exos_ct_claim(gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: authenticated cannot call the job''s functions';
  ok := false;
  BEGIN PERFORM public.exos_commission_plan_due(NULL);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: nor plan transfers';
  ok := false;
  BEGIN INSERT INTO public.exos_org_commission_settings(org_id) VALUES ('0d0d0000-0000-0000-0000-000000000002');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: no client writes';
  ok := false;
  BEGIN UPDATE public.exos_commission_netting SET voided_at = now();
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: no client writes to netting';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0d0d0000-0000-0000-0000-0000000000b1',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_commission_transfers) = 0, 'CM13: org B sees no transfers of A';
  ASSERT (SELECT count(*) FROM public.exos_commission_netting) = 0, 'CM13: org B sees no netting of A';
  ASSERT (SELECT count(*) FROM public.exos_org_commission_settings) = 0, 'CM13: org B sees no settings of A';
  ASSERT (SELECT count(*) FROM public.exos_event_commission_settings WHERE org_id = '0d0d0000-0000-0000-0000-000000000001') = 0
     AND (SELECT count(*) FROM public.exos_event_commission_settings) = 1, 'CM13: org B sees only its own event lock';
  ASSERT (SELECT count(*) FROM public.exos_checkout_commission_plans) = 0, 'CM13: org B sees no plans of A (none of its own)';
  BEGIN PERFORM public.exos_commission_balances('0d0d0000-0000-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: org B cannot read A''s balances';
  ok := false;
  BEGIN PERFORM public.exos_set_commission_settings('0d0d0000-0000-0000-0000-000000000001', 'manual', 3);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: org B cannot change A''s settings';
  ok := false;
  BEGIN PERFORM public.exos_set_event_commission_method('0d0d0000-0000-0000-0000-0000000000e5', 'manual');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: org B cannot set A''s event method';
  ok := false;
  BEGIN PERFORM public.exos_set_promoter_commission_method(current_setting('test.p')::uuid, 'manual');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: org B cannot set A''s promoter method';
  ok := false;
  BEGIN PERFORM * FROM public.exos_commission_payable(current_setting('test.p')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'CM13: org B cannot list A''s payable sales';
  RAISE NOTICE 'OK  CM13 RLS, grants and cross-org isolation';
END $$;
RESET ROLE;
SELECT set_config('app.uid','',false);
DO $$
DECLARE ok boolean := false;
BEGIN
  -- Org B's planner never touches org A.
  ASSERT (public.exos_commission_plan_due('0d0d0000-0000-0000-0000-000000000002')->>'planned')::int = 0, 'CM13: org B plans nothing';
  -- A plan for another org's session is refused by the FK / org match.
  ASSERT (SELECT org_id FROM public.exos_checkout_commission_plans WHERE session_id = 'cm-s1') = '0d0d0000-0000-0000-0000-000000000001',
         'CM13: plan rows carry the session''s org';
  ASSERT public.exos_ct_claim((SELECT id FROM public.exos_commission_transfers WHERE session_id = 'cm-s4' AND kind = 'split_org'),
                              'send', '0d0d0000-0000-0000-0000-0000000000b1')->>'error' = 'not_found', 'CM13: org B''s owner cannot send A''s transfer';
END $$;

-- CM14. Every new definer function pins search_path; none is anon; the
-- job's are service-role only.
DO $$
DECLARE bad text;
  svc text[] := ARRAY['_exos_commission_pin', '_exos_commission_resolve', '_exos_commission_payable_at',
                      '_exos_org_promoter_stripe_needed', 'exos_commission_checkout_plan', 'exos_record_commission_plan',
                      '_exos_split_entitlement', '_exos_split_true_up', '_exos_ct_pay_promoter', '_exos_split_plan_order',
                      '_exos_fee_plan_promoter', 'exos_commission_plan_due', 'exos_commission_record_charge', '_exos_ct_mirror',
                      'exos_ct_due', 'exos_ct_claim', 'exos_ct_lease_ok', 'exos_ct_mark', 'exos_ct_reconcile',
                      'exos_ct_lease_release', 'exos_ct_cancel', 'exos_tg_pc_method', 'exos_tg_pc_gate', 'exos_tg_pc_netting',
                      'exos_tg_split_true_up'];
  usr text[] := ARRAY['exos_get_commission_settings', 'exos_set_commission_settings', 'exos_set_event_commission_method',
                      'exos_set_promoter_commission_method', 'exos_commission_balances', 'exos_commission_payable'];
BEGIN
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = ANY (svc || usr)
     AND (NOT p.prosecdef OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));
  ASSERT bad IS NULL, 'CM14: not definer with a pinned search_path: ' || bad;
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = ANY (svc || usr) AND has_function_privilege('anon', p.oid, 'EXECUTE');
  ASSERT bad IS NULL, 'CM14: anon may call ' || bad;
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = ANY (svc) AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
  ASSERT bad IS NULL, 'CM14: authenticated may call service functions ' || bad;
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = ANY (usr) AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  ASSERT bad IS NULL, 'CM14: dashboard functions not callable signed in: ' || bad;
  ASSERT NOT has_function_privilege('authenticated', 'public.exos_promoter_by_token(uuid)', 'EXECUTE'), 'CM14: by_token stays service-only';
  ASSERT has_function_privilege('anon', 'public.exos_promoter_earnings(uuid)', 'EXECUTE'), 'CM14: earnings keeps its token grant';
  RAISE NOTICE 'OK  CM14 search_path pinned; grants as intended';
END $$;

\echo 'test_commission_methods: all passed'
ROLLBACK;
