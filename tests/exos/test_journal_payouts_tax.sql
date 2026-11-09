-- ============================================================================
-- The journal's last gaps (mig 20261111130000). Self-contained (BEGIN /
-- ROLLBACK; ids md5('jp01:…')).
--   JP0 shape: the payouts table (RLS, no client writes), the new functions
--       service-role only with search_path pinned, the triggers, the source
--       check, both marker patches in place
--   JP1 Stripe's payouts: recorded per org only with the org's own connected
--       account; in transit posts nothing, paid posts Dr bank / Cr Stripe
--       clearing once (a replay, a stale earlier status and a second call
--       change nothing), a failure after paid reverses it, a final status
--       never moves; a negative payout debits the bank; another org can't
--       claim a payout id; an instant payout Exos sent posts once (from
--       either side, in either order); bad rows are skipped; audit rows;
--       owner / finance read, manager and the other org don't; the backfill
--       is a no-op
--   JP2 the Exos fee owed on a gift card part: each refund back on the card
--       hands back its share (cumulative, so 700 + 700 + 600 of 2000 hand
--       back exactly the 61 owed), idempotent; an order with nothing owed
--       posts nothing; a card that paid in full gets it all back on the full
--       refund; the backfill posts it for a refund row it missed
--   JP3 the sales tax report = the journal: a refund to a gift card, a card
--       refund with no credit note, one that failed later, a door sale
--       refunded; per org, currency, event and period the report's net is
--       the journal's sales tax payable; the rates still split; readers
--   JP4 every entry balances; the whole database's trial balance is zero
-- Users: o1 owner A, m1 manager A, f1 finance A, s1 scanner A (staff of e1),
--        o2 owner B, b1 buyer.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5('jp01:' || p)::uuid $$;
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
CREATE FUNCTION pg_temp.bal(p_account text, p_source text DEFAULT NULL, p_org text DEFAULT '1')
RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0)::bigint
    FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
   WHERE l.account = p_account AND e.org_id = pg_temp.u(p_org) AND (p_source IS NULL OR e.source_id = p_source)
$$;
CREATE FUNCTION pg_temp.n(p_source text, p_kind text DEFAULT NULL) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_journal_entries
   WHERE source_id = p_source AND (p_kind IS NULL OR kind = p_kind OR kind LIKE p_kind || ':%')
$$;
-- The order's entries of one kind on its gift card's refund rows: the sum of an account.
CREATE FUNCTION pg_temp.gcfee(p_session text) RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(l.debit_cents - l.credit_cents), 0)::bigint
    FROM public.exos_journal_lines l JOIN public.exos_journal_entries e ON e.id = l.entry_id
   WHERE e.session_id = p_session AND e.kind = 'gc_refund_fee' AND l.account = 'organizer_payable'
$$;
CREATE FUNCTION pg_temp.commit_point() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS exos_gift_card_ledger_journal IMMEDIATE;
  SET CONSTRAINTS exos_gift_card_ledger_journal DEFERRED;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced IMMEDIATE;
  SET CONSTRAINTS exos_journal_entries_balanced, exos_journal_lines_balanced DEFERRED;
