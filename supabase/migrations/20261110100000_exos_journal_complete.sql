-- ============================================================================
-- Migration 20261110100000 — Exos: the money journal, completed.
--   docs/journal.md. KANBAN "Next (money records)": the journal line.
--
-- Branch:   claude/exos-journal-2
-- Touches:  W: TABLE exos_journal_entries (source_table check: + the six new
--              sources below)
--           W: FUNCTION exos_journal_accounts, _exos_journal_account_ok (the
--              chart: + 1030 bank, 1040 cash on hand, 3000 opening balances,
--              4040 gift card breakage, 5050 cash over / short, 5060 gift
--              cards given away), exos_journal_post_pos_payment (+ card
--              tenders), _exos_tg_journal (+ the new sources),
--              _exos_journal_backfill (+ the new sources). All four were
--              created by 20261108100000 and nothing else patches them: this
--              file redefines them whole (CREATE OR REPLACE), no text patch.
--           C: FUNCTION exos_journal_post_pos_reversal (card refund at the
--              door), exos_journal_post_gift_card (the gift card ledger),
--              exos_journal_post_gift_card_redemption, exos_journal_post_drawer
--              (float, count variance, close), exos_journal_post_instant_payout,
--              exos_journal_post_paypal_remittance (service role only)
--           C: TRIGGER on exos_pos_reversals, exos_gift_card_ledger (deferred
--              to commit), exos_gift_card_redemptions, exos_pos_drawer_sessions,
--              exos_org_instant_payouts, exos_paypal_org_remittances
--           R: exos_pos_payments / _orders / _order_lines / _card_payments /
--              _reversals / _drawer_sessions / _drawer_recounts, exos_gift_cards,
--              exos_gift_card_ledger / _redemptions, exos_commerce_orders,
--              exos_partner_reservations, exos_checkout_sessions,
--              exos_org_instant_payouts, exos_paypal_org_remittances, exos_events
-- Pre-reqs: 20261108100000 (money journal), 20261107130000 (card at the door),
--           20261030130000 / 20261102110000 (gift cards), 20261104200000 (drawer
--           recount), 20261102150000 (instant payouts), 20261031220000 (PayPal).
--
-- What posts what (same rules as 20261108100000: balanced, integer cents,
-- idempotent on (source_table, source_id, kind), append-only, a failure is a
-- WARNING and never undoes the money move, the backfill catches up):
--   * POS card tender (exos_pos_payments 'card'): pos_card_sale, like an online
--     order: Dr clearing (charge), Cr tax / face / bar and merch (the order's
--     lines, as a cash tender); Dr Exos fee + card fees, Cr clearing: the
--     application fee withheld (exos_pos_card_payments).
--   * Its refund (exos_pos_reversals, card_refund_status 'succeeded'):
--     pos_card_refund: Dr refunds + tax, Cr clearing (net), Cr Exos fee + card
--     fees (the fee comes back in proportion, as online). A capture that never
--     became a sale (refund_pending) posts nothing: in and out at Stripe.
--   * Gift cards (exos_gift_card_ledger): issue = a liability, never revenue:
--     Dr where the money went (Stripe clearing less the application fee for an
--     online sale; the drawer for cash into a drawer; cash on hand for cash,
--     check or a card taken outside Exos; gift cards given away for a comp;
--     opening balances for an import), Cr gift cards outstanding. A redemption
--     on an order is the order's own sale entry (Dr gift cards, 20261108100000);
--     on a partner reservation it posts when captured (gc_redeem: Dr gift cards,
--     Cr ticket revenue). A refund back to a card restores the liability
--     (gc_refund: Dr refunds + the tax share, Cr gift cards). A void is
--     breakage, or, when the purchase itself was refunded, the money back
--     (gc_purchase_refund). Hold / release rows post nothing (an order that
--     never completed).
--   * Payouts: an instant payout sent (exos_org_instant_payouts): Dr bank, Cr
--     Stripe clearing. A PayPal remittance (exos_paypal_org_remittances): Dr
--     bank (or Stripe clearing for a Stripe transfer), Cr the PayPal
--     receivable. Stripe's scheduled payouts aren't recorded anywhere in Exos.
--   * Drawer (exos_pos_drawer_sessions): the float in (Dr drawer, Cr cash on
--     hand), the count variance at close (Dr / Cr drawer vs cash over / short)
--     and the counted cash out (Dr cash on hand, Cr drawer); a recount posts the
--     difference. A closed drawer's account nets to zero.
--   * NOT posted: the Exos fee on walk-up cash sales (an open operator decision,
--     docs/pos.md; docs/journal.md has the TODO).
--
-- Additive, replay-safe (CREATE OR REPLACE, DROP ... IF EXISTS before each
-- trigger and the widened check, an idempotent backfill). D4 authors; not
-- applied. Prod apply needs operator OK.
-- ROLLBACK: drop the six new triggers and the six new functions; re-run
-- 20261108100000's definitions of the four redefined functions; the new
-- entries stay (append-only) and still balance.
-- ============================================================================

