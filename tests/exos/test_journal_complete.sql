-- ============================================================================
-- The money journal, completed (mig 20261110100000). Self-contained (BEGIN /
-- ROLLBACK; ids md5('jc01:…')).
--   JC0 shape: the chart (25 accounts), the new posting functions are
--       service-role only with search_path pinned, the new triggers (the gift
--       card ledger's deferred to commit), the source check takes the new tables
--   JC1 POS card tender: the real card flow (begin, attach, capture,
--       complete) posts pos_card_sale: clearing net of the application fee,
--       Exos fee + card fees, tax, face; posting twice (and the webhook's
--       replay) is one entry; the card refund posts once Stripe says
--       succeeded and nets the sale to zero at Stripe; a late 'pending'
--       answer changes nothing
--   JC2 gift cards: an online sale (application fee withheld), a cash sale
--       into a drawer, a comp, a check sale; a redemption on an order is the
--       order's sale (no second entry); a refund to the card restores the
--       liability with its tax share (twice with one key = one entry), then
--       the rest on a full refund; a reservation redemption posts when the
--       reservation completes; a void is breakage; a refunded online purchase
--       gives the money back; the liability equals the cards' balances
--   JC3 payouts: an instant payout posts once sent and reverses if it fails;
--       a PayPal remittance moves the receivable to the bank (a Stripe
--       transfer to Stripe clearing); a repeat of the same reference is one
--   JC4 the drawer: float in, cash sale, paid-out, a cash gift card, close
--       short (cash over / short), the counted cash out (the drawer nets to
--       zero), a recount posts only the difference; posting twice is a no-op
--   JC5 a gift card row naming another org's order posts nothing; RLS and
--       cross-org isolation on the new entries; clients and anon can't post
--   JC6 every entry balances; the trial balance balances for both orgs; the
--       backfill is a no-op; and on the WHOLE harness database every org and
--       currency balances
-- Users: o1 owner A, m1 manager A, f1 finance A, s1 scanner A (staff of e1),
--        o2 owner B, b1 buyer.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('jc01:' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO authenticated;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true), set_config('app.jwt', '', true) $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO authenticated;
-- Signed balance (debit − credit) of an account: over one source id (or a
-- source id prefix with p_like), or the whole org.
CREATE FUNCTION pg_temp.bal(p_account text, p_source text DEFAULT NULL, p_org text DEFAULT '1', p_like boolean DEFAULT false)
RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0)::bigint
    FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
   WHERE l.account = p_account AND e.org_id = pg_temp.u(p_org)
     AND (p_source IS NULL OR e.source_id = p_source OR (p_like AND e.source_id LIKE p_source || '%'))
$$;
CREATE FUNCTION pg_temp.n(p_source text, p_kind text DEFAULT NULL) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_journal_entries
   WHERE source_id = p_source AND (p_kind IS NULL OR kind = p_kind OR kind LIKE p_kind || ':%')
$$;
-- The ledger rows of one card (and kind), oldest first.
CREATE FUNCTION pg_temp.gl(p_card uuid, p_kind text) RETURNS bigint LANGUAGE sql AS $$
  SELECT max(id) FROM public.exos_gift_card_ledger WHERE card_id = p_card AND kind = p_kind $$;
-- Fire the deferred checks and the deferred gift card trigger now (they run at
-- COMMIT; this file rolls back), then defer them again.
CREATE FUNCTION pg_temp.commit_point() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS exos_gift_card_ledger_journal IMMEDIATE;
  SET CONSTRAINTS exos_gift_card_ledger_journal DEFERRED;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced IMMEDIATE;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced DEFERRED;