END $$;
-- The tax report's net vs the journal's sales tax payable (credit − debit), per currency.
CREATE FUNCTION pg_temp.tax_gap(p_org uuid, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_event uuid DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  WITH rep AS (
    SELECT x ->> 'currency' AS cur, sum((x ->> 'net_tax_cents')::bigint) AS net
      FROM jsonb_array_elements(public.exos_sales_tax_report(p_org, p_from, p_to, p_event) -> 'rows') x GROUP BY 1
  ), jr AS (
    SELECT currency AS cur, -sum(balance_cents) AS net FROM public.exos_journal_trial_balance(p_org, p_from, p_to, p_event)
     WHERE account = 'sales_tax_payable' GROUP BY 1
  )
  SELECT string_agg(format('%s report %s journal %s', coalesce(rep.cur, jr.cur), rep.net, jr.net), '; ')
    FROM rep FULL JOIN jr ON jr.cur = rep.cur
   WHERE rep.net IS DISTINCT FROM jr.net AND NOT (coalesce(rep.net, 0) = 0 AND coalesce(jr.net, 0) = 0)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.tax_gap(uuid, timestamptz, timestamptz, uuid) TO authenticated;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('o1'), 'jp-o1@x.com', now()), (pg_temp.u('m1'), 'jp-m1@x.com', now()),
  (pg_temp.u('f1'), 'jp-f1@x.com', now()), (pg_temp.u('s1'), 'jp-s1@x.com', now()),
  (pg_temp.u('o2'), 'jp-o2@x.com', now()), (pg_temp.u('b1'), 'jp-b1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'JP Hall', 'jp-hall', pg_temp.u('o1')),
  (pg_temp.u('2'), 'JP Other', 'jp-other', pg_temp.u('o2'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('o1'), 'owner'), (pg_temp.u('1'), pg_temp.u('m1'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('f1'), 'finance'), (pg_temp.u('1'), pg_temp.u('s1'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('o2'), 'owner');
UPDATE public.exos_org_billing SET fee_free_until = now() - interval '1 day' WHERE org_id IN (pg_temp.u('1'), pg_temp.u('2'));
-- The harness has no phase-1 exos_org_secrets: its prod shape, rolled back.
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_org_secrets (org_id, payments) VALUES
  (pg_temp.u('1'), '{"connectedAccountId":"acct_jpOrgA","chargesEnabled":true}'),
  (pg_temp.u('2'), '{"connectedAccountId":"acct_jpOrgB","chargesEnabled":true}')
ON CONFLICT (org_id) DO UPDATE SET payments = EXCLUDED.payments;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, doors_at, total_tickets, tickets_sold, currency, created_by, venue_address) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'JP Night', 'jp-night', 'published', now() + interval '2 hours', now() - interval '1 hour', 500, 0, 'usd',
   pg_temp.u('o1'), '{"city":"Brooklyn","region":"NY","postal":"11211","country":"US"}'),
  (pg_temp.u('e2'), pg_temp.u('1'), 'JP Jersey', 'jp-jersey', 'published', now() + interval '3 days', NULL, 500, 0, 'usd',
   pg_temp.u('o1'), '{"city":"Hoboken","region":"NJ","country":"US"}'),
  (pg_temp.u('e9'), pg_temp.u('2'), 'JP Elsewhere', 'jp-else', 'published', now() + interval '2 hours', NULL, 500, 0, 'usd',
   pg_temp.u('o2'), '{"city":"Austin","region":"TX","country":"US"}');
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES (pg_temp.u('e1'), pg_temp.u('s1'), pg_temp.u('1'));
INSERT INTO public.exos_tax_rules (id, event_id, name, rate_percent, price_includes_tax) VALUES
  (pg_temp.u('x1'), pg_temp.u('e1'), 'NY sales tax', 8.875, false),
  (pg_temp.u('x3'), pg_temp.u('e1'), 'NY reduced', 4, false),
  (pg_temp.u('x2'), pg_temp.u('e2'), 'NJ sales tax', 6.625, false);
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, tax_rate_id) VALUES
  (pg_temp.u('t1'), pg_temp.u('e1'), 'GA', 40, 200, 0, pg_temp.u('x1')),
  (pg_temp.u('t3'), pg_temp.u('e1'), 'Kids', 20, 200, 0, pg_temp.u('x3')),
  (pg_temp.u('t2'), pg_temp.u('e2'), 'GA', 20, 200, 0, pg_temp.u('x2')),
  (pg_temp.u('t9'), pg_temp.u('e9'), 'GA', 30, 200, 0, NULL);

-- JP0 ------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_stripe_org_payouts'::regclass), 'JP0 RLS on the payouts';
  ASSERT NOT has_table_privilege('anon', 'public.exos_stripe_org_payouts', 'SELECT'), 'JP0 anon reads payouts';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_stripe_org_payouts', 'INSERT,UPDATE,DELETE'), 'JP0 clients write payouts';
  FOREACH f IN ARRAY ARRAY['public.exos_stripe_org_payouts_record(uuid,text,jsonb)', 'public.exos_journal_post_stripe_org_payout(text)',
                           'public._exos_journal_gc_refund_fee(bigint)', 'public._exos_tg_journal_stripe_payout()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'JP0 anon runs ' || f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'JP0 authenticated runs ' || f;
    ASSERT (SELECT bool_or(c LIKE 'search_path=%') FROM pg_proc p, unnest(p.proconfig) c WHERE p.oid = f::regprocedure),
           'JP0 search_path pinned on ' || f;
  END LOOP;
  ASSERT has_function_privilege('authenticated', 'public.exos_sales_tax_report(uuid,timestamptz,timestamptz,uuid)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.exos_sales_tax_report(uuid,timestamptz,timestamptz,uuid)', 'EXECUTE'),
         'JP0 the tax report: authenticated (checked inside), never anon';
  ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'exos_stripe_org_payouts_journal'), 'JP0 payouts trigger';
  ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'exos_org_instant_payouts_journal_stripe'), 'JP0 instant payouts trigger';
  ASSERT position('exos_stripe_org_payouts' IN (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                                                 WHERE conname = 'exos_journal_entries_source_table_check')) > 0, 'JP0 source check';
  ASSERT position('/* exos: gc refund fee */' IN pg_get_functiondef('public.exos_journal_post_gift_card(bigint)'::regprocedure)) > 0,
         'JP0 gift card patch';
  ASSERT position('/* exos: journal stripe payouts */' IN pg_get_functiondef('public._exos_journal_backfill(uuid)'::regprocedure)) > 0,
         'JP0 backfill patch';
  ASSERT position('/* exos: journal complete */' IN pg_get_functiondef('public._exos_tg_journal()'::regprocedure)) > 0,
         'JP0 earlier markers intact';
  RAISE NOTICE 'OK  JP0 shape: payouts table (RLS, no client writes), writers service-role only + search_path, triggers, source check, markers';
