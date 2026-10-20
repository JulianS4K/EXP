-- ============================================================================
-- Migration 20261021160000 — Exos (Bridge / D4): ledger P1 fixes (usage
--                            simulation 2026-10-19, round 2 "Money")
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_order_payments (+stripe_fee_currency, +exchange_rate)
--              TABLE exos_stripe_balance_txns (+exchange_rate)
--              TABLE exos_refund_requests (+application_fee_refunded)
--              FUNCTION exos_record_payment_fee_currency (new, service role)
--              VIEW exos_order_fee_details (new, security_invoker)
--              FUNCTION exos_pos_settlement_summary (replaced: fee per order
--                at its sale time)
--              FUNCTION exos_refund_order_reserved (replaced: + lost disputes)
--              FUNCTION exos_refund_lost_dispute_cents (new, internal)
--              FUNCTION _exos_dispute_rank (new, internal)
--           P: exos_refund_claim, _exos_refund_ask_state,
--              exos_event_refund_asks, exos_refund_preview,
--              exos_record_dispute, exos_record_dispute_event
-- Pre-reqs: 20260929131000 (fee columns, exos_order_money), 20260926040000
--           (organizer refunds), 20261015090000 (refund asks), 20260929074000
--           (POS), 20260929062000 (exos_org_fee_bps), 20261001101000
--           (disputes, balance-txn snapshot).
--
-- A. Card fee on the Money tab. The organizer pays the card-fee part of the
--    application fee fixed at checkout (application fee - Exos fee); Stripe's
--    actual fee is what the PLATFORM paid. exos_order_fee_details returns
--    card_fee_charged_cents, and the Money tab shows that (gross - Exos fee -
--    card fee = net). exos_order_money.card_fee_actual_cents stays for
--    platform-side views.
-- B. EUR on a USD-settling platform. The balance transaction of an EUR charge
--    is in USD (exchange_rate set) and its fee is USD. The payment row now
--    keeps the fee's own currency (stripe_fee_currency) and the rate;
--    net_cents (application fee - Stripe fee) is in stripe_fee_currency. The
--    daily reconcile compares amounts in the settlement currency (the
--    snapshot keeps exchange_rate), so a correct EUR order isn't flagged.
-- C. POS: the Exos fee on a POS sale is the org's rate at the sale's paid_at
--    (exos_org_fee_bps(org, paid_at)), per order, not today's rate.
-- D. Lost dispute: the lost amount is gone (Stripe took it back), so it counts
--    as already returned in exos_refund_order_reserved; the refund preview,
--    the refund list, "refund everyone" and the claim all see less (usually
--    nothing) left to refund. The preview also reports lost_dispute_cents.
-- E. Refund asks: an ask's amount is re-read (the ticket's rest, capped at
--    what's left on the order), and a per-ticket refund with no amount takes
--    the ticket's rest capped at what's left on the order, so an order-level
--    partial refund after the ask doesn't make the ask refund fail or show a
--    stale amount.
-- F. Disputes: a status can't move backwards when Stripe's events arrive out
--    of order (needs_response after under_review); closed stays closed.
-- G. EXOS_REFUND_KEEP_PLATFORM_FEE: exos-refund records per request whether
--    the application fee was refunded; exos_order_fee_details sums the refunds
--    that kept it (refunded_fee_kept_cents), and the Money tab's net after refunds
--    takes those out in full (the organizer covered the whole refund).
--
-- Nothing here changes what is charged. Re-run safe (IF NOT EXISTS, CREATE OR
-- REPLACE, marker-guarded patches); nothing is dropped. Apply BEFORE deploying
-- the edge functions of this change (exos-reconcile-stripe reads the new
-- columns). D4 authors; applying
-- to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  -- Pasted through a browser the patch text can carry CRLF line ends; compare without CRs.
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  p_marker := replace(p_marker, chr(13), ''); p_old := replace(p_old, chr(13), ''); p_new := replace(p_new, chr(13), '');
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

