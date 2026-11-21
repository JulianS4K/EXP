-- ============================================================================
-- Migration 20261111130000 — Exos: the money journal's last gaps: Stripe's
--   scheduled payouts to the organizer's bank, the sales tax report read from
--   the journal, and the Exos fee owed on a gift card part handed back.
--   docs/journal.md. KANBAN "Next (money records)": the journal line.
--
-- Branch:   claude/exos-journal-3
-- Touches:  C: TABLE exos_stripe_org_payouts (the payouts Stripe made from each
--              org's connected account, as exos-reconcile-stripe lists them:
--              read-only at Stripe; RLS: owner / finance of the org and
--              platform admins read; no client writes)
--           C: FUNCTION exos_stripe_org_payouts_record (service role:
--              exos-reconcile-stripe), exos_journal_post_stripe_org_payout,
--              _exos_journal_gc_refund_fee (service role), the trigger
--              function _exos_tg_journal_stripe_payout
--           C: TRIGGER on exos_stripe_org_payouts (insert / status) and on
--              exos_org_instant_payouts (stripe_payout_id / status: an instant
--              payout Exos sent is posted from that table, never twice)
--           W: TABLE exos_journal_entries (source_table check:
--              + exos_stripe_org_payouts)
--           W: FUNCTION exos_journal_post_gift_card (marker
--              /* exos: gc refund fee */: a refund back to the gift card of an
--              order also hands back that part's Exos fee owed),
--              _exos_journal_backfill (marker /* exos: journal stripe payouts */:
--              + the payouts). Both were last defined by 20261110100000 and
--              nothing else patches them: text patches, each matching once.
--           W: FUNCTION exos_sales_tax_report (redefined whole; only
--              20261108100000 defined it): the tax amounts are now the
--              journal's sales tax lines, so the report and the journal agree.
--           R: exos_org_secrets (the connected account), exos_org_instant_payouts,
--              exos_gift_card_ledger, exos_checkout_sessions, exos_journal_*,
--              exos_price_disclosure_lines, exos_tax_rules, exos_ticket_tiers,
--              exos_event_addons, exos_pos_orders / _order_lines / _payments /
--              _paid_outs / _reversals, exos_events
-- Pre-reqs: 20261110100000 (the journal completed), 20261108100000 (the
--           journal, the tax report), 20261001101000 (exos-reconcile-stripe),
--           20261102150000 (instant payouts), 20261109100000 (_exos_audit).
--
-- 1. Scheduled payouts. A Stripe checkout is a destination charge: the
--    organizer's share lands on their connected account and Stripe pays it
--    out to their bank on the account's schedule. Those payouts are objects
--    of the CONNECTED account: the platform's balance transactions
--    (exos_stripe_balance_txns) carry the transfer to the account, never its
--    payouts, and nothing else in Exos records them. Stripe lets a Connect
--    platform read a connected account's objects with the Stripe-Account
--    header, and Exos already does for the balance (exos-instant-payouts), so
--    exos-reconcile-stripe now also lists each connected account's payouts
--    (GET /v1/payouts, a read; never a write) and hands them to
--    exos_stripe_org_payouts_record, which checks the account is the org's
--    own connected account and upserts one row per payout id. A paid payout
--    posts stripe_payout (Dr bank, Cr Stripe clearing), synced on the payout
--    id: a payout that fails after it was paid posts stripe_payout_reversal,
--    a replay posts nothing. A status never moves backwards (pending <
--    in_transit < paid < failed / canceled). An instant payout Exos sent is
--    already posted from exos_org_instant_payouts: its Stripe row posts
--    nothing (and, if that row learns the payout id later, the Stripe row's
--    posting is taken back). Stripe's fee on a payout isn't posted (Exos
--    only knows an estimate for instant ones; standard payouts have none).
-- 2. The sales tax report. It counted only the credit notes' tax as
--    refunded, so a refund back to a gift card (the journal returns its tax
--    share), a refund with no credit note (pro rata in the journal), a
--    refund that failed later (reversed in the journal) and the door's
--    partial cash refunds read differently from the journal. Now every tax
--    amount in the report is a journal sales tax line, attributed to the
--    venue and the tax rate: an order's lines are spread over its rates by
--    the order's own tax split (disclosure lines; a door order's lines),
--    the remainder to the largest, so the report's net per org, currency,
--    event and period is exactly what the journal's sales tax payable moved.
--    Collected = sale entries (orders, door tenders), refunded = everything
--    else, dated by the journal entry. Taxable and order counts still come
--    from the orders.
-- 3. The Exos fee owed on a gift card part (exos_fee_owed_cents: a card that
--    never paid the fee, spent on an order) was never handed back when that
--    part went back on the card. Now each refund row on the order's card
--    posts gc_refund_fee (Dr organizer payable, Cr Exos fee): the owed fee in
--    proportion to the gift card part handed back, cumulative per order over
--    the ledger rows in id order (like a card refund's application fee), so
--    the parts add up to the whole owed fee exactly. The backfill posts it
--    for refund rows already there.
--
-- Additive, replay-safe (IF NOT EXISTS, CREATE OR REPLACE, marker-checked
-- patches, DROP ... IF EXISTS before each trigger and the widened check, an
-- idempotent backfill). D4 authors; not applied. Prod apply needs operator
-- OK. Stripe: reads only (the connected accounts' payouts list).
-- ROLLBACK: drop the three triggers, the five new functions and the table;
-- re-run 20261110100000's exos_journal_post_gift_card and
-- _exos_journal_backfill and 20261108100000's exos_sales_tax_report;
-- redeploy the previous exos-reconcile-stripe. The posted entries stay
-- (append-only) and still balance.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. The sources
-- ===========================================================================
ALTER TABLE public.exos_journal_entries DROP CONSTRAINT IF EXISTS exos_journal_entries_source_table_check;
ALTER TABLE public.exos_journal_entries ADD CONSTRAINT exos_journal_entries_source_table_check CHECK (source_table IN (
  'exos_checkout_sessions', 'exos_order_refunds', 'exos_fee_adjustments', 'exos_disputes',
  'exos_marketplace_orders', 'exos_org_payout_lines', 'exos_promoter_commissions',
  'exos_pos_payments', 'exos_pos_paid_outs',
  'exos_pos_reversals', 'exos_gift_card_ledger', 'exos_gift_card_redemptions', 'exos_pos_drawer_sessions',
  'exos_org_instant_payouts', 'exos_paypal_org_remittances',
  'exos_stripe_org_payouts'));

-- ===========================================================================
-- 2. Stripe's payouts from each org's connected account
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_stripe_org_payouts (
  payout_id     text PRIMARY KEY CHECK (payout_id ~ '^po_[A-Za-z0-9]{1,64}$'),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  account_id    text NOT NULL CHECK (account_id ~ '^acct_[A-Za-z0-9]{1,64}$'),
  -- Signed: Stripe debits the bank with a negative payout when the account's
  -- balance is negative.
  amount_cents  bigint NOT NULL CHECK (abs(amount_cents) <= 100000000000),
  currency      text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  status        text NOT NULL CHECK (status IN ('pending', 'in_transit', 'paid', 'failed', 'canceled')),
  method        text NOT NULL DEFAULT 'standard' CHECK (method IN ('standard', 'instant')),
  automatic     boolean,
  failure_code  text CHECK (failure_code IS NULL OR failure_code ~ '^[a-z0-9_]{1,60}$'),
  created       timestamptz NOT NULL,
  arrival_date  timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_stripe_org_payouts_org_idx ON public.exos_stripe_org_payouts (org_id, created DESC);
ALTER TABLE public.exos_stripe_org_payouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_stripe_org_payouts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_stripe_org_payouts TO authenticated;
GRANT ALL ON public.exos_stripe_org_payouts TO service_role;
DROP POLICY IF EXISTS exos_stripe_org_payouts_sel ON public.exos_stripe_org_payouts;
CREATE POLICY exos_stripe_org_payouts_sel ON public.exos_stripe_org_payouts FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'finance']));
DROP TRIGGER IF EXISTS exos_stripe_org_payouts_touch ON public.exos_stripe_org_payouts;
CREATE TRIGGER exos_stripe_org_payouts_touch BEFORE UPDATE ON public.exos_stripe_org_payouts
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_stripe_org_payouts FROM %I', r);
    END IF;
  END LOOP;