END $$;
CREATE TEMP TABLE jk (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM jk WHERE k = p_k $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('o1'), 'jc-o1@x.com', now()), (pg_temp.u('m1'), 'jc-m1@x.com', now()),
  (pg_temp.u('f1'), 'jc-f1@x.com', now()), (pg_temp.u('s1'), 'jc-s1@x.com', now()),
  (pg_temp.u('o2'), 'jc-o2@x.com', now()), (pg_temp.u('b1'), 'jc-b1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'JC Hall', 'jc-hall', pg_temp.u('o1')),
  (pg_temp.u('2'), 'JC Other', 'jc-other', pg_temp.u('o2'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('o1'), 'owner'), (pg_temp.u('1'), pg_temp.u('m1'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('f1'), 'finance'), (pg_temp.u('1'), pg_temp.u('s1'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('o2'), 'owner');
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id IN (pg_temp.u('1'), pg_temp.u('2'));
-- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('1'), '{"connectedAccountId":"acct_jcOrgA","chargesEnabled":true}'),
  (pg_temp.u('2'), '{"connectedAccountId":"acct_jcOrgB","chargesEnabled":true}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'JC Night', 'jc-night', 'published', now() + interval '2 hours', now() - interval '1 hour', 500, 0, 'usd', pg_temp.u('o1')),
  (pg_temp.u('e9'), pg_temp.u('2'), 'JC Elsewhere', 'jc-else', 'published', now() + interval '2 hours', now() - interval '1 hour', 500, 0, 'usd', pg_temp.u('o2'));
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES (pg_temp.u('e1'), pg_temp.u('s1'), pg_temp.u('1'));
INSERT INTO public.exos_tax_rules (id, event_id, name, rate_percent, price_includes_tax) VALUES
  (pg_temp.u('x1'), pg_temp.u('e1'), 'NY sales tax', 8.875, false);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, tax_rate_id) VALUES
  (pg_temp.u('t1'), pg_temp.u('e1'), 'GA', 40, 200, 0, pg_temp.u('x1')),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 30, 200, 0, NULL);

-- JC0 ------------------------------------------------------------------------
DO $$
DECLARE f text; t text;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_journal_accounts()) = 25, 'JC0 the chart has 25 accounts';
  ASSERT (SELECT bool_and(public._exos_journal_account_ok(code)) FROM public.exos_journal_accounts()), 'JC0 every code accepted';
  ASSERT (SELECT type FROM public.exos_journal_accounts() WHERE code = 'opening_balances') = 'equity', 'JC0 equity account';
  FOREACH f IN ARRAY ARRAY['public.exos_journal_post_pos_reversal(uuid)', 'public.exos_journal_post_gift_card(bigint)',
                           'public.exos_journal_post_gift_card_redemption(text)', 'public.exos_journal_post_drawer(uuid)',
                           'public.exos_journal_post_instant_payout(uuid)', 'public.exos_journal_post_paypal_remittance(uuid)',
                           'public.exos_journal_post_pos_payment(uuid)', 'public._exos_journal_backfill(uuid)',
                           'public._exos_journal_pos_card_fees(public.exos_pos_payments)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'JC0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'JC0 authenticated runs ' || f;
    ASSERT (SELECT bool_or(c LIKE 'search_path=%') FROM pg_proc p, unnest(p.proconfig) c WHERE p.oid = f::regprocedure),
           'JC0 search_path pinned on ' || f;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_pos_reversals', 'exos_gift_card_ledger', 'exos_gift_card_redemptions', 'exos_pos_drawer_sessions',
                           'exos_org_instant_payouts', 'exos_paypal_org_remittances'] LOOP
    ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = ('public.' || t)::regclass AND tgname = t || '_journal'),
           'JC0 journal trigger on ' || t;
  END LOOP;
  ASSERT (SELECT tgdeferrable AND tginitdeferred FROM pg_trigger WHERE tgname = 'exos_gift_card_ledger_journal'),
         'JC0 the gift card ledger posts at commit';
  ASSERT position('exos_gift_card_ledger' in pg_get_constraintdef((SELECT oid FROM pg_constraint
           WHERE conname = 'exos_journal_entries_source_table_check'))) > 0, 'JC0 the source check takes the new tables';
  RAISE NOTICE 'OK  JC0 shape: 25 accounts, writers service-role only + search_path, the new triggers (ledger deferred), sources';
END $$;

