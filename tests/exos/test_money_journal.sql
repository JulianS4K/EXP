-- ============================================================================
-- Money journal, sales tax by jurisdiction, $0 orders (mig 20261108100000).
-- Self-contained (BEGIN / ROLLBACK; ids a7f1…).
--   MJ0 shape: RLS on both tables; clients read only; no anon grant; the
--       writers are service-role only; search_path pinned; append-only (as
--       the owner too); every patch marker; the chart's codes
--   MJ1 a paid order balances: face, buyer fees, tax, donation, gift card,
--       Exos fee + card-fee estimate withheld, an Exos fee owed; posting twice
--       is one entry; a PayPal order posts to the PayPal receivable
--   MJ2 refunds: two partials and the rest add up exactly to the settlement's
--       net after refunds; the credit note's tax; a refund that fails later
--       is reversed; a refund before the sale is posted waits for the sale;
--       the fee-change log reclassifies (refund / manual)
--   MJ3 disputes: lost without the recovery policy posts nothing; with it,
--       amount + fee owed to Exos; waiving it reverses; a lost PayPal dispute
--       writes off what was owed
--   MJ4 marketplace: sale, re-price (the difference), payout sent, cancel
--   MJ5 promoter commissions: accrued, paid, reversed; platform_fee none
--   MJ6 POS: a cash walk-up sale (with a tip and tax), a void, a paid-out;
--       a comp at the door gets a $0 order and no entry
--   MJ7 the trial balance balances per currency; who may read it; RLS and
--       cross-org isolation on the tables and the view
--   MJ8 sales tax by jurisdiction: online by rate, unspecified tax, credit
--       notes, POS; period filter; who may read it
--   MJ9 $0 orders: a free claim, a comp batch, a box-office comp, an RSVP, a
--       referral reward each get one $0 order (no invoice, no journal entry);
--       paid checkouts, marketplace and partner tickets don't; the reports
--       read the same with and without them (no double count, no revenue)
--   MJ10 the deferred balance check refuses an unbalanced entry; the writer
--       refuses one up front; the backfill is a no-op on a posted org
-- Users: o1 owner A, m1 manager A, f1 finance A, s1 scanner A, o2 owner B,
--        b1 / b2 buyers.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('a7f1:' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO authenticated;
CREATE FUNCTION pg_temp.act(p_uid uuid, p_email text DEFAULT '') RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true),
         set_config('app.jwt', CASE WHEN p_email = '' THEN '' ELSE json_build_object('email', p_email)::text END, true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid, text) TO authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO authenticated;
-- Signed balance (debit − credit) of an account over one source's entries, or the org's.
CREATE FUNCTION pg_temp.bal(p_account text, p_source text DEFAULT NULL, p_org text DEFAULT '1') RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0)::bigint
    FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
   WHERE l.account = p_account AND e.org_id = pg_temp.u(p_org) AND (p_source IS NULL OR e.source_id = p_source)
$$;
CREATE FUNCTION pg_temp.n(p_source text, p_kind text DEFAULT NULL) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_journal_entries
   WHERE source_id = p_source AND (p_kind IS NULL OR kind = p_kind OR kind LIKE p_kind || ':%')
$$;
-- Fire the deferred balance checks now (they'd run at COMMIT; this file rolls back).
CREATE FUNCTION pg_temp.check_all() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced IMMEDIATE;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced DEFERRED;
END $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('o1'), 'mj-o1@x.com', now()), (pg_temp.u('m1'), 'mj-m1@x.com', now()),
  (pg_temp.u('f1'), 'mj-f1@x.com', now()), (pg_temp.u('s1'), 'mj-s1@x.com', now()),
  (pg_temp.u('o2'), 'mj-o2@x.com', now()), (pg_temp.u('b1'), 'mj-b1@x.com', now()),
  (pg_temp.u('b2'), 'mj-b2@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'MJ Hall', 'mj-hall', pg_temp.u('o1')),
  (pg_temp.u('2'), 'MJ Other', 'mj-other', pg_temp.u('o2'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('o1'), 'owner'), (pg_temp.u('1'), pg_temp.u('m1'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('f1'), 'finance'), (pg_temp.u('1'), pg_temp.u('s1'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('o2'), 'owner');
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id IN (pg_temp.u('1'), pg_temp.u('2'));
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by, venue_address) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'MJ Night', 'mj-night', 'published', now() + interval '2 hours', now() - interval '1 hour', 500, 0, 'usd',
   pg_temp.u('o1'), '{"street":"1 Main St","city":"Brooklyn","region":"NY","postal":"11211","country":"us"}'),
  (pg_temp.u('e2'), pg_temp.u('1'), 'MJ Jersey', 'mj-jersey', 'published', now() + interval '3 days', NULL, 500, 0, 'usd',
   pg_temp.u('o1'), '{"city":"Hoboken","region":"NJ","country":"US"}'),
  (pg_temp.u('e9'), pg_temp.u('2'), 'MJ Elsewhere', 'mj-else', 'published', now() + interval '2 hours', NULL, 500, 0, 'usd',
   pg_temp.u('o2'), '{"city":"Austin","region":"TX","country":"US"}');
INSERT INTO public.exos_tax_rules (id, event_id, name, rate_percent, price_includes_tax) VALUES
  (pg_temp.u('x1'), pg_temp.u('e1'), 'NY sales tax', 8.875, false),
  (pg_temp.u('x2'), pg_temp.u('e2'), 'NJ sales tax', 6.625, false);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, tax_rate_id) VALUES
  (pg_temp.u('t1'), pg_temp.u('e1'), 'GA', 40, 200, 0, pg_temp.u('x1')),
  (pg_temp.u('tf'), pg_temp.u('e1'), 'Free', 0, 200, 0, NULL),
  (pg_temp.u('t2'), pg_temp.u('e2'), 'GA', 20, 200, 0, pg_temp.u('x2')),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 30, 200, 0, NULL);

-- Orders. s1: b1, 2 × GA, $100.00 charged: tax $8.00, a $3.00 passed-on fee,
-- a $5.00 donation, $10.00 on a gift card on top; application fee $5.00 =
-- Exos $3.00 + card estimate $2.00; $1.00 Exos fee owed (gift card part).
-- s2: b2, $40.00 on e2 (NJ). pp: PayPal $30.00. s9: org B.
INSERT INTO public.exos_giving_campaigns (id, org_id, name, slug) VALUES (pg_temp.u('gc'), pg_temp.u('1'), 'MJ Fund', 'mj-fund');
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status,
            tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, donation_cents, donation_campaign_id,
            exos_fee_owed_cents, processor, fulfilled_at) VALUES
  ('cs_mj_1', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'mj-b1@x.com', 2, 10000, 'usd', 'pending',
   800, 500, 300, 200, 1000, 500, pg_temp.u('gc'), 100, 'stripe', NULL),
  ('cs_mj_2', pg_temp.u('e2'), pg_temp.u('t2'), pg_temp.u('1'), pg_temp.u('b2'), 'mj-b2@x.com', 2, 4000, 'usd', 'pending',
   250, 280, 120, 160, 0, 0, NULL, 0, 'stripe', NULL),
  ('pp_' || repeat('a7', 16), pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b2'), 'mj-b2@x.com', 1, 3000, 'usd', 'pending',
   0, 210, 90, 120, 0, 0, NULL, 0, 'paypal', NULL),
  ('cs_mj_9', pg_temp.u('e9'), pg_temp.u('t9'), pg_temp.u('2'), pg_temp.u('b1'), 'mj-b1@x.com', 1, 3000, 'usd', 'pending',
   0, 210, 90, 120, 0, 0, NULL, 0, 'stripe', NULL);
