-- ============================================================================
-- The promoter wedge (mig 20261102150000): step commissions, idempotent
-- settle, Stripe transfer funding + cap, leaderboard, instant payouts ledger,
-- money so far, phone-number RSVP. Self-contained (ids 0f0f…, slugs pw-*),
-- everything rolled back.
-- Users: org A owner …a1, manager …a2, finance …a3, stranger …a4, buyer …a5;
--        org B owner …b1.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('0f0f0000-0000-0000-0000-0000000000a1','pwowner@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000a2','pwmanager@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000a3','pwfinance@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000a4','pwstranger@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000a5','pwbuyer@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000b1','pwbowner@x.com',now()),
  ('0f0f0000-0000-0000-0000-0000000000c1','pwguest@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('0f0f0000-0000-0000-0000-000000000001','PW Org','pw-org','0f0f0000-0000-0000-0000-0000000000a1'),
  ('0f0f0000-0000-0000-0000-000000000002','PW Other','pw-other','0f0f0000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1','owner'),
  ('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a2','manager'),
  ('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a3','finance'),
  ('0f0f0000-0000-0000-0000-000000000002','0f0f0000-0000-0000-0000-0000000000b1','owner');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,currency) VALUES
  ('0f0f0000-0000-0000-0000-0000000000e1','0f0f0000-0000-0000-0000-000000000001','PW Paid Night','published',now()+interval '7 days','usd'),
  ('0f0f0000-0000-0000-0000-0000000000e2','0f0f0000-0000-0000-0000-000000000001','PW Free Night','published',now()+interval '3 days','usd'),
  ('0f0f0000-0000-0000-0000-0000000000e3','0f0f0000-0000-0000-0000-000000000002','PW Other Night','published',now()+interval '3 days','usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('0f0f0000-0000-0000-0000-0000000000d1','0f0f0000-0000-0000-0000-0000000000e1','GA',20,0,0),
  ('0f0f0000-0000-0000-0000-0000000000d2','0f0f0000-0000-0000-0000-0000000000e2','RSVP',0,6,0),
  ('0f0f0000-0000-0000-0000-0000000000d3','0f0f0000-0000-0000-0000-0000000000e2','VIP',25,0,0),
  ('0f0f0000-0000-0000-0000-0000000000d4','0f0f0000-0000-0000-0000-0000000000e3','RSVP',0,0,0);

-- Promoters: P (10%, step after 2 -> 15%), Q (10%), R in org B.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a1',false);
SELECT public.exos_upsert_promoter('0f0f0000-0000-0000-0000-000000000001','pw-p','Promoter P');
SELECT public.exos_upsert_promoter('0f0f0000-0000-0000-0000-000000000001','pw-q','Promoter Q');
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000b1',false);
SELECT public.exos_upsert_promoter('0f0f0000-0000-0000-0000-000000000002','pw-r','Promoter R');
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE p uuid; q uuid; r uuid;
BEGIN
  SELECT id INTO p FROM public.exos_promoters WHERE code='pw-p';
  SELECT id INTO q FROM public.exos_promoters WHERE code='pw-q';
  SELECT id INTO r FROM public.exos_promoters WHERE code='pw-r';
  PERFORM public.exos_set_promoter_terms(p, 1000, 0);
  PERFORM public.exos_set_promoter_step(p, 2, 1500, 0);
  PERFORM public.exos_set_promoter_terms(q, 1000, 0);
  PERFORM set_config('test.p', p::text, false);
  PERFORM set_config('test.q', q::text, false);
  PERFORM set_config('test.r', r::text, false);
END $$;
SELECT set_config('app.uid','',false);

-- Paid orders on E1 (2000 per ticket, no tax), all Stripe:
--   w1: P x3 (ordinals 1, 2, 3)  app fee 180  transfer tr_w1
--   w2: Q x1                     app fee 1990 transfer tr_w2 (organizer kept 10c)
--   w3: Q x1                     no transfer id (organizer not paid through Stripe)
--   w4: P x1                     app fee 60   transfer tr_w4
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id,application_fee_cents,exos_fee_cents,card_fee_est_cents) VALUES
  ('pw-w1','0f0f0000-0000-0000-0000-0000000000e1','0f0f0000-0000-0000-0000-0000000000d1','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a5','pwbuyer@x.com',3,6000,'pending','pw-p',180,180,0),
  ('pw-w2','0f0f0000-0000-0000-0000-0000000000e1','0f0f0000-0000-0000-0000-0000000000d1','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a5','pwbuyer@x.com',1,2000,'pending','pw-q',1990,1990,0),
  ('pw-w3','0f0f0000-0000-0000-0000-0000000000e1','0f0f0000-0000-0000-0000-0000000000d1','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a5','pwbuyer@x.com',1,2000,'pending','pw-q',60,60,0),
  ('pw-w4','0f0f0000-0000-0000-0000-0000000000e1','0f0f0000-0000-0000-0000-0000000000d1','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a5','pwbuyer@x.com',1,2000,'pending','pw-p',60,60,0);
SELECT public.exos_fulfill_checkout('pw-w1');
SELECT public.exos_fulfill_checkout('pw-w2');
SELECT public.exos_fulfill_checkout('pw-w3');
SELECT public.exos_fulfill_checkout('pw-w4');
INSERT INTO public.exos_order_payments(session_id,org_id,event_id,payment_intent,amount_cents,currency,status,transfer_id) VALUES
  ('pw-w1','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000e1','pi_pww1',6000,'usd','succeeded','tr_pww1'),
  ('pw-w2','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000e1','pi_pww2',2000,'usd','succeeded','tr_pww2'),
  ('pw-w3','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000e1','pi_pww3',2000,'usd','succeeded',NULL),
  ('pw-w4','0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000e1','pi_pww4',2000,'usd','succeeded','tr_pww4');

-- PW1. Step terms: the third ticket at the event earns the step rate.
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(c.commission_cents || (CASE WHEN c.stepped THEN 's' ELSE '' END), ',' ORDER BY c.commission_cents, c.stepped) INTO v
    FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id WHERE t.order_ref = 'pw-w1';
  ASSERT v = '200,200,300s', 'PW1: 10%, 10%, then 15% stepped, got ' || v;
  ASSERT (SELECT c.commission_cents FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
           WHERE t.order_ref = 'pw-w4') = 300, 'PW1: fourth ticket stays on the step';
  RAISE NOTICE 'OK  PW1 step terms by ticket ordinal at the event';