-- ===========================================================================
-- 1. The chart (six new accounts) and the sources
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_journal_accounts()
RETURNS TABLE (code text, number int, name text, type text, normal text)
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT * FROM (VALUES
    ('stripe_clearing',              1000, 'Cash at Stripe / clearing',                'asset',          'debit'),
    ('paypal_receivable',            1010, 'PayPal balance due from Exos',             'asset',          'debit'),
    ('pos_cash_drawer',              1020, 'POS cash drawer',                          'asset',          'debit'),
    ('bank',                         1030, 'Bank (payouts received)',                  'asset',          'debit'),
    ('cash_on_hand',                 1040, 'Cash on hand (outside Exos)',              'asset',          'debit'),
    ('marketplace_receivable',       1100, 'Marketplace receivable',                   'asset',          'debit'),
    ('organizer_payable',            2000, 'Organizer payable (owed to Exos)',         'liability',      'credit'),
    ('sales_tax_payable',            2100, 'Sales tax payable',                        'liability',      'credit'),
    ('promoter_commissions_payable', 2200, 'Promoter commissions payable',             'liability',      'credit'),
    ('gift_cards_outstanding',       2300, 'Gift cards outstanding',                   'liability',      'credit'),
    ('tips_payable',                 2400, 'Tips payable (POS)',                       'liability',      'credit'),
    ('opening_balances',             3000, 'Opening balances (imported gift cards)',   'equity',         'credit'),
    ('ticket_revenue',               4000, 'Ticket revenue (face)',                    'revenue',        'credit'),
    ('buyer_fees',                   4010, 'Buyer fees',                               'revenue',        'credit'),
    ('pos_other_sales',              4020, 'Bar and merch sales (POS)',                'revenue',        'credit'),
    ('donations',                    4030, 'Donations',                                'revenue',        'credit'),
    ('gift_card_breakage',           4040, 'Gift card breakage (voided balances)',     'revenue',        'credit'),
    ('refunds',                      4900, 'Refunds',                                  'contra_revenue', 'debit'),
    ('exos_fee',                     5000, 'Exos fee',                                 'expense',        'debit'),
    ('card_fees',                    5010, 'Card processing fees',                     'expense',        'debit'),
    ('disputes',                     5020, 'Disputes',                                 'expense',        'debit'),
    ('promoter_commissions',         5030, 'Promoter commissions',                     'expense',        'debit'),
    ('pos_paid_outs',                5040, 'Cash paid-outs (POS)',                     'expense',        'debit'),
    ('cash_over_short',              5050, 'Cash over / short (POS)',                  'expense',        'debit'),
    ('gift_card_comps',              5060, 'Gift cards given away',                    'expense',        'debit')
  ) a(code, number, name, type, normal)