INSERT INTO public.exos_order_fees (session_id, org_id, event_id, rule_name, kind, calc, per, item_kind, unit_cents, quantity, amount_cents) VALUES
  ('cs_mj_1', pg_temp.u('1'), pg_temp.u('e1'), 'Service', 'passed_on', 'fixed', 'ticket', 'ticket', 150, 2, 300),
  ('cs_mj_1', pg_temp.u('1'), pg_temp.u('e1'), 'Venue', 'absorbed', 'fixed', 'order', 'order', 100, 1, 100);
-- What the buyer was shown (the sales-tax report's lines): s1 two GA lines
-- with $8.00 tax; s2 one line with $2.00 of its $2.50 tax (the rest
-- unexplained); pp has no tax.
INSERT INTO public.exos_price_disclosures (session_id, event_id, org_id, currency, total_shown_cents) VALUES
  ('cs_mj_1', pg_temp.u('e1'), pg_temp.u('1'), 'usd', 10000), ('cs_mj_2', pg_temp.u('e2'), pg_temp.u('1'), 'usd', 4000);
INSERT INTO public.exos_price_disclosure_lines (session_id, line_no, kind, item_id, item_name, quantity, face_unit_cents, tax_cents, tax_included, fee_cents,
            unit_all_in_cents, line_total_cents) VALUES
  ('cs_mj_1', 1, 'ticket', pg_temp.u('t1'), 'GA', 2, 4000, 800, false, 300, 4550, 9100),
  ('cs_mj_2', 1, 'ticket', pg_temp.u('t2'), 'GA', 2, 1800, 200, false, 0, 1900, 3800);

-- MJ0 -------------------------------------------------------------------------
DO $$
DECLARE f text; bad text; r text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_journal_entries', 'exos_journal_lines'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || f)::regclass), 'MJ0 RLS on ' || f;
    ASSERT NOT has_table_privilege('anon', 'public.' || f, 'SELECT'), 'MJ0 anon reads ' || f;
    ASSERT has_table_privilege('authenticated', 'public.' || f, 'SELECT'), 'MJ0 authenticated reads ' || f;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || f, 'INSERT,UPDATE,DELETE'), 'MJ0 authenticated writes ' || f;
    ASSERT NOT has_table_privilege('service_role', 'public.' || f, 'INSERT,UPDATE,DELETE'), 'MJ0 service role writes ' || f;
  END LOOP;
  ASSERT NOT has_table_privilege('anon', 'public.exos_journal_rows', 'SELECT'), 'MJ0 anon reads the rows view';
  ASSERT (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE oid = 'public.exos_journal_rows'::regclass), 'MJ0 invoker view';
  FOREACH f IN ARRAY ARRAY[
      'public._exos_journal_post(uuid,uuid,text,text,text,timestamptz,text,text,jsonb,text,bigint,uuid)',
      'public._exos_journal_sync(uuid,uuid,text,text,timestamptz,text,text,jsonb,text,text,text,text)',
      'public._exos_journal_backfill(uuid)', 'public._exos_journal_lock(text)', 'public._exos_journal_next_kind(text,text,text)',
      'public.exos_journal_post_order(text)', 'public.exos_journal_post_refund(uuid)', 'public.exos_journal_post_fee_adjustment(uuid)',
      'public.exos_journal_post_dispute(uuid)', 'public.exos_journal_post_marketplace(uuid)', 'public.exos_journal_post_payout_line(uuid)',
      'public.exos_journal_post_commission(uuid)', 'public.exos_journal_post_pos_payment(uuid)', 'public.exos_journal_post_pos_paid_out(uuid)',
      'public._exos_journal_reader_ok(uuid)', 'public._exos_tg_journal()', 'public._exos_journal_check()', 'public._exos_journal_guard()',
      'public._exos_zero_order_attach(public.exos_tickets,text)', 'public._exos_tg_ticket_zero_order()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'MJ0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'MJ0 authenticated runs ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_journal_trial_balance(uuid,timestamptz,timestamptz,uuid)',
                           'public.exos_sales_tax_report(uuid,timestamptz,timestamptz,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'MJ0 anon runs ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'MJ0 authenticated can''t run ' || f;
  END LOOP;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND (p.proname LIKE '%journal%' OR p.proname IN ('exos_sales_tax_report', '_exos_zero_order_attach', '_exos_tg_ticket_zero_order'))
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  ASSERT bad IS NULL, 'MJ0 search_path not pinned: ' || bad;
  FOREACH f IN ARRAY ARRAY['public._exos_channel_lines(uuid)', 'public._exos_buyer_geo(uuid,uuid,timestamptz,integer)',
                           'public._exos_cash_summary(uuid,uuid,timestamptz,timestamptz)', 'public._exos_gl_backfill(uuid,uuid)',
                           'public.exos_event_in_app_report(uuid)'] LOOP
    ASSERT position('/* exos: zero orders */' in pg_get_functiondef(f::regprocedure)) > 0, 'MJ0 marker in ' || f;
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_journal_accounts()) = 19, 'MJ0 the chart';
  ASSERT (SELECT bool_and(public._exos_journal_account_ok(code)) FROM public.exos_journal_accounts()), 'MJ0 chart codes accepted';
  RAISE NOTICE 'OK  MJ0 shape: RLS, read-only grants, writers closed, search_path, markers, chart';
END $$;

-- MJ1 -------------------------------------------------------------------------
UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() - interval '2 days'
 WHERE session_id IN ('cs_mj_1', 'cs_mj_2', 'pp_' || repeat('a7', 16), 'cs_mj_9');