END $$;

-- PW2. Re-pricing is step-aware; an event override replaces the step.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE p uuid := current_setting('test.p')::uuid; n int; v text;
BEGIN
  n := public.exos_set_promoter_step(p, 3, 2000, 0, NULL, true);
  ASSERT n = 4, 'PW2: four accrued rows re-priced, got ' || n;
  SELECT string_agg(c.commission_cents::text, ',' ORDER BY c.accrued_at, c.id) INTO v
    FROM public.exos_promoter_commissions c WHERE c.promoter_id = p;
  ASSERT v = '200,200,200,400', 'PW2: step after 3 at 20%, got ' || v;
  PERFORM public.exos_set_promoter_terms(p, 500, 0, '0f0f0000-0000-0000-0000-0000000000e1', true);
  SELECT string_agg(c.commission_cents::text, ',' ORDER BY c.accrued_at, c.id) INTO v
    FROM public.exos_promoter_commissions c WHERE c.promoter_id = p;
  ASSERT v = '100,100,100,100', 'PW2: the override (5%, no step) wins, got ' || v;
  BEGIN
    PERFORM public.exos_set_promoter_step(p, 1, 900, 0, '0f0f0000-0000-0000-0000-0000000000e2');
    ASSERT false, 'PW2: step on an event without an override';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  -- Back to the default (10%, step after 2 -> 15%).
  PERFORM public.exos_set_promoter_terms(p, NULL, NULL, '0f0f0000-0000-0000-0000-0000000000e1');
  PERFORM public.exos_set_promoter_step(p, 2, 1500, 0, NULL, true);
  SELECT string_agg(c.commission_cents::text, ',' ORDER BY c.accrued_at, c.id) INTO v
    FROM public.exos_promoter_commissions c WHERE c.promoter_id = p;
  ASSERT v = '200,200,300,300', 'PW2: restored, got ' || v;
  RAISE NOTICE 'OK  PW2 step-aware re-price; override replaces the step';
END $$;
SELECT set_config('app.uid','',false);

-- PW3. Idempotent manual settle.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a2',false);
DO $$
DECLARE q uuid := current_setting('test.q')::uuid; ids uuid[]; a jsonb; b jsonb; ok boolean := false;
BEGIN
  SELECT array_agg(c.id) INTO ids FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
   WHERE t.order_ref = 'pw-w3';
  a := public.exos_settle_promoter(q, ids, 200, 'Venmo', 'key-manual-0001');
  b := public.exos_settle_promoter(q, ids, 200, 'Venmo', 'key-manual-0001');
  ASSERT (a->>'replayed')::boolean = false AND (b->>'replayed')::boolean = true AND a->>'payout_id' = b->>'payout_id',
         'PW3: same key, same payout: ' || a::text || ' / ' || b::text;
  ASSERT (SELECT count(*) FROM public.exos_promoter_payouts WHERE promoter_id = q) = 1, 'PW3: one payout row';
  BEGIN PERFORM public.exos_settle_promoter(q, ids, 199, 'Venmo', 'key-manual-0001');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW3: key reused for another amount is refused';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(q, ids, 200, 'Venmo', 'key-manual-0002');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW3: a new key cannot pay the same sales twice';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(q, ids, 200, 'Venmo', 'bad key');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW3: key format checked';
  RAISE NOTICE 'OK  PW3 settle is idempotent per key';
END $$;
SELECT set_config('app.uid','',false);

-- PW4. Stripe settle: switch (owner only), payout account, fundable sales.
DO $$
DECLARE p uuid := current_setting('test.p')::uuid; q uuid := current_setting('test.q')::uuid; ids uuid[]; ok boolean;
BEGIN
  PERFORM set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a2',false);
  SELECT array_agg(c.id) INTO ids FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
   WHERE t.order_ref = 'pw-w1';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(p, ids, 700, 'x', 'key-stripe-0001', 'stripe');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW4: stripe refused while the org switch is off';
  ok := false;
  BEGIN PERFORM public.exos_set_promoter_stripe_transfers('0f0f0000-0000-0000-0000-000000000001', true);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW4: a manager cannot turn the switch on';
  PERFORM set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a1',false);
  PERFORM public.exos_set_promoter_stripe_transfers('0f0f0000-0000-0000-0000-000000000001', true);
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(p, ids, 700, 'x', 'key-stripe-0001', 'stripe');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW4: refused until the promoter has a ready payout account';
  PERFORM public.exos_record_promoter_stripe(p, 'acct_pwP', true, true, true);
  PERFORM public.exos_record_promoter_stripe(q, 'acct_pwQ', true, true, true);
  RAISE NOTICE 'OK  PW4 stripe settle needs the owner switch and a ready account';
END $$;

-- PW5. The transfer cap: never more than the organizer received per order.
DO $$
DECLARE p uuid := current_setting('test.p')::uuid; q uuid := current_setting('test.q')::uuid;
        ids uuid[]; r jsonb; ok boolean;