-- JC1 ------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_o uuid; v_pay uuid; v_rv uuid; v_dev uuid; v_tax int; v_total int; e record;
BEGIN
  PERFORM pg_temp.act(NULL);
  PERFORM public._exos_pos_terminal_save_location(pg_temp.u('o1'), pg_temp.u('1'), false, 'tml_jcOrgA', 'JC box office', '{"line1":"1 Main St"}');
  r := public._exos_pos_terminal_save_reader(pg_temp.u('o1'), pg_temp.u('1'), false, 'tmr_jcDoor', 'Door 1', 'stripe_s700', NULL);
  v_dev := (r ->> 'device_id')::uuid;
  -- 2 × GA at the door by card: $40 + 8.875% tax each.
  r := public._exos_pos_walkup_begin_card(pg_temp.u('s1'), pg_temp.u('e1'), pg_temp.u('t1'), 2, pg_temp.u('k1'),
                                          NULL, 'Card Buyer', NULL, NULL, false);
  v_o := (r ->> 'id')::uuid;
  SELECT tax_cents, total_cents INTO v_tax, v_total FROM public.exos_pos_orders WHERE id = v_o;
  PERFORM public._exos_pos_card_begin(pg_temp.u('s1'), v_o, 'reader', v_dev, false);
  PERFORM public._exos_pos_card_attach(v_o, 'pi_jcCard1', v_total, 'usd', 300, 120, 180, 300);
  ASSERT public._exos_pos_card_capture_prepare(v_o, 'pi_jcCard1') ->> 'action' = 'capture', 'JC1 capture';
  r := public._exos_pos_card_complete(v_o, 'pi_jcCard1', v_total, 'door', NULL);
  ASSERT r ->> 'status' = 'paid', 'JC1 paid by card: ' || r::text;
  SELECT id INTO v_pay FROM public.exos_pos_payments WHERE order_id = v_o AND method = 'card';
  INSERT INTO jk VALUES ('card_order', v_o::text), ('card_pay', v_pay::text);
  ASSERT pg_temp.n(v_pay::text, 'pos_card_sale') = 1, 'JC1 the card tender posted';
  SELECT * INTO e FROM public.exos_journal_entries WHERE source_id = v_pay::text;
  ASSERT e.org_id = pg_temp.u('1') AND e.event_id = pg_temp.u('e1') AND e.source_table = 'exos_pos_payments' AND e.currency = 'USD',
         'JC1 entry header';
  ASSERT pg_temp.bal('stripe_clearing', v_pay::text) = v_total - 300, 'JC1 clearing = charge − application fee';
  ASSERT pg_temp.bal('exos_fee', v_pay::text) = 120 AND pg_temp.bal('card_fees', v_pay::text) = 180, 'JC1 Exos fee + card fees';
  ASSERT pg_temp.bal('sales_tax_payable', v_pay::text) = -v_tax AND pg_temp.bal('ticket_revenue', v_pay::text) = -(v_total - v_tax),
         'JC1 tax and face';
  ASSERT pg_temp.bal('pos_cash_drawer', v_pay::text) = 0, 'JC1 nothing in a drawer';
  -- Twice, and the webhook's replay of the completion: one entry.
  ASSERT public.exos_journal_post_pos_payment(v_pay) IS NULL, 'JC1 second post is a no-op';
  r := public._exos_pos_card_complete(v_o, 'pi_jcCard1', v_total, 'webhook', 'evt_jcReplay');
  ASSERT (r ->> 'replay')::boolean, 'JC1 webhook replay';
  ASSERT pg_temp.n(v_pay::text) = 1, 'JC1 still one entry';
  -- Voided the same night: nothing until Stripe confirms the refund.
  r := public._exos_pos_card_reverse(pg_temp.u('s1'), v_o, 'void', 'wrong night', false, NULL);
  SELECT id INTO v_rv FROM public.exos_pos_reversals WHERE order_id = v_o;
  INSERT INTO jk VALUES ('card_rv', v_rv::text);
  ASSERT pg_temp.n(v_rv::text) = 0, 'JC1 a pending card refund posts nothing';
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_jcCard1', 're_jcCard1', 'pending', NULL);
  ASSERT pg_temp.n(v_rv::text) = 0, 'JC1 still pending';
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_jcCard1', 're_jcCard1', 'succeeded', NULL);
  ASSERT pg_temp.n(v_rv::text, 'pos_card_refund') = 1, 'JC1 the refund posted';
  ASSERT pg_temp.bal('refunds', v_rv::text) = v_total - v_tax AND pg_temp.bal('sales_tax_payable', v_rv::text) = v_tax
     AND pg_temp.bal('stripe_clearing', v_rv::text) = -(v_total - 300) AND pg_temp.bal('exos_fee', v_rv::text) = -120
     AND pg_temp.bal('card_fees', v_rv::text) = -180, 'JC1 the refund mirrors the sale';
  -- A late 'pending' answer, the trigger again, a direct post: nothing new.
  PERFORM public._exos_pos_card_refund_record(v_o, 'pi_jcCard1', 're_jcCard1', 'pending', NULL);
  ASSERT public.exos_journal_post_pos_reversal(v_rv) IS NULL AND pg_temp.n(v_rv::text) = 1, 'JC1 refund idempotent';
  ASSERT pg_temp.bal('stripe_clearing', v_pay::text) + pg_temp.bal('stripe_clearing', v_rv::text) = 0
     AND pg_temp.bal('exos_fee', v_pay::text) + pg_temp.bal('exos_fee', v_rv::text) = 0, 'JC1 sale + refund net to zero at Stripe';
  PERFORM pg_temp.commit_point();
  RAISE NOTICE 'OK  JC1 POS card: sale posted from the real flow (fee withheld, tax, face), idempotent with the webhook replay; refund on success only, once';
END $$;