DO $$
DECLARE e record; v uuid;
BEGIN
  ASSERT pg_temp.n('cs_mj_1', 'sale') = 1, 'MJ1 one sale entry for s1';
  SELECT * INTO e FROM public.exos_journal_entries WHERE source_id = 'cs_mj_1' AND kind = 'sale';
  ASSERT e.org_id = pg_temp.u('1') AND e.event_id = pg_temp.u('e1') AND e.currency = 'USD' AND e.source_table = 'exos_checkout_sessions',
         'MJ1 entry header';
  ASSERT (SELECT sum(debit_cents) = sum(credit_cents) AND sum(debit_cents) = e.total_cents FROM public.exos_journal_lines WHERE entry_id = e.id),
         'MJ1 balanced';
  -- value 11000 = 10000 charged + 1000 gift card; face = 11000 − 800 − 300 − 500 = 9400.
  ASSERT pg_temp.bal('stripe_clearing', 'cs_mj_1') = 10000 - 500, 'MJ1 cash at Stripe = charge − application fee';
  ASSERT pg_temp.bal('gift_cards_outstanding', 'cs_mj_1') = 1000, 'MJ1 gift card part';
  ASSERT pg_temp.bal('ticket_revenue', 'cs_mj_1') = -9400, 'MJ1 face';
  ASSERT pg_temp.bal('buyer_fees', 'cs_mj_1') = -300, 'MJ1 buyer fees (passed on only)';
  ASSERT pg_temp.bal('sales_tax_payable', 'cs_mj_1') = -800, 'MJ1 tax';
  ASSERT pg_temp.bal('donations', 'cs_mj_1') = -500, 'MJ1 donation';
  ASSERT pg_temp.bal('exos_fee', 'cs_mj_1') = 300 + 100, 'MJ1 Exos fee withheld + owed';
  ASSERT pg_temp.bal('card_fees', 'cs_mj_1') = 200, 'MJ1 card-fee estimate';
  ASSERT pg_temp.bal('organizer_payable', 'cs_mj_1') = -100, 'MJ1 owed to Exos';
  -- The organizer net matches exos_order_money.
  ASSERT pg_temp.bal('stripe_clearing', 'cs_mj_1') = (SELECT organizer_net_cents FROM public.exos_order_money WHERE session_id = 'cs_mj_1'),
         'MJ1 = exos_order_money organizer net';
  -- Twice (and again through the trigger): still one entry.
  v := public.exos_journal_post_order('cs_mj_1');
  ASSERT v IS NULL, 'MJ1 second post is a no-op';
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE session_id = 'cs_mj_1';
  ASSERT pg_temp.n('cs_mj_1') = 1, 'MJ1 still one entry';
  -- PayPal: the money is Exos's to pay over.
  ASSERT pg_temp.bal('paypal_receivable', 'pp_' || repeat('a7', 16)) = 3000 - 210, 'MJ1 PayPal receivable';
  ASSERT pg_temp.bal('stripe_clearing', 'pp_' || repeat('a7', 16)) = 0, 'MJ1 PayPal not at Stripe';
  ASSERT pg_temp.bal('stripe_clearing', 'cs_mj_9', '2') = 3000 - 210, 'MJ1 org B posts to org B';
  -- A pending order posts nothing.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status)
  VALUES ('cs_mj_p', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'mj-b1@x.com', 1, 4000, 'usd', 'pending');
  ASSERT pg_temp.n('cs_mj_p') = 0, 'MJ1 pending: nothing';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ1 a paid order balances (face, fees, tax, donation, gift card, owed fee); idempotent; PayPal; pending none';
END $$;

-- MJ2 -------------------------------------------------------------------------
DO $$
DECLARE r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); r3 uuid := gen_random_uuid(); r4 uuid := gen_random_uuid();
        v_after bigint; v_net bigint; v_entry uuid; v_fa uuid;
BEGIN
  -- s1: $33.33, then $33.33, then the remaining $33.34 back (the charge).
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, is_partial, created_at)
  VALUES (r1, 'cs_mj_1', pg_temp.u('1'), 'stripe', 're_mj_1', 3333, 'usd', 'succeeded', true, now() - interval '1 day');
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, is_partial, created_at)
  VALUES (r2, 'cs_mj_1', pg_temp.u('1'), 'stripe', 're_mj_2', 3333, 'usd', 'succeeded', true, now() - interval '1 day');
  ASSERT pg_temp.n(r1::text, 'refund') = 1 AND pg_temp.n(r2::text, 'refund') = 1, 'MJ2 one entry per refund';
  -- settlement.ts orderNetAfterRefunds: net − round(net × refunded / gross).
  v_net := 9500;
  v_after := v_net - round(v_net::numeric * 6666 / 10000);
  ASSERT pg_temp.bal('stripe_clearing', 'cs_mj_1') + pg_temp.bal('stripe_clearing', r1::text) + pg_temp.bal('stripe_clearing', r2::text) = v_after,
         format('MJ2 net after two partials = settlement (%s)', v_after);
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, created_at)
  VALUES (r3, 'cs_mj_1', pg_temp.u('1'), 'stripe', 're_mj_3', 3334, 'usd', 'succeeded', now() - interval '1 day');
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_mj_1';
  ASSERT pg_temp.bal('stripe_clearing', 'cs_mj_1') + pg_temp.bal('stripe_clearing', r1::text) + pg_temp.bal('stripe_clearing', r2::text)
         + pg_temp.bal('stripe_clearing', r3::text) = 0, 'MJ2 fully refunded: nothing left at Stripe';
  ASSERT pg_temp.bal('exos_fee', r1::text) + pg_temp.bal('exos_fee', r2::text) + pg_temp.bal('exos_fee', r3::text) = -300,
         'MJ2 Exos fee all returned';
  ASSERT pg_temp.bal('card_fees', r1::text) + pg_temp.bal('card_fees', r2::text) + pg_temp.bal('card_fees', r3::text) = -200,
         'MJ2 card estimate all returned';
  ASSERT pg_temp.bal('refunds', r1::text) + pg_temp.bal('refunds', r2::text) + pg_temp.bal('refunds', r3::text)
         + pg_temp.bal('sales_tax_payable', r1::text) + pg_temp.bal('sales_tax_payable', r2::text) + pg_temp.bal('sales_tax_payable', r3::text) = 10000,
         'MJ2 refunds + tax = what went back';
  -- Each refund entry used its credit note's tax when there is one.
  ASSERT (SELECT bool_and(pg_temp.bal('sales_tax_payable', c.refund_id::text) = c.tax_cents)
            FROM public.exos_credit_notes c WHERE c.session_id = 'cs_mj_1') IS NOT FALSE, 'MJ2 credit note tax';

  -- s2: a refund that fails later is reversed; a second success posts again.
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, created_at)
  VALUES (r4, 'cs_mj_2', pg_temp.u('1'), 'stripe', 're_mj_4', 1000, 'usd', 'succeeded', now() - interval '1 day');
  ASSERT pg_temp.n(r4::text, 'refund') = 1, 'MJ2 s2 refund';
  UPDATE public.exos_order_refunds SET status = 'failed' WHERE id = r4;
  ASSERT pg_temp.n(r4::text, 'refund_reversal') = 1, 'MJ2 failed later: reversed';
  SELECT reverses INTO v_entry FROM public.exos_journal_entries WHERE source_id = r4::text AND kind = 'refund_reversal';
  ASSERT v_entry = (SELECT id FROM public.exos_journal_entries WHERE source_id = r4::text AND kind = 'refund'), 'MJ2 reversal points at the refund';
  ASSERT pg_temp.bal('refunds', r4::text) = 0 AND pg_temp.bal('stripe_clearing', r4::text) = 0, 'MJ2 reversal nets to zero';
  UPDATE public.exos_order_refunds SET status = 'failed' WHERE id = r4;
  ASSERT pg_temp.n(r4::text) = 2, 'MJ2 a repeat changes nothing';

  -- The fee-change log: the refund's buyer-fee part moves from Refunds to Buyer fees (no cash).
  SELECT id INTO v_fa FROM public.exos_fee_adjustments WHERE session_id = 'cs_mj_1' AND reason = 'refund' ORDER BY processed_at LIMIT 1;
  IF v_fa IS NULL THEN
    INSERT INTO public.exos_fee_adjustments (org_id, event_id, session_id, reason, fees_change_cents, refund_id)
    VALUES (pg_temp.u('1'), pg_temp.u('e1'), 'cs_mj_1', 'refund', -100, r1) RETURNING id INTO v_fa;
  END IF;
  ASSERT pg_temp.n(v_fa::text, 'fee_adjustment') = 1, 'MJ2 fee log posted';
  ASSERT pg_temp.bal('buyer_fees', v_fa::text) = -(SELECT fees_change_cents FROM public.exos_fee_adjustments WHERE id = v_fa)
     AND pg_temp.bal('refunds', v_fa::text) = (SELECT fees_change_cents FROM public.exos_fee_adjustments WHERE id = v_fa)
     AND pg_temp.bal('stripe_clearing', v_fa::text) = 0, 'MJ2 refund fee part reclassified';
  INSERT INTO public.exos_fee_adjustments (id, org_id, event_id, session_id, reason, note, fees_change_cents)
  VALUES (pg_temp.u('fa2'), pg_temp.u('1'), pg_temp.u('e2'), 'cs_mj_2', 'manual', 'correction', 50);
  ASSERT pg_temp.bal('buyer_fees', pg_temp.u('fa2')::text) = -50 AND pg_temp.bal('ticket_revenue', pg_temp.u('fa2')::text) = 50,
         'MJ2 a manual change moves face to fees';
  PERFORM public.exos_journal_post_fee_adjustment(pg_temp.u('fa2'));
  ASSERT pg_temp.n(pg_temp.u('fa2')::text) = 1, 'MJ2 fee change idempotent';

  -- A refund that lands before its sale was posted (the backfill order): waits for the sale.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency, status,
              application_fee_cents, exos_fee_cents, card_fee_est_cents)
  VALUES ('cs_mj_late', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'mj-b1@x.com', 1, 4000, 'usd', 'pending', 280, 120, 160);
  INSERT INTO public.exos_order_refunds (session_id, org_id, provider, refund_id, amount_cents, currency, status)
  VALUES ('cs_mj_late', pg_temp.u('1'), 'stripe', 're_mj_late', 4000, 'usd', 'succeeded');
  ASSERT pg_temp.n('cs_mj_late') = 0, 'MJ2 nothing before the sale';
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_mj_late';
  ASSERT pg_temp.n('cs_mj_late', 'sale') = 1
     AND (SELECT count(*) FROM public.exos_journal_entries WHERE session_id = 'cs_mj_late' AND kind = 'refund') = 1, 'MJ2 sale then its refund';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ2 refunds: partials add up to the settlement, credit note tax, reversal, fee-log reclass, late sale';