-- ---------------------------------------------------------------------------
-- B. Fee currency + exchange rate
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_order_payments
  ADD COLUMN IF NOT EXISTS stripe_fee_currency text,
  ADD COLUMN IF NOT EXISTS exchange_rate       numeric;
ALTER TABLE public.exos_stripe_balance_txns
  ADD COLUMN IF NOT EXISTS exchange_rate numeric;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_order_payments_fee_currency_chk') THEN
    ALTER TABLE public.exos_order_payments
      ADD CONSTRAINT exos_order_payments_fee_currency_chk CHECK (
        (stripe_fee_currency IS NULL OR stripe_fee_currency ~ '^[a-z]{3}$')
        AND (exchange_rate IS NULL OR exchange_rate > 0));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_order_payments.stripe_fee_currency IS
  'Currency of stripe_fee_cents and net_cents: the balance transaction''s (the platform''s settlement currency), which differs from currency when Stripe converted the charge. NULL on rows recorded before mig 20261021160000. mig 20261021160000.';
COMMENT ON COLUMN public.exos_order_payments.exchange_rate IS
  'balance_transaction.exchange_rate: charge currency -> settlement currency (NULL when no conversion). mig 20261021160000.';
COMMENT ON COLUMN public.exos_order_payments.net_cents IS
  'What the platform keeps on the charge: application fee - Stripe fee, in stripe_fee_currency (the application fee converted at exchange_rate). mig 20260929131000, 20261021160000.';
COMMENT ON COLUMN public.exos_stripe_balance_txns.exchange_rate IS
  'Stripe''s rate from the charge / refund currency to this transaction''s currency (NULL when none). mig 20261021160000.';