-- JC2 ------------------------------------------------------------------------
-- An open drawer at e1 (scanner s1) for the cash gift card and JC4.
SELECT pg_temp.act(pg_temp.u('s1'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 5000);
DO $$
DECLARE r jsonb; v_on uuid; v_cash uuid; v_comp uuid; v_chk uuid; v_l bigint; v_code text; v_tax_order int; n int;
        v_res uuid; v_on2 uuid; v_cs_tax bigint;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- a. Online: a commerce order of $50.00 with a $2.50 application fee.
  INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, amount_cents, currency, details, application_fee_cents, status)
  VALUES ('cs_jc_gc1', pg_temp.u('1'), 'gift_card', 5000, 'usd', '{"amount_cents":5000}', 250, 'pending');
  r := public._exos_gift_card_issue(pg_temp.u('1'), NULL, 5000, 'usd', 'online', 'card', 'cs_jc_gc1', NULL, pg_temp.u('b1'),
                                    'jc-b1@x.com', NULL, NULL, NULL, false);
  v_on := (r ->> 'card_id')::uuid; v_code := r ->> 'code';
  INSERT INTO jk VALUES ('gc_on', v_on::text), ('gc_on_code', v_code);
  v_l := pg_temp.gl(v_on, 'issue');
  ASSERT pg_temp.n(v_l::text) = 0, 'JC2 the issue posts at commit, not before';
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.n(v_l::text, 'gc_issue') = 1, 'JC2 online issue posted';
  ASSERT pg_temp.bal('gift_cards_outstanding', v_l::text) = -5000 AND pg_temp.bal('stripe_clearing', v_l::text) = 4750
     AND pg_temp.bal('exos_fee', v_l::text) = 250 AND pg_temp.bal('ticket_revenue', v_l::text) = 0,
         'JC2 online sale: a liability, not revenue; the fee withheld';
  ASSERT public.exos_journal_post_gift_card(v_l) IS NULL AND pg_temp.n(v_l::text) = 1, 'JC2 issue idempotent';

  -- b. Cash at the box office into the open drawer (manager), c. a comp (owner), d. a check (manager).
  PERFORM pg_temp.act(pg_temp.u('m1'));
  r := public.exos_gift_card_issue(p_org_id => pg_temp.u('1'), p_amount_cents => 2500, p_payment_method => 'cash',
                                   p_drawer_id => pg_temp.u('dr'));
  v_cash := (r ->> 'card_id')::uuid;
  INSERT INTO jk VALUES ('gc_cash', v_cash::text), ('gc_cash_code', r ->> 'code');
  PERFORM pg_temp.act(pg_temp.u('o1'));
  r := public.exos_gift_card_issue(p_org_id => pg_temp.u('1'), p_amount_cents => 1500, p_payment_method => 'comp', p_source => 'dashboard');
  v_comp := (r ->> 'card_id')::uuid;
  PERFORM pg_temp.act(pg_temp.u('m1'));
  r := public.exos_gift_card_issue(p_org_id => pg_temp.u('1'), p_amount_cents => 2000, p_payment_method => 'check');
  v_chk := (r ->> 'card_id')::uuid;
  INSERT INTO jk VALUES ('gc_chk', v_chk::text);
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.commit_point();
  v_l := pg_temp.gl(v_cash, 'issue');
  ASSERT pg_temp.bal('pos_cash_drawer', v_l::text) = 2500 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = -2500
     AND (SELECT event_id FROM public.exos_journal_entries WHERE source_id = v_l::text) = pg_temp.u('e1'),
         'JC2 cash card: into the drawer it was sold from (set after the issue row; posted at commit)';
  v_l := pg_temp.gl(v_comp, 'issue');
  ASSERT pg_temp.bal('gift_card_comps', v_l::text) = 1500 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = -1500,
         'JC2 comp card: given away';
  v_l := pg_temp.gl(v_chk, 'issue');
  ASSERT pg_temp.bal('cash_on_hand', v_l::text) = 2000 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = -2000,
         'JC2 check: cash on hand';

  -- e. An order paid $30.00 by card + $20.00 by the online gift card ($4.00 tax).
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, processor)
  VALUES ('cs_jc_o1', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jc-b1@x.com', 1, 3000, 'usd', 'pending',
          400, 210, 90, 120, 2000, 'stripe');
  PERFORM public.exos_gift_card_hold(v_code, 'cs_jc_o1', 2000, 'jc-test', pg_temp.u('1'), 'usd');
  ASSERT public._exos_gift_card_capture('cs_jc_o1', 2000), 'JC2 captured';
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_jc_o1';
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.n('cs_jc_o1', 'sale') = 1 AND pg_temp.bal('gift_cards_outstanding', 'cs_jc_o1') = 2000,
         'JC2 the order''s sale moves the gift card part to revenue';
  ASSERT pg_temp.n(pg_temp.gl(v_on, 'redeem')::text) = 0, 'JC2 the hold row posts nothing';
  ASSERT public.exos_journal_post_gift_card_redemption('cs_jc_o1') IS NULL AND pg_temp.n('cs_jc_o1') = 1,
         'JC2 posting the redemption again is the same one sale entry';
  -- f. $10.00 back on the card, twice with one key: one ledger row, one entry.
  PERFORM public.exos_gift_card_refund_order('cs_jc_o1', 1000, 'part1', 'partial');
  PERFORM public.exos_gift_card_refund_order('cs_jc_o1', 1000, 'part1', 'partial');
  PERFORM pg_temp.commit_point();
  v_l := pg_temp.gl(v_on, 'refund');
  ASSERT (SELECT count(*) FROM public.exos_gift_card_ledger WHERE card_id = v_on AND kind = 'refund') = 1, 'JC2 one refund row';
  ASSERT pg_temp.n(v_l::text, 'gc_refund') = 1, 'JC2 refund to the card posted';
  -- tax share: 400 × 1000 / 5000 = 80.
  ASSERT pg_temp.bal('gift_cards_outstanding', v_l::text) = -1000 AND pg_temp.bal('sales_tax_payable', v_l::text) = 80
     AND pg_temp.bal('refunds', v_l::text) = 920, 'JC2 the liability restored, with its tax share';
  ASSERT (SELECT session_id FROM public.exos_journal_entries WHERE source_id = v_l::text) = 'cs_jc_o1', 'JC2 tied to the order';
  ASSERT public.exos_journal_post_gift_card(v_l) IS NULL, 'JC2 refund idempotent';
  -- The whole order refunded: the rest of the card part comes back too.
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_jc_o1';
  PERFORM pg_temp.commit_point();
  ASSERT (SELECT count(*) FROM public.exos_journal_entries e JOIN public.exos_gift_card_ledger l ON e.source_id = l.id::text
           WHERE e.source_table = 'exos_gift_card_ledger' AND l.card_id = v_on AND e.kind = 'gc_refund') = 2, 'JC2 the rest back';
  SELECT coalesce(sum(jl.debit_cents - jl.credit_cents), 0) INTO v_cs_tax FROM public.exos_journal_lines jl
    JOIN public.exos_journal_entries e ON e.id = jl.entry_id
   WHERE e.session_id = 'cs_jc_o1' AND e.source_table <> 'exos_checkout_sessions' AND jl.account = 'sales_tax_payable';
  ASSERT v_cs_tax = 160 AND v_cs_tax <= 400, 'JC2 gift card tax back = its share, never above the order''s tax: ' || v_cs_tax;

  -- g. A partner reservation paid $15.00 by the cash card: posts when it completes.
  INSERT INTO public.exos_partner_reservations (id, token, org_id, event_id, channel, channel_source, expires_at, lines, quantity, total_cents)
  VALUES (pg_temp.u('rs'), 'rsv_' || rpad('jc', 43, 'x'), pg_temp.u('1'), pg_temp.u('e1'), 'partner', 'partner:jc',
          now() + interval '1 hour', '[]', 1, 4355);
  INSERT INTO public.exos_gift_card_redemptions (session_id, card_id, org_id, amount_cents, partner_reservation_id, fee_paid_at_sale)
  VALUES ('res_jc_1', v_cash, pg_temp.u('1'), 1500, pg_temp.u('rs'), false);
  PERFORM public._exos_gift_card_move(v_cash, 'redeem', -1500, 'res_jc_1', 'res_jc_1', NULL, 'held for reservation');
  ASSERT pg_temp.n('res_jc_1') = 0, 'JC2 a held reservation part posts nothing';
  UPDATE public.exos_partner_reservations SET status = 'completed', completed_at = now() WHERE id = pg_temp.u('rs');
  ASSERT pg_temp.n('res_jc_1', 'gc_redeem') = 1 AND pg_temp.bal('gift_cards_outstanding', 'res_jc_1') = 1500
     AND pg_temp.bal('ticket_revenue', 'res_jc_1') = -1500, 'JC2 reservation redemption: liability to revenue';
  ASSERT public.exos_journal_post_gift_card_redemption('res_jc_1') IS NULL AND pg_temp.n('res_jc_1') = 1, 'JC2 redemption idempotent';
  -- $5.00 of it back on the card.
  PERFORM public.exos_gift_card_refund_order('res_jc_1', 500, 'r1', 'partial');
  PERFORM pg_temp.commit_point();
  v_l := pg_temp.gl(v_cash, 'refund');
  ASSERT pg_temp.bal('refunds', v_l::text) = 500 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = -500,
         'JC2 a reservation refund to the card';

  -- h. The check card voided: breakage.
  PERFORM public.exos_gift_card_void(v_chk, 'lost and found');
  PERFORM pg_temp.commit_point();
  v_l := pg_temp.gl(v_chk, 'void');
  ASSERT pg_temp.n(v_l::text, 'gc_void') = 1 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = 2000
     AND pg_temp.bal('gift_card_breakage', v_l::text) = -2000, 'JC2 void: breakage';

  -- i. A second online card whose purchase is refunded: the money goes back.
  INSERT INTO public.exos_commerce_orders (session_id, org_id, kind, amount_cents, currency, details, application_fee_cents, status)
  VALUES ('cs_jc_gc2', pg_temp.u('1'), 'gift_card', 4000, 'usd', '{"amount_cents":4000}', 200, 'pending');
  r := public._exos_gift_card_issue(pg_temp.u('1'), NULL, 4000, 'usd', 'online', 'card', 'cs_jc_gc2', NULL, NULL, NULL,
                                    NULL, NULL, NULL, false);
  v_on2 := (r ->> 'card_id')::uuid;
  UPDATE public.exos_commerce_orders SET status = 'fulfilled', result_id = v_on2, fulfilled_at = now() WHERE session_id = 'cs_jc_gc2';
  PERFORM public.exos_commerce_refund('cs_jc_gc2', 'buyer changed mind');
  PERFORM pg_temp.commit_point();
  v_l := pg_temp.gl(v_on2, 'void');
  ASSERT pg_temp.n(v_l::text, 'gc_purchase_refund') = 1 AND pg_temp.bal('gift_cards_outstanding', v_l::text) = 4000
     AND pg_temp.bal('stripe_clearing', v_l::text) = -3800 AND pg_temp.bal('exos_fee', v_l::text) = -200,
         'JC2 a refunded purchase: the money back, the fee returned, no breakage';
  ASSERT pg_temp.bal('gift_card_breakage', v_l::text) = 0, 'JC2 no breakage on a refunded purchase';

  -- The liability equals what the org's cards hold (no hold open).
  ASSERT -pg_temp.bal('gift_cards_outstanding') = (SELECT sum(balance_cents) FROM public.exos_gift_cards WHERE org_id = pg_temp.u('1')),
         format('JC2 gift cards outstanding %s = the cards'' balances %s', -pg_temp.bal('gift_cards_outstanding'),
                (SELECT sum(balance_cents) FROM public.exos_gift_cards WHERE org_id = pg_temp.u('1')));
  RAISE NOTICE 'OK  JC2 gift cards: sale (online / cash drawer / comp / check) is a liability; redemption on the order; refund restores it with its tax share; reservation; void breakage; purchase refund; liability = balances';