END $$;

-- MJ3 -------------------------------------------------------------------------
DO $$
BEGIN
  -- Policy off: a lost dispute is Exos's (destination charge); nothing for the org.
  INSERT INTO public.exos_disputes (id, org_id, event_id, session_id, dispute_id, amount_cents, fee_cents, status, recovery_status)
  VALUES (pg_temp.u('d1'), pg_temp.u('1'), pg_temp.u('e2'), 'cs_mj_2', 'dp_mj1', 4000, 1500, 'needs_response', 'none');
  UPDATE public.exos_disputes SET status = 'lost', recovery_status = 'not_recovered', recovery_candidate_cents = 5500 WHERE id = pg_temp.u('d1');
  ASSERT pg_temp.n(pg_temp.u('d1')::text) = 0, 'MJ3 not recovered: no entry';
  -- The org recovers it: amount + fee owed to Exos.
  UPDATE public.exos_disputes SET recovery_status = 'recovery_pending' WHERE id = pg_temp.u('d1');
  ASSERT pg_temp.n(pg_temp.u('d1')::text, 'dispute_lost') = 1, 'MJ3 recovered: posted';
  ASSERT pg_temp.bal('disputes', pg_temp.u('d1')::text) = 5500 AND pg_temp.bal('organizer_payable', pg_temp.u('d1')::text) = -5500,
         'MJ3 amount + fee owed to Exos';
  UPDATE public.exos_disputes SET recovery_status = 'recovered' WHERE id = pg_temp.u('d1');
  ASSERT pg_temp.n(pg_temp.u('d1')::text) = 1, 'MJ3 pending → recovered: no change';
  -- Waived: the reversal.
  UPDATE public.exos_disputes SET recovery_status = 'not_recovered' WHERE id = pg_temp.u('d1');
  ASSERT pg_temp.n(pg_temp.u('d1')::text, 'dispute_lost_reversal') = 1
     AND pg_temp.bal('disputes', pg_temp.u('d1')::text) = 0 AND pg_temp.bal('organizer_payable', pg_temp.u('d1')::text) = 0,
         'MJ3 waived: reversed';
  ASSERT (SELECT reverses IS NOT NULL FROM public.exos_journal_entries WHERE source_id = pg_temp.u('d1')::text AND kind = 'dispute_lost_reversal'),
         'MJ3 reversal links its entry';
  -- PayPal lost: what Exos owed the org for the order is written off.
  INSERT INTO public.exos_disputes (id, org_id, event_id, session_id, dispute_id, amount_cents, fee_cents, status)
  VALUES (pg_temp.u('d2'), pg_temp.u('1'), pg_temp.u('e1'), 'pp_' || repeat('a7', 16), 'ppdsp_mj2', 3000, 0, 'lost');
  ASSERT pg_temp.bal('disputes', pg_temp.u('d2')::text) = 2790
     AND pg_temp.bal('paypal_receivable', 'pp_' || repeat('a7', 16)) + pg_temp.bal('paypal_receivable', pg_temp.u('d2')::text) = 0,
         'MJ3 PayPal: owed written off';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ3 disputes: none without the policy, owed with it, reversed when waived; PayPal write-off';
END $$;

-- MJ4 -------------------------------------------------------------------------
DO $$
DECLARE o uuid := pg_temp.u('mk1'); p uuid := pg_temp.u('po1'); l uuid := pg_temp.u('pl1');
BEGIN
  INSERT INTO public.exos_marketplace_orders (id, channel, external_order_id, event_id, org_id, quantity, proceeds, currency, sale_status, status)
  VALUES (o, 'evo', 'MJ-1', pg_temp.u('e1'), pg_temp.u('1'), 2, 80.00, 'usd', 'delivered', 'delivered');
  -- 3% Exos fee: 2.40; net 77.60.
  ASSERT pg_temp.n(o::text, 'mkt_sale') = 1, 'MJ4 sale posted';
  ASSERT pg_temp.bal('marketplace_receivable', o::text) = 7760 AND pg_temp.bal('exos_fee', o::text) = 240
     AND pg_temp.bal('ticket_revenue', o::text) = -8000, 'MJ4 receivable, fee, face';
  UPDATE public.exos_marketplace_orders SET proceeds = 90.00 WHERE id = o;
  ASSERT pg_temp.n(o::text, 'mkt_adjust') = 1 AND pg_temp.bal('ticket_revenue', o::text) = -9000
     AND pg_temp.bal('marketplace_receivable', o::text) = 8730, 'MJ4 re-priced: the difference';
  UPDATE public.exos_marketplace_orders SET sale_note = 'touch' WHERE id = o;
  ASSERT pg_temp.n(o::text) = 2, 'MJ4 an unrelated update posts nothing';
  -- Paid out.
  INSERT INTO public.exos_org_payouts (id, org_id, currency, amount, status, idempotency_key) VALUES (p, pg_temp.u('1'), 'usd', 87.30, 'planned', 'mj-payout-1');
  INSERT INTO public.exos_org_payout_lines (id, payout_id, org_id, order_id, kind, amount) VALUES (l, p, pg_temp.u('1'), o, 'sale', 87.30);
  ASSERT pg_temp.n(l::text) = 0, 'MJ4 planned: nothing yet';
  UPDATE public.exos_org_payouts SET status = 'sent', sent_at = now() WHERE id = p;
  ASSERT pg_temp.n(l::text, 'mkt_payout') = 1 AND pg_temp.bal('marketplace_receivable', l::text) = -8730
     AND pg_temp.bal('stripe_clearing', l::text) = 8730, 'MJ4 sent: receivable → cash';
  ASSERT pg_temp.bal('marketplace_receivable', o::text) + pg_temp.bal('marketplace_receivable', l::text) = 0, 'MJ4 receivable settled';
  -- Cancelled: the sale is reversed (the clawback is its own payout line).
  UPDATE public.exos_marketplace_orders SET status = 'cancelled' WHERE id = o;
  ASSERT pg_temp.n(o::text, 'mkt_cancel') = 1 AND pg_temp.bal('ticket_revenue', o::text) = 0, 'MJ4 cancelled: reversed';
  PERFORM public.exos_journal_post_marketplace(o);
  ASSERT pg_temp.n(o::text) = 3, 'MJ4 idempotent';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ4 marketplace: sale, re-price difference, payout sent, cancel';