-- The fee's currency and Stripe's rate, recorded next to the other actuals
-- (stripe-webhook / exos-reconcile-checkouts call it right after
-- exos_record_payment_fees, whose signature is unchanged). Service role only;
-- a NULL never erases a value. Returns true when a payment row was updated.
CREATE OR REPLACE FUNCTION public.exos_record_payment_fee_currency(
  p_payment_intent      text,
  p_stripe_fee_currency text    DEFAULT NULL,
  p_exchange_rate       numeric DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cur text := lower(nullif(btrim(coalesce(p_stripe_fee_currency, '')), ''));
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_payment_fee_currency: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_payment_intent IS NULL OR p_payment_intent !~ '^[A-Za-z0-9_]{1,255}$' THEN
    RAISE EXCEPTION 'exos_record_payment_fee_currency: malformed Stripe id' USING ERRCODE = '22023';
  END IF;
  IF (v_cur IS NOT NULL AND v_cur !~ '^[a-z]{3}$') OR coalesce(p_exchange_rate, 1) <= 0 THEN
    RAISE EXCEPTION 'exos_record_payment_fee_currency: bad currency or exchange rate' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_order_payments
     SET stripe_fee_currency = coalesce(v_cur, stripe_fee_currency),
         exchange_rate       = coalesce(p_exchange_rate, exchange_rate),
         updated_at          = now()
   WHERE provider = 'stripe' AND payment_intent = p_payment_intent;
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_payment_fee_currency(text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_payment_fee_currency(text, text, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- G. Whether a refund returned the application fee
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_refund_requests
  ADD COLUMN IF NOT EXISTS application_fee_refunded boolean;
COMMENT ON COLUMN public.exos_refund_requests.application_fee_refunded IS
  'The Stripe refund was sent with refund_application_fee = this (exos-refund; false under EXOS_REFUND_KEEP_PLATFORM_FEE). NULL = before mig 20261021160000, read as true (the default). mig 20261021160000.';

-- ---------------------------------------------------------------------------
-- A + B + G. exos_order_fee_details: next to exos_order_money
-- ---------------------------------------------------------------------------
-- A separate view, not new columns on exos_order_money: replaying mig
-- 20260929131000 recreates that view with its own columns (CREATE OR
-- REPLACE VIEW can't drop columns). Same access rule: security_invoker and
-- org owner / manager / finance only.
CREATE OR REPLACE VIEW public.exos_order_fee_details WITH (security_invoker = true) AS
  SELECT s.session_id,
         s.org_id,
         s.event_id,
         -- What the organizer paid for card processing: fixed at checkout.
         coalesce(s.application_fee_cents - s.exos_fee_cents, s.card_fee_est_cents) AS card_fee_charged_cents,
         p.stripe_fee_currency,
         p.exchange_rate,
         coalesce(r.fee_kept_cents, 0) AS refunded_fee_kept_cents
    FROM public.exos_checkout_sessions s
    LEFT JOIN LATERAL (
      SELECT op.stripe_fee_currency, op.exchange_rate
        FROM public.exos_order_payments op
       WHERE op.session_id = s.session_id AND op.status = 'succeeded'
       ORDER BY op.created_at DESC
       LIMIT 1) p ON true
    LEFT JOIN LATERAL (
      SELECT sum(rf.amount_cents)::int AS fee_kept_cents
        FROM public.exos_order_refunds rf
       WHERE rf.session_id = s.session_id AND rf.status = 'succeeded'
         AND EXISTS (SELECT 1 FROM public.exos_refund_requests rq
                      WHERE rq.stripe_refund_id = rf.refund_id AND rq.application_fee_refunded = false)) r ON true
   WHERE current_user NOT IN ('anon', 'authenticated')
      OR public.exos_has_org_role(s.org_id, ARRAY['owner','manager','finance']);
REVOKE ALL ON public.exos_order_fee_details FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_fee_details TO authenticated, service_role;

COMMENT ON VIEW public.exos_order_fee_details IS
  'Per checkout, beside exos_order_money: the card fee charged to the organizer (application fee - Exos fee; gross - Exos fee - card fee = net), the currency / rate of Stripe''s actual fee (exos_order_money.card_fee_actual_cents, platform side), and the succeeded refunds that kept the application fee (EXOS_REFUND_KEEP_PLATFORM_FEE). Org owner / manager / finance only. mig 20261021160000.';

-- ---------------------------------------------------------------------------
-- C. POS settlement: the Exos rate at each sale's time
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_pos_settlement_summary(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org uuid; v_currency text; v_bps int; r jsonb;
BEGIN
  SELECT org_id, coalesce(currency, 'usd') INTO v_org, v_currency FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_pos_settlement_summary: unknown event' USING ERRCODE = '42501';
  END IF;
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','finance'])
          OR (auth.uid() IS NULL AND coalesce(auth.jwt() ->> 'role', '') = 'service_role')) THEN
    RAISE EXCEPTION 'exos_pos_settlement_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  -- Today's rate: only reported (fee_bps_now). The fee itself is per order at
  -- its sale time, like an online order's fee is fixed at checkout.
  v_bps := public.exos_org_fee_bps(v_org, now());

  WITH o AS (
    SELECT id, total_cents, public.exos_org_fee_bps(v_org, coalesce(paid_at, created_at)) AS bps
      FROM public.exos_pos_orders WHERE event_id = p_event_id AND status = 'paid'
  ), pay AS (
    SELECT p.order_id,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'cash'), 0)::bigint AS cash,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'card'), 0)::bigint AS card,
           coalesce(sum(p.amount_cents) FILTER (WHERE p.method = 'comp'), 0)::bigint AS comp,
           coalesce(sum(p.tip_cents)    FILTER (WHERE p.method = 'cash'), 0)::bigint AS tip_cash,
           coalesce(sum(p.tip_cents)    FILTER (WHERE p.method = 'card'), 0)::bigint AS tip_card
      FROM public.exos_pos_payments p JOIN o ON o.id = p.order_id
     WHERE p.status = 'succeeded'
     GROUP BY p.order_id
  ), ln AS (
    SELECT l.order_id,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'ticket'), 0)::bigint AS ticket,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'bar'), 0)::bigint    AS bar,
           coalesce(sum(l.line_total_cents) FILTER (WHERE l.category = 'merch'), 0)::bigint  AS merch,
           coalesce(sum(l.tax_cents), 0)::bigint                                             AS tax
      FROM public.exos_pos_order_lines l JOIN o ON o.id = l.order_id
     GROUP BY l.order_id
  ), per0 AS (
    SELECT o.id, o.bps, o.total_cents::bigint AS total, coalesce(ln.ticket, 0) AS ticket, coalesce(ln.bar, 0) AS bar,
           coalesce(ln.merch, 0) AS merch, coalesce(ln.tax, 0) AS tax,
           coalesce(pay.cash, 0) AS cash, coalesce(pay.card, 0) AS card, coalesce(pay.comp, 0) AS comp,
           coalesce(pay.tip_cash, 0) AS tip_cash, coalesce(pay.tip_card, 0) AS tip_card
      FROM o LEFT JOIN ln ON ln.order_id = o.id LEFT JOIN pay ON pay.order_id = o.id
  ), per AS (
    SELECT per0.*,
           CASE WHEN total > 0 THEN (ticket * card) / total ELSE 0 END AS card_ticket
      FROM per0
  ), tot AS (
    -- sum(bigint) is numeric: cast back so the fee below is integer math.
    SELECT count(*) AS orders,
           coalesce(sum(ticket), 0)::bigint AS ticket, coalesce(sum(bar), 0)::bigint AS bar,
           coalesce(sum(merch), 0)::bigint AS merch, coalesce(sum(tax), 0)::bigint AS tax,
           coalesce(sum(cash), 0)::bigint AS cash, coalesce(sum(card), 0)::bigint AS card,
           coalesce(sum(comp), 0)::bigint AS comp, coalesce(sum(tip_cash), 0)::bigint AS tip_cash,
           coalesce(sum(tip_card), 0)::bigint AS tip_card,
           coalesce(sum(card_ticket), 0)::bigint AS card_ticket,
           -- The Exos fee, order by order at the rate of its sale time.
           coalesce(sum(CASE WHEN card_ticket > 0 AND bps > 0 THEN (card_ticket * bps + 5000) / 10000 ELSE 0 END), 0)::bigint AS fee,
           min(bps) AS bps_min, max(bps) AS bps_max
      FROM per
  ), promo AS (
    SELECT coalesce(jsonb_agg(jsonb_build_object('promoter_id', x.promoter_id, 'tickets', x.qty, 'base_cents', x.base)
                              ORDER BY x.promoter_id), '[]'::jsonb) AS rows
      FROM (SELECT l.promoter_id, sum(l.quantity) AS qty,
                   sum(CASE WHEN per.total > 0
                            THEN ((l.line_total_cents - l.tax_cents)::bigint * (per.cash + per.card)) / per.total
                            ELSE 0 END)::bigint AS base
              FROM public.exos_pos_order_lines l JOIN per ON per.id = l.order_id
             WHERE l.category = 'ticket' AND l.promoter_id IS NOT NULL
             GROUP BY l.promoter_id) x
  ), dr AS (
    SELECT count(*) FILTER (WHERE status = 'open') AS open_drawers,
           count(*) FILTER (WHERE status = 'closed') AS closed_drawers,
           coalesce(sum(open_float_cents) FILTER (WHERE status = 'closed'), 0) AS float_cents,
           coalesce(sum(expected_cents), 0) AS expected, coalesce(sum(counted_cents), 0) AS counted,
           coalesce(sum(variance_cents), 0) AS variance
      FROM public.exos_pos_drawer_sessions WHERE event_id = p_event_id
  ), misc AS (
    SELECT (SELECT count(*) FROM public.exos_pos_orders WHERE event_id = p_event_id AND status = 'open') AS open_orders,
           (SELECT count(*) FROM public.exos_pos_tabs WHERE event_id = p_event_id AND status = 'open') AS open_tabs
  )
  SELECT jsonb_build_object(
           'event_id', p_event_id, 'org_id', v_org, 'currency', v_currency,
           -- The rate the sales were charged at (null when it changed between
           -- them: fee-free window ended mid-event); fee_bps_now is today's.
           'fee_bps', CASE WHEN tot.orders = 0 THEN v_bps
                           WHEN tot.bps_min = tot.bps_max THEN tot.bps_min END,
           'fee_bps_now', v_bps,
           'orders', tot.orders, 'open_orders', misc.open_orders, 'open_tabs', misc.open_tabs,
           'gross', jsonb_build_object('ticket', tot.ticket, 'bar', tot.bar, 'merch', tot.merch,
                                       'total', tot.ticket + tot.bar + tot.merch),
           'tax_cents', tot.tax,
           'tenders', jsonb_build_object('cash', tot.cash, 'card', tot.card, 'comp', tot.comp),
           'tips', jsonb_build_object('cash', tot.tip_cash, 'card', tot.tip_card, 'total', tot.tip_cash + tot.tip_card),
           'card_ticket_cents', tot.card_ticket,
           'exos_fee_cents', tot.fee,
           'organizer_net_cents', tot.cash + tot.card - tot.fee,
           'promoters', promo.rows,
           'drawers', jsonb_build_object('open', dr.open_drawers, 'closed', dr.closed_drawers,
                                         'float_cents', dr.float_cents, 'expected_cents', dr.expected,
                                         'counted_cents', dr.counted, 'variance_cents', dr.variance),
           'computed_at', now())
    INTO r
    FROM tot, promo, dr, misc;
  RETURN r;