END $$;

-- JP1 ------------------------------------------------------------------------
DO $$
DECLARE r jsonb; n int; v_cnt int; v text;
  po jsonb := '{"id":"po_jpA1","amount":12000,"currency":"usd","status":"in_transit","method":"standard","automatic":true}';
BEGIN
  po := po || jsonb_build_object('created', now() - interval '3 days', 'arrival_date', now() - interval '1 day');
  -- In transit: recorded, nothing posted.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(po));
  ASSERT (r ->> 'new')::int = 1, 'JP1 recorded: ' || r::text;
  ASSERT (SELECT status FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpA1') = 'in_transit', 'JP1 in transit';
  ASSERT pg_temp.n('po_jpA1') = 0, 'JP1 in transit posts nothing';
  -- Paid: Dr bank, Cr Stripe clearing, dated by the arrival.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(po || '{"status":"paid"}'));
  ASSERT (r ->> 'changed')::int = 1, 'JP1 paid: ' || r::text;
  ASSERT pg_temp.n('po_jpA1', 'stripe_payout') = 1 AND pg_temp.bal('bank', 'po_jpA1') = 12000
     AND pg_temp.bal('stripe_clearing', 'po_jpA1') = -12000, 'JP1 paid posts Dr bank / Cr clearing';
  ASSERT (SELECT occurred_at::date FROM public.exos_journal_entries WHERE source_id = 'po_jpA1') = (now() - interval '1 day')::date,
         'JP1 dated by the arrival';
  ASSERT (SELECT source_table FROM public.exos_journal_entries WHERE source_id = 'po_jpA1') = 'exos_stripe_org_payouts', 'JP1 source';
  -- A replay, a stale earlier status, a direct second post: nothing.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(po || '{"status":"paid"}'));
  ASSERT (r ->> 'changed')::int = 0 AND (r ->> 'new')::int = 0, 'JP1 replay changes nothing: ' || r::text;
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(po));
  ASSERT (SELECT status FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpA1') = 'paid', 'JP1 a stale status never moves it back';
  ASSERT public.exos_journal_post_stripe_org_payout('po_jpA1') IS NULL AND pg_temp.n('po_jpA1') = 1, 'JP1 posting twice is one entry';
  -- Failed after paid: reversed; then final.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA',
         jsonb_build_array(po || '{"status":"failed","failure_code":"account_closed"}'));
  ASSERT pg_temp.n('po_jpA1', 'stripe_payout_reversal') = 1 AND pg_temp.bal('bank', 'po_jpA1') = 0
     AND pg_temp.bal('stripe_clearing', 'po_jpA1') = 0, 'JP1 a failure after paid reverses it';
  ASSERT (SELECT reverses FROM public.exos_journal_entries WHERE source_id = 'po_jpA1' AND kind = 'stripe_payout_reversal')
         = (SELECT id FROM public.exos_journal_entries WHERE source_id = 'po_jpA1' AND kind = 'stripe_payout'), 'JP1 names what it reverses';
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(po || '{"status":"paid"}'));
  ASSERT (SELECT status FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpA1') = 'failed' AND pg_temp.n('po_jpA1') = 2,
         'JP1 failed is final';
  ASSERT (SELECT failure_code FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpA1') = 'account_closed', 'JP1 failure code';
  -- Audit: paid and failed, by the service.
  SELECT count(*) INTO n FROM public.exos_org_audit
   WHERE org_id = pg_temp.u('1') AND action = 'payout.stripe_status' AND entity_id = 'po_jpA1' AND actor_kind = 'service';
  ASSERT n = 2, 'JP1 audit rows for paid and failed: ' || n;

  -- A negative payout (Stripe debits the bank) and bad rows in the same call.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(
         jsonb_build_object('id', 'po_jpNeg', 'amount', -2500, 'currency', 'usd', 'status', 'paid', 'created', now()),
         jsonb_build_object('id', 'tr_notapayout', 'amount', 100, 'currency', 'usd', 'status', 'paid', 'created', now()),
         jsonb_build_object('id', 'po_jpBad1', 'amount', '100', 'currency', 'usd', 'status', 'paid', 'created', now()),
         jsonb_build_object('id', 'po_jpBad2', 'amount', 100, 'currency', 'usd', 'status', 'reversed', 'created', now()),
         jsonb_build_object('id', 'po_jpBad3', 'amount', 100, 'currency', 'usd', 'status', 'paid', 'created', 'not a date')));
  ASSERT (r ->> 'new')::int = 1 AND (r ->> 'skipped')::int = 4, 'JP1 bad rows skipped: ' || r::text;
  ASSERT pg_temp.bal('bank', 'po_jpNeg') = -2500 AND pg_temp.bal('stripe_clearing', 'po_jpNeg') = 2500, 'JP1 a negative payout debits the bank';

  -- Only the org's own connected account; never another org's payout.
  ASSERT pg_temp.st(format($q$SELECT public.exos_stripe_org_payouts_record(%L, 'acct_jpOrgB', '[]')$q$, pg_temp.u('1'))) = '42501',
         'JP1 another org''s account refused';
  ASSERT pg_temp.st(format($q$SELECT public.exos_stripe_org_payouts_record(%L, 'acct_jpOrgA', '[]')$q$, pg_temp.u('9'))) = '42501',
         'JP1 an org with no account refused';
  ASSERT pg_temp.st(format($q$SELECT public.exos_stripe_org_payouts_record(%L, 'acct_jpOrgA', '{}')$q$, pg_temp.u('1'))) = '22023',
         'JP1 not a list refused';
  r := public.exos_stripe_org_payouts_record(pg_temp.u('2'), 'acct_jpOrgB', jsonb_build_array(
         jsonb_build_object('id', 'po_jpNeg', 'amount', 999, 'currency', 'usd', 'status', 'failed', 'created', now())));
  ASSERT (r ->> 'skipped')::int = 1, 'JP1 org B can''t touch org A''s payout: ' || r::text;
  ASSERT (SELECT org_id FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpNeg') = pg_temp.u('1')
     AND (SELECT status FROM public.exos_stripe_org_payouts WHERE payout_id = 'po_jpNeg') = 'paid'
     AND pg_temp.bal('bank', 'po_jpNeg') = -2500 AND pg_temp.bal('bank', NULL, '2') = 0, 'JP1 the row and the books unchanged';

  -- An instant payout Exos sent: posted from exos_org_instant_payouts only.
  INSERT INTO public.exos_org_instant_payouts (id, org_id, currency, amount_cents, fee_estimate_cents, idempotency_key, requested_by)
  VALUES (pg_temp.u('ip1'), pg_temp.u('1'), 'usd', 3000, 45, 'jp-instant-0001', pg_temp.u('o1'));
  UPDATE public.exos_org_instant_payouts SET status = 'sent', stripe_payout_id = 'po_jpInst1' WHERE id = pg_temp.u('ip1');
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(
         jsonb_build_object('id', 'po_jpInst1', 'amount', 3000, 'currency', 'usd', 'status', 'paid', 'method', 'instant', 'created', now())));
  ASSERT pg_temp.n('po_jpInst1') = 0 AND pg_temp.bal('bank', pg_temp.u('ip1')::text) = 3000, 'JP1 an instant payout Exos sent posts once';
  -- ... and the other order: Stripe's row first, then the instant payout learns its id.
  r := public.exos_stripe_org_payouts_record(pg_temp.u('1'), 'acct_jpOrgA', jsonb_build_array(
         jsonb_build_object('id', 'po_jpInst2', 'amount', 1800, 'currency', 'usd', 'status', 'paid', 'method', 'instant', 'created', now())));
  ASSERT pg_temp.bal('bank', 'po_jpInst2') = 1800, 'JP1 an instant payout Exos doesn''t know yet posts from Stripe''s row';
  INSERT INTO public.exos_org_instant_payouts (id, org_id, currency, amount_cents, fee_estimate_cents, idempotency_key, requested_by)
  VALUES (pg_temp.u('ip2'), pg_temp.u('1'), 'usd', 1800, 45, 'jp-instant-0002', pg_temp.u('o1'));
  UPDATE public.exos_org_instant_payouts SET status = 'sent', stripe_payout_id = 'po_jpInst2' WHERE id = pg_temp.u('ip2');
  ASSERT pg_temp.bal('bank', 'po_jpInst2') = 0 AND pg_temp.n('po_jpInst2', 'stripe_payout_reversal') = 1
     AND pg_temp.bal('bank', pg_temp.u('ip2')::text) = 1800, 'JP1 once Exos knows it, Stripe''s posting is taken back: one 1800 in the bank';

  -- Readers: owner and finance of A; not the manager, the scanner, org B or anon.
  PERFORM pg_temp.act(pg_temp.u('f1'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_stripe_org_payouts;
  RESET ROLE;
  SELECT count(*) INTO v_cnt FROM public.exos_stripe_org_payouts WHERE org_id = pg_temp.u('1');
  ASSERT n = v_cnt AND n >= 4, format('JP1 finance reads the org''s payouts (%s of %s)', n, v_cnt);
  PERFORM pg_temp.act(pg_temp.u('o1'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_stripe_org_payouts;
  RESET ROLE;
  ASSERT n = v_cnt, 'JP1 owner reads them';
  FOREACH v IN ARRAY ARRAY['m1', 's1', 'o2', 'b1'] LOOP
    PERFORM pg_temp.act(pg_temp.u(v));
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.exos_stripe_org_payouts WHERE org_id = pg_temp.u('1');
    RESET ROLE;
    ASSERT n = 0, 'JP1 ' || v || ' reads org A''s payouts: ' || n;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  SET LOCAL ROLE anon;
  ASSERT pg_temp.st('SELECT count(*) FROM public.exos_stripe_org_payouts') = '42501', 'JP1 anon has no grant';
  ASSERT pg_temp.st($q$SELECT public.exos_stripe_org_payouts_record(md5('jp01:1')::uuid, 'acct_jpOrgA', '[]')$q$) = '42501', 'JP1 anon can''t record';
  RESET ROLE;
  PERFORM pg_temp.act(pg_temp.u('o1'));
  SET LOCAL ROLE authenticated;
  ASSERT pg_temp.st($q$SELECT public.exos_stripe_org_payouts_record(md5('jp01:1')::uuid, 'acct_jpOrgA', '[]')$q$) = '42501',
         'JP1 the owner can''t record';
  ASSERT pg_temp.st($q$SELECT public.exos_journal_post_stripe_org_payout('po_jpA1')$q$) = '42501', 'JP1 a client can''t post';
  RESET ROLE;
  -- The backfill posts nothing more.
  SELECT count(*) INTO n FROM public.exos_journal_entries WHERE org_id = pg_temp.u('1');
  PERFORM public._exos_journal_backfill(pg_temp.u('1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE org_id = pg_temp.u('1')) = n, 'JP1 the backfill is a no-op';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  JP1 payouts: recorded per org with its own account; paid posts once, failure reverses, final stays; negative; another org refused; instant once either way; audit; readers';
END $$;

-- JP2 ------------------------------------------------------------------------
-- A box-office card (cash, never paid the Exos fee) spent on orders.
DO $$
DECLARE r jsonb; v_card uuid; v_code text; v_l bigint; v_ids bigint[]; n int; v_red int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('m1'));
  r := public.exos_gift_card_issue(p_org_id => pg_temp.u('1'), p_amount_cents => 10000, p_payment_method => 'cash');
  v_card := (r ->> 'card_id')::uuid; v_code := r ->> 'code';
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.commit_point();
  -- a. $30.00 by card + $20.00 by the gift card, $4.00 tax, $0.61 Exos fee owed on the card part.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, exos_fee_owed_cents, processor)
  VALUES ('cs_jp_g1', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 1, 3000, 'usd', 'pending',
          400, 210, 90, 120, 2000, 61, 'stripe');
  PERFORM public.exos_gift_card_hold(v_code, 'cs_jp_g1', 2000, 'jp-test', pg_temp.u('1'), 'usd');
  ASSERT public._exos_gift_card_capture('cs_jp_g1', 2000), 'JP2 captured';
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() - interval '2 days' WHERE session_id = 'cs_jp_g1';
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.bal('organizer_payable', 'cs_jp_g1') = -61, 'JP2 the sale records the owed fee';
  -- $7.00, $7.00, $6.00 back on the card: 61 × 700/2000 = 21.35 → 21; 1400 → 42.7 → 43 (22); 2000 → 61 (18).
  PERFORM public.exos_gift_card_refund_order('cs_jp_g1', 700, 'k1', 'partial');
  PERFORM public.exos_gift_card_refund_order('cs_jp_g1', 700, 'k2', 'partial');
  PERFORM public.exos_gift_card_refund_order('cs_jp_g1', 600, 'k3', 'partial');
  PERFORM pg_temp.commit_point();
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM public.exos_gift_card_ledger WHERE session_id = 'cs_jp_g1' AND kind = 'refund';
  ASSERT cardinality(v_ids) = 3, 'JP2 three refund rows';
  ASSERT pg_temp.bal('organizer_payable', v_ids[1]::text) = 21 AND pg_temp.bal('organizer_payable', v_ids[2]::text) = 22
     AND pg_temp.bal('organizer_payable', v_ids[3]::text) = 18,
         format('JP2 each part''s share: %s %s %s', pg_temp.bal('organizer_payable', v_ids[1]::text),
                pg_temp.bal('organizer_payable', v_ids[2]::text), pg_temp.bal('organizer_payable', v_ids[3]::text));
  ASSERT pg_temp.bal('exos_fee', v_ids[1]::text) = -21, 'JP2 the Exos fee comes back';
  ASSERT pg_temp.gcfee('cs_jp_g1') = 61 AND pg_temp.bal('organizer_payable', 'cs_jp_g1') + pg_temp.gcfee('cs_jp_g1') = 0,
         'JP2 the whole owed fee handed back, the payable nets to zero';
  ASSERT (SELECT bool_and(kind = 'gc_refund_fee' AND session_id = 'cs_jp_g1' AND event_id = pg_temp.u('e1'))
            FROM public.exos_journal_entries WHERE source_id = v_ids[2]::text AND kind LIKE 'gc_refund_fee%'), 'JP2 tied to the order';
  -- The tax shares are unchanged (400 × 700 / 5000 = 56, 56, 48).
  ASSERT pg_temp.bal('sales_tax_payable', v_ids[1]::text) = 56 AND pg_temp.bal('sales_tax_payable', v_ids[3]::text) = 48, 'JP2 tax shares';
  -- Idempotent: posting again changes nothing.
  SELECT count(*) INTO n FROM public.exos_journal_entries WHERE session_id = 'cs_jp_g1';
  ASSERT public._exos_journal_gc_refund_fee(v_ids[2]) IS NULL AND public.exos_journal_post_gift_card(v_ids[2]) IS NULL, 'JP2 again: no-op';
  PERFORM public._exos_journal_backfill(pg_temp.u('1'));
  ASSERT (SELECT count(*) FROM public.exos_journal_entries WHERE session_id = 'cs_jp_g1') = n, 'JP2 still the same entries';

  -- b. Nothing owed (a card bought online): nothing to hand back.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, exos_fee_owed_cents, processor)
  VALUES ('cs_jp_g2', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 1, 3000, 'usd', 'pending',
          0, 210, 90, 120, 1000, 0, 'stripe');
  PERFORM public.exos_gift_card_hold(v_code, 'cs_jp_g2', 1000, 'jp-test', pg_temp.u('1'), 'usd');
  PERFORM public._exos_gift_card_capture('cs_jp_g2', 1000);
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_jp_g2';
  PERFORM public.exos_gift_card_refund_order('cs_jp_g2', 500, 'k1', 'partial');
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.n((SELECT max(id) FROM public.exos_gift_card_ledger WHERE session_id = 'cs_jp_g2' AND kind = 'refund')::text, 'gc_refund') = 1
     AND pg_temp.gcfee('cs_jp_g2') = 0, 'JP2 nothing owed: nothing handed back';

  -- c. Paid in full by the card (no Stripe charge): the whole fee owed, all of it back on a full refund.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, exos_fee_owed_cents, processor)
  VALUES ('cs_jp_g3', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 1, 0, 'usd', 'pending',
          0, 0, 0, 0, 2500, 125, 'stripe');
  PERFORM public.exos_gift_card_hold(v_code, 'cs_jp_g3', 2500, 'jp-test', pg_temp.u('1'), 'usd');
  PERFORM public._exos_gift_card_capture('cs_jp_g3', 2500);
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_jp_g3';
  PERFORM public.exos_gift_card_refund_order('cs_jp_g3', 1000, 'k1', 'partial');
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.gcfee('cs_jp_g3') = 50, 'JP2 1000 of 2500 back: 50 of the 125 owed: ' || pg_temp.gcfee('cs_jp_g3');
  UPDATE public.exos_checkout_sessions SET status = 'refunded' WHERE session_id = 'cs_jp_g3';
  PERFORM pg_temp.commit_point();
  ASSERT pg_temp.gcfee('cs_jp_g3') = 125 AND pg_temp.bal('organizer_payable', 'cs_jp_g3') = -125,
         'JP2 the full refund hands back the rest: ' || pg_temp.gcfee('cs_jp_g3');

  -- d. A refund row the triggers never saw (written with them off): the backfill posts it, fee included.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, gift_card_cents, exos_fee_owed_cents, processor)
  VALUES ('cs_jp_g4', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 1, 1000, 'usd', 'pending',
          0, 100, 40, 60, 1000, 40, 'stripe');
  PERFORM public.exos_gift_card_hold(v_code, 'cs_jp_g4', 1000, 'jp-test', pg_temp.u('1'), 'usd');
  PERFORM public._exos_gift_card_capture('cs_jp_g4', 1000);
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() WHERE session_id = 'cs_jp_g4';
  PERFORM pg_temp.commit_point();
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO public.exos_gift_card_ledger (card_id, org_id, kind, amount_cents, balance_after, session_id, key)
  VALUES (v_card, pg_temp.u('1'), 'refund', 250, 0, 'cs_jp_g4', 'cs_jp_g4:missed') RETURNING id INTO v_l;
  PERFORM set_config('session_replication_role', 'origin', true);
  ASSERT pg_temp.n(v_l::text) = 0, 'JP2 the missed row has no entry';
  PERFORM public._exos_journal_backfill(pg_temp.u('1'));
  ASSERT pg_temp.n(v_l::text, 'gc_refund') = 1 AND pg_temp.n(v_l::text, 'gc_refund_fee') = 1 AND pg_temp.gcfee('cs_jp_g4') = 10,
         'JP2 the backfill posts the refund and its fee share (40 × 250/1000 = 10)';
  PERFORM pg_temp.commit_point();
  RAISE NOTICE 'OK  JP2 the Exos fee owed on a gift card part: handed back in proportion (21 + 22 + 18 = 61), idempotent, none owed none back, a full refund gets it all, the backfill catches up';
END $$;

-- JP3 ------------------------------------------------------------------------
SELECT pg_temp.act(pg_temp.u('s1'));
INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES (pg_temp.u('dr'), pg_temp.u('e1'), 5000);
DO $$
DECLARE r jsonb; j jsonb; ga jsonb; kids jsonb; unrec jsonb; pos jsonb; v_rf uuid := pg_temp.u('rf1'); v_rf2 uuid := pg_temp.u('rf2');
        v_order uuid; v_mid timestamptz; v text; v_gap text;
BEGIN
  PERFORM pg_temp.act(NULL);
  -- An order 40 days ago: 2 × GA ($7.10 tax at 8.875%) + 1 × Kids ($0.80 at 4%), $107.90 by card.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, processor, created_at, fulfilled_at)
  VALUES ('cs_jp_t1', pg_temp.u('e1'), pg_temp.u('t1'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 3, 10790, 'usd', 'pending',
          790, 600, 300, 300, 'stripe', now() - interval '41 days', NULL);
  INSERT INTO public.exos_price_disclosures (session_id, event_id, org_id, currency, total_shown_cents)
  VALUES ('cs_jp_t1', pg_temp.u('e1'), pg_temp.u('1'), 'usd', 10790);
  INSERT INTO public.exos_price_disclosure_lines (session_id, line_no, kind, item_id, item_name, quantity, face_unit_cents, tax_cents,
              tax_included, fee_cents, unit_all_in_cents, line_total_cents) VALUES
    ('cs_jp_t1', 1, 'ticket', pg_temp.u('t1'), 'GA', 2, 4000, 710, false, 0, 4355, 8710),
    ('cs_jp_t1', 2, 'ticket', pg_temp.u('t3'), 'Kids', 1, 2000, 80, false, 0, 2080, 2080);
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() - interval '40 days' WHERE session_id = 'cs_jp_t1';
  -- A card refund with no credit note yesterday (tax pro rata: 790 × 3000 / 10790 = 220), and one that failed later.
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, is_partial, created_at)
  VALUES (v_rf, 'cs_jp_t1', pg_temp.u('1'), 'stripe', 're_jp_1', 3000, 'usd', 'succeeded', true, now() - interval '1 day');
  INSERT INTO public.exos_order_refunds (id, session_id, org_id, provider, refund_id, amount_cents, currency, status, is_partial, created_at)
  VALUES (v_rf2, 'cs_jp_t1', pg_temp.u('1'), 'stripe', 're_jp_2', 1000, 'usd', 'succeeded', true, now() - interval '1 day');
  UPDATE public.exos_order_refunds SET status = 'failed' WHERE id = v_rf2;
  ASSERT pg_temp.bal('sales_tax_payable', v_rf::text) = 220 AND pg_temp.bal('sales_tax_payable', v_rf2::text) = 0, 'JP3 journal refunds';
  -- NJ: an order with tax its lines don't explain. Org B: a taxed order of its own.
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, currency,
              status, tax_cents, application_fee_cents, exos_fee_cents, card_fee_est_cents, processor, fulfilled_at) VALUES
    ('cs_jp_t2', pg_temp.u('e2'), pg_temp.u('t2'), pg_temp.u('1'), pg_temp.u('b1'), 'jp-b1@x.com', 2, 4265, 'usd', 'pending', 265, 280, 120, 160, 'stripe', NULL),
    ('cs_jp_t9', pg_temp.u('e9'), pg_temp.u('t9'), pg_temp.u('2'), pg_temp.u('b1'), 'jp-b1@x.com', 1, 3250, 'usd', 'pending', 250, 210, 90, 120, 'stripe', NULL);
  UPDATE public.exos_checkout_sessions SET status = 'fulfilled', fulfilled_at = now() - interval '3 hours' WHERE session_id IN ('cs_jp_t2', 'cs_jp_t9');
  -- The door: 3 × GA cash, then refunded.
  PERFORM pg_temp.act(pg_temp.u('s1'));
  r := public.exos_pos_walkup_sell(pg_temp.u('e1'), pg_temp.u('t1'), 3, pg_temp.u('k-pos'), 0, 'cash', NULL, pg_temp.u('dr'), 'Walk Up', NULL, NULL, NULL);
  v_order := (r ->> 'id')::uuid;
  PERFORM pg_temp.act(pg_temp.u('o1'));
  PERFORM public.exos_pos_refund_order(v_order, 'changed their mind', false, pg_temp.u('dr'));
  PERFORM pg_temp.act(NULL);
  PERFORM pg_temp.commit_point();

  -- The report as finance reads it.
  PERFORM pg_temp.act(pg_temp.u('f1'));
  SET LOCAL ROLE authenticated;
  j := public.exos_sales_tax_report(pg_temp.u('1'));
  SELECT x INTO ga FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'tax_name' = 'NY sales tax' AND x ->> 'source' = 'online';
  SELECT x INTO kids FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'tax_name' = 'NY reduced';
  SELECT x INTO unrec FROM jsonb_array_elements(j -> 'rows') x
   WHERE x ->> 'region' = 'NY' AND x -> 'tax_name' = 'null'::jsonb AND x ->> 'source' = 'online';
  SELECT x INTO pos FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'source' = 'pos';
  -- 220 back over the order's split 710 / 80: 197 + 22, the remainder (1) to the largest.
  ASSERT (ga ->> 'tax_collected_cents')::int = 710 AND (ga ->> 'tax_refunded_cents')::int = 198 AND (ga ->> 'taxable_cents')::int = 8000
     AND (ga ->> 'rate_percent')::numeric = 8.875 AND ga ->> 'city' = 'Brooklyn', 'JP3 GA: ' || coalesce(ga::text, 'none');
  ASSERT (kids ->> 'tax_collected_cents')::int = 80 AND (kids ->> 'tax_refunded_cents')::int = 22, 'JP3 Kids: ' || coalesce(kids::text, 'none');
  -- The gift card order's tax (no lines: "rate not recorded"): 400 collected, its three shares back on the card (160).
  ASSERT (unrec ->> 'tax_collected_cents')::int = 400 AND (unrec ->> 'tax_refunded_cents')::int = 160 + 0,
         'JP3 the tax handed back to a gift card is in the report: ' || coalesce(unrec::text, 'none');
  ASSERT (pos ->> 'tax_collected_cents')::int = 1065 AND (pos ->> 'tax_refunded_cents')::int = 1065 AND (pos ->> 'net_tax_cents')::int = 0
     AND (pos ->> 'rate_percent')::numeric = 8.875, 'JP3 the door sale and its refund: ' || coalesce(pos::text, 'none');
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') x WHERE x ->> 'region' = 'TX'), 'JP3 nothing of org B';

  -- = the journal: all time, periods, each event.
  v_gap := pg_temp.tax_gap(pg_temp.u('1'));
  ASSERT v_gap IS NULL, 'JP3 all time: ' || v_gap;
  FOREACH v IN ARRAY ARRAY['30 days', '2 days', '36 hours', '1 hour'] LOOP
    v_mid := now() - v::interval;
    v_gap := coalesce(pg_temp.tax_gap(pg_temp.u('1'), NULL, v_mid), pg_temp.tax_gap(pg_temp.u('1'), v_mid, NULL));
    ASSERT v_gap IS NULL, 'JP3 split at ' || v || ': ' || v_gap;
  END LOOP;
  v_gap := coalesce(pg_temp.tax_gap(pg_temp.u('1'), now() - interval '2 days', now() - interval '12 hours'),
                    pg_temp.tax_gap(pg_temp.u('1'), NULL, NULL, pg_temp.u('e1')), pg_temp.tax_gap(pg_temp.u('1'), NULL, NULL, pg_temp.u('e2')));
  ASSERT v_gap IS NULL, 'JP3 a window / an event: ' || v_gap;
  -- The old period holds only the sale; yesterday only the refunds.
  j := public.exos_sales_tax_report(pg_temp.u('1'), NULL, now() - interval '30 days');
  ASSERT (SELECT sum((x ->> 'tax_collected_cents')::int) FROM jsonb_array_elements(j -> 'rows') x) = 790
     AND (SELECT sum((x ->> 'tax_refunded_cents')::int) FROM jsonb_array_elements(j -> 'rows') x) = 0, 'JP3 the old period: ' || j::text;
  j := public.exos_sales_tax_report(pg_temp.u('1'), now() - interval '36 hours', now() - interval '12 hours');
  -- (the failed refund's 73 was handed back yesterday too; its reversal is dated today)
  ASSERT (SELECT sum((x ->> 'tax_refunded_cents')::int) FROM jsonb_array_elements(j -> 'rows') x) = 220 + 73
     AND (SELECT sum((x ->> 'tax_collected_cents')::int) FROM jsonb_array_elements(j -> 'rows') x) = 0, 'JP3 yesterday: ' || j::text;
  RESET ROLE;
  -- Org B, through its owner.
  PERFORM pg_temp.act(pg_temp.u('o2'));
  SET LOCAL ROLE authenticated;
  v_gap := pg_temp.tax_gap(pg_temp.u('2'));
  ASSERT v_gap IS NULL, 'JP3 org B: ' || v_gap;
  ASSERT (SELECT sum((x ->> 'net_tax_cents')::int) FROM jsonb_array_elements(public.exos_sales_tax_report(pg_temp.u('2')) -> 'rows') x) = 250,
         'JP3 org B''s own tax';
  ASSERT pg_temp.st(format('SELECT public.exos_sales_tax_report(%L)', pg_temp.u('1'))) = '42501', 'JP3 org B can''t read org A';
  PERFORM pg_temp.act(pg_temp.u('s1'));
  ASSERT pg_temp.st(format('SELECT public.exos_sales_tax_report(%L)', pg_temp.u('1'))) = '42501', 'JP3 a scanner can''t';
  RESET ROLE;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  JP3 the sales tax report = the journal (gift card refunds, refunds without a credit note, a failed refund, the door; all time, periods, events, both orgs); rates still split; readers';
END $$;

-- JP4 ------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.commit_point();
  SELECT count(*) INTO n FROM (
    SELECT e.id FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
     GROUP BY e.id HAVING sum(l.debit_cents) <> sum(l.credit_cents)) x;
  ASSERT n = 0, 'JP4 unbalanced entries: ' || n;
  SELECT count(*) INTO n FROM (
    SELECT e.org_id, e.currency FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
     GROUP BY e.org_id, e.currency HAVING sum(l.debit_cents - l.credit_cents) <> 0) x;
  ASSERT n = 0, 'JP4 orgs whose trial balance is off: ' || n;
  RAISE NOTICE 'OK  JP4 every entry balances; every org and currency in the database balances';
END $$;

ROLLBACK;