END $$;
COMMENT ON TABLE public.exos_stripe_org_payouts IS
  'Payouts Stripe made from each org''s connected account to its bank, as exos-reconcile-stripe lists them (read-only at Stripe). Written only by exos_stripe_org_payouts_record; owner / finance read. A paid payout posts stripe_payout to the journal. mig 20261111130000.';

-- Record one org's payouts as Stripe listed them (service role:
-- exos-reconcile-stripe). p_account_id must be the org's own connected
-- account (exos_org_secrets), so a payout can only ever land on the org whose
-- account made it; a payout id already recorded for another org or account is
-- left alone. Status only moves forward. Returns counts.
CREATE OR REPLACE FUNCTION public.exos_stripe_org_payouts_record(p_org_id uuid, p_account_id text, p_payouts jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_acct text; i jsonb; o public.exos_stripe_org_payouts%ROWTYPE;
  v_id text; v_amt bigint; v_cur text; v_status text; v_method text; v_auto boolean; v_fail text;
  v_created timestamptz; v_arrival timestamptz; v_ins text;
  v_seen int := 0; v_new int := 0; v_changed int := 0; v_skipped int := 0;
BEGIN
  IF p_org_id IS NULL OR p_account_id IS NULL OR p_account_id !~ '^acct_[A-Za-z0-9]{1,64}$' THEN
    RAISE EXCEPTION 'exos_stripe_org_payouts_record: bad org or account' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payouts) IS DISTINCT FROM 'array' OR jsonb_array_length(p_payouts) > 1000 THEN
    RAISE EXCEPTION 'exos_stripe_org_payouts_record: payouts must be a list of at most 1000' USING ERRCODE = '22023';
  END IF;
  SELECT s.payments ->> 'connectedAccountId' INTO v_acct FROM public.exos_org_secrets s WHERE s.org_id = p_org_id;
  IF v_acct IS DISTINCT FROM p_account_id THEN
    RAISE EXCEPTION 'exos_stripe_org_payouts_record: not this org''s connected account' USING ERRCODE = '42501';
  END IF;

  FOR i IN SELECT * FROM jsonb_array_elements(p_payouts) LOOP
    v_seen := v_seen + 1;
    BEGIN
      v_id := i ->> 'id';
      v_amt := CASE WHEN jsonb_typeof(i -> 'amount') = 'number' THEN (i ->> 'amount')::bigint END;
      v_cur := lower(i ->> 'currency');
      v_status := i ->> 'status';
      v_method := coalesce(nullif(i ->> 'method', ''), 'standard');
      v_auto := CASE WHEN jsonb_typeof(i -> 'automatic') = 'boolean' THEN (i ->> 'automatic')::boolean END;
      v_fail := left(nullif(i ->> 'failure_code', ''), 60);
      v_created := (i ->> 'created')::timestamptz;
      v_arrival := (i ->> 'arrival_date')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      v_id := NULL;
    END;
    IF v_id IS NULL OR v_id !~ '^po_[A-Za-z0-9]{1,64}$' OR v_amt IS NULL OR abs(v_amt) > 100000000000
       OR v_cur IS NULL OR v_cur !~ '^[a-z]{3}$' OR v_created IS NULL
       OR v_status IS NULL OR v_status NOT IN ('pending', 'in_transit', 'paid', 'failed', 'canceled')
       OR v_method NOT IN ('standard', 'instant') OR (v_fail IS NOT NULL AND v_fail !~ '^[a-z0-9_]{1,60}$') THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.exos_stripe_org_payouts (payout_id, org_id, account_id, amount_cents, currency, status, method,
                                                automatic, failure_code, created, arrival_date)
    VALUES (v_id, p_org_id, p_account_id, v_amt, v_cur, v_status, v_method, v_auto, v_fail, v_created, v_arrival)
    ON CONFLICT (payout_id) DO NOTHING
    RETURNING payout_id INTO v_ins;
    IF v_ins IS NOT NULL THEN
      v_new := v_new + 1;
      IF v_status IN ('paid', 'failed', 'canceled') THEN
        /* exos: audit payout.stripe_status */
        PERFORM public._exos_audit(p_org_id, 'payout.stripe_status', 'payout', v_id, NULL,
                                   jsonb_build_object('status', jsonb_build_array(NULL::text, v_status), 'method', v_method),
                                   v_amt, v_cur, NULL, NULL, NULL, 'system');
      END IF;
      CONTINUE;
    END IF;

    SELECT * INTO o FROM public.exos_stripe_org_payouts WHERE payout_id = v_id FOR UPDATE;
    IF o.org_id IS DISTINCT FROM p_org_id OR o.account_id IS DISTINCT FROM p_account_id THEN
      v_skipped := v_skipped + 1;   -- another org's (or account's) payout: never moved
      CONTINUE;
    END IF;
    -- Forward only: pending < in_transit < paid < failed / canceled (final).
    IF o.status IN ('failed', 'canceled')
       OR (CASE v_status WHEN 'pending' THEN 1 WHEN 'in_transit' THEN 2 WHEN 'paid' THEN 3 ELSE 4 END)
          < (CASE o.status WHEN 'pending' THEN 1 WHEN 'in_transit' THEN 2 WHEN 'paid' THEN 3 ELSE 4 END) THEN
      CONTINUE;
    END IF;
    IF o.status IS DISTINCT FROM v_status OR o.arrival_date IS DISTINCT FROM v_arrival
       OR o.failure_code IS DISTINCT FROM v_fail OR o.automatic IS DISTINCT FROM v_auto THEN
      UPDATE public.exos_stripe_org_payouts
         SET status = v_status, arrival_date = v_arrival, failure_code = v_fail, automatic = v_auto
       WHERE payout_id = v_id;
      IF o.status IS DISTINCT FROM v_status THEN
        v_changed := v_changed + 1;
        IF v_status IN ('paid', 'failed', 'canceled') THEN
          PERFORM public._exos_audit(p_org_id, 'payout.stripe_status', 'payout', v_id, NULL,
                                     jsonb_build_object('status', jsonb_build_array(o.status, v_status), 'method', o.method),
                                     o.amount_cents, o.currency, v_fail, NULL, NULL, 'system');
        END IF;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('org_id', p_org_id, 'seen', v_seen, 'new', v_new, 'changed', v_changed, 'skipped', v_skipped);