END $function$;

-- ---------------------------------------------------------------------------
-- D. Lost disputes count as money already returned
-- ---------------------------------------------------------------------------
-- What a lost dispute took back on the order: the exos_disputes rows (mig
-- 20261001101000), or, for a dispute recorded only on the session (the
-- fallback recorder), the whole order.
CREATE OR REPLACE FUNCTION public.exos_refund_lost_dispute_cents(p_session_id text)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce(
           (SELECT sum(coalesce(d.amount_cents, cs.amount_cents))::int
              FROM public.exos_disputes d
             WHERE d.session_id = p_session_id AND d.status = 'lost'),
           CASE WHEN cs.dispute_status = 'lost' THEN cs.amount_cents END,
           0)
    FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_session_id;
$$;
REVOKE ALL ON FUNCTION public.exos_refund_lost_dispute_cents(text) FROM PUBLIC, anon, authenticated;

-- Everything already refunded or reserved against the order, and what a lost
-- dispute took back (mig 20261021160000): nothing of that can be refunded.
CREATE OR REPLACE FUNCTION public.exos_refund_order_reserved(p_session_id text)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT (coalesce((SELECT sum(r.amount_cents) FROM public.exos_refund_requests r
                     WHERE r.session_id = p_session_id
                       AND r.status IN ('claimed', 'pending', 'succeeded')), 0)
        + coalesce((SELECT sum(o.amount_cents) FROM public.exos_order_refunds o
                     WHERE o.session_id = p_session_id
                       AND o.status IN ('pending', 'succeeded')
                       AND NOT EXISTS (SELECT 1 FROM public.exos_refund_requests r
                                        WHERE r.stripe_refund_id = o.refund_id)), 0)
        + coalesce(public.exos_refund_lost_dispute_cents(p_session_id), 0))::int;