END $$;

-- MJ5 -------------------------------------------------------------------------
SELECT pg_temp.act(pg_temp.u('o1'));
SELECT public.exos_upsert_promoter(pg_temp.u('1'), 'mj-pa', 'Promoter A');
SELECT pg_temp.act(NULL);
DO $$
DECLARE pr uuid; c1 uuid := pg_temp.u('pc1'); c2 uuid := pg_temp.u('pc2'); c3 uuid := pg_temp.u('pc3'); po uuid := pg_temp.u('pp1');
BEGIN
  SELECT id INTO pr FROM public.exos_promoters WHERE code = 'mj-pa' AND org_id = pg_temp.u('1');
  INSERT INTO public.exos_promoter_commissions (id, org_id, promoter_id, event_id, currency, gross_cents, base_cents, rate_bps, flat_cents,
              terms_source, commission_cents, method)
  VALUES (c1, pg_temp.u('1'), pr, pg_temp.u('e1'), 'usd', 4000, 4000, 1000, 0, 'promoter', 400, 'manual'),
         (c2, pg_temp.u('1'), pr, pg_temp.u('e1'), 'usd', 4000, 4000, 1000, 0, 'promoter', 400, 'manual'),
         (c3, pg_temp.u('1'), pr, pg_temp.u('e1'), 'usd', 4000, 4000, 1000, 0, 'promoter', 400, 'manual');
  ASSERT pg_temp.n(c1::text, 'commission_accrued') = 1 AND pg_temp.bal('promoter_commissions', c1::text) = 400
     AND pg_temp.bal('promoter_commissions_payable', c1::text) = -400, 'MJ5 accrued';
  UPDATE public.exos_promoter_commissions SET status = 'reversed', reversed_at = now(), reversed_reason = 'refund' WHERE id = c2;
  ASSERT pg_temp.n(c2::text, 'commission_reversed') = 1 AND pg_temp.bal('promoter_commissions', c2::text) = 0, 'MJ5 reversed';
  INSERT INTO public.exos_promoter_payouts (id, org_id, promoter_id, currency, amount_cents, commission_cents, row_count, method, via)
  VALUES (po, pg_temp.u('1'), pr, 'usd', 400, 400, 1, 'Venmo', 'manual');
  UPDATE public.exos_promoter_commissions SET status = 'paid', payout_id = po, paid_at = now() WHERE id = c3;
  ASSERT pg_temp.n(c3::text || ':paid', 'commission_paid') = 1 AND pg_temp.bal('promoter_commissions_payable', c3::text || ':paid') = 400
     AND pg_temp.bal('stripe_clearing', c3::text || ':paid') = -400, 'MJ5 paid';
  ASSERT pg_temp.bal('promoter_commissions', c3::text) = 400, 'MJ5 paid keeps its accrual';
  -- Paid inside the Exos fee: never in the organizer's books.
  INSERT INTO public.exos_promoter_commissions (id, org_id, promoter_id, event_id, currency, gross_cents, base_cents, rate_bps, flat_cents,
              terms_source, commission_cents, method)
  VALUES (pg_temp.u('pc4'), pg_temp.u('1'), pr, pg_temp.u('e1'), 'usd', 4000, 4000, 1000, 0, 'promoter', 400, 'platform_fee');
  ASSERT (SELECT method FROM public.exos_promoter_commissions WHERE id = pg_temp.u('pc4')) <> 'platform_fee'
      OR pg_temp.n(pg_temp.u('pc4')::text) = 0, 'MJ5 platform_fee: nothing';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ5 commissions: accrued, reversed, paid; platform_fee none';
END $$;

-- MJ6 -------------------------------------------------------------------------
SELECT pg_temp.act(pg_temp.u('s1'));
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES (pg_temp.u('e1'), pg_temp.u('s1'), pg_temp.u('1'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 5000);
DO $$
DECLARE r jsonb; v_order uuid; v_pay uuid; v_po uuid; v_tax int; v_total int; v_comp uuid; r2 jsonb;
BEGIN
  -- 2 × GA at the door ($40 + 8.875% tax = 43.55 each).
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('t1'), 2, pg_temp.u('k1'), 0, 'cash', NULL, pg_temp.u('dr'), 'Walk Up', NULL, NULL, NULL);
  v_order := (r ->> 'id')::uuid;
  SELECT id INTO v_pay FROM public.exos_pos_payments WHERE order_id = v_order AND method = 'cash';
  SELECT tax_cents, total_cents INTO v_tax, v_total FROM public.exos_pos_orders WHERE id = v_order;
  ASSERT v_pay IS NOT NULL AND pg_temp.n(v_pay::text, 'pos_cash_sale') = 1, 'MJ6 cash sale posted: ' || r::text;
  ASSERT pg_temp.bal('pos_cash_drawer', v_pay::text) = v_total AND pg_temp.bal('sales_tax_payable', v_pay::text) = -v_tax
     AND pg_temp.bal('ticket_revenue', v_pay::text) = -(v_total - v_tax), 'MJ6 drawer, tax, face';
  -- Void the same night: cash back out of the drawer.
  PERFORM pg_temp.act(pg_temp.u('o1'));
  PERFORM public.exos_pos_void_order(v_order, 'rang the wrong type', NULL);
  SELECT id INTO v_po FROM public.exos_pos_paid_outs WHERE order_id = v_order AND kind = 'void';
  ASSERT pg_temp.n(v_po::text, 'pos_void') = 1 AND pg_temp.bal('pos_cash_drawer', v_po::text) = -v_total
     AND pg_temp.bal('sales_tax_payable', v_po::text) = v_tax AND pg_temp.bal('refunds', v_po::text) = v_total - v_tax, 'MJ6 void';
  -- A paid-out for ice.
  PERFORM pg_temp.act(pg_temp.u('s1'));
  r := public.exos_pos_paid_out(pg_temp.u('dr'), 1200, 'ice for the bar', NULL);
  ASSERT pg_temp.n((r ->> 'id'), 'pos_paid_out') = 1 AND pg_temp.bal('pos_paid_outs', r ->> 'id') = 1200
     AND pg_temp.bal('pos_cash_drawer', r ->> 'id') = -1200, 'MJ6 paid-out';
  -- A comp at the door (owner / manager): a $0 order, no journal entry.
  PERFORM pg_temp.act(pg_temp.u('o1'));
  r2 := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('t1'), 1, pg_temp.u('k2'), 1, 'comp', NULL, NULL, 'Guest', 'mj-comp@x.com', NULL, NULL);
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE event_id = pg_temp.u('e1') AND free_kind = 'pos_comp') = 1,
         'MJ6 POS comp: one $0 order: ' || r2::text;
  ASSERT (SELECT count(*) FROM public.exos_journal_entries e JOIN public.exos_checkout_sessions s ON s.session_id = e.source_id
           WHERE s.free_kind IS NOT NULL) = 0, 'MJ6 no entry for a $0 order';
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ6 POS: cash sale (tax split), void, paid-out; a door comp gets a $0 order and no entry';
END $$;