END $$;

-- JC3 ------------------------------------------------------------------------
DO $$
DECLARE v_ip uuid := pg_temp.u('ip'); v_pr uuid; v_pr2 uuid; v_prb uuid;
BEGIN
  INSERT INTO public.exos_org_instant_payouts (id, org_id, currency, amount_cents, fee_estimate_cents, idempotency_key, requested_by)
  VALUES (v_ip, pg_temp.u('1'), 'usd', 3000, 45, 'jc-instant-0001', pg_temp.u('o1'));
  ASSERT pg_temp.n(v_ip::text) = 0, 'JC3 a requested payout posts nothing';
  UPDATE public.exos_org_instant_payouts SET status = 'sent', stripe_payout_id = 'po_jc1' WHERE id = v_ip;
  ASSERT pg_temp.n(v_ip::text, 'stripe_payout') = 1 AND pg_temp.bal('bank', v_ip::text) = 3000
     AND pg_temp.bal('stripe_clearing', v_ip::text) = -3000, 'JC3 instant payout: Stripe to the bank';
  ASSERT public.exos_journal_post_instant_payout(v_ip) IS NULL, 'JC3 idempotent';
  UPDATE public.exos_org_instant_payouts SET status = 'failed', error = 'bank said no' WHERE id = v_ip;
  ASSERT pg_temp.n(v_ip::text, 'stripe_payout_reversal') = 1 AND pg_temp.bal('bank', v_ip::text) = 0
     AND (SELECT reverses IS NOT NULL FROM public.exos_journal_entries WHERE source_id = v_ip::text AND kind = 'stripe_payout_reversal'),
         'JC3 a failed payout reverses';
  v_pr := public.exos_record_paypal_remittance(pg_temp.u('1'), 2500, 'jc-pp-1', 'usd', 'bank', NULL, now(), NULL);
  ASSERT pg_temp.n(v_pr::text, 'paypal_remittance') = 1 AND pg_temp.bal('bank', v_pr::text) = 2500
     AND pg_temp.bal('paypal_receivable', v_pr::text) = -2500, 'JC3 PayPal remittance to the bank';
  v_pr2 := public.exos_record_paypal_remittance(pg_temp.u('1'), 2500, 'jc-pp-1', 'usd', 'bank', 'again', now(), NULL);
  ASSERT v_pr2 = v_pr AND pg_temp.n(v_pr::text) = 1, 'JC3 the same reference is one entry';
  v_pr2 := public.exos_record_paypal_remittance(pg_temp.u('1'), 700, 'jc-pp-2', 'usd', 'stripe_transfer', NULL, now(), NULL);
  ASSERT pg_temp.bal('stripe_clearing', v_pr2::text) = 700 AND pg_temp.bal('bank', v_pr2::text) = 0, 'JC3 a Stripe transfer lands at Stripe';
  -- Org B's remittance stays in org B.
  v_prb := public.exos_record_paypal_remittance(pg_temp.u('2'), 900, 'jc-pp-b', 'usd', 'manual', NULL, now(), NULL);
  INSERT INTO jk VALUES ('pp_b', v_prb::text);
  ASSERT pg_temp.bal('bank', v_prb::text, '2') = 900 AND pg_temp.bal('bank', v_prb::text, '1') = 0, 'JC3 org B''s remittance in org B';
  PERFORM pg_temp.commit_point();
  RAISE NOTICE 'OK  JC3 payouts: instant payout on sent (reversed on failure), PayPal remittances (bank / Stripe transfer), one per reference';