$$;
REVOKE ALL ON FUNCTION public.exos_refund_order_reserved(text) FROM PUBLIC, anon, authenticated;

SELECT pg_temp.exos_patch_n('public.exos_refund_preview(text)', '/* lost dispute */',
  $o$    'refundable_cents', v_left,
$o$,
  $n$    'refundable_cents', v_left,
    'lost_dispute_cents', coalesce(public.exos_refund_lost_dispute_cents(p_session_id), 0), /* lost dispute */
$n$, 1);

-- ---------------------------------------------------------------------------
-- E. Refund asks and per-ticket refunds: capped at what's left on the order
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_refund_claim(uuid, text, text, jsonb, integer, boolean, text, text)',
  '/* ticket rest capped */',
  $o$        v_amt := st.share_cents - st.allocated_cents;
$o$,
  $n$        -- The ticket's rest, but never more than the order still has (an
        -- order-level partial isn't allocated to tickets). /* ticket rest capped */
        v_amt := least(st.share_cents - st.allocated_cents, v_left - v_total);
$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_refund_ask_state(uuid)', '/* order left */',
  $o$    v_share := greatest(coalesce(st.share_cents, 0) - coalesce(st.allocated_cents, 0), 0);
$o$,
  $n$    v_share := least(greatest(coalesce(st.share_cents, 0) - coalesce(st.allocated_cents, 0), 0),
                     greatest(coalesce(s.amount_cents, 0) - public.exos_refund_order_reserved(s.session_id), 0)); /* order left */