END $$;
REVOKE ALL ON FUNCTION public.exos_stripe_org_payouts_record(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_stripe_org_payouts_record(uuid, text, jsonb) TO service_role;

-- A payout to the bank: Dr bank, Cr Stripe clearing once Stripe says it's
-- paid; taken back if it fails later. Synced on the payout id (posting twice
-- is a no-op). An instant payout Exos sent posts from exos_org_instant_payouts
-- instead: its Stripe row posts nothing.
CREATE OR REPLACE FUNCTION public.exos_journal_post_stripe_org_payout(p_payout text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE x public.exos_stripe_org_payouts%ROWTYPE; v_target jsonb := '{}'::jsonb; v_paid boolean;
BEGIN
  IF p_payout IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM public._exos_journal_lock('stripe_payout:' || p_payout);
  SELECT * INTO x FROM public.exos_stripe_org_payouts WHERE payout_id = p_payout;
  IF x.payout_id IS NULL THEN
    RETURN NULL;
  END IF;
  v_paid := x.status = 'paid' AND x.amount_cents <> 0
            AND NOT EXISTS (SELECT 1 FROM public.exos_org_instant_payouts i
                             WHERE i.stripe_payout_id = x.payout_id AND i.org_id = x.org_id);
  IF v_paid THEN
    v_target := jsonb_build_object('bank', x.amount_cents, 'stripe_clearing', -x.amount_cents);
  END IF;
  RETURN public._exos_journal_sync(
    x.org_id, NULL, 'exos_stripe_org_payouts', x.payout_id,
    CASE WHEN v_paid THEN least(coalesce(x.arrival_date, x.updated_at), x.updated_at) ELSE x.updated_at END,
    x.currency, CASE WHEN x.method = 'instant' THEN 'Stripe instant payout to the bank' ELSE 'Stripe payout to the bank' END,
    v_target, 'stripe_payout', 'stripe_payout_adjust', 'stripe_payout_reversal');
END $$;
REVOKE ALL ON FUNCTION public.exos_journal_post_stripe_org_payout(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_journal_post_stripe_org_payout(text) TO service_role;

-- Triggers: a failure warns, the row stands; the backfill posts it.
CREATE OR REPLACE FUNCTION public._exos_tg_journal_stripe_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  BEGIN
    IF TG_TABLE_NAME = 'exos_stripe_org_payouts' THEN
      PERFORM public.exos_journal_post_stripe_org_payout(NEW.payout_id);
    ELSIF TG_TABLE_NAME = 'exos_org_instant_payouts' AND NEW.stripe_payout_id IS NOT NULL THEN
      PERFORM public.exos_journal_post_stripe_org_payout(NEW.stripe_payout_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'exos journal: % on % (%): the backfill will post it', SQLERRM, TG_TABLE_NAME, SQLSTATE;
  END;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_journal_stripe_payout() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_stripe_org_payouts_journal ON public.exos_stripe_org_payouts;
CREATE TRIGGER exos_stripe_org_payouts_journal AFTER INSERT OR UPDATE OF status ON public.exos_stripe_org_payouts
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal_stripe_payout();
DROP TRIGGER IF EXISTS exos_org_instant_payouts_journal_stripe ON public.exos_org_instant_payouts;
CREATE TRIGGER exos_org_instant_payouts_journal_stripe AFTER INSERT OR UPDATE OF stripe_payout_id, status ON public.exos_org_instant_payouts
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_journal_stripe_payout();

-- ===========================================================================
-- 3. The Exos fee owed on a gift card part handed back
-- ===========================================================================
-- One refund row back on an order's gift card: the order's owed Exos fee in
-- proportion to the gift card part handed back, cumulative over the order's
-- refund rows in id order (each row's share is fixed, whatever order they
-- post in, and together they hand back exactly the owed fee).
CREATE OR REPLACE FUNCTION public._exos_journal_gc_refund_fee(p_ledger bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE l public.exos_gift_card_ledger%ROWTYPE; s public.exos_checkout_sessions%ROWTYPE; c public.exos_gift_cards%ROWTYPE;
        v_gc bigint; v_owed bigint; v_cum0 bigint; v_cum1 bigint; v_fee bigint;
BEGIN
  SELECT * INTO l FROM public.exos_gift_card_ledger WHERE id = p_ledger;
  IF l.id IS NULL OR l.kind <> 'refund' OR l.session_id IS NULL OR l.amount_cents <= 0 THEN
    RETURN NULL;
  END IF;
  PERFORM public._exos_journal_lock('order:' || l.session_id);
  IF EXISTS (SELECT 1 FROM public.exos_journal_entries
              WHERE source_table = 'exos_gift_card_ledger' AND source_id = l.id::text AND kind = 'gc_refund_fee') THEN
    RETURN NULL;
  END IF;
  SELECT * INTO c FROM public.exos_gift_cards WHERE id = l.card_id;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = l.session_id;
  v_gc := coalesce(s.gift_card_cents, 0);
  v_owed := coalesce(s.exos_fee_owed_cents, 0);
  IF s.session_id IS NULL OR s.org_id IS DISTINCT FROM c.org_id OR NOT public._exos_journal_paid(s.status)
     OR v_gc <= 0 OR v_owed <= 0 THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_journal_entries
                  WHERE source_table = 'exos_checkout_sessions' AND source_id = s.session_id AND kind = 'sale') THEN
    RETURN NULL;   -- the sale (and its owed fee) isn't posted: nothing to hand back yet
  END IF;
  SELECT coalesce(sum(x.amount_cents), 0) INTO v_cum0 FROM public.exos_gift_card_ledger x
   WHERE x.session_id = l.session_id AND x.card_id = l.card_id AND x.kind = 'refund' AND x.amount_cents > 0 AND x.id < l.id;
  v_cum0 := least(v_cum0, v_gc);
  v_cum1 := least(v_cum0 + l.amount_cents, v_gc);
  v_fee := round(v_owed::numeric * v_cum1 / v_gc) - round(v_owed::numeric * v_cum0 / v_gc);
  IF v_fee <= 0 THEN
    RETURN NULL;
  END IF;
  RETURN public._exos_journal_post(
    s.org_id, s.event_id, 'exos_gift_card_ledger', l.id::text, 'gc_refund_fee', l.created_at, coalesce(s.currency, c.currency),
    'Exos fee owed on the gift card part, handed back, order ' || s.session_id,
    jsonb_build_array(jsonb_build_object('a', 'organizer_payable', 'c', v_fee, 'm', 'Exos fee no longer owed'),
                      jsonb_build_object('a', 'exos_fee', 'c', -v_fee, 'm', 'Exos fee owed (gift card), returned')),
    s.session_id, v_cum1 - v_cum0);
END $$;
REVOKE ALL ON FUNCTION public._exos_journal_gc_refund_fee(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_journal_gc_refund_fee(bigint) TO service_role;

SELECT pg_temp.exos_patch_n('public.exos_journal_post_gift_card(bigint)',
  '/* exos: gc refund fee */',
  $o$      RETURN public._exos_journal_post(
        s.org_id, s.event_id, 'exos_gift_card_ledger', l.id::text, 'gc_refund',$o$,
  $n$      PERFORM public._exos_journal_gc_refund_fee(l.id);   /* exos: gc refund fee */ -- mig 20261111130000
      RETURN public._exos_journal_post(
        s.org_id, s.event_id, 'exos_gift_card_ledger', l.id::text, 'gc_refund',$n$, 1);

-- ===========================================================================
-- 4. The backfill: + the Stripe payouts
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_journal_backfill(uuid)',
  '/* exos: journal stripe payouts */',
  $o$  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;$o$,
  $n$  /* exos: journal stripe payouts */ -- mig 20261111130000
  FOR r IN SELECT payout_id FROM public.exos_stripe_org_payouts WHERE p_org IS NULL OR org_id = p_org ORDER BY created, payout_id LOOP
    PERFORM public.exos_journal_post_stripe_org_payout(r.payout_id);
  END LOOP;
  SELECT count(*) INTO v_after FROM public.exos_journal_entries WHERE p_org IS NULL OR org_id = p_org;$n$, 1);

-- ===========================================================================
-- 5. Sales tax by jurisdiction, read from the journal
-- ===========================================================================
-- Grouped by the event's venue (country, region, city, postal code from
-- venue_address), the tax rule (name and rate) and the source (online /
-- pos). Every tax amount is a journal sales tax line in [p_from, p_to) (and
-- of p_event): collected = the sale entries (orders, door tenders), refunded
-- = every other entry on the account (card refunds, refunds to a gift card,
-- door cash-outs and card refunds; a reversal counts back). An order's
-- amount is spread over its rates by the order's own tax split (the
-- disclosure lines, or a door order's lines; what they don't explain is
-- "Rate not recorded"), the remainder to the largest. So the net per org,
-- currency, event and period is exactly the journal's sales tax payable.
-- Taxable and order counts come from the orders dated in the period (online:
-- fulfilment; door: payment).
CREATE OR REPLACE FUNCTION public.exos_sales_tax_report(p_org uuid, p_from timestamptz DEFAULT NULL,
                                                        p_to timestamptz DEFAULT NULL, p_event uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_rows jsonb;
BEGIN
  IF p_org IS NULL OR NOT public._exos_journal_reader_ok(p_org) THEN
    RAISE EXCEPTION 'exos_sales_tax_report: not authorized' USING ERRCODE = '42501';
  END IF;
  /* exos: tax report from the journal */ -- mig 20261111130000
  WITH evall AS (   -- the org's events and their venue
    SELECT e.id,
           nullif(upper(btrim(coalesce(e.venue_address ->> 'country', ''))), '') AS country,
           nullif(btrim(coalesce(e.venue_address ->> 'region', '')), '') AS region,
           nullif(btrim(coalesce(e.venue_address ->> 'city', '')), '') AS city,
           nullif(btrim(coalesce(e.venue_address ->> 'postal', '')), '') AS postal
      FROM public.exos_events e
     WHERE e.org_id = p_org
  ), jt AS (   -- the journal's sales tax, per entry (credit − debit)
    SELECT e.id, e.event_id, e.currency, e.source_table, e.source_id, e.session_id,
           sum(l.credit_cents - l.debit_cents)::bigint AS tax
      FROM public.exos_journal_entries e JOIN public.exos_journal_lines l ON l.entry_id = e.id
     WHERE e.org_id = p_org AND l.org_id = p_org AND l.account = 'sales_tax_payable'
       AND (p_from IS NULL OR e.occurred_at >= p_from) AND (p_to IS NULL OR e.occurred_at < p_to)
       AND (p_event IS NULL OR e.event_id = p_event)
     GROUP BY e.id, e.event_id, e.currency, e.source_table, e.source_id, e.session_id
    HAVING sum(l.credit_cents - l.debit_cents) <> 0
  ), jk AS (   -- each entry's order: a checkout session, or a door order
    SELECT jt.*,
           jt.source_table IN ('exos_checkout_sessions', 'exos_pos_payments') AS collected,
           CASE WHEN jt.source_table IN ('exos_checkout_sessions', 'exos_order_refunds', 'exos_gift_card_ledger')
                THEN jt.session_id END AS sid,
           CASE jt.source_table
             WHEN 'exos_pos_payments' THEN (SELECT p.order_id FROM public.exos_pos_payments p WHERE p.id = jt.source_id::uuid)
             WHEN 'exos_pos_paid_outs' THEN (SELECT x.order_id FROM public.exos_pos_paid_outs x WHERE x.id = jt.source_id::uuid)
             WHEN 'exos_pos_reversals' THEN (SELECT rv.order_id FROM public.exos_pos_reversals rv WHERE rv.id = jt.source_id::uuid)
           END AS pos_order
      FROM jt
  ), so AS (   -- paid orders of the org's events (taxable and counts), any date
    SELECT s.session_id, s.event_id, upper(coalesce(s.currency, 'usd')) AS currency, coalesce(s.tax_cents, 0)::bigint AS tax,
           (coalesce(s.amount_cents, 0) + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0))::bigint AS value,
           coalesce(s.fulfilled_at, s.created_at) AS at
      FROM public.exos_checkout_sessions s JOIN evall ON evall.id = s.event_id
     WHERE s.org_id = p_org AND public._exos_journal_paid(s.status) AND s.free_kind IS NULL
       AND (p_event IS NULL OR s.event_id = p_event)
  ), sx AS (   -- the orders whose split is needed: the paid ones, and any the journal names
    SELECT so.session_id, so.tax, so.value FROM so
    UNION
    SELECT s.session_id, coalesce(s.tax_cents, 0)::bigint,
           (coalesce(s.amount_cents, 0) + coalesce(s.gift_card_cents, 0) - coalesce(s.donation_cents, 0))::bigint
      FROM public.exos_checkout_sessions s
     WHERE s.org_id = p_org AND s.session_id IN (SELECT jk.sid FROM jk WHERE jk.sid IS NOT NULL)
  ), sl AS (   -- per order and rate: tax and taxable base from the disclosure lines
    SELECT l.session_id, r.name AS tax_name, r.rate_percent::numeric AS rate,
           sum(l.tax_cents)::bigint AS tax, sum(l.line_total_cents - l.tax_cents)::bigint AS taxable
      FROM public.exos_price_disclosure_lines l
      JOIN sx ON sx.session_id = l.session_id
      LEFT JOIN public.exos_ticket_tiers tt ON l.kind = 'ticket' AND tt.id = l.item_id
      LEFT JOIN public.exos_event_addons ea ON l.kind = 'addon' AND ea.id = l.item_id
      LEFT JOIN public.exos_tax_rules r ON r.id = coalesce(tt.tax_rate_id, ea.tax_rate_id)
     WHERE coalesce(l.tax_cents, 0) <> 0 OR r.id IS NOT NULL
     GROUP BY l.session_id, r.name, r.rate_percent
  ), sg AS (   -- the order's groups, plus what the lines don't explain
    SELECT sl.session_id, sl.tax_name, sl.rate, sl.tax, sl.taxable FROM sl
    UNION ALL
    SELECT sx.session_id, NULL, NULL, sx.tax - coalesce(x.tax, 0),
           CASE WHEN x.session_id IS NULL THEN sx.value - sx.tax ELSE 0 END
      FROM sx LEFT JOIN (SELECT session_id, sum(tax) AS tax FROM sl GROUP BY session_id) x ON x.session_id = sx.session_id
     WHERE sx.tax - coalesce(x.tax, 0) <> 0 OR (x.session_id IS NULL AND sx.tax <> 0)
  ), po AS (   -- door orders: the share of each sale paid in money (a comp tender collects no tax)
    SELECT o.id, o.event_id, upper(coalesce(o.currency, 'usd')) AS currency, o.paid_at, o.total_cents::bigint AS total,
           coalesce((SELECT sum(p.amount_cents) FROM public.exos_pos_payments p
                      WHERE p.order_id = o.id AND p.method <> 'comp' AND p.status IN ('succeeded', 'refunded')), 0)::bigint AS paid
      FROM public.exos_pos_orders o JOIN evall ON evall.id = o.event_id
     WHERE o.org_id = p_org AND o.paid_at IS NOT NULL AND o.status IN ('paid', 'void', 'refunded') AND o.total_cents > 0
       AND (p_event IS NULL OR o.event_id = p_event)
  ), pgr AS (   -- a door order's rates (the split the journal's amounts are spread by)
    SELECT l.order_id, NULL::text AS tax_name, l.tax_rate_percent::numeric AS rate, sum(l.tax_cents)::bigint AS tax
      FROM public.exos_pos_order_lines l
     WHERE l.order_id IN (SELECT jk.pos_order FROM jk WHERE jk.pos_order IS NOT NULL)
     GROUP BY l.order_id, l.tax_rate_percent
  ), grp AS (   -- one split per journal entry: its order's groups (none: one "not recorded" group)
    SELECT jk.id, jk.event_id, jk.currency, jk.collected, jk.tax AS amt,
           CASE WHEN jk.sid IS NOT NULL THEN 'online' WHEN jk.pos_order IS NOT NULL THEN 'pos' ELSE 'other' END AS source,
           g.tax_name, g.rate, coalesce(g.w, 0) AS w
      FROM jk
      LEFT JOIN LATERAL (
        SELECT sg.tax_name, sg.rate, sg.tax AS w FROM sg WHERE jk.sid IS NOT NULL AND sg.session_id = jk.sid
        UNION ALL
        SELECT pgr.tax_name, pgr.rate, pgr.tax FROM pgr WHERE jk.pos_order IS NOT NULL AND pgr.order_id = jk.pos_order
      ) g ON true
  ), grw AS (
    SELECT grp.*, sum(grp.w) OVER (PARTITION BY grp.id) AS wt,
           row_number() OVER (PARTITION BY grp.id ORDER BY grp.w DESC, grp.tax_name NULLS LAST, grp.rate NULLS LAST) AS rk
      FROM grp
  ), gra AS (
    SELECT grw.*, CASE WHEN grw.wt = 0 THEN 0 ELSE (grw.amt * grw.w) / grw.wt END AS part FROM grw
  ), alloc AS (   -- the remainder (and a split with no weight) to the largest group
    SELECT gra.event_id, gra.currency, gra.tax_name, gra.rate, gra.source, gra.collected,
           gra.part + CASE WHEN gra.rk = 1 THEN gra.amt - sum(gra.part) OVER (PARTITION BY gra.id) ELSE 0 END AS tax
      FROM gra
  ), jrows AS (
    SELECT a.event_id, a.currency, a.tax_name, a.rate, a.source, 0::bigint AS orders, 0::bigint AS taxable,
           sum(CASE WHEN a.collected THEN a.tax ELSE 0 END)::bigint AS collected,
           sum(CASE WHEN a.collected THEN 0 ELSE -a.tax END)::bigint AS refunded
      FROM alloc a
     GROUP BY a.event_id, a.currency, a.tax_name, a.rate, a.source
  ), online_base AS (
    SELECT so.event_id, so.currency, g.tax_name, g.rate, 'online'::text AS source,
           count(DISTINCT so.session_id)::bigint AS orders, sum(g.taxable)::bigint AS taxable, 0::bigint AS collected,
           0::bigint AS refunded
      FROM so JOIN sg g ON g.session_id = so.session_id
     WHERE (p_from IS NULL OR so.at >= p_from) AND (p_to IS NULL OR so.at < p_to)
     GROUP BY so.event_id, so.currency, g.tax_name, g.rate
  ), pos_base AS (
    SELECT po.event_id, po.currency, NULL::text AS tax_name, l.tax_rate_percent::numeric AS rate, 'pos'::text AS source,
           count(DISTINCT po.id)::bigint AS orders,
           sum(((l.line_total_cents - l.tax_cents)::bigint * po.paid) / po.total)::bigint AS taxable,
           0::bigint AS collected, 0::bigint AS refunded
      FROM po JOIN public.exos_pos_order_lines l ON l.order_id = po.id
     WHERE po.paid > 0 AND (p_from IS NULL OR po.paid_at >= p_from) AND (p_to IS NULL OR po.paid_at < p_to)
     GROUP BY po.event_id, po.currency, l.tax_rate_percent
  ), allrows AS (
    SELECT * FROM jrows UNION ALL SELECT * FROM online_base UNION ALL SELECT * FROM pos_base
  ), g AS (
    SELECT ev.country, ev.region, ev.city, ev.postal, a.tax_name, a.rate, a.source, a.currency,
           sum(a.orders)::bigint AS orders, sum(a.taxable)::bigint AS taxable, sum(a.collected)::bigint AS collected,
           sum(a.refunded)::bigint AS refunded
      FROM allrows a LEFT JOIN evall ev ON ev.id = a.event_id
     GROUP BY ev.country, ev.region, ev.city, ev.postal, a.tax_name, a.rate, a.source, a.currency
    HAVING sum(a.collected) <> 0 OR sum(a.refunded) <> 0
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'country', g.country, 'region', g.region, 'city', g.city, 'postal_code', g.postal,
           'tax_name', g.tax_name, 'rate_percent', g.rate, 'source', g.source, 'currency', g.currency,
           'orders', g.orders, 'taxable_cents', g.taxable, 'tax_collected_cents', g.collected,
           'tax_refunded_cents', g.refunded, 'net_tax_cents', g.collected - g.refunded)
           ORDER BY g.currency, g.country NULLS LAST, g.region NULLS LAST, g.city NULLS LAST, g.postal NULLS LAST,
                    g.source, g.tax_name NULLS LAST, g.rate NULLS LAST), '[]'::jsonb)
    INTO v_rows FROM g;
  RETURN jsonb_build_object('org_id', p_org, 'event_id', p_event, 'from', p_from, 'to', p_to, 'rows', v_rows,
                            'computed_at', now());
END $$;
REVOKE ALL ON FUNCTION public.exos_sales_tax_report(uuid, timestamptz, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_sales_tax_report(uuid, timestamptz, timestamptz, uuid) TO authenticated, service_role;

-- ===========================================================================
-- 6. Post what's already there (the owed fee on refunds already back on a
--    gift card; payouts once recorded). Idempotent.
-- ===========================================================================
SELECT public._exos_journal_backfill(NULL);