BEGIN
  -- Q's w2 sale earns 200 but the organizer kept only 10c of that order.
  SELECT array_agg(c.id) INTO ids FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
   WHERE t.order_ref = 'pw-w2';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(q, ids, 200, 'x', 'key-stripe-cap1', 'stripe');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW5: more than the organizer received is refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_promoter_payouts WHERE idempotency_key = 'key-stripe-cap1'), 'PW5: nothing written';
  -- P's w1 (700): 5820 kept, fully fundable.
  SELECT array_agg(c.id) INTO ids FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
   WHERE t.order_ref = 'pw-w1';
  r := public.exos_settle_promoter(p, ids, 700, 'ignored', 'key-stripe-0001', 'stripe');
  ASSERT r->>'transfer_status' = 'pending' AND r->>'via' = 'stripe', 'PW5: pending stripe payout ' || r::text;
  ASSERT (SELECT method FROM public.exos_promoter_payouts WHERE id = (r->>'payout_id')::uuid) = 'Stripe transfer', 'PW5: method set';
  ASSERT (SELECT string_agg(session_id || ':' || amount_cents || ':' || org_transfer_id || ':' || status, ',')
            FROM public.exos_promoter_payout_funding WHERE payout_id = (r->>'payout_id')::uuid) = 'pw-w1:700:tr_pww1:planned',
         'PW5: one funding line from w1';
  -- Refund most of w4 (net 1940 -> 40): its 300 commission can't be funded.
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,currency,status)
  VALUES ('pw-w4','0f0f0000-0000-0000-0000-000000000001','re_pww4',1900,'usd','succeeded');
  SELECT array_agg(c.id) INTO ids FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
   WHERE t.order_ref = 'pw-w4';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(p, ids, 300, 'x', 'key-stripe-cap2', 'stripe');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW5: refunds shrink what can be taken';
  DELETE FROM public.exos_order_refunds WHERE refund_id = 're_pww4';
  -- Funding already planned for an order counts against it.
  UPDATE public.exos_checkout_sessions SET application_fee_cents = 1800, exos_fee_cents = 1800 WHERE session_id = 'pw-w4';  -- net 200
  INSERT INTO public.exos_promoter_payout_funding(payout_id, session_id, org_id, org_transfer_id, amount_cents)
  VALUES ((r->>'payout_id')::uuid, 'pw-w4', '0f0f0000-0000-0000-0000-000000000001', 'tr_pww4', 1);
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(p, ids, 300, 'x', 'key-stripe-cap3', 'stripe');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW5: 300 > 200 - 1 kept';
  DELETE FROM public.exos_promoter_payout_funding WHERE session_id = 'pw-w4';
  UPDATE public.exos_checkout_sessions SET application_fee_cents = 60, exos_fee_cents = 60 WHERE session_id = 'pw-w4';
  -- A sale from an order with no Stripe transfer must be paid manually.
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(q,
          (SELECT array_agg(c.id) FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id = c.ticket_id
            WHERE t.order_ref = 'pw-w2'), 200, 'x', 'key-stripe-cap4', 'stripe');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW5: still capped';
  ASSERT (SELECT count(*) FROM public.exos_promoter_unpaid(q) u WHERE u.fundable) = 1, 'PW5: w2 listed as fundable';
  ASSERT (SELECT count(*) FROM public.exos_promoter_unpaid(p) u WHERE u.fundable) = 1, 'PW5: w4 listed as fundable';
  PERFORM set_config('test.po1', r->>'payout_id', false);
  RAISE NOTICE 'OK  PW5 transfer amount capped by what the organizer received';
END $$;

-- PW6. The send: claim (owner / manager only), funding lines, mark.
DO $$
DECLARE po uuid := current_setting('test.po1')::uuid; c jsonb; ok boolean;
BEGIN
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a3');
  ASSERT c->>'error' = 'not_found', 'PW6: finance cannot send';
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000b1');
  ASSERT c->>'error' = 'not_found', 'PW6: another org''s owner cannot send';
  -- A tampered funding line makes the claim refuse.
  UPDATE public.exos_promoter_payout_funding SET amount_cents = 701 WHERE payout_id = po;
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a2');
  ASSERT c->>'error' = 'funding_mismatch', 'PW6: lines must add up to the payout: ' || c::text;
  UPDATE public.exos_promoter_payout_funding SET amount_cents = 700 WHERE payout_id = po;
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a2');
  ASSERT (c->>'ok')::boolean AND (c->>'amount_cents')::int = 700 AND c->>'destination' = 'acct_pwP'
         AND jsonb_array_length(c->'lines') = 1, 'PW6: claimed ' || c::text;
  ASSERT public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a2')->>'error' = 'busy', 'PW6: leased';
  ok := false;
  BEGIN PERFORM public.exos_promoter_transfer_mark(po, 'sent', 'tr_pwout1');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW6: sent before the funding is taken is refused';
  ASSERT public.exos_promoter_funding_mark(po, 'pw-w1', 'taken', 'trr_pww1'), 'PW6: line taken';
  ASSERT public.exos_promoter_transfer_mark(po, 'sent', 'tr_pwout1'), 'PW6: sent';
  ASSERT public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a2')->>'error' = 'sent', 'PW6: no resend';
  RAISE NOTICE 'OK  PW6 claim, fund, send';
END $$;

-- PW7. Cancel a payout that never went out; its sales are unpaid again.
DO $$
DECLARE p uuid := current_setting('test.p')::uuid; ids uuid[]; r jsonb; c jsonb; e jsonb;
BEGIN
  SELECT array_agg(c2.id) INTO ids FROM public.exos_promoter_commissions c2 JOIN public.exos_tickets t ON t.id = c2.ticket_id
   WHERE t.order_ref = 'pw-w4';
  r := public.exos_settle_promoter(p, ids, 300, 'x', 'key-stripe-0002', 'stripe');
  c := public.exos_promoter_transfer_claim((r->>'payout_id')::uuid, '0f0f0000-0000-0000-0000-0000000000a1');
  PERFORM public.exos_promoter_transfer_mark((r->>'payout_id')::uuid, 'dry_run');
  e := public.exos_promoter_earnings((SELECT kit_token FROM public.exos_promoters WHERE id = p));
  ASSERT (e->'totals'->0->>'paid_cents')::int = 700 AND (e->'totals'->0->>'processing_cents')::int = 300,
         'PW7: dry run shows as processing, not paid: ' || (e->'totals')::text;
  c := public.exos_promoter_transfer_claim((r->>'payout_id')::uuid, '0f0f0000-0000-0000-0000-0000000000a1', 'cancel');
  ASSERT (c->>'ok')::boolean AND (c->>'needs_reconcile')::boolean, 'PW7: claimed for cancel; a send was started ' || c::text;
  -- Cancel is refused from 'sending' until Stripe has been checked.
  BEGIN
    PERFORM public.exos_promoter_payout_cancel((r->>'payout_id')::uuid);
    ASSERT false, 'PW7: cancel before reconcile';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  ASSERT public.exos_promoter_transfer_reconcile((r->>'payout_id')::uuid, NULL) = 'reconciled', 'PW7: Stripe has nothing';
  ASSERT public.exos_promoter_payout_cancel((r->>'payout_id')::uuid), 'PW7: cancelled';
  ASSERT (SELECT status FROM public.exos_promoter_commissions WHERE id = ids[1]) = 'accrued', 'PW7: sale unpaid again';
  ASSERT (SELECT status FROM public.exos_promoter_payout_funding WHERE payout_id = (r->>'payout_id')::uuid) = 'released', 'PW7: funding released';
  e := public.exos_promoter_earnings((SELECT kit_token FROM public.exos_promoters WHERE id = p));
  ASSERT jsonb_array_length(e->'payouts') = 1 AND (e->'totals'->0->>'owed_cents')::int = 300, 'PW7: earnings ' || e::text;
  ASSERT e->'payout_account'->>'ready' = 'true' AND e->'terms'->>'step_after' = '2', 'PW7: account + step on the portal';
  ASSERT position('acct_' in e::text) = 0 AND position('pwbuyer' in e::text) = 0, 'PW7: no account id or buyer data';
  -- A sent payout can't be cancelled.
  ASSERT NOT public.exos_promoter_payout_cancel(current_setting('test.po1')::uuid), 'PW7: sent stays sent';
  RAISE NOTICE 'OK  PW7 cancel returns sales; earnings split paid / processing';