END $$;

-- JC4 ------------------------------------------------------------------------
DO $$
DECLARE r jsonb; v_dr uuid := pg_temp.u('dr'); v_exp int; v_tot int; v_var bigint; v_drawer_before bigint; d record;
BEGIN
  ASSERT pg_temp.n(v_dr::text, 'drawer_float') = 1 AND pg_temp.bal('pos_cash_drawer', v_dr::text) = 5000
     AND pg_temp.bal('cash_on_hand', v_dr::text) = -5000, 'JC4 the float went in';
  PERFORM pg_temp.act(pg_temp.u('s1'));
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('t1'), 1, pg_temp.u('k4'), 0, 'cash', NULL, v_dr, 'Walk Up', NULL, NULL, NULL);
  SELECT total_cents INTO v_tot FROM public.exos_pos_orders WHERE id = (r ->> 'id')::uuid;
  r := public.exos_pos_paid_out(v_dr, 1200, 'ice for the bar', NULL);
  -- Expected: float 5000 + sale + the $25.00 cash gift card (JC2) − 1200; counted $3.00 short.
  v_exp := 5000 + v_tot + 2500 - 1200;
  ASSERT public._exos_pos_drawer_cash(v_dr) = v_exp, 'JC4 the drawer''s cash';
  -- What the journal says the drawer holds before the close = the expected cash.
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0) INTO v_drawer_before
    FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
   WHERE e.org_id = pg_temp.u('1') AND l.account = 'pos_cash_drawer';
  ASSERT v_drawer_before = v_exp, format('JC4 the journal''s drawer %s = the expected cash %s', v_drawer_before, v_exp);
  r := public.exos_pos_close_drawer(v_dr, v_exp - 300, NULL, 'end of night');
  SELECT * INTO d FROM public.exos_pos_drawer_sessions WHERE id = v_dr;
  ASSERT d.variance_cents = -300, 'JC4 short by 300';
  ASSERT pg_temp.n(v_dr::text || ':variance', 'drawer_variance') = 1 AND pg_temp.bal('cash_over_short', v_dr::text || ':variance') = 300
     AND pg_temp.bal('pos_cash_drawer', v_dr::text || ':variance') = -300, 'JC4 the shortfall to cash over / short';
  ASSERT pg_temp.bal('cash_on_hand', v_dr::text || ':close') = v_exp - 300 AND pg_temp.bal('pos_cash_drawer', v_dr::text || ':close') = -(v_exp - 300),
         'JC4 the counted cash out of the drawer';
  ASSERT pg_temp.bal('pos_cash_drawer') = 0, 'JC4 a closed drawer nets to zero: ' || pg_temp.bal('pos_cash_drawer');
  ASSERT public.exos_journal_post_drawer(v_dr) IS NULL, 'JC4 posting again is a no-op';
  -- The owner recounts: $1.00 over after all. Only the difference posts.
  PERFORM pg_temp.act(pg_temp.u('o1'));
  r := public.exos_pos_recount_drawer(v_dr, v_exp + 100, 'found the roll of quarters');
  ASSERT pg_temp.n(v_dr::text || ':variance', 'drawer_variance_adjust') = 1 AND pg_temp.n(v_dr::text || ':close', 'drawer_close_adjust') = 1,
         'JC4 the recount posts adjustments';
  ASSERT pg_temp.bal('cash_over_short', v_dr::text || ':variance') = -100 AND pg_temp.bal('cash_on_hand', v_dr::text || ':close') = v_exp + 100,
         'JC4 now over by 100, all counted cash out';
  ASSERT pg_temp.bal('pos_cash_drawer') = 0, 'JC4 still zero after the recount';
  ASSERT pg_temp.n(v_dr::text, NULL) = 1 AND pg_temp.n(v_dr::text || ':variance') = 2 AND pg_temp.n(v_dr::text || ':close') = 2,
         'JC4 entry counts (float 1, variance 2, close 2)';
  -- Org B: a drawer with a float, closed exact.
  PERFORM pg_temp.act(pg_temp.u('o2'));
  INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('drb'), pg_temp.u('e9'), 1000);
  PERFORM public.exos_pos_close_drawer(pg_temp.u('drb'), 1000, NULL, NULL);
  ASSERT pg_temp.n(pg_temp.u('drb')::text || ':variance') = 0 AND pg_temp.bal('pos_cash_drawer', NULL, '2') = 0
     AND pg_temp.bal('cash_on_hand', NULL, '2') = 0, 'JC4 an exact close: no variance, nets to zero';
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.commit_point();
  RAISE NOTICE 'OK  JC4 drawer: float, sale, paid-out, cash gift card = expected; close short to over / short; counted out; recount difference; zero';