-- MJ7 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE v_dr bigint; v_cr bigint; n int; v text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('f1'));
  SELECT sum(debit_cents), sum(credit_cents), count(*) INTO v_dr, v_cr, n FROM public.exos_journal_trial_balance(pg_temp.u('1'));
  ASSERT n > 5 AND v_dr = v_cr, format('MJ7 trial balance balances (%s accounts, %s / %s)', n, v_dr, v_cr);
  ASSERT (SELECT balance_cents FROM public.exos_journal_trial_balance(pg_temp.u('1')) WHERE account = 'ticket_revenue') < 0, 'MJ7 revenue credit';
  -- A period: only the last day (the refunds were dated a day back, sales two).
  SELECT count(*) INTO n FROM public.exos_journal_trial_balance(pg_temp.u('1'), now() - interval '36 hours', now() - interval '12 hours');
  ASSERT n > 0 AND (SELECT sum(debit_cents) = sum(credit_cents)
                      FROM public.exos_journal_trial_balance(pg_temp.u('1'), now() - interval '36 hours', now() - interval '12 hours')),
         'MJ7 a period balances too';
  -- One event.
  ASSERT (SELECT sum(debit_cents) = sum(credit_cents) FROM public.exos_journal_trial_balance(pg_temp.u('1'), NULL, NULL, pg_temp.u('e2'))),
         'MJ7 one event balances';
  -- Readers: owner, manager, finance; not a scanner, an outsider or the other org.
  PERFORM pg_temp.act(pg_temp.u('m1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_trial_balance(pg_temp.u('1'))) > 0, 'MJ7 manager reads';
  PERFORM pg_temp.act(pg_temp.u('o1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('1')) > 0, 'MJ7 owner reads the rows';
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('2')) = 0, 'MJ7 owner A sees nothing of B';
  FOREACH v IN ARRAY ARRAY['s1', 'b1', 'o2'] LOOP
    PERFORM pg_temp.act(pg_temp.u(v));
    ASSERT pg_temp.st(format('SELECT * FROM public.exos_journal_trial_balance(%L)', pg_temp.u('1'))) = '42501', 'MJ7 ' || v || ' refused';
    ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE org_id = pg_temp.u('1')) = 0, 'MJ7 ' || v || ' reads no entries';
    ASSERT (SELECT count(*) FROM public.exos_journal_lines WHERE org_id = pg_temp.u('1')) = 0, 'MJ7 ' || v || ' reads no lines';
  END LOOP;
  PERFORM pg_temp.act(pg_temp.u('o2'));
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('2')) > 0, 'MJ7 owner B reads B';
  PERFORM pg_temp.act(pg_temp.u('o1'));
  ASSERT pg_temp.st($q$INSERT INTO public.exos_journal_entries (org_id, source_table, source_id, kind, occurred_at, currency, total_cents)
                       VALUES (pg_temp.u('1'), 'exos_pos_payments', 'x', 'manual', now(), 'USD', 1)$q$) = '42501', 'MJ7 a client can''t insert';
  ASSERT pg_temp.st($q$SELECT public.exos_journal_post_order('cs_mj_2')$q$) = '42501', 'MJ7 a client can''t post';
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_journal_entries') = '42501', 'MJ7 anon has no grant';
  ASSERT pg_temp.st(format('SELECT public.exos_journal_trial_balance(%L)', md5('a7f1:1')::uuid)) = '42501', 'MJ7 anon can''t run it';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  MJ7 trial balance balances (all time, a period, an event); owner / manager / finance only; RLS across orgs'; END $$;

-- MJ8 -------------------------------------------------------------------------
SET ROLE authenticated;
DO $$
DECLARE j jsonb; r jsonb; ny jsonb; nj jsonb; unsp jsonb; pos jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('f1'));
  j := public.exos_sales_tax_report(pg_temp.u('1'));
  SELECT x INTO ny FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'tax_name' = 'NY sales tax' AND x ->> 'source' = 'online';
  ASSERT ny ->> 'country' = 'US' AND ny ->> 'region' = 'NY' AND ny ->> 'city' = 'Brooklyn' AND ny ->> 'postal_code' = '11211',
         'MJ8 NY jurisdiction: ' || coalesce(ny::text, 'none');
  ASSERT (ny ->> 'tax_collected_cents')::int = 800 AND (ny ->> 'taxable_cents')::int = 8300 AND (ny ->> 'rate_percent')::numeric = 8.875,
         'MJ8 NY collected / taxable / rate: ' || ny::text;
  ASSERT (ny ->> 'tax_refunded_cents')::int = (SELECT coalesce(sum(tax_cents), 0) FROM public.exos_credit_notes WHERE session_id = 'cs_mj_1'),
         'MJ8 NY refunded = the credit notes: ' || ny::text;
  SELECT x INTO nj FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'tax_name' = 'NJ sales tax';
  SELECT x INTO unsp FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'region' = 'NJ' AND x -> 'tax_name' = 'null'::jsonb AND x ->> 'source' = 'online';
  ASSERT (nj ->> 'tax_collected_cents')::int = 200 AND (unsp ->> 'tax_collected_cents')::int = 50, 'MJ8 NJ by rate + unspecified: ' || j::text;
  -- POS: the voided door sale collected and handed back its tax.
  SELECT x INTO pos FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'source' = 'pos' AND x ->> 'region' = 'NY';
  ASSERT (pos ->> 'tax_collected_cents')::int > 0 AND (pos ->> 'tax_refunded_cents')::int = (pos ->> 'tax_collected_cents')::int
     AND (pos ->> 'net_tax_cents')::int = 0, 'MJ8 POS void nets to zero: ' || coalesce(pos::text, 'none');
  -- One event; a period with nothing in it.
  j := public.exos_sales_tax_report(pg_temp.u('1'), NULL, NULL, pg_temp.u('e2'));
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'region' <> 'NJ'), 'MJ8 one event';
  j := public.exos_sales_tax_report(pg_temp.u('1'), now() + interval '1 day', now() + interval '2 days');
  ASSERT jsonb_array_length(j -> 'rows') = 0, 'MJ8 empty period';
  -- Nothing of org B; readers as the journal.
  j := public.exos_sales_tax_report(pg_temp.u('1'));
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'region' = 'TX'), 'MJ8 no org B rows';
  PERFORM pg_temp.act(pg_temp.u('s1'));
  ASSERT pg_temp.st(format('SELECT public.exos_sales_tax_report(%L)', pg_temp.u('1'))) = '42501', 'MJ8 scanner refused';
  PERFORM pg_temp.act(pg_temp.u('o2'));
  ASSERT pg_temp.st(format('SELECT public.exos_sales_tax_report(%L)', pg_temp.u('1'))) = '42501', 'MJ8 other org refused';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  MJ8 sales tax by jurisdiction: rates, unspecified, credit notes, POS, event and period filters, readers';
END $$;
RESET ROLE;