$$;
REVOKE ALL ON FUNCTION public.exos_journal_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_journal_accounts() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_journal_account_ok(p_code text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_code IN ('stripe_clearing', 'paypal_receivable', 'pos_cash_drawer', 'bank', 'cash_on_hand', 'marketplace_receivable',
                    'organizer_payable', 'sales_tax_payable', 'promoter_commissions_payable', 'gift_cards_outstanding',
                    'tips_payable', 'opening_balances', 'ticket_revenue', 'buyer_fees', 'pos_other_sales', 'donations',
                    'gift_card_breakage', 'refunds', 'exos_fee', 'card_fees', 'disputes', 'promoter_commissions', 'pos_paid_outs',
                    'cash_over_short', 'gift_card_comps')
$$;
REVOKE ALL ON FUNCTION public._exos_journal_account_ok(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_journal_account_ok(text) TO authenticated, service_role;

ALTER TABLE public.exos_journal_entries DROP CONSTRAINT IF EXISTS exos_journal_entries_source_table_check;
ALTER TABLE public.exos_journal_entries ADD CONSTRAINT exos_journal_entries_source_table_check CHECK (source_table IN (
  'exos_checkout_sessions', 'exos_order_refunds', 'exos_fee_adjustments', 'exos_disputes',
  'exos_marketplace_orders', 'exos_org_payout_lines', 'exos_promoter_commissions',
  'exos_pos_payments', 'exos_pos_paid_outs',
  'exos_pos_reversals', 'exos_gift_card_ledger', 'exos_gift_card_redemptions', 'exos_pos_drawer_sessions',
  'exos_org_instant_payouts', 'exos_paypal_org_remittances'));

-- ===========================================================================
-- 2. Card at the door
-- ===========================================================================
-- The application fee of one card tender: the card attempt's split, in
-- proportion when the tender isn't the whole attempt (it always is today).
CREATE OR REPLACE FUNCTION public._exos_journal_pos_card_fees(p public.exos_pos_payments, OUT app bigint, OUT exos bigint, OUT card bigint)
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_pos_card_payments%ROWTYPE; v_app bigint; v_exos bigint;
BEGIN
  SELECT * INTO c FROM public.exos_pos_card_payments
   WHERE order_id = p.order_id AND (payment_intent_id = p.terminal_ref OR p.terminal_ref IS NULL)
   ORDER BY created_at LIMIT 1;
  v_app := coalesce(c.application_fee_cents, 0);
  v_exos := least(greatest(coalesce(c.exos_fee_cents, v_app - coalesce(c.card_fee_est_cents, 0)), 0), v_app);
  IF coalesce(c.amount_cents, 0) > 0 AND c.amount_cents <> p.amount_cents THEN
    v_app := round(v_app::numeric * p.amount_cents / c.amount_cents);
    v_exos := least(round(v_exos::numeric * p.amount_cents / c.amount_cents), v_app);
  END IF;
  app := least(v_app, p.amount_cents); exos := least(v_exos, app); card := app - exos;
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_pos_card_fees(public.exos_pos_payments) FROM PUBLIC, anon, authenticated;

-- A POS tender: cash into the drawer, or a card at Stripe (the application
-- fee withheld, as an online order). Split by the order's lines (tax pro rata
-- to the order, tickets vs bar / merch by their net). A comp posts nothing.
CREATE OR REPLACE FUNCTION public.exos_journal_post_pos_payment(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE p public.exos_pos_payments%ROWTYPE; o public.exos_pos_orders%ROWTYPE; v_ticket bigint; v_other bigint;
        v_tax bigint; v_net bigint; v_tk bigint; f record;
BEGIN
  SELECT * INTO p FROM public.exos_pos_payments WHERE id = p_id;
  IF p.id IS NULL OR p.method NOT IN ('cash', 'card') THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = p.order_id;
  SELECT coalesce(sum(line_total_cents - tax_cents) FILTER (WHERE category = 'ticket'), 0),
         coalesce(sum(line_total_cents - tax_cents) FILTER (WHERE category <> 'ticket'), 0)
    INTO v_ticket, v_other FROM public.exos_pos_order_lines WHERE order_id = p.order_id;
  v_tax := CASE WHEN coalesce(o.total_cents, 0) > 0 THEN round(p.amount_cents::numeric * o.tax_cents / o.total_cents) ELSE 0 END;
  v_net := p.amount_cents - v_tax;
  v_tk := CASE WHEN v_ticket + v_other > 0 THEN round(v_net::numeric * v_ticket / (v_ticket + v_other)) ELSE v_net END;
  IF p.method = 'cash' THEN
    RETURN public._exos_journal_post(
      p.org_id, p.event_id, 'exos_pos_payments', p.id::text, 'pos_cash_sale', p.created_at, o.currency,
      'POS cash sale ' || p.order_id,
      jsonb_build_array(
        jsonb_build_object('a', 'pos_cash_drawer', 'c', p.amount_cents + p.tip_cents),
        jsonb_build_object('a', 'tips_payable', 'c', -p.tip_cents),
        jsonb_build_object('a', 'sales_tax_payable', 'c', -v_tax),
        jsonb_build_object('a', 'ticket_revenue', 'c', -v_tk),
        jsonb_build_object('a', 'pos_other_sales', 'c', -(v_net - v_tk))),
      NULL, p.amount_cents);
  END IF;
  /* exos: journal pos card */
  f := public._exos_journal_pos_card_fees(p);
  RETURN public._exos_journal_post(
    p.org_id, p.event_id, 'exos_pos_payments', p.id::text, 'pos_card_sale', p.created_at, o.currency,
    'POS card sale ' || p.order_id,
    jsonb_build_array(
      jsonb_build_object('a', 'stripe_clearing', 'c', p.amount_cents + p.tip_cents, 'm', 'Charged at the door'),
      jsonb_build_object('a', 'tips_payable', 'c', -p.tip_cents),
      jsonb_build_object('a', 'sales_tax_payable', 'c', -v_tax),
      jsonb_build_object('a', 'ticket_revenue', 'c', -v_tk),
      jsonb_build_object('a', 'pos_other_sales', 'c', -(v_net - v_tk)),
      jsonb_build_object('a', 'exos_fee', 'c', f.exos),
      jsonb_build_object('a', 'card_fees', 'c', f.card, 'm', 'Card-fee estimate in the application fee'),
      jsonb_build_object('a', 'stripe_clearing', 'c', -f.app, 'm', 'Application fee withheld')),
    NULL, p.amount_cents);
END $$;

-- A void / refund of a card sale, once Stripe says the card refund
-- succeeded: the sale's split, back. Synced, so a refund that somehow fails
-- after succeeding (never today: 'succeeded' is final) would reverse.
CREATE OR REPLACE FUNCTION public.exos_journal_post_pos_reversal(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE rv public.exos_pos_reversals%ROWTYPE; o public.exos_pos_orders%ROWTYPE; p public.exos_pos_payments%ROWTYPE;
        v_target jsonb := '{}'::jsonb; v_amt bigint; v_tax bigint; v_app bigint; v_exos bigint; f record;
BEGIN
  PERFORM public._exos_journal_lock('posrev:' || p_id);
  SELECT * INTO rv FROM public.exos_pos_reversals WHERE id = p_id;
  IF rv.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM public.exos_pos_orders WHERE id = rv.order_id;
  SELECT * INTO p FROM public.exos_pos_payments WHERE order_id = rv.order_id AND method = 'card' ORDER BY created_at LIMIT 1;
  IF rv.card_refund_status = 'succeeded' AND coalesce(rv.card_cents, 0) > 0 AND p.id IS NOT NULL THEN
    -- Its sale first (a replay, or the sale's trigger warned).
    PERFORM public.exos_journal_post_pos_payment(p.id);
    v_amt := least(rv.card_cents, p.amount_cents);
    f := public._exos_journal_pos_card_fees(p);
    v_tax := CASE WHEN coalesce(o.total_cents, 0) > 0 THEN round(v_amt::numeric * o.tax_cents / o.total_cents) ELSE 0 END;
    v_app := round(f.app::numeric * v_amt / p.amount_cents);
    v_exos := least(round(f.exos::numeric * v_amt / p.amount_cents), v_app);
    v_target := jsonb_build_object('refunds', v_amt - v_tax, 'sales_tax_payable', v_tax,
                                   'stripe_clearing', -(v_amt - v_app), 'exos_fee', -v_exos, 'card_fees', -(v_app - v_exos));
  END IF;
  RETURN public._exos_journal_sync(
    rv.org_id, rv.event_id, 'exos_pos_reversals', rv.id::text, coalesce(rv.created_at, now()), coalesce(o.currency, 'usd'),
    'POS card ' || rv.kind || ' ' || rv.order_id, v_target, 'pos_card_refund', 'pos_card_refund_adjust', 'pos_card_refund_reversal');
END $$;

-- ===========================================================================
-- 3. Gift cards
-- ===========================================================================
-- A redemption on a partner reservation (no checkout order carries it): the
-- liability becomes ticket revenue once the reservation completes. A
-- redemption on a checkout order is that order's sale entry.
CREATE OR REPLACE FUNCTION public.exos_journal_post_gift_card_redemption(p_session text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r public.exos_gift_card_redemptions%ROWTYPE; v_event uuid; v_cur text;
BEGIN
  SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = p_session;
  IF r.session_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF r.partner_reservation_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM public.exos_checkout_sessions WHERE session_id = r.session_id) THEN
      RETURN public.exos_journal_post_order(r.session_id);   -- the order's sale carries the gift card part
    END IF;
    RETURN NULL;
  END IF;
  IF r.status <> 'captured' THEN
    RETURN NULL;   -- held (nothing spent yet) or released (given back)
  END IF;
  -- The card, the reservation and the redemption are one org's (else nothing: never another org's books).
  SELECT event_id INTO v_event FROM public.exos_partner_reservations WHERE id = r.partner_reservation_id AND org_id = r.org_id;
  SELECT currency INTO v_cur FROM public.exos_gift_cards WHERE id = r.card_id AND org_id = r.org_id;
  IF v_event IS NULL OR v_cur IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN public._exos_journal_post(
    r.org_id, v_event, 'exos_gift_card_redemptions', r.session_id, 'gc_redeem', r.updated_at, v_cur,
    'Gift card on reservation ' || r.partner_reservation_id,
    jsonb_build_array(jsonb_build_object('a', 'gift_cards_outstanding', 'c', r.amount_cents, 'm', 'Paid by gift card'),
                      jsonb_build_object('a', 'ticket_revenue', 'c', -r.amount_cents)),
    NULL, r.amount_cents);
END $$;

-- One gift card ledger row.
CREATE OR REPLACE FUNCTION public.exos_journal_post_gift_card(p_ledger bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l public.exos_gift_card_ledger%ROWTYPE; c public.exos_gift_cards%ROWTYPE; co public.exos_commerce_orders%ROWTYPE;
        s public.exos_checkout_sessions%ROWTYPE; r public.exos_gift_card_redemptions%ROWTYPE;
        v_lines jsonb; v_acct text; v_memo text; v_event uuid; v_app bigint; v_amt bigint; v_value bigint;
        v_tax bigint; v_tax_back bigint;
BEGIN
  SELECT * INTO l FROM public.exos_gift_card_ledger WHERE id = p_ledger;
  IF l.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = l.card_id;
  IF c.id IS NULL THEN
    RETURN NULL;
  END IF;
  v_amt := abs(l.amount_cents);

  IF l.kind = 'issue' THEN
    IF l.amount_cents <= 0 THEN
      RETURN NULL;
    END IF;
    IF c.source = 'online' AND c.payment_method = 'card' AND c.issue_key IS NOT NULL THEN
      SELECT * INTO co FROM public.exos_commerce_orders
       WHERE session_id = c.issue_key AND org_id = c.org_id AND kind = 'gift_card';
    END IF;
    IF co.session_id IS NOT NULL THEN
      -- Sold online: a destination charge, the application fee withheld.
      v_app := least(greatest(coalesce(co.application_fee_cents, 0), 0), co.amount_cents);
      v_lines := jsonb_build_array(
        jsonb_build_object('a', 'stripe_clearing', 'c', co.amount_cents, 'm', 'Charged'),
        jsonb_build_object('a', 'gift_cards_outstanding', 'c', -l.amount_cents),
        jsonb_build_object('a', 'buyer_fees', 'c', -(co.amount_cents - l.amount_cents)),
        jsonb_build_object('a', 'exos_fee', 'c', v_app),
        jsonb_build_object('a', 'stripe_clearing', 'c', -v_app, 'm', 'Application fee withheld'));
      v_memo := 'Gift card sold online';
    ELSE
      v_acct := CASE WHEN c.payment_method = 'comp' THEN 'gift_card_comps'
                     WHEN c.payment_method = 'external' OR c.source = 'import' THEN 'opening_balances'
                     WHEN c.payment_method = 'card' AND c.source = 'online' THEN 'stripe_clearing'
                     WHEN c.payment_method = 'cash' AND c.pos_drawer_id IS NOT NULL THEN 'pos_cash_drawer'
                     ELSE 'cash_on_hand' END;
      v_memo := CASE v_acct WHEN 'gift_card_comps' THEN 'Gift card given (comp)'
                            WHEN 'opening_balances' THEN 'Gift card imported (opening balance)'
                            ELSE 'Gift card sold (' || c.source || ', ' || c.payment_method || ')' END;
      v_lines := jsonb_build_array(jsonb_build_object('a', v_acct, 'c', l.amount_cents),
                                   jsonb_build_object('a', 'gift_cards_outstanding', 'c', -l.amount_cents));
      IF c.pos_drawer_id IS NOT NULL THEN
        SELECT event_id INTO v_event FROM public.exos_pos_drawer_sessions WHERE id = c.pos_drawer_id;
      END IF;
    END IF;
    RETURN public._exos_journal_post(c.org_id, v_event, 'exos_gift_card_ledger', l.id::text, 'gc_issue', l.created_at,
                                     c.currency, v_memo, v_lines, NULL, l.amount_cents);

  ELSIF l.kind = 'refund' THEN
    IF l.amount_cents <= 0 OR l.session_id IS NULL THEN
      RETURN NULL;
    END IF;
    PERFORM public._exos_journal_lock('order:' || l.session_id);
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = l.session_id;
    IF s.session_id IS NOT NULL THEN
      IF s.org_id IS DISTINCT FROM c.org_id OR NOT public._exos_journal_paid(s.status) OR coalesce(s.gift_card_cents, 0) <= 0 THEN
        RETURN NULL;   -- never sold: the hold went back, nothing was journaled
      END IF;
      PERFORM public.exos_journal_post_order(s.session_id);   -- the sale first (a no-op once posted)
      IF NOT EXISTS (SELECT 1 FROM public.exos_journal_entries
                      WHERE source_table = 'exos_checkout_sessions' AND source_id = s.session_id AND kind = 'sale') THEN
        RETURN NULL;
      END IF;
      -- The tax share of the gift card part, never more than the order's tax
      -- not yet handed back (card refunds and earlier gift card refunds).
      v_value := coalesce(s.amount_cents, 0)::bigint + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0);
      SELECT coalesce(sum(jl.debit_cents - jl.credit_cents), 0) INTO v_tax_back
        FROM public.exos_journal_lines jl JOIN public.exos_journal_entries e ON e.id = jl.entry_id
       WHERE e.session_id = s.session_id AND e.source_table <> 'exos_checkout_sessions' AND jl.account = 'sales_tax_payable';
      v_tax := CASE WHEN v_value > 0 THEN round(coalesce(s.tax_cents, 0)::numeric * v_amt / v_value) ELSE 0 END;
      v_tax := least(greatest(least(v_tax, coalesce(s.tax_cents, 0) - v_tax_back), 0), v_amt);
      RETURN public._exos_journal_post(
        s.org_id, s.event_id, 'exos_gift_card_ledger', l.id::text, 'gc_refund', l.created_at, coalesce(s.currency, c.currency),
        'Refund to gift card, order ' || s.session_id,
        jsonb_build_array(jsonb_build_object('a', 'refunds', 'c', v_amt - v_tax),
                          jsonb_build_object('a', 'sales_tax_payable', 'c', v_tax),
                          jsonb_build_object('a', 'gift_cards_outstanding', 'c', -v_amt, 'm', 'Back on the gift card')),
        s.session_id, v_amt);
    END IF;
    SELECT * INTO r FROM public.exos_gift_card_redemptions WHERE session_id = l.session_id;
    IF r.partner_reservation_id IS NULL OR r.status <> 'captured' OR r.card_id <> c.id OR r.org_id <> c.org_id THEN
      RETURN NULL;
    END IF;
    IF public.exos_journal_post_gift_card_redemption(r.session_id) IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.exos_journal_entries
                        WHERE source_table = 'exos_gift_card_redemptions' AND source_id = r.session_id AND kind = 'gc_redeem') THEN
      RETURN NULL;   -- the redemption was never journaled: nothing to give back
    END IF;
    SELECT event_id INTO v_event FROM public.exos_partner_reservations WHERE id = r.partner_reservation_id;
    RETURN public._exos_journal_post(
      c.org_id, v_event, 'exos_gift_card_ledger', l.id::text, 'gc_refund', l.created_at, c.currency,
      'Refund to gift card, reservation ' || r.partner_reservation_id,
      jsonb_build_array(jsonb_build_object('a', 'refunds', 'c', v_amt),
                        jsonb_build_object('a', 'gift_cards_outstanding', 'c', -v_amt, 'm', 'Back on the gift card')),
      NULL, v_amt);

  ELSIF l.kind IN ('void', 'adjust') THEN
    IF l.amount_cents = 0 THEN
      RETURN NULL;   -- a new code: no money
    END IF;
    IF l.kind = 'void' AND c.source = 'online' AND c.payment_method = 'card' AND c.issue_key IS NOT NULL THEN
      SELECT * INTO co FROM public.exos_commerce_orders
       WHERE session_id = c.issue_key AND org_id = c.org_id AND kind = 'gift_card' AND status = 'refunded';
    END IF;
    IF co.session_id IS NOT NULL AND co.amount_cents > 0 THEN
      -- The purchase was refunded (exos_commerce_refund voids the card): the
      -- balance goes back to the buyer, the application fee in proportion.
      v_app := round(least(greatest(coalesce(co.application_fee_cents, 0), 0), co.amount_cents)::numeric
                     * least(v_amt, co.amount_cents) / co.amount_cents);
      RETURN public._exos_journal_post(
        c.org_id, NULL, 'exos_gift_card_ledger', l.id::text, 'gc_purchase_refund', l.created_at, c.currency,
        'Gift card purchase refunded',
        jsonb_build_array(jsonb_build_object('a', 'gift_cards_outstanding', 'c', v_amt),
                          jsonb_build_object('a', 'stripe_clearing', 'c', -(v_amt - v_app), 'm', 'Pulled back from the organizer'),
                          jsonb_build_object('a', 'exos_fee', 'c', -v_app, 'm', 'Application fee returned')),
        NULL, v_amt);
    END IF;
    -- What's left on a voided card (or an adjustment) is breakage.
    RETURN public._exos_journal_post(
      c.org_id, NULL, 'exos_gift_card_ledger', l.id::text, 'gc_' || l.kind, l.created_at, c.currency,
      CASE WHEN l.kind = 'void' THEN 'Gift card voided' ELSE 'Gift card adjusted' END,
      jsonb_build_array(jsonb_build_object('a', 'gift_cards_outstanding', 'c', -l.amount_cents),
                        jsonb_build_object('a', 'gift_card_breakage', 'c', l.amount_cents)),
      NULL, v_amt);
  END IF;
  RETURN NULL;   -- redeem / release: a hold and its release; the order posts what was spent
END $$;

-- ===========================================================================
-- 4. Payouts
-- ===========================================================================
-- An instant payout from the connected account to the organizer's bank.
-- Stripe's fee on it isn't known to Exos (only an estimate): not posted.
CREATE OR REPLACE FUNCTION public.exos_journal_post_instant_payout(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE x public.exos_org_instant_payouts%ROWTYPE; v_target jsonb := '{}'::jsonb;
BEGIN
  PERFORM public._exos_journal_lock('instant:' || p_id);
  SELECT * INTO x FROM public.exos_org_instant_payouts WHERE id = p_id;
  IF x.id IS NULL THEN
    RETURN NULL;
  END IF;
  IF x.status = 'sent' THEN
    v_target := jsonb_build_object('bank', x.amount_cents, 'stripe_clearing', -x.amount_cents);
  END IF;
  RETURN public._exos_journal_sync(
    x.org_id, NULL, 'exos_org_instant_payouts', x.id::text, x.updated_at, x.currency, 'Instant payout to the bank',
    v_target, 'stripe_payout', 'stripe_payout_adjust', 'stripe_payout_reversal');
END $$;

-- What the operator paid an org out of the platform PayPal balance.
CREATE OR REPLACE FUNCTION public.exos_journal_post_paypal_remittance(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE x public.exos_paypal_org_remittances%ROWTYPE;
BEGIN
  SELECT * INTO x FROM public.exos_paypal_org_remittances WHERE id = p_id;
  IF x.id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN public._exos_journal_post(
    x.org_id, NULL, 'exos_paypal_org_remittances', x.id::text, 'paypal_remittance', x.paid_at, x.currency,
    'PayPal balance paid out (' || x.method || ')',
    jsonb_build_array(jsonb_build_object('a', CASE WHEN x.method = 'stripe_transfer' THEN 'stripe_clearing' ELSE 'bank' END,
                                         'c', x.amount_cents),
                      jsonb_build_object('a', 'paypal_receivable', 'c', -x.amount_cents)),
    NULL, x.amount_cents);
END $$;

-- ===========================================================================
-- 5. The cash drawer
-- ===========================================================================
-- The float comes from the organizer's cash; at close the count variance goes
-- to cash over / short and the counted cash leaves the drawer. A recount
-- posts the difference. Three synced parts, each its own source id.
CREATE OR REPLACE FUNCTION public.exos_journal_post_drawer(p_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE d public.exos_pos_drawer_sessions%ROWTYPE; v_cur text; v_at timestamptz; v1 uuid; v2 uuid; v3 uuid;
        v_closed boolean;
BEGIN
  PERFORM public._exos_journal_lock('drawer:' || p_id);
  SELECT * INTO d FROM public.exos_pos_drawer_sessions WHERE id = p_id;
  IF d.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(nullif(currency, ''), 'usd') INTO v_cur FROM public.exos_events WHERE id = d.event_id;
  v_closed := d.status = 'closed' AND d.counted_cents IS NOT NULL AND d.variance_cents IS NOT NULL;
  v_at := greatest(d.closed_at, (SELECT max(created_at) FROM public.exos_pos_drawer_recounts WHERE session_id = d.id));
  v1 := public._exos_journal_sync(
    d.org_id, d.event_id, 'exos_pos_drawer_sessions', d.id::text, d.opened_at, v_cur, 'Drawer float',
    jsonb_build_object('pos_cash_drawer', d.open_float_cents, 'cash_on_hand', -d.open_float_cents),
    'drawer_float', 'drawer_float_adjust', 'drawer_float_reversal');
  v2 := public._exos_journal_sync(
    d.org_id, d.event_id, 'exos_pos_drawer_sessions', d.id::text || ':variance', coalesce(v_at, now()), v_cur,
    'Drawer count ' || CASE WHEN coalesce(d.variance_cents, 0) >= 0 THEN 'over' ELSE 'short' END,
    CASE WHEN v_closed THEN jsonb_build_object('pos_cash_drawer', d.variance_cents, 'cash_over_short', -d.variance_cents)
         ELSE '{}'::jsonb END,
    'drawer_variance', 'drawer_variance_adjust', 'drawer_variance_reversal');
  v3 := public._exos_journal_sync(
    d.org_id, d.event_id, 'exos_pos_drawer_sessions', d.id::text || ':close', coalesce(v_at, now()), v_cur,
    'Drawer closed: counted cash out',
    CASE WHEN v_closed THEN jsonb_build_object('cash_on_hand', d.counted_cents, 'pos_cash_drawer', -d.counted_cents)
         ELSE '{}'::jsonb END,
    'drawer_close', 'drawer_close_adjust', 'drawer_close_reversal');
  RETURN coalesce(v3, v2, v1);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['exos_journal_post_pos_payment(uuid)', 'exos_journal_post_pos_reversal(uuid)',
                           'exos_journal_post_gift_card(bigint)', 'exos_journal_post_gift_card_redemption(text)',
                           'exos_journal_post_instant_payout(uuid)', 'exos_journal_post_paypal_remittance(uuid)',
                           'exos_journal_post_drawer(uuid)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', f);
  END LOOP;
END $$;

-- ===========================================================================
-- 6. Triggers (a failure warns; the money move stands)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_tg_journal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record;
BEGIN
  BEGIN
    CASE TG_TABLE_NAME
      WHEN 'exos_checkout_sessions' THEN
        IF public._exos_journal_paid(NEW.status) THEN PERFORM public.exos_journal_post_order(NEW.session_id); END IF;
      WHEN 'exos_order_refunds' THEN PERFORM public.exos_journal_post_refund(NEW.id);
      WHEN 'exos_fee_adjustments' THEN PERFORM public.exos_journal_post_fee_adjustment(NEW.id);
      WHEN 'exos_disputes' THEN PERFORM public.exos_journal_post_dispute(NEW.id);
      WHEN 'exos_marketplace_orders' THEN PERFORM public.exos_journal_post_marketplace(NEW.id);
      WHEN 'exos_org_payout_lines' THEN PERFORM public.exos_journal_post_payout_line(NEW.id);
      WHEN 'exos_org_payouts' THEN
        FOR r IN SELECT id FROM public.exos_org_payout_lines WHERE payout_id = NEW.id LOOP
          PERFORM public.exos_journal_post_payout_line(r.id);
        END LOOP;
      WHEN 'exos_promoter_commissions' THEN PERFORM public.exos_journal_post_commission(NEW.id);
      WHEN 'exos_pos_payments' THEN PERFORM public.exos_journal_post_pos_payment(NEW.id);
      WHEN 'exos_pos_paid_outs' THEN PERFORM public.exos_journal_post_pos_paid_out(NEW.id);
      /* exos: journal complete */
      WHEN 'exos_pos_reversals' THEN PERFORM public.exos_journal_post_pos_reversal(NEW.id);
      WHEN 'exos_gift_card_ledger' THEN PERFORM public.exos_journal_post_gift_card(NEW.id);
      WHEN 'exos_gift_card_redemptions' THEN PERFORM public.exos_journal_post_gift_card_redemption(NEW.session_id);
      WHEN 'exos_pos_drawer_sessions' THEN PERFORM public.exos_journal_post_drawer(NEW.id);
      WHEN 'exos_org_instant_payouts' THEN PERFORM public.exos_journal_post_instant_payout(NEW.id);
      WHEN 'exos_paypal_org_remittances' THEN PERFORM public.exos_journal_post_paypal_remittance(NEW.id);
      ELSE NULL;
    END CASE;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos journal: % on % (%): the backfill will post it', SQLERRM, TG_TABLE_NAME, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_journal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_pos_reversals_journal ON public.exos_pos_reversals;
CREATE TRIGGER exos_pos_reversals_journal AFTER INSERT OR UPDATE OF card_refund_status, card_cents ON public.exos_pos_reversals
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
-- Deferred to commit: a box-office card is tied to its drawer right after the
-- issue row is written, and a purchase refund marks the commerce order
-- refunded right after the void row; at commit the posting sees both.
DROP TRIGGER IF EXISTS exos_gift_card_ledger_journal ON public.exos_gift_card_ledger;
CREATE CONSTRAINT TRIGGER exos_gift_card_ledger_journal AFTER INSERT ON public.exos_gift_card_ledger
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_gift_card_redemptions_journal ON public.exos_gift_card_redemptions;
CREATE TRIGGER exos_gift_card_redemptions_journal AFTER INSERT OR UPDATE OF status ON public.exos_gift_card_redemptions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_pos_drawer_sessions_journal ON public.exos_pos_drawer_sessions;
CREATE TRIGGER exos_pos_drawer_sessions_journal
  AFTER INSERT OR UPDATE OF status, counted_cents, variance_cents ON public.exos_pos_drawer_sessions
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_org_instant_payouts_journal ON public.exos_org_instant_payouts;
CREATE TRIGGER exos_org_instant_payouts_journal AFTER INSERT OR UPDATE OF status ON public.exos_org_instant_payouts
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();
DROP TRIGGER IF EXISTS exos_paypal_org_remittances_journal ON public.exos_paypal_org_remittances;
CREATE TRIGGER exos_paypal_org_remittances_journal AFTER INSERT ON public.exos_paypal_org_remittances
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal();

-- ===========================================================================
-- 7. Backfill (service role; re-runnable: every posting is idempotent)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_journal_backfill(p_org uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_before bigint; v_after bigint;
BEGIN
  SELECT count(*) INTO v_before FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;
  FOR r IN SELECT session_id FROM public.exos_checkout_sessions
            WHERE (p_org IS NULL OR org_id = p_org) AND public._exos_journal_paid(status)
            ORDER BY coalesce(fulfilled_at, created_at), session_id LOOP
    PERFORM public.exos_journal_post_order(r.session_id);   -- and its refunds
  END LOOP;
  FOR r IN SELECT id FROM public.exos_fee_adjustments WHERE p_org IS NULL OR org_id = p_org ORDER BY processed_at, id LOOP
    PERFORM public.exos_journal_post_fee_adjustment(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_disputes WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_dispute(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_marketplace_orders WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_marketplace(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_org_payout_lines WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_payout_line(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_promoter_commissions WHERE p_org IS NULL OR org_id = p_org ORDER BY accrued_at, id LOOP
    PERFORM public.exos_journal_post_commission(r.id);
  END LOOP;
  -- Drawers before their cash, so a drawer's float comes first in the journal.
  FOR r IN SELECT id FROM public.exos_pos_drawer_sessions WHERE p_org IS NULL OR org_id = p_org ORDER BY opened_at, id LOOP
    PERFORM public.exos_journal_post_drawer(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_pos_payments
            WHERE (p_org IS NULL OR org_id = p_org) AND method IN ('cash', 'card') ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_pos_payment(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_pos_paid_outs WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_pos_paid_out(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_pos_reversals
            WHERE (p_org IS NULL OR org_id = p_org) AND card_cents > 0 ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_pos_reversal(r.id);
  END LOOP;
  FOR r IN SELECT session_id FROM public.exos_gift_card_redemptions
            WHERE (p_org IS NULL OR org_id = p_org) AND partner_reservation_id IS NOT NULL AND status = 'captured'
            ORDER BY created_at, session_id LOOP
    PERFORM public.exos_journal_post_gift_card_redemption(r.session_id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_gift_card_ledger
            WHERE (p_org IS NULL OR org_id = p_org) AND kind IN ('issue', 'refund', 'void', 'adjust') ORDER BY id LOOP
    PERFORM public.exos_journal_post_gift_card(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_org_instant_payouts WHERE p_org IS NULL OR org_id = p_org ORDER BY created_at, id LOOP
    PERFORM public.exos_journal_post_instant_payout(r.id);
  END LOOP;
  FOR r IN SELECT id FROM public.exos_paypal_org_remittances WHERE p_org IS NULL OR org_id = p_org ORDER BY paid_at, id LOOP
    PERFORM public.exos_journal_post_paypal_remittance(r.id);
  END LOOP;
  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;
  RETURN jsonb_build_object('org_id', p_org, 'posted', v_after - v_before, 'entries', v_after);
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_backfill(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_journal_backfill(uuid) TO service_role;

-- ===========================================================================
-- 8. Backfill what's already there
-- ===========================================================================
SELECT public._exos_journal_backfill(NULL);