END $$;

-- JC5 ------------------------------------------------------------------------
-- A refund row on org A's card that names an order of org B (never written
-- by Exos; a forged or broken row) posts nothing into either org's books.
DO $$
DECLARE v_l bigint; v_card uuid := pg_temp.v('gc_cash')::uuid;
BEGIN
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, processor, fulfilled_at)
  VALUES ('cs_jc_b1', pg_temp.u('e9'), pg_temp.u('t9'), pg_temp.u('2'), pg_temp.u('b1'), 'jc-b1@x.com', 1, 1000, 'usd', 'fulfilled',
          0, 70, 30, 40, 2000, 'stripe', now());
  INSERT INTO public.exos_gift_card_ledger (card_id, org_id, kind, amount_cents, balance_after, session_id, key)
  VALUES (v_card, pg_temp.u('1'), 'refund', 100, 100, 'cs_jc_b1', 'cs_jc_b1:forged') RETURNING id INTO v_l;
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.n(v_l::text) = 0 AND public.exos_journal_post_gift_card(v_l) IS NULL, 'JC5 a cross-org refund row posts nothing';
  ASSERT pg_temp.bal('gift_cards_outstanding', 'cs_jc_b1', '2') = 2000, 'JC5 org B''s own order is its own (its sale only)';
  RAISE NOTICE 'OK  JC5a a gift card row naming another org''s order posts nothing';