-- MJ9 -------------------------------------------------------------------------
-- Report outputs before any $0 order of this block, to compare after.
SELECT pg_temp.act(pg_temp.u('o1'));
CREATE TEMP TABLE mj_before AS
SELECT 'channel' AS k, (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.channel, c.kind, c.tickets) FROM public._exos_channel_lines(pg_temp.u('e1')) c) AS v
UNION ALL SELECT 'geo', public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10)
UNION ALL SELECT 'box', public._exos_box_office(pg_temp.u('e1'))
UNION ALL SELECT 'mcp', public.exos_mcp_event_sales(pg_temp.u('1'), pg_temp.u('e1')) -> 'orders'
UNION ALL SELECT 'money', public.exos_event_money_so_far(pg_temp.u('e1')) -> 'online';
DO $$
DECLARE ids uuid[]; v_sid text; s record; n int; r record; v_inv int;
BEGIN
  SELECT count(*) INTO v_inv FROM public.exos_invoices WHERE org_id = pg_temp.u('1');
  -- A free claim: 2 tickets, one $0 order.
  PERFORM pg_temp.act(pg_temp.u('b1'), 'mj-b1@x.com');
  ids := public.exos_claim_free_tickets(pg_temp.u('e1'), pg_temp.u('tf'), 2, NULL, NULL, NULL);
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE free_kind = 'free_claim' AND ticket_ids && ids;
  ASSERT s.session_id LIKE 'zero\_%' AND s.amount_cents = 0 AND s.quantity = 2 AND s.status = 'fulfilled' AND s.buyer_uid = pg_temp.u('b1')
     AND s.ticket_ids @> ids AND cardinality(s.ticket_ids) = 2 AND s.application_fee_cents = 0, 'MJ9 free claim: one $0 order';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE id = ANY (ids) AND order_ref = s.session_id) = 0, 'MJ9 tickets keep their order_ref';
  -- A comp batch: one order per recipient (one has an account, one doesn't).
  PERFORM pg_temp.act(pg_temp.u('o1'), 'mj-o1@x.com');
  FOR r IN SELECT * FROM public.exos_issue_comp_batch(pg_temp.u('e1'), pg_temp.u('t1'), ARRAY['mj-b2@x.com', 'mj-new@x.com'], 2) LOOP END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE free_kind = 'comp' AND event_id = pg_temp.u('e1')) = 2, 'MJ9 comp batch: two orders';
  ASSERT (SELECT buyer_uid FROM public.exos_checkout_sessions WHERE free_kind = 'comp' AND buyer_email = 'mj-b2@x.com') = pg_temp.u('b2'),
         'MJ9 comp to an account';
  ASSERT (SELECT buyer_uid IS NULL AND guest AND quantity = 2 FROM public.exos_checkout_sessions WHERE free_kind = 'comp' AND buyer_email = 'mj-new@x.com'),
         'MJ9 comp parked on staff is the recipient''s (guest), not the staff member''s';
  -- A box-office comp to an email.
  PERFORM public.exos_issue_ticket_to_email(pg_temp.u('e1'), pg_temp.u('t1'), 'mj-bo@x.com', 1, NULL);
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE free_kind = 'comp' AND buyer_email = 'mj-bo@x.com') = 1, 'MJ9 box-office comp';
  -- RSVP and referral reward refs (as their paths mint them).
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
  VALUES (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('tf'), 'Free', NULL, NULL, 'mj-rsvp@x.com', 'active', 'mj-r1', 0, 'rsvp:' || pg_temp.u('rv'), 'vibepass'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('tf'), 'Free', NULL, NULL, 'mj-rsvp@x.com', 'active', 'mj-r2', 0, 'rsvp:' || pg_temp.u('rv'), 'vibepass'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('tf'), 'Free', pg_temp.u('b2'), pg_temp.u('b2'), 'mj-b2@x.com', 'active', 'mj-r3', 0, 'referral_x', 'referral_reward'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('tf'), 'Free', NULL, NULL, NULL, 'active', 'mj-r4', 0, 'rsvp:phone', 'vibepass');
  ASSERT (SELECT quantity FROM public.exos_checkout_sessions WHERE free_kind = 'rsvp') = 2, 'MJ9 RSVP: one order of 2';
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE free_kind = 'referral') = 1, 'MJ9 referral reward';
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE free_kind = 'rsvp') = 1, 'MJ9 no buyer (phone only): no order';
  -- Not for: a paid checkout's tickets, a marketplace ticket, a partner sale, a paid door ticket.
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email, status, barcode_secret, price_paid, order_ref, channel_source)
  VALUES (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'mj-b1@x.com', 'active', 'mj-n1', 0, 'cs_mj_2', 'stripe'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'mj-b1@x.com', 'active', 'mj-n2', 0, 'cs_mj_2', 'vibepass'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'mj-b1@x.com', 'active', 'mj-n3', 0, 'mk_x', 'seatgeek'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'mj-b1@x.com', 'active', 'mj-n4', 0, 'po:x', 'vibepass'),
         (pg_temp.u('e1'), pg_temp.u('1'), pg_temp.u('t1'), 'GA', pg_temp.u('b1'), pg_temp.u('b1'), 'mj-b1@x.com', 'active', 'mj-n5', 40, NULL, 'boxoffice');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs, public.exos_tickets t
                      WHERE t.barcode_secret IN ('mj-n1', 'mj-n2', 'mj-n3', 'mj-n4', 'mj-n5') AND t.id = ANY (cs.ticket_ids)), 'MJ9 none for those';
  -- No invoice, no journal entry, no money for any of them.
  ASSERT (SELECT count(*) FROM public.exos_invoices WHERE org_id = pg_temp.u('1')) = v_inv, 'MJ9 no invoices';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_journal_entries e JOIN public.exos_checkout_sessions cs ON cs.session_id = e.source_id
                      WHERE cs.free_kind IS NOT NULL), 'MJ9 no journal entry';
  ASSERT (SELECT sum(amount_cents) FROM public.exos_checkout_sessions WHERE free_kind IS NOT NULL) = 0, 'MJ9 $0';
  -- A fulfilled update (the invoice trigger's path) still issues nothing.
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled' WHERE free_kind IS NOT NULL;
  ASSERT (SELECT count(*) FROM public.exos_invoices WHERE org_id = pg_temp.u('1')) = v_inv, 'MJ9 still no invoices';
  -- The constraint keeps them at $0.
  ASSERT pg_temp.st($q$UPDATE public.exos_checkout_sessions SET amount_cents = 100 WHERE free_kind = 'comp'$q$) = '23514', 'MJ9 $0 enforced';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  MJ9a $0 orders: free claim, comp batch (account / parked), box office, RSVP, referral; none for paid / marketplace / partner; no invoice, no entry';
END $$;
-- The reports read the same with and without the $0 orders (no double count, no revenue).
DO $$
DECLARE b record; now_v jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('o1'));
  FOR b IN SELECT * FROM mj_before LOOP
    now_v := CASE b.k
      WHEN 'channel' THEN (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.channel, c.kind, c.tickets) FROM public._exos_channel_lines(pg_temp.u('e1')) c)
      WHEN 'geo' THEN public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10)
      WHEN 'box' THEN public._exos_box_office(pg_temp.u('e1'))
      WHEN 'mcp' THEN public.exos_mcp_event_sales(pg_temp.u('1'), pg_temp.u('e1')) -> 'orders'
      WHEN 'money' THEN public.exos_event_money_so_far(pg_temp.u('e1')) -> 'online' END;
    IF b.k IN ('geo') THEN
      -- The new tickets show up once, as "other tickets" (as before this migration), never also as orders.
      ASSERT (now_v ->> 'orders') = (b.v ->> 'orders') AND (now_v ->> 'tickets') = (b.v ->> 'tickets'), 'MJ9 geo orders/tickets: ' || now_v::text;
    ELSIF b.k IN ('channel', 'box') THEN
      -- Comps minted since change the comp counts only (from exos_tickets), never paid or gross.
      NULL;
    ELSE
      ASSERT now_v = b.v, format('MJ9 %s changed: %s → %s', b.k, b.v, now_v);
    END IF;
  END LOOP;
  -- Channel lines and the box office, now, with and without the $0 rows: identical.
  CREATE TEMP TABLE mj_with AS
  SELECT 'channel' AS k, (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.channel, c.kind, c.tickets) FROM public._exos_channel_lines(pg_temp.u('e1')) c) AS v
  UNION ALL SELECT 'geo', public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10)
  UNION ALL SELECT 'box', public._exos_box_office(pg_temp.u('e1'))
  UNION ALL SELECT 'cash', public._exos_cash_summary(pg_temp.u('1'), pg_temp.u('e1'), NULL, NULL) - 'computed_at'
  UNION ALL SELECT 'inapp', public.exos_event_in_app_report(pg_temp.u('e1'))
  UNION ALL SELECT 'analytics', public.exos_event_analytics(pg_temp.u('e1')) - 'computed_at' - 'generated_at';
  BEGIN
    ALTER TABLE public.exos_checkout_sessions DISABLE TRIGGER USER;
    DELETE FROM public.exos_checkout_sessions WHERE free_kind IS NOT NULL;
    ALTER TABLE public.exos_checkout_sessions ENABLE TRIGGER USER;
    FOR b IN SELECT * FROM mj_with LOOP
      now_v := CASE b.k
        WHEN 'channel' THEN (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.channel, c.kind, c.tickets) FROM public._exos_channel_lines(pg_temp.u('e1')) c)
        WHEN 'geo' THEN public._exos_buyer_geo(pg_temp.u('1'), pg_temp.u('e1'), NULL, 10)
        WHEN 'box' THEN public._exos_box_office(pg_temp.u('e1'))
        WHEN 'cash' THEN public._exos_cash_summary(pg_temp.u('1'), pg_temp.u('e1'), NULL, NULL) - 'computed_at'
        WHEN 'inapp' THEN public.exos_event_in_app_report(pg_temp.u('e1'))
        WHEN 'analytics' THEN public.exos_event_analytics(pg_temp.u('e1')) - 'computed_at' - 'generated_at' END;
      ASSERT now_v IS NOT DISTINCT FROM b.v, format('MJ9 %s differs with the $0 orders: %s vs %s', b.k, b.v, now_v);
    END LOOP;
    RAISE EXCEPTION 'undo' USING ERRCODE = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE free_kind IS NOT NULL) >= 6, 'MJ9 the $0 orders are back';
  RAISE NOTICE 'OK  MJ9b reports read the same with and without the $0 orders (channel lines, geo, box office, cash summary, in-app, analytics, MCP, money so far)';