END $$;

-- PW7b. The transfer went out but 'sent' was never recorded: reconcile marks
--       it sent and the cancel is refused, so the sales can't be paid twice.
DO $$
DECLARE p uuid := current_setting('test.p')::uuid; ids uuid[]; r jsonb; c jsonb; po uuid;
BEGIN
  SELECT array_agg(c2.id) INTO ids FROM public.exos_promoter_commissions c2 JOIN public.exos_tickets t ON t.id = c2.ticket_id
   WHERE t.order_ref = 'pw-w4';
  r := public.exos_settle_promoter(p, ids, 300, 'x', 'key-stripe-0003', 'stripe');
  po := (r->>'payout_id')::uuid;
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a1');
  ASSERT (c->>'ok')::boolean, 'PW7b: send claimed';
  -- (Stripe reversed and transferred; the function crashed before marking.)
  UPDATE public.exos_promoter_payouts SET lease_until = now() - interval '1 second' WHERE id = po;
  c := public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a1', 'cancel');
  ASSERT (c->>'needs_reconcile')::boolean, 'PW7b: reconcile required';
  BEGIN
    PERFORM public.exos_promoter_payout_cancel(po);
    ASSERT false, 'PW7b: cancel from sending';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  ASSERT public.exos_promoter_transfer_reconcile(po, 'tr_pwfound', '[{"session_id":"pw-w4","reversal_id":"trr_pwfound"}]') = 'sent',
         'PW7b: found at Stripe, so sent';
  ASSERT (SELECT transfer_status || ':' || stripe_transfer_id FROM public.exos_promoter_payouts WHERE id = po) = 'sent:tr_pwfound', 'PW7b: recorded';
  ASSERT (SELECT status || ':' || reversal_id FROM public.exos_promoter_payout_funding WHERE payout_id = po) = 'taken:trr_pwfound', 'PW7b: reversal recorded';
  ASSERT NOT public.exos_promoter_payout_cancel(po), 'PW7b: a sent payout is never cancelled';
  ASSERT public.exos_promoter_transfer_claim(po, '0f0f0000-0000-0000-0000-0000000000a1', 'cancel')->>'error' = 'sent', 'PW7b: no cancel claim';
  ASSERT (SELECT bool_and(status = 'paid' AND payout_id = po) FROM public.exos_promoter_commissions WHERE id = ANY (ids)), 'PW7b: sales stay paid';
  RAISE NOTICE 'OK  PW7b reconcile before cancel: a sent transfer stays sent';
END $$;
SELECT set_config('app.uid','',false);