$n$, 1);

-- An open ask shows what refunding it would refund now (re-read), not the
-- amount at the time of asking.
SELECT pg_temp.exos_patch_n('public.exos_event_refund_asks(uuid)', '/* ask amount now */',
  $o$           a.reason, a.amount_cents, a.currency,$o$,
  $n$           a.reason,
           CASE WHEN a.status = 'open' /* ask amount now */
                THEN coalesce((public._exos_refund_ask_state(a.ticket_id) ->> 'amount_cents')::int, a.amount_cents)
                ELSE a.amount_cents END,
           a.currency,$n$, 1);

-- ---------------------------------------------------------------------------
-- F. Dispute status never moves backwards
-- ---------------------------------------------------------------------------
-- Stripe's dispute lifecycle, in order. Unknown statuses rank 0 (they never
-- override a known one).
CREATE OR REPLACE FUNCTION public._exos_dispute_rank(p_status text)
RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE lower(coalesce(p_status, ''))
           WHEN 'warning_needs_response' THEN 1
           WHEN 'warning_under_review'   THEN 2
           WHEN 'needs_response'         THEN 3
           WHEN 'under_review'           THEN 4
           WHEN 'won'                    THEN 9
           WHEN 'lost'                   THEN 9
           WHEN 'warning_closed'         THEN 9
           WHEN 'prevented'              THEN 9
           ELSE 0 END
$$;
REVOKE ALL ON FUNCTION public._exos_dispute_rank(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_dispute_rank(text) TO authenticated, service_role;

SELECT pg_temp.exos_patch_n('public.exos_record_dispute(text, text, text, text, integer, text)', '/* dispute rank */',
  $o$  -- Same dispute already closed: keep the final state.
  IF s.dispute_id = p_dispute_id AND s.dispute_status = ANY (v_final) AND NOT (v_new = ANY (v_final)) THEN$o$,
  $n$  -- Same dispute already closed, or further along (Stripe's events arrive
  -- out of order): keep the stored state. /* dispute rank */
  IF s.dispute_id = p_dispute_id
     AND public._exos_dispute_rank(v_new) < public._exos_dispute_rank(s.dispute_status) THEN$n$, 1);

SELECT pg_temp.exos_patch_n(
  'public.exos_record_dispute_event(text, text, text, text, integer, text, text, text, integer, text, timestamp with time zone, boolean, boolean, jsonb)',
  '/* dispute rank */',
  $o$  v_status := CASE WHEN v_found AND d.status = ANY (v_final) AND NOT (v_new = ANY (v_final)) THEN d.status ELSE v_new END;$o$,
  $n$  -- ... and never steps back to an earlier status. /* dispute rank */
  v_status := CASE WHEN v_found AND public._exos_dispute_rank(v_new) < public._exos_dispute_rank(d.status)
                   THEN d.status ELSE v_new END;$n$, 1);