END $$;

-- MJ10 ------------------------------------------------------------------------
DO $$
DECLARE r text; v_id uuid; j jsonb;
BEGIN
  -- Append-only, the table owner too.
  r := pg_temp.st($q$UPDATE public.exos_journal_lines SET debit_cents = debit_cents + 1 WHERE org_id = pg_temp.u('1')$q$);
  ASSERT r = '55000', 'MJ10 update refused: ' || r;
  r := pg_temp.st($q$DELETE FROM public.exos_journal_entries WHERE org_id = pg_temp.u('1')$q$);
  ASSERT r = '55000', 'MJ10 delete refused: ' || r;
  r := pg_temp.st($q$TRUNCATE public.exos_journal_lines$q$);
  ASSERT r = '55000', 'MJ10 truncate refused: ' || r;
  -- The writer refuses an unbalanced entry up front; an unknown account too.
  r := pg_temp.st($q$SELECT public._exos_journal_post(pg_temp.u('1'), NULL, 'exos_pos_payments', 'mj-bad', 'pos_cash_sale', now(), 'usd', 'x',
                       '[{"a":"pos_cash_drawer","c":100},{"a":"ticket_revenue","c":-99}]'::jsonb)$q$);
  ASSERT r = '23514', 'MJ10 writer refuses unbalanced: ' || r;
  r := pg_temp.st($q$SELECT public._exos_journal_post(pg_temp.u('1'), NULL, 'exos_pos_payments', 'mj-bad', 'pos_cash_sale', now(), 'usd', 'x',
                       '[{"a":"cash","c":100},{"a":"ticket_revenue","c":-100}]'::jsonb)$q$);
  ASSERT r = '22023', 'MJ10 unknown account: ' || r;
  -- A direct unbalanced insert (as the owner) is caught by the deferred check.
  BEGIN
    INSERT INTO public.exos_journal_entries (org_id, source_table, source_id, kind, occurred_at, currency, total_cents)
    VALUES (pg_temp.u('1'), 'exos_pos_payments', 'mj-direct', 'pos_cash_sale', now(), 'USD', 100) RETURNING id INTO v_id;
    INSERT INTO public.exos_journal_lines (entry_id, org_id, line_no, account, debit_cents) VALUES (v_id, pg_temp.u('1'), 1, 'pos_cash_drawer', 100);
    INSERT INTO public.exos_journal_lines (entry_id, org_id, line_no, account, credit_cents) VALUES (v_id, pg_temp.u('1'), 2, 'ticket_revenue', 90);
    PERFORM pg_temp.check_all();
    RAISE EXCEPTION 'MJ10 the deferred check let an unbalanced entry through';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- A line on another org's entry is refused too.
  BEGIN
    INSERT INTO public.exos_journal_entries (org_id, source_table, source_id, kind, occurred_at, currency, total_cents)
    VALUES (pg_temp.u('1'), 'exos_pos_payments', 'mj-direct2', 'pos_cash_sale', now(), 'USD', 100) RETURNING id INTO v_id;
    INSERT INTO public.exos_journal_lines (entry_id, org_id, line_no, account, debit_cents) VALUES (v_id, pg_temp.u('1'), 1, 'pos_cash_drawer', 100);
    INSERT INTO public.exos_journal_lines (entry_id, org_id, line_no, account, credit_cents) VALUES (v_id, pg_temp.u('2'), 2, 'ticket_revenue', 100);
    PERFORM pg_temp.check_all();
    RAISE EXCEPTION 'MJ10 a line of another org got through';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- The backfill on a posted org posts nothing; everything posted so far balances.
  j := public._exos_journal_backfill(pg_temp.u('1'));
  ASSERT (j ->> 'posted')::int = 0, 'MJ10 backfill no-op: ' || j::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
                      WHERE e.org_id IN (pg_temp.u('1'), pg_temp.u('2'))
                      GROUP BY e.id HAVING sum(l.debit_cents) <> sum(l.credit_cents)), 'MJ10 every entry balances';
  PERFORM pg_temp.check_all();
  RAISE NOTICE 'OK  MJ10 append-only, writer and deferred checks refuse unbalanced / cross-org lines, backfill no-op';
END $$;

ROLLBACK;