-- PW8. RLS, grants and cross-org isolation for the payout tables.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a3',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_promoter_payout_funding) >= 1, 'PW8: finance reads funding';
  ASSERT (SELECT count(*) FROM public.exos_promoter_stripe_accounts) = 2, 'PW8: finance reads accounts';
  ok := false;
  BEGIN PERFORM public.exos_settle_promoter(current_setting('test.q')::uuid, ARRAY[gen_random_uuid()], 0, 'x', 'key-fin-00001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW8: finance cannot settle';
  ok := false;
  BEGIN PERFORM public.exos_promoter_transfer_claim(current_setting('test.po1')::uuid, '0f0f0000-0000-0000-0000-0000000000a1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW8: authenticated cannot call the job''s functions';
  ok := false;
  BEGIN INSERT INTO public.exos_promoter_stripe_accounts(promoter_id, org_id, stripe_account_id)
        VALUES (current_setting('test.q')::uuid, '0f0f0000-0000-0000-0000-000000000001', 'acct_evil');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW8: no client writes';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000b1',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_promoter_payout_funding) = 0, 'PW8: org B sees no funding of A';
  ASSERT (SELECT count(*) FROM public.exos_promoter_stripe_accounts) = 0, 'PW8: org B sees no accounts of A';
  ASSERT (SELECT count(*) FROM public.exos_org_promoter_payouts) = 0, 'PW8: org B sees no switch of A';
  BEGIN PERFORM * FROM public.exos_promoter_unpaid(current_setting('test.p')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW8: org B cannot list A''s unpaid sales';
  ok := false;
  BEGIN PERFORM public.exos_set_promoter_step(current_setting('test.p')::uuid, 1, 0, 0);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW8: org B cannot set A''s terms';
  RAISE NOTICE 'OK  PW8 payout RLS, grants and cross-org isolation';
END $$;
RESET ROLE;
SELECT set_config('app.uid','',false);

-- PW9. The promoter leaderboard: token-gated, names + tickets only, own org.
SELECT set_config('test.tp', (SELECT kit_token::text FROM public.exos_promoters WHERE code = 'pw-p'), false);
SELECT set_config('test.tr', (SELECT kit_token::text FROM public.exos_promoters WHERE code = 'pw-r'), false);
SET LOCAL ROLE anon;
DO $$
DECLARE b jsonb; tp uuid := current_setting('test.tp')::uuid; tr uuid := current_setting('test.tr')::uuid;
BEGIN
  b := public.exos_promoter_leaderboard(tp);
  ASSERT (b->>'promoters')::int = 2, 'PW9: two active promoters in org A: ' || b::text;
  ASSERT b->'rows'->0->>'name' = 'Promoter P' AND (b->'rows'->0->>'tickets')::int = 4 AND (b->'rows'->0->>'me')::boolean,
         'PW9: P first with 4 tickets: ' || b::text;
  ASSERT position('Promoter R' in b::text) = 0 AND position('cents' in b::text) = 0 AND position('pw-p' in b::text) = 0,
         'PW9: no other org, money or codes';
  ASSERT public.exos_promoter_leaderboard(gen_random_uuid()) IS NULL, 'PW9: wrong token';
  ASSERT public.exos_promoter_leaderboard(tp, '0f0f0000-0000-0000-0000-0000000000e3') IS NULL, 'PW9: other org''s event';
  ASSERT (public.exos_promoter_leaderboard(tr)->>'promoters')::int = 1, 'PW9: org B board';
  RAISE NOTICE 'OK  PW9 leaderboard scoped to the token''s org';
END $$;
RESET ROLE;

-- PW10. Instant payout ledger: owner only, idempotent per key, 5 a day.
DO $$
DECLARE a jsonb; b jsonb; i int;
BEGIN
  a := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a3',1000,'usd',50,'inst-key-0001');
  ASSERT a->>'error' = 'owner_only', 'PW10: finance cannot request';
  a := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000b1',1000,'usd',50,'inst-key-0001');
  ASSERT a->>'error' = 'owner_only', 'PW10: another org''s owner cannot request';
  a := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1',1000,'USD',50,'inst-key-0001');
  b := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1',1000,'usd',50,'inst-key-0001');
  ASSERT (a->>'ok')::boolean AND (b->>'replayed')::boolean AND a->>'id' = b->>'id', 'PW10: idempotent ' || b::text;
  b := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1',900,'usd',50,'inst-key-0001');
  ASSERT b->>'error' = 'key_reused', 'PW10: key reused';
  ASSERT public.exos_instant_payout_mark((a->>'id')::uuid, 'sent', 'po_pw1'), 'PW10: marked sent';
  FOR i IN 2..5 LOOP
    b := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1',100,'usd',50,'inst-key-000' || i);
    ASSERT (b->>'ok')::boolean, 'PW10: request ' || i;
  END LOOP;
  b := public.exos_instant_payout_begin('0f0f0000-0000-0000-0000-000000000001','0f0f0000-0000-0000-0000-0000000000a1',100,'usd',50,'inst-key-0006');
  ASSERT b->>'error' = 'daily_limit', 'PW10: sixth in a day refused';
  RAISE NOTICE 'OK  PW10 instant payouts: owner only, idempotent, capped';
END $$;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a2',false);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_org_instant_payouts) = 0, 'PW10: managers do not see instant payouts';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a3',false);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_org_instant_payouts) = 5, 'PW10: finance sees them';
END $$;
RESET ROLE;