END $$;
SET ROLE authenticated;
DO $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('f1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('1')
            AND source_table IN ('exos_gift_card_ledger', 'exos_pos_drawer_sessions', 'exos_org_instant_payouts',
                                 'exos_paypal_org_remittances', 'exos_pos_reversals', 'exos_gift_card_redemptions')) > 10,
         'JC5 finance reads the new entries';
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('2')) = 0, 'JC5 finance A sees nothing of B';
  ASSERT (SELECT sum(debit_cents) = sum(credit_cents) FROM public.exos_journal_trial_balance(pg_temp.u('1'))), 'JC5 A balances';
  PERFORM pg_temp.act(pg_temp.u('o2'));
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('2')) > 0, 'JC5 owner B reads B';
  ASSERT (SELECT count(*) FROM public.exos_journal_rows WHERE org_id = pg_temp.u('1')) = 0, 'JC5 owner B sees nothing of A';
  ASSERT pg_temp.st(format('SELECT * FROM public.exos_journal_trial_balance(%L)', pg_temp.u('1'))) = '42501', 'JC5 B can''t read A''s balance';
  ASSERT (SELECT sum(debit_cents) = sum(credit_cents) FROM public.exos_journal_trial_balance(pg_temp.u('2'))), 'JC5 B balances';
  PERFORM pg_temp.act(pg_temp.u('s1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE org_id = pg_temp.u('1')) = 0, 'JC5 a scanner reads no entries';
  -- Clients can't post.
  PERFORM pg_temp.act(pg_temp.u('o1'));
  FOREACH v IN ARRAY ARRAY[format('SELECT public.exos_journal_post_drawer(%L)', pg_temp.u('dr')),
                           format('SELECT public.exos_journal_post_gift_card(%s)', 1),
                           format('SELECT public.exos_journal_post_gift_card_redemption(%L)', 'res_jc_1'),
                           format('SELECT public.exos_journal_post_instant_payout(%L)', pg_temp.u('ip')),
                           format('SELECT public.exos_journal_post_paypal_remittance(%L)', pg_temp.u('ip')),
                           format('SELECT public.exos_journal_post_pos_reversal(%L)', pg_temp.u('ip'))] LOOP
    ASSERT pg_temp.st(v) = '42501', 'JC5 a client can''t run: ' || v;
  END LOOP;
  PERFORM pg_temp.act(NULL);
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st(format('SELECT public.exos_journal_post_drawer(%L)', md5('jc01:dr')::uuid)) = '42501', 'JC5 anon can''t post';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  JC5 RLS on the new entries (finance / owner of the org only, nothing across orgs), clients and anon can''t post'; END $$;

-- JC6 ------------------------------------------------------------------------
DO $$
DECLARE j jsonb; bad text;
BEGIN
  PERFORM pg_temp.commit_point();
  j := public._exos_journal_backfill(pg_temp.u('1'));
  ASSERT (j ->> 'posted')::int = 0, 'JC6 backfill A no-op: ' || j::text;
  j := public._exos_journal_backfill(pg_temp.u('2'));
  ASSERT (j ->> 'posted')::int = 0, 'JC6 backfill B no-op: ' || j::text;
  -- The whole harness database: every entry balances, and so does every org's
  -- trial balance per currency (this file's entries and anything committed).
  SELECT string_agg(e.id::text, ', ') INTO bad FROM (
    SELECT e.id FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
     GROUP BY e.id HAVING sum(l.debit_cents) <> sum(l.credit_cents) OR sum(l.debit_cents) <> max(e.total_cents)) e;
  ASSERT bad IS NULL, 'JC6 unbalanced entries: ' || bad;
  SELECT string_agg(x.org_id || '/' || x.currency, ', ') INTO bad FROM (
    SELECT e.org_id::text AS org_id, e.currency FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
     GROUP BY e.org_id, e.currency HAVING sum(l.debit_cents) <> sum(l.credit_cents)) x;
  ASSERT bad IS NULL, 'JC6 trial balance off for: ' || bad;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_journal_lines l WHERE NOT public._exos_journal_account_ok(l.account)), 'JC6 every account in the chart';
  RAISE NOTICE 'OK  JC6 every entry and every org''s trial balance (whole database) balances; backfill no-op';
END $$;

ROLLBACK;