-- PW11. Money so far.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a3',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE m jsonb;
BEGIN
  m := public.exos_event_money_so_far('0f0f0000-0000-0000-0000-0000000000e1');
  ASSERT (m->'online'->>'orders')::int = 4 AND (m->'online'->>'gross_cents')::int = 12000, 'PW11: gross ' || m::text;
  ASSERT (m->'online'->>'fees_cents')::int = 2290 AND (m->'online'->>'net_cents')::int = 9710, 'PW11: fees and net ' || m::text;
  ASSERT (m->'tickets'->>'paid')::int = 6, 'PW11: paid tickets';
  ASSERT (m->'promoters'->>'owed_cents')::int = 200 AND (m->'promoters'->>'paid_cents')::int = 1200,
         'PW11: commissions owed / paid ' || (m->'promoters')::text;
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a4',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.exos_event_money_so_far('0f0f0000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW11: a stranger is refused';
  RAISE NOTICE 'OK  PW11 money so far, staff only';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.exos_event_money_so_far('0f0f0000-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW11: anon is refused';
END $$;
RESET ROLE;
SELECT set_config('app.uid','',false);

-- PW12. Phone RSVP settings: owner / manager, free GA tiers only.
DO $$
DECLARE ok boolean;
BEGIN
  ASSERT (SELECT (public.exos_phone_rsvp_info('0f0f0000-0000-0000-0000-0000000000e2'))->>'reason') = 'off', 'PW12: off by default';
  PERFORM set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a4',false);
  ok := false;
  BEGIN PERFORM public.exos_set_phone_rsvp('0f0f0000-0000-0000-0000-0000000000e2', true);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW12: a stranger cannot turn it on';
  PERFORM set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a2',false);
  ok := false;
  BEGIN PERFORM public.exos_set_phone_rsvp('0f0f0000-0000-0000-0000-0000000000e2', true, '0f0f0000-0000-0000-0000-0000000000d3');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'PW12: a paid tier is refused';
  PERFORM public.exos_set_phone_rsvp('0f0f0000-0000-0000-0000-0000000000e2', true, NULL, 1);
  ASSERT (public.exos_phone_rsvp_info('0f0f0000-0000-0000-0000-0000000000e2'))->>'reason' = 'open', 'PW12: open';
  ASSERT (public.exos_phone_rsvp_info('0f0f0000-0000-0000-0000-0000000000e2'))->>'tier_name' = 'RSVP', 'PW12: picks the free tier';
  PERFORM set_config('app.uid','0f0f0000-0000-0000-0000-0000000000b1',false);
  PERFORM public.exos_set_phone_rsvp('0f0f0000-0000-0000-0000-0000000000e3', true);
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  PW12 phone RSVP settings';
END $$;

-- PW13. Start: validation, channel, rate limits.
DO $$
DECLARE r jsonb; i int;
BEGIN
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '555-0100', NULL, 0, NULL, true);
  ASSERT r->>'error' = 'bad_phone', 'PW13: short number';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', '  ', '(212) 555-0101', NULL, 0, NULL, true);
  ASSERT r->>'error' = 'bad_name', 'PW13: name required';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '(212) 555-0101', NULL, 2, NULL, true);
  ASSERT r->>'error' = 'too_many_guests', 'PW13: plus-ones capped at 1';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '(212) 555-0101', NULL, 0, NULL, false);
  ASSERT r->>'error' = 'no_channel', 'PW13: no texts and no email: not available';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '(212) 555-0101', 'Ana@X.com', 0, NULL, false);
  ASSERT r->>'channel' = 'email' AND r->>'code' IS NULL, 'PW13: email fallback, code not returned ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'rsvp-code' AND to_email = 'ana@x.com'), 'PW13: code mailed';
  -- A number that replied STOP to this org gets mail, not a text.
  INSERT INTO public.exos_sms_subscribers(org_id, phone, consent_text, opted_out_at)
  VALUES ('0f0f0000-0000-0000-0000-000000000001', '+12125550199', 'I agree to get texts from PW Org. Reply STOP to opt out.', now());
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Stop', '+12125550199', 'stop@x.com', 0, NULL, true);
  ASSERT r->>'channel' = 'email', 'PW13: opted-out number falls back to email';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '(212) 555-0101', NULL, 0, repeat('a', 64), true);
  ASSERT r->>'channel' = 'sms' AND r->>'code' ~ '^[0-9]{6}$' AND r->>'to' = '+12125550101', 'PW13: sms ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvps WHERE phone = '+12125550101' AND status = 'pending') = 1,
         'PW13: the newer code replaces the older one';
  -- Phone: 3 per 10 minutes (already 2 for this number).
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '+12125550101', NULL, 0, NULL, true);
  ASSERT (r->>'ok')::boolean, 'PW13: third ok';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ana', '+12125550101', NULL, 0, NULL, true);
  ASSERT r->>'error' = 'rate_limited', 'PW13: fourth in 10 minutes refused';
  -- Network: 10 per 10 minutes.
  FOR i IN 1..10 LOOP
    r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Bot', '+1212555' || lpad(i::text, 4, '0'), NULL, 0, repeat('b', 64), true);
    ASSERT (r->>'ok')::boolean, 'PW13: network start ' || i || ' ' || r::text;
  END LOOP;
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Bot', '+12125559999', NULL, 0, repeat('b', 64), true);
  ASSERT r->>'error' = 'rate_limited', 'PW13: eleventh from one network refused';
  -- Clear the bot rows (and age Ana's) so later checks start clean.
  DELETE FROM public.exos_phone_rsvps WHERE ip_hash = repeat('b', 64);
  UPDATE public.exos_phone_rsvps SET created_at = now() - interval '1 hour' WHERE phone = '+12125550101';
  RAISE NOTICE 'OK  PW13 start: validation, channel fallback, rate limits';
END $$;

-- PW14. Verify: wrong codes lock after 5; expiry; the right code issues tickets.
DO $$
DECLARE r jsonb; v jsonb; i int; bad text;
BEGIN
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Lock', '+12125550111', NULL, 0, NULL, true);
  bad := CASE WHEN r->>'code' = '000000' THEN '000001' ELSE '000000' END;
  FOR i IN 1..4 LOOP
    v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, bad, 'https://exos.example');
    ASSERT v->>'error' = 'wrong_code', 'PW14: wrong ' || i || ' ' || v::text;
  END LOOP;
  ASSERT (v->>'attempts_left')::int = 1, 'PW14: one try left ' || v::text;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, bad, 'https://exos.example');
  ASSERT v->>'error' = 'locked', 'PW14: fifth wrong locks';
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example');
  ASSERT v->>'error' = 'locked', 'PW14: even the right code after lock';
  -- Expiry.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Late', '+12125550112', NULL, 0, NULL, true);
  UPDATE public.exos_phone_rsvps SET code_expires_at = now() - interval '1 second' WHERE id = (r->>'rsvp_id')::uuid;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example');
  ASSERT v->>'error' = 'expired', 'PW14: expired code';
  -- The right code: guest + 1, parked on the org owner, links that work.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Bea Guest', '+12125550113', NULL, 1, NULL, true, 'pw-q');
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example');
  ASSERT (v->>'ok')::boolean AND jsonb_array_length(v->'tickets') = 2, 'PW14: two tickets ' || v::text;
  ASSERT (SELECT count(*) FROM public.exos_tickets t
           WHERE t.order_ref = 'rsvp:' || (r->>'rsvp_id') AND t.owner_id = '0f0f0000-0000-0000-0000-0000000000a1'
             AND t.price_paid = 0 AND t.status = 'active' AND t.promoter_id = 'pw-q') = 2, 'PW14: parked on the owner, credited to Q';
  ASSERT (SELECT attendee_name FROM public.exos_tickets WHERE id = (v->'tickets'->1->>'id')::uuid) = 'Guest of Bea Guest', 'PW14: plus-one named';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '0f0f0000-0000-0000-0000-0000000000d2') = 2, 'PW14: tier sold +2';
  ASSERT (public.exos_ticket_link_view((v->'tickets'->0->>'id')::uuid,
            substring(v->'tickets'->0->>'url' FROM '#k=(.*)$'))->>'state') = 'valid', 'PW14: the link shows a live code';
  ASSERT v->'tickets'->0->>'url' LIKE 'https://exos.example/t/%#k=%', 'PW14: link shape';
  ASSERT public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example')->>'error' = 'used', 'PW14: a used code';
  PERFORM set_config('test.rsvp1', r->>'rsvp_id', false);
  PERFORM set_config('test.tk1', v->'tickets'->0->>'id', false);
  PERFORM set_config('test.key1', substring(v->'tickets'->0->>'url' FROM '#k=(.*)$'), false);
  -- One RSVP per phone per event: a second verify resends the same tickets.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Bea Again', '+12125550113', NULL, 0, NULL, true);
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example');
  ASSERT (v->>'ok')::boolean AND jsonb_array_length(v->'tickets') = 2
         AND v->'tickets'->0->>'id' = current_setting('test.tk1'), 'PW14: duplicate resends ' || v::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '0f0f0000-0000-0000-0000-0000000000d2') = 2, 'PW14: no new seats';
  ASSERT (SELECT status FROM public.exos_phone_rsvps WHERE id = (r->>'rsvp_id')::uuid) = 'duplicate', 'PW14: marked duplicate';
  RAISE NOTICE 'OK  PW14 verify: attempts, expiry, tickets, one per phone';
END $$;

-- PW15. Capacity: start pre-checks, verify re-checks under the lock (race).
DO $$
DECLARE r1 jsonb; r2 jsonb; v jsonb;
BEGIN
  -- 6 seats, 2 taken. Two guests each start for 2 while 4 are left...
  r1 := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Cy', '+12125550121', NULL, 1, NULL, true);
  r2 := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Di', '+12125550122', NULL, 1, NULL, true);
  ASSERT (r1->>'ok')::boolean AND (r2->>'ok')::boolean, 'PW15: both may start';
  -- ...then a door comp takes 1 seat before they verify.
  UPDATE public.exos_ticket_tiers SET sold = sold + 1 WHERE id = '0f0f0000-0000-0000-0000-0000000000d2';
  v := public.exos_phone_rsvp_verify((r1->>'rsvp_id')::uuid, r1->>'code', 'https://exos.example');
  ASSERT (v->>'ok')::boolean, 'PW15: first verify gets the seats';
  v := public.exos_phone_rsvp_verify((r2->>'rsvp_id')::uuid, r2->>'code', 'https://exos.example');
  ASSERT v->>'error' = 'sold_out', 'PW15: second is sold out ' || v::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '0f0f0000-0000-0000-0000-0000000000d2') = 5, 'PW15: never oversold';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref = 'rsvp:' || (r2->>'rsvp_id')), 'PW15: no partial mint';
  r2 := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Ed', '+12125550123', NULL, 1, NULL, true);
  ASSERT r2->>'error' = 'sold_out', 'PW15: start refuses 2 with 1 left';
  RAISE NOTICE 'OK  PW15 capacity holds under a race';
END $$;

-- PW15b. RSVP takeover: a victim's number with the attacker's email gets no
--        tickets; the legitimate resend (same phone by text, or the exact
--        email that confirmed it) still works, even when the event is full.
DO $$
DECLARE r jsonb; v jsonb; rid uuid := gen_random_uuid(); first jsonb;
BEGIN
  -- Bea (+12125550113) confirmed by text in PW14. Texts unavailable (or her
  -- number replied STOP): the email fallback is refused for her number.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Mallory', '+12125550113', 'mallory@evil.com', 0, NULL, false);
  ASSERT r->>'error' = 'already' AND r->'rsvp_id' IS NULL, 'PW15b: email fallback refused for an RSVP''d number ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'mallory@evil.com'), 'PW15b: no code mailed';
  -- Even a pending email row (written some other way) can't pull the links at verify.
  INSERT INTO public.exos_phone_rsvps (id, org_id, event_id, tier_id, guest_name, phone, email, channel, code_hash, code_expires_at)
  VALUES (rid, '0f0f0000-0000-0000-0000-000000000001', '0f0f0000-0000-0000-0000-0000000000e2', '0f0f0000-0000-0000-0000-0000000000d2',
          'Mallory', '+12125550113', 'mallory@evil.com', 'email', encode(extensions.digest(rid::text || ':123456', 'sha256'), 'hex'),
          now() + interval '10 minutes');
  v := public.exos_phone_rsvp_verify(rid, '123456', 'https://exos.example');
  ASSERT v->>'error' = 'already' AND v->'tickets' IS NULL AND position(current_setting('test.tk1') in v::text) = 0,
         'PW15b: no links or ticket ids ' || v::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail WHERE to_email = 'mallory@evil.com'), 'PW15b: no ticket mail';
  -- Em confirms by email (the code is in the mail), taking the last seat.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Em', '+12125550131', 'Em@X.com', 0, NULL, false);
  first := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid,
             (SELECT substring(html FROM '<strong>([0-9]{6})</strong>') FROM public.exos_mail
               WHERE template = 'rsvp-code' AND to_email = 'em@x.com' ORDER BY created_at DESC, id DESC LIMIT 1),
             'https://exos.example');
  ASSERT (first->>'ok')::boolean AND jsonb_array_length(first->'tickets') = 1, 'PW15b: Em confirmed by email ' || first::text;
  ASSERT (public.exos_phone_rsvp_info('0f0f0000-0000-0000-0000-0000000000e2'))->>'reason' = 'sold_out', 'PW15b: now full';
  -- Legit resend 1: exactly the same email, even though the event is full.
  DELETE FROM public.exos_mail WHERE to_email = 'em@x.com';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Em', '+12125550131', 'em@x.com', 0, NULL, false);
  ASSERT (r->>'ok')::boolean AND r->>'channel' = 'email', 'PW15b: same email may ask again ' || r::text;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid,
         (SELECT substring(html FROM '<strong>([0-9]{6})</strong>') FROM public.exos_mail WHERE template = 'rsvp-code' AND to_email = 'em@x.com' LIMIT 1),
         'https://exos.example');
  ASSERT (v->>'ok')::boolean AND v->'tickets'->0->>'id' = first->'tickets'->0->>'id', 'PW15b: same tickets resent by email ' || v::text;
  -- Another email for Em's number: refused.
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Em', '+12125550131', 'other@x.com', 0, NULL, false);
  ASSERT r->>'error' = 'already', 'PW15b: a different email is refused';
  -- Legit resend 2: Bea's own phone by text, event full.
  UPDATE public.exos_phone_rsvps SET created_at = now() - interval '1 hour' WHERE phone = '+12125550113';
  r := public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'Bea', '+12125550113', NULL, 0, NULL, true);
  ASSERT (r->>'ok')::boolean AND r->>'channel' = 'sms', 'PW15b: the phone itself may ask again ' || r::text;
  v := public.exos_phone_rsvp_verify((r->>'rsvp_id')::uuid, r->>'code', 'https://exos.example');
  ASSERT (v->>'ok')::boolean AND v->'tickets'->0->>'id' = current_setting('test.tk1'), 'PW15b: Bea''s tickets by text ' || v::text;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id = '0f0f0000-0000-0000-0000-0000000000d2') = 6, 'PW15b: resends mint nothing';
  RAISE NOTICE 'OK  PW15b no RSVP takeover by email; legitimate resends work';
END $$;

-- PW16. Claim into an account by the link key; the old link dies.
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.exos_phone_rsvp_claim(current_setting('test.tk1')::uuid, current_setting('test.key1'));
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW16: anon cannot claim';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000c1',false);
SELECT set_config('app.jwt','{"email":"pwguest@x.com"}',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_phone_rsvp_claim(current_setting('test.tk1')::uuid,
         CASE WHEN current_setting('test.key1') LIKE 'A%' THEN 'B' ELSE 'A' END || substring(current_setting('test.key1') FROM 2));
  ASSERT r->>'error' = 'not_found', 'PW16: wrong key';
  r := public.exos_phone_rsvp_claim(current_setting('test.tk1')::uuid, current_setting('test.key1'));
  ASSERT (r->>'ok')::boolean, 'PW16: claimed ' || r::text;
  ASSERT public.exos_phone_rsvp_claim(current_setting('test.tk1')::uuid, current_setting('test.key1'))->>'error' = 'not_found',
         'PW16: the old key no longer works';
END $$;
RESET ROLE;
SELECT set_config('app.jwt','',false);
DO $$
BEGIN
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = current_setting('test.tk1')::uuid) = '0f0f0000-0000-0000-0000-0000000000c1',
         'PW16: owned by the guest';
  ASSERT (public.exos_ticket_link_view(current_setting('test.tk1')::uuid, current_setting('test.key1'))->>'ok')::boolean = false,
         'PW16: the old link is dead';
  RAISE NOTICE 'OK  PW16 claim into an account';
END $$;

-- PW17. RSVP RLS, column grants, function grants, cross-org isolation.
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a2',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvps WHERE event_id = '0f0f0000-0000-0000-0000-0000000000e2'
           AND phone = '+12125550113' AND status IN ('confirmed', 'duplicate')) = 3, 'PW17: the manager sees the org''s RSVPs';
  BEGIN PERFORM code_hash FROM public.exos_phone_rsvps LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW17: code hashes are not readable';
  ok := false;
  BEGIN PERFORM public.exos_phone_rsvp_start('0f0f0000-0000-0000-0000-0000000000e2', 'X', '+12125550188', NULL, 0, NULL, true);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW17: authenticated cannot start (exos-rsvp only)';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000a3',false);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvps) = 0, 'PW17: finance does not see guests'' phones';
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvp_settings) = 1, 'PW17: finance sees the setting';
END $$;
RESET ROLE;
SELECT set_config('app.uid','0f0f0000-0000-0000-0000-0000000000b1',false);
SET LOCAL ROLE authenticated;
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvps) = 0, 'PW17: org B sees none of A''s RSVPs';
  ASSERT (SELECT count(*) FROM public.exos_phone_rsvp_settings) = 1, 'PW17: org B sees only its own setting';
  BEGIN PERFORM public.exos_set_phone_rsvp('0f0f0000-0000-0000-0000-0000000000e2', false);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW17: org B cannot change A''s event';
END $$;
RESET ROLE;
SELECT set_config('app.uid','',false);
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.exos_phone_rsvp_verify(current_setting('test.rsvp1')::uuid, '123456', 'https://exos.example');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW17: anon cannot verify directly';
  ok := false;
  BEGIN PERFORM count(*) FROM public.exos_phone_rsvps;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'PW17: anon cannot read the table';
  RAISE NOTICE 'OK  PW17 RSVP RLS, grants and cross-org isolation';
END $$;
RESET ROLE;

-- PW18. Every new definer function pins search_path; only the leaderboard is anon.
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosecdef
     AND p.proname IN ('_exos_pc_terms', '_exos_pc_reprice', 'exos_set_promoter_step', 'exos_promoter_unpaid',
                       'exos_settle_promoter', 'exos_set_promoter_stripe_transfers', 'exos_promoter_leaderboard',
                       'exos_promoter_by_token', 'exos_record_promoter_stripe', 'exos_promoter_transfer_claim',
                       'exos_promoter_funding_mark', 'exos_promoter_transfer_mark', 'exos_promoter_payout_cancel',
                       'exos_instant_payout_begin', 'exos_instant_payout_mark', 'exos_event_money_so_far',
                       'exos_set_phone_rsvp', '_exos_phone_rsvp_offer', 'exos_phone_rsvp_info',
                       'exos_phone_rsvp_start', 'exos_phone_rsvp_verify', 'exos_phone_rsvp_claim')
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  ASSERT bad IS NULL, 'PW18: no pinned search_path: ' || bad;
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('_exos_pc_terms', '_exos_pc_reprice', 'exos_set_promoter_step', 'exos_promoter_unpaid',
                       'exos_settle_promoter', 'exos_set_promoter_stripe_transfers',
                       'exos_promoter_by_token', 'exos_record_promoter_stripe', 'exos_promoter_transfer_claim',
                       'exos_promoter_funding_mark', 'exos_promoter_transfer_mark', 'exos_promoter_payout_cancel',
                       'exos_instant_payout_begin', 'exos_instant_payout_mark', 'exos_event_money_so_far',
                       'exos_set_phone_rsvp', '_exos_phone_rsvp_offer', 'exos_phone_rsvp_info',
                       'exos_phone_rsvp_start', 'exos_phone_rsvp_verify', 'exos_phone_rsvp_claim')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  ASSERT bad IS NULL, 'PW18: anon may call ' || bad;
  ASSERT has_function_privilege('anon', 'public.exos_promoter_leaderboard(uuid, uuid, integer)', 'EXECUTE'), 'PW18: leaderboard is anon';
  SELECT string_agg(p.proname, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('_exos_pc_terms', '_exos_pc_reprice', 'exos_promoter_by_token', 'exos_record_promoter_stripe',
                       'exos_promoter_transfer_claim', 'exos_promoter_transfer_reconcile', 'exos_promoter_funding_mark', 'exos_promoter_transfer_mark',
                       'exos_promoter_payout_cancel', 'exos_instant_payout_begin', 'exos_instant_payout_mark',
                       '_exos_phone_rsvp_offer', 'exos_phone_rsvp_info', 'exos_phone_rsvp_start', 'exos_phone_rsvp_verify')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
  ASSERT bad IS NULL, 'PW18: authenticated may call service functions ' || bad;
  RAISE NOTICE 'OK  PW18 search_path pinned; grants as intended';
END $$;

ROLLBACK;
