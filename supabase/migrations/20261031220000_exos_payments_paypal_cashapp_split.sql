-- ============================================================================
-- Migration 20261031220000 — Exos: PayPal / Venmo checkout, Cash App Pay,
--                            and "split with friends" (Venmo, restaurant-style)
--
-- Touches:  W: TABLE exos_checkout_sessions (+processor, +paypal_order_id,
--                 +payment_method)
--              TABLE exos_order_payments (+processor_fee_cents,
--                 +funding_source; provider CHECK)
--              TABLE exos_order_refunds (provider CHECK)
--              TABLE exos_disputes (+provider, generated from the id)
--              TABLE exos_org_payment_methods (new; owner / manager write,
--                 finance reads)
--              VIEW  exos_public_payment_methods (new; anon: does a published
--                 event's org take PayPal / Venmo)
--              VIEW  exos_order_money (replaced: PayPal's fee is the actual
--                 card fee; same columns, so replaying 20260929131000 works)
--              TABLE exos_paypal_org_remittances (new; what the operator paid
--                 an org out of the PayPal balance; service writes)
--              VIEW  exos_paypal_order_owed, exos_paypal_org_balances (new)
--              TABLE exos_group_splits, exos_group_split_shares (new; host only)
--              FUNCTION exos_record_payment, exos_record_refund (replaced:
--                 provider = the session's processor; signatures unchanged)
--              FUNCTION exos_paypal_capture_gate, exos_paypal_record_capture,
--                 exos_record_paypal_remittance (new, service role)
--              FUNCTION exos_bulk_create_transfers, exos_split_save,
--                 exos_split_get, exos_split_mark_paid, exos_split_nudged
--                 (new, authenticated)
--           R: exos_cart_holds, exos_tickets, exos_transfers,
--              exos_fulfill_checkout, exos_refund_checkout,
--              exos_record_price_charged, exos_create_transfer
-- Pre-reqs: 20260702123100 (payment ledger), 20260924205115 (latest
--           exos_record_refund), 20260929131000 (fee columns,
--           exos_order_money), 20261001101000 (exos_disputes),
--           20260929010000 (exos_transfers.claim_key),
--           20260927010000 (latest exos_create_transfer)
--
-- 1. PayPal as a second processor (operator, 2026-10-30), for Venmo. Funds
--    land on the PLATFORM's PayPal account (no Connect equivalent is used):
--      * a PayPal checkout is an exos_checkout_sessions row with processor
--        'paypal' and the PayPal order id; the session id is 'pp_' + 32 hex.
--        Pricing, holds, limits, the price-disclosure record and fulfilment
--        are the Stripe path's, unchanged (exos-checkout).
--      * ledger ids are prefixed so they fit the existing id CHECKs and can
--        never collide with Stripe's: payment_intent 'ppcap_<capture id>',
--        refund_id 'pprf_<refund id>' (a reversal: 'pprev_<id>'), dispute_id
--        'ppdsp_<id without dashes>'. exos_order_payments.provider /
--        exos_order_refunds.provider = 'paypal' (from the session, so the
--        Stripe callers don't change).
--      * exos_paypal_record_capture is the one place a capture lands (the
--        buyer's return and the webhook both call it; it locks the session,
--        so they serialize): amount + currency must match the order, then
--        the payment row, then exos_fulfill_checkout. It says when the
--        money must go back (sold out at fulfilment, amount mismatch); the
--        edge function refunds at PayPal with an idempotency key.
--      * The platform fee and fee rules work as on Stripe: the session's
--        application_fee_cents = Exos 3% + PayPal's fee ESTIMATE (the card-fee
--        slot), so the organizer gets exactly what a Stripe sale gives them.
--        PayPal's actual fee is processor_fee_cents on the payment.
--      * Paying organizers is NOT automated for PayPal money.
--        exos_paypal_order_owed says what each PayPal order owes its org
--        (net of refunds the way Stripe's reverse_transfer +
--        refund_application_fee splits them; nothing while a dispute is open;
--        nothing once one is lost). exos_paypal_org_balances totals it per org
--        less exos_paypal_org_remittances (what the operator paid out by hand).
--        Stripe's payout ledger (exos_org_payouts) is keyed to marketplace
--        orders and sends Stripe transfers, so PayPal money isn't put there.
-- 2. Cash App Pay (a Stripe method) and PayPal are per-org opt-ins in
--    exos_org_payment_methods (both default off; the platform has its own env
--    switches). exos_public_payment_methods lets the event page show the
--    PayPal / Venmo button only where it will work.
-- 3. Split with friends (KANBAN "Group buy: split with friends"): the host
--    buys every ticket in one normal checkout, then sends each friend a
--    ticket (an exos_create_transfer claim link) and a prefilled Venmo / Cash
--    App link to pay the HOST back. Exos never touches the friends' money:
--    "paid" is the host's checkbox. Send mode 'now' (default) transfers at
--    once; 'on_paid' waits for the checkbox. exos_bulk_create_transfers is
--    the all-or-nothing bulk transfer under it. A friend needs an email
--    (exos_create_transfer mails the claim link); the phone is optional and
--    only fills the host's text message. Rows are the host's own: org staff
--    don't read their friends' contact details.
--
-- Additive, re-run safe (IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF
-- EXISTS / guarded constraints). Prod apply needs operator OK.
-- ROLLBACK: restore exos_record_payment (20260702123100), exos_record_refund
--   (20260924205115) and exos_order_money (20260929131000); then DROP the new
--   functions, views and tables; the new columns can stay (defaults).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Sessions: which processor took the money.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS processor       text NOT NULL DEFAULT 'stripe',
  ADD COLUMN IF NOT EXISTS paypal_order_id text,
  ADD COLUMN IF NOT EXISTS payment_method  text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_processor_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_processor_chk CHECK (
        processor IN ('stripe', 'paypal')
        AND (paypal_order_id IS NULL OR (processor = 'paypal' AND paypal_order_id ~ '^[A-Z0-9]{8,40}$'))
        AND (payment_method IS NULL OR payment_method IN ('card', 'cashapp', 'paypal', 'venmo')));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS exos_checkout_sessions_paypal_order_uq
  ON public.exos_checkout_sessions (paypal_order_id) WHERE paypal_order_id IS NOT NULL;

COMMENT ON COLUMN public.exos_checkout_sessions.processor IS
  'Who took the money: stripe (default) or paypal (PayPal Checkout incl. Venmo, platform account). mig 20261031220000.';
COMMENT ON COLUMN public.exos_checkout_sessions.paypal_order_id IS
  'PayPal Orders v2 order id of a processor = paypal session. mig 20261031220000.';
COMMENT ON COLUMN public.exos_checkout_sessions.payment_method IS
  'How the buyer paid, when known: card, cashapp (Stripe), paypal or venmo (PayPal). mig 20261031220000.';

-- ---------------------------------------------------------------------------
-- 2. Ledger rows carry the processor (provider) and PayPal's own fee.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_order_payments
  ADD COLUMN IF NOT EXISTS processor_fee_cents int,
  ADD COLUMN IF NOT EXISTS funding_source      text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_order_payments_provider_chk') THEN
    ALTER TABLE public.exos_order_payments
      ADD CONSTRAINT exos_order_payments_provider_chk CHECK (
        provider IN ('stripe', 'paypal')
        AND (processor_fee_cents IS NULL OR processor_fee_cents >= 0)
        AND (funding_source IS NULL OR funding_source IN ('card', 'cashapp', 'paypal', 'venmo'))
        AND (provider <> 'paypal' OR payment_intent IS NULL OR payment_intent ~ '^ppcap_[A-Za-z0-9]{6,64}$'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_order_refunds_provider_chk') THEN
    ALTER TABLE public.exos_order_refunds
      ADD CONSTRAINT exos_order_refunds_provider_chk CHECK (
        provider IN ('stripe', 'paypal')
        AND (provider <> 'paypal' OR refund_id IS NULL OR refund_id ~ '^pp(rf|rev)_[A-Za-z0-9]{6,64}$'));
  END IF;
END $$;
COMMENT ON COLUMN public.exos_order_payments.processor_fee_cents IS
  'The processor''s actual fee when it isn''t Stripe (PayPal: seller_receivable_breakdown.paypal_fee). mig 20261031220000.';

-- Disputes: the processor follows from the id (PayPal ids are 'ppdsp_…').
ALTER TABLE public.exos_disputes
  ADD COLUMN IF NOT EXISTS provider text
  GENERATED ALWAYS AS (CASE WHEN dispute_id LIKE 'ppdsp\_%' THEN 'paypal' ELSE 'stripe' END) STORED;

-- ---------------------------------------------------------------------------
-- 3. exos_record_payment / exos_record_refund: provider from the session.
--    Same signatures, grants and behavior for Stripe sessions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_payment(
  p_session_id       text,
  p_payment_intent   text,
  p_amount_cents     int,
  p_status           text,
  p_charge_id        text  DEFAULT NULL,
  p_currency         text  DEFAULT 'usd',
  p_failure_reason   text  DEFAULT NULL,
  p_provider_event_id text DEFAULT NULL,
  p_meta             jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s    public.exos_checkout_sessions%ROWTYPE;
  v_id uuid;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_payment: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('pending','processing','succeeded','failed','canceled') THEN
    RAISE EXCEPTION 'exos_record_payment: invalid status %', p_status;
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_payment: unknown session %', p_session_id;
  END IF;

  INSERT INTO public.exos_order_payments (
    session_id, org_id, event_id, buyer_uid, provider, payment_intent, charge_id,
    amount_cents, currency, status, failure_reason, provider_event_id, meta
  ) VALUES (
    p_session_id, s.org_id, s.event_id, s.buyer_uid, coalesce(s.processor, 'stripe'), p_payment_intent, p_charge_id,
    p_amount_cents, lower(coalesce(p_currency, 'usd')), p_status,
    left(p_failure_reason, 500), p_provider_event_id, p_meta
  )
  ON CONFLICT (provider, payment_intent) WHERE payment_intent IS NOT NULL
  DO UPDATE SET
    status            = EXCLUDED.status,
    charge_id         = COALESCE(EXCLUDED.charge_id, public.exos_order_payments.charge_id),
    amount_cents      = EXCLUDED.amount_cents,
    failure_reason    = EXCLUDED.failure_reason,
    provider_event_id = EXCLUDED.provider_event_id,
    meta              = COALESCE(EXCLUDED.meta, public.exos_order_payments.meta)
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_payment(text, text, int, text, text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_payment(text, text, int, text, text, text, text, text, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.exos_record_refund(
  p_session_id       text,
  p_refund_id        text,
  p_amount_cents     int,
  p_status           text,
  p_payment_intent   text  DEFAULT NULL,
  p_reason           text  DEFAULT NULL,
  p_currency         text  DEFAULT 'usd',
  p_provider_event_id text DEFAULT NULL,
  p_meta             jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_pay      public.exos_order_payments%ROWTYPE;
  v_partial  boolean := false;
  v_id       uuid;
  v_refunded int;
  v_paid     int;
  v_provider text;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_refund: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('pending','succeeded','failed','canceled') THEN
    RAISE EXCEPTION 'exos_record_refund: invalid status %', p_status;
  END IF;
  IF p_refund_id IS NULL OR btrim(p_refund_id) = '' THEN
    RAISE EXCEPTION 'exos_record_refund: refund id is required';
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_refund: unknown session %', p_session_id;
  END IF;
  v_provider := coalesce(s.processor, 'stripe');

  IF p_payment_intent IS NOT NULL THEN
    SELECT * INTO v_pay FROM public.exos_order_payments
     WHERE provider = v_provider AND payment_intent = p_payment_intent;
  END IF;
  IF v_pay.id IS NULL THEN
    SELECT * INTO v_pay FROM public.exos_order_payments
     WHERE session_id = p_session_id AND status = 'succeeded'
     ORDER BY amount_cents DESC LIMIT 1;
  END IF;
  IF v_pay.id IS NOT NULL AND p_amount_cents < v_pay.amount_cents THEN
    v_partial := true;
  END IF;

  INSERT INTO public.exos_order_refunds (
    payment_id, session_id, org_id, provider, refund_id, amount_cents, currency,
    status, reason, is_partial, provider_event_id, meta
  ) VALUES (
    v_pay.id, p_session_id, s.org_id, v_provider, p_refund_id, p_amount_cents,
    lower(coalesce(p_currency, 'usd')), p_status, left(p_reason, 500), v_partial,
    p_provider_event_id, p_meta
  )
  ON CONFLICT (refund_id) WHERE refund_id IS NOT NULL
  DO UPDATE SET
    status            = EXCLUDED.status,
    amount_cents      = EXCLUDED.amount_cents,
    is_partial        = EXCLUDED.is_partial,
    reason            = EXCLUDED.reason,
    provider_event_id = EXCLUDED.provider_event_id,
    meta              = COALESCE(EXCLUDED.meta, public.exos_order_refunds.meta)
  RETURNING id INTO v_id;

  IF s.status <> 'refunded' THEN
    SELECT COALESCE(SUM(amount_cents), 0) INTO v_refunded
      FROM public.exos_order_refunds WHERE session_id = p_session_id AND status = 'succeeded';
    v_paid := s.amount_cents;
    IF v_refunded > 0 THEN
      UPDATE public.exos_checkout_sessions
         SET status = CASE WHEN v_refunded >= v_paid THEN 'refunded' ELSE 'partially_refunded' END
       WHERE session_id = p_session_id;
    END IF;
  END IF;

  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_refund(text, text, int, text, text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_refund(text, text, int, text, text, text, text, text, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Per-org payment methods (opt-in; the platform env switches come first).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_org_payment_methods (
  org_id          uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  paypal_enabled  boolean NOT NULL DEFAULT false,
  cashapp_enabled boolean NOT NULL DEFAULT false,
  updated_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS exos_org_payment_methods_touch ON public.exos_org_payment_methods;
CREATE TRIGGER exos_org_payment_methods_touch BEFORE UPDATE ON public.exos_org_payment_methods
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_org_payment_methods ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_org_payment_methods FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.exos_org_payment_methods TO authenticated;
GRANT ALL ON public.exos_org_payment_methods TO service_role;
DROP POLICY IF EXISTS exos_org_payment_methods_sel ON public.exos_org_payment_methods;
CREATE POLICY exos_org_payment_methods_sel ON public.exos_org_payment_methods FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
DROP POLICY IF EXISTS exos_org_payment_methods_ins ON public.exos_org_payment_methods;
CREATE POLICY exos_org_payment_methods_ins ON public.exos_org_payment_methods FOR INSERT TO authenticated
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
DROP POLICY IF EXISTS exos_org_payment_methods_upd ON public.exos_org_payment_methods;
CREATE POLICY exos_org_payment_methods_upd ON public.exos_org_payment_methods FOR UPDATE TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (public.exos_has_org_role(org_id, ARRAY['owner','manager']));
COMMENT ON TABLE public.exos_org_payment_methods IS
  'Org opt-ins for extra payment methods: PayPal / Venmo (platform PayPal account) and Cash App Pay (Stripe). Owner / manager write, finance reads. mig 20261031220000.';

-- Buyers: does this published event's org take PayPal (and so Venmo)?
CREATE OR REPLACE VIEW public.exos_public_payment_methods
WITH (security_barrier = true)
AS
SELECT e.id AS event_id, coalesce(m.paypal_enabled, false) AS paypal
  FROM public.exos_events e
  LEFT JOIN public.exos_org_payment_methods m ON m.org_id = e.org_id
 WHERE e.status = 'published';
REVOKE ALL ON public.exos_public_payment_methods FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_public_payment_methods TO anon, authenticated, service_role;
COMMENT ON VIEW public.exos_public_payment_methods IS
  'Per published event: the org takes PayPal / Venmo. The platform switch (EXOS_PAYPAL_*) is checked at checkout. mig 20261031220000.';

-- ---------------------------------------------------------------------------
-- 5. exos_order_money: PayPal's fee is the actual "card" fee. Exactly the
--    same columns (20260929131000 replays CREATE OR REPLACE over it, and a
--    view can't lose a column); the processor is on the session row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_order_money WITH (security_invoker = true) AS
  SELECT s.session_id,
         s.org_id,
         s.event_id,
         s.status,
         s.currency,
         s.created_at,
         s.fulfilled_at,
         s.amount_cents                        AS gross_cents,
         coalesce(s.tax_cents, 0)              AS tax_cents,
         s.application_fee_cents,
         s.exos_fee_cents,
         s.card_fee_est_cents,
         coalesce(p.stripe_fee_cents, p.processor_fee_cents) AS card_fee_actual_cents,
         s.fee_bps,
         s.fee_free,
         s.amount_cents - s.application_fee_cents AS organizer_net_cents,
         p.net_cents                           AS platform_net_cents,
         coalesce(r.refunded_cents, 0)         AS refunded_cents,
         p.payment_intent,
         p.transfer_id,
         p.balance_txn_id
    FROM public.exos_checkout_sessions s
    LEFT JOIN LATERAL (
      SELECT op.stripe_fee_cents, op.processor_fee_cents, op.net_cents, op.payment_intent, op.transfer_id, op.balance_txn_id
        FROM public.exos_order_payments op
       WHERE op.session_id = s.session_id AND op.status = 'succeeded'
       ORDER BY op.created_at DESC
       LIMIT 1) p ON true
    LEFT JOIN LATERAL (
      SELECT sum(rf.amount_cents)::int AS refunded_cents
        FROM public.exos_order_refunds rf
       WHERE rf.session_id = s.session_id AND rf.status = 'succeeded') r ON true
   WHERE current_user NOT IN ('anon', 'authenticated')
      OR public.exos_has_org_role(s.org_id, ARRAY['owner','manager','finance']);
REVOKE ALL ON public.exos_order_money FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_order_money TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. PayPal capture: the gate before capturing, and where a capture lands.
-- ---------------------------------------------------------------------------
-- May this PayPal order be captured now? Only a pending PayPal session whose
-- seat hold is still live (or that never needed one: a capacity-bypass
-- voucher). An order approved after its hold lapsed isn't captured, so the
-- buyer is never charged for seats that went back on sale; the session is
-- marked expired. Returns { ok, session_id, status, reason? }.
CREATE OR REPLACE FUNCTION public.exos_paypal_capture_gate(p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s       public.exos_checkout_sessions%ROWTYPE;
  v_holds int;
  v_live  int;
BEGIN
  IF p_order_id IS NULL OR p_order_id !~ '^[A-Z0-9]{8,40}$' THEN
    RAISE EXCEPTION 'exos_paypal_capture_gate: bad order id' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE paypal_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_paypal_capture_gate: unknown order' USING ERRCODE = 'P0002';
  END IF;
  IF s.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'session_id', s.session_id, 'status', s.status, 'reason', 'not_pending');
  END IF;
  SELECT count(*), count(*) FILTER (WHERE status = 'active' AND expires_at > now())
    INTO v_holds, v_live
    FROM public.exos_cart_holds WHERE checkout_session_id = s.session_id;
  IF v_holds > 0 AND v_live = 0 THEN
    UPDATE public.exos_checkout_sessions SET status = 'expired', failure_reason = 'reservation expired before payment'
     WHERE session_id = s.session_id;
    RETURN jsonb_build_object('ok', false, 'session_id', s.session_id, 'status', 'expired', 'reason', 'hold_expired');
  END IF;
  RETURN jsonb_build_object('ok', true, 'session_id', s.session_id, 'status', s.status);
END $$;
REVOKE ALL ON FUNCTION public.exos_paypal_capture_gate(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_paypal_capture_gate(text) TO service_role;

-- Record a PayPal capture and fulfil on COMPLETED. Idempotent on the capture
-- (the payment row is unique per provider + id; fulfilment is keyed on the
-- session), so the buyer's return, the webhook and the reconcile sweep can all
-- send it. p_status is PayPal's capture status:
--   COMPLETED           -> payment succeeded; amount + currency must equal the
--                          order's, then exos_fulfill_checkout
--   PENDING             -> payment processing (no tickets until COMPLETED)
--   DECLINED / DENIED / FAILED -> payment failed; a pending session fails
--                          and its holds go back; tickets already issued are
--                          voided (exos_refund_checkout)
-- A later PENDING never downgrades a succeeded payment. Returns
--   { session_id, session_status, payment_status, needs_refund, tickets }
-- needs_refund: money arrived but the order can't stand (sold out at
-- fulfilment, wrong amount) and no refund is on file yet.
CREATE OR REPLACE FUNCTION public.exos_paypal_record_capture(
  p_order_id          text,
  p_capture_id        text,
  p_status            text,
  p_amount_cents      int,
  p_currency          text,
  p_fee_cents         int   DEFAULT NULL,
  p_funding_source    text  DEFAULT NULL,
  p_provider_event_id text  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s         public.exos_checkout_sessions%ROWTYPE;
  v_ref     text;
  v_st      text := upper(btrim(coalesce(p_status, '')));
  v_pay_st  text;
  v_cur     text := lower(btrim(coalesce(p_currency, '')));
  v_prev    text;
  v_ids     uuid[];
  v_fund    text := nullif(lower(btrim(coalesce(p_funding_source, ''))), '');
  v_refund  boolean := false;
  v_has_rf  boolean;
BEGIN
  IF p_order_id IS NULL OR p_order_id !~ '^[A-Z0-9]{8,40}$' THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: bad order id' USING ERRCODE = '22023';
  END IF;
  IF p_capture_id IS NULL OR p_capture_id !~ '^[A-Za-z0-9]{6,64}$' THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: bad capture id' USING ERRCODE = '22023';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 0 OR v_cur !~ '^[a-z]{3}$' THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: bad amount' USING ERRCODE = '22023';
  END IF;
  IF p_fee_cents IS NOT NULL AND p_fee_cents < 0 THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: negative fee' USING ERRCODE = '22023';
  END IF;
  IF v_fund IS NOT NULL AND v_fund NOT IN ('paypal', 'venmo', 'card') THEN v_fund := NULL; END IF;
  v_pay_st := CASE v_st
    WHEN 'COMPLETED' THEN 'succeeded'
    WHEN 'PENDING' THEN 'processing'
    WHEN 'DECLINED' THEN 'failed' WHEN 'DENIED' THEN 'failed' WHEN 'FAILED' THEN 'failed'
    ELSE NULL END;
  IF v_pay_st IS NULL THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: unhandled capture status %', p_status USING ERRCODE = '22023';
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE paypal_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: unknown order' USING ERRCODE = 'P0002';
  END IF;
  IF s.processor <> 'paypal' THEN
    RAISE EXCEPTION 'exos_paypal_record_capture: not a PayPal session' USING ERRCODE = '22023';
  END IF;
  v_ref := 'ppcap_' || p_capture_id;

  SELECT status INTO v_prev FROM public.exos_order_payments WHERE provider = 'paypal' AND payment_intent = v_ref;
  IF NOT (v_prev = 'succeeded' AND v_pay_st = 'processing') THEN
    PERFORM public.exos_record_payment(s.session_id, v_ref, p_amount_cents, v_pay_st, NULL, v_cur,
      CASE WHEN v_pay_st = 'failed' THEN 'paypal capture ' || lower(v_st) END,
      left(p_provider_event_id, 100),
      jsonb_build_object('paypal_order_id', p_order_id));
    UPDATE public.exos_order_payments
       SET processor_fee_cents = coalesce(p_fee_cents, processor_fee_cents),
           funding_source      = coalesce(v_fund, funding_source),
           net_cents           = CASE WHEN p_fee_cents IS NOT NULL AND s.application_fee_cents IS NOT NULL
                                      THEN s.application_fee_cents - p_fee_cents ELSE net_cents END,
           fees_recorded_at    = CASE WHEN p_fee_cents IS NOT NULL THEN coalesce(fees_recorded_at, now()) ELSE fees_recorded_at END
     WHERE provider = 'paypal' AND payment_intent = v_ref;
  END IF;

  UPDATE public.exos_checkout_sessions
     SET payment_intent = coalesce(payment_intent, v_ref),
         payment_method = coalesce(v_fund, payment_method, 'paypal')
   WHERE session_id = s.session_id;

  IF v_pay_st = 'succeeded' THEN
    IF p_amount_cents <> s.amount_cents OR v_cur <> lower(s.currency) THEN
      -- Money we didn't ask for: never fulfil it; give it back.
      UPDATE public.exos_checkout_sessions
         SET status = 'failed', failure_reason = 'paid amount does not match the order'
       WHERE session_id = s.session_id AND status = 'pending';
      UPDATE public.exos_cart_holds SET status = 'released', released_at = now()
       WHERE checkout_session_id = s.session_id AND status = 'active';
    ELSE
      v_ids := public.exos_fulfill_checkout(s.session_id);
      BEGIN
        PERFORM public.exos_record_price_charged(s.session_id, p_amount_cents, v_cur);
      EXCEPTION WHEN others THEN
        RAISE WARNING 'exos_paypal_record_capture: price_charged not recorded for %: %', s.session_id, SQLERRM;
      END;
    END IF;
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = s.session_id;
    SELECT EXISTS (SELECT 1 FROM public.exos_order_refunds r
                    WHERE r.session_id = s.session_id AND r.status IN ('pending', 'succeeded'))
      INTO v_has_rf;
    -- Paid but not issued: failed at fulfilment, the wrong amount, or the
    -- session had already expired (exos_fulfill_checkout only takes pending).
    v_refund := s.status IN ('failed', 'expired') AND NOT v_has_rf;
  ELSIF v_pay_st = 'failed' THEN
    IF s.status = 'pending' THEN
      UPDATE public.exos_checkout_sessions
         SET status = 'failed', failure_reason = 'paypal capture ' || lower(v_st)
       WHERE session_id = s.session_id;
      UPDATE public.exos_cart_holds SET status = 'released', released_at = now()
       WHERE checkout_session_id = s.session_id AND status = 'active';
    ELSIF s.status IN ('fulfilled', 'partially_refunded') THEN
      -- Issued on an earlier COMPLETED that PayPal then denied: no money, no tickets.
      PERFORM public.exos_refund_checkout(s.session_id, 'paypal capture ' || lower(v_st));
    END IF;
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = s.session_id;
  END IF;

  RETURN jsonb_build_object(
    'session_id', s.session_id,
    'session_status', s.status,
    'payment_status', coalesce((SELECT status FROM public.exos_order_payments WHERE provider = 'paypal' AND payment_intent = v_ref), v_pay_st),
    'needs_refund', v_refund,
    'tickets', coalesce(array_length(s.ticket_ids, 1), 0));
END $$;
REVOKE ALL ON FUNCTION public.exos_paypal_record_capture(text, text, text, int, text, int, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_paypal_record_capture(text, text, text, int, text, int, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. What PayPal orders owe their orgs (payouts are by hand, not automated).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_paypal_org_remittances (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  amount_cents int  NOT NULL CHECK (amount_cents > 0),
  currency     text NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  reference    text NOT NULL CHECK (char_length(reference) BETWEEN 1 AND 200),
  method       text NOT NULL DEFAULT 'manual' CHECK (method IN ('paypal_payout', 'bank', 'stripe_transfer', 'manual')),
  paid_at      timestamptz NOT NULL DEFAULT now(),
  note         text CHECK (note IS NULL OR char_length(note) <= 500),
  recorded_by  uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, reference)
);
DROP TRIGGER IF EXISTS exos_paypal_org_remittances_touch ON public.exos_paypal_org_remittances;
CREATE TRIGGER exos_paypal_org_remittances_touch BEFORE UPDATE ON public.exos_paypal_org_remittances
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
ALTER TABLE public.exos_paypal_org_remittances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_paypal_org_remittances FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_paypal_org_remittances TO authenticated;
GRANT ALL ON public.exos_paypal_org_remittances TO service_role;
DROP POLICY IF EXISTS exos_paypal_org_remittances_sel ON public.exos_paypal_org_remittances;
CREATE POLICY exos_paypal_org_remittances_sel ON public.exos_paypal_org_remittances FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
COMMENT ON TABLE public.exos_paypal_org_remittances IS
  'Money the operator paid an org out of the platform PayPal balance (by hand; not automated). Service role writes (exos_record_paypal_remittance); owner / manager / finance read. mig 20261031220000.';

-- Per PayPal order: what the org is owed. Refunds split like a Stripe
-- reverse_transfer with refund_application_fee: the org gives back the
-- refunded amount less its share of the application fee. An open dispute
-- holds the order (held_cents); a lost one owes nothing.
CREATE OR REPLACE VIEW public.exos_paypal_order_owed WITH (security_invoker = true) AS
  SELECT x.session_id, x.org_id, x.event_id, x.currency, x.gross_cents, x.application_fee_cents,
         x.refunded_cents, x.dispute_status,
         CASE WHEN x.state = 'owed' THEN x.owed_cents ELSE 0 END AS owed_cents,
         CASE WHEN x.state = 'held' THEN x.owed_cents ELSE 0 END AS held_cents,
         x.state, x.fulfilled_at
    FROM (
      SELECT s.session_id, s.org_id, s.event_id, lower(s.currency) AS currency,
             s.amount_cents AS gross_cents,
             coalesce(s.application_fee_cents, 0) AS application_fee_cents,
             coalesce(r.refunded, 0) AS refunded_cents,
             s.dispute_status, s.fulfilled_at,
             greatest(0,
               (s.amount_cents - coalesce(s.application_fee_cents, 0))
               - (coalesce(r.refunded, 0)
                  - CASE WHEN s.amount_cents > 0
                         THEN round(coalesce(s.application_fee_cents, 0)::numeric * coalesce(r.refunded, 0) / s.amount_cents)::int
                         ELSE 0 END)) AS owed_cents,
             CASE WHEN s.dispute_status = 'lost' THEN 'lost'
                  WHEN s.dispute_status IS NOT NULL AND s.dispute_status NOT IN ('won', 'warning_closed') THEN 'held'
                  ELSE 'owed' END AS state
        FROM public.exos_checkout_sessions s
        LEFT JOIN LATERAL (
          SELECT sum(rf.amount_cents)::int AS refunded FROM public.exos_order_refunds rf
           WHERE rf.session_id = s.session_id AND rf.status = 'succeeded') r ON true
       WHERE s.processor = 'paypal'
         AND EXISTS (SELECT 1 FROM public.exos_order_payments p
                      WHERE p.session_id = s.session_id AND p.provider = 'paypal' AND p.status = 'succeeded')
    ) x
   WHERE current_user NOT IN ('anon', 'authenticated')
      OR public.exos_has_org_role(x.org_id, ARRAY['owner','manager','finance']);
REVOKE ALL ON public.exos_paypal_order_owed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_paypal_order_owed TO authenticated, service_role;

CREATE OR REPLACE VIEW public.exos_paypal_org_balances WITH (security_invoker = true) AS
  SELECT o.org_id, o.currency,
         sum(o.owed_cents)::int  AS owed_cents,
         sum(o.held_cents)::int  AS held_cents,
         coalesce(max(m.paid), 0)::int AS remitted_cents,
         (sum(o.owed_cents) - coalesce(max(m.paid), 0))::int AS balance_cents,
         count(*)::int AS orders
    FROM public.exos_paypal_order_owed o
    LEFT JOIN LATERAL (
      SELECT sum(r.amount_cents) AS paid FROM public.exos_paypal_org_remittances r
       WHERE r.org_id = o.org_id AND r.currency = o.currency) m ON true
   GROUP BY o.org_id, o.currency;
REVOKE ALL ON public.exos_paypal_org_balances FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_paypal_org_balances TO authenticated, service_role;
COMMENT ON VIEW public.exos_paypal_org_balances IS
  'Per org + currency: what PayPal orders owe the org, held by open disputes, already paid out by hand, and the balance due. Owner / manager / finance. mig 20261031220000.';

-- The operator records a payout made outside Exos. Idempotent on reference.
CREATE OR REPLACE FUNCTION public.exos_record_paypal_remittance(
  p_org_id       uuid,
  p_amount_cents int,
  p_reference    text,
  p_currency     text DEFAULT 'usd',
  p_method       text DEFAULT 'manual',
  p_note         text DEFAULT NULL,
  p_paid_at      timestamptz DEFAULT NULL,
  p_recorded_by  uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'exos_record_paypal_remittance: amount must be positive' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_paypal_org_remittances AS t
    (org_id, amount_cents, currency, reference, method, note, paid_at, recorded_by)
  VALUES (p_org_id, p_amount_cents, lower(coalesce(p_currency, 'usd')), btrim(p_reference),
          coalesce(p_method, 'manual'), p_note, coalesce(p_paid_at, now()), p_recorded_by)
  ON CONFLICT (org_id, reference) DO UPDATE SET note = coalesce(EXCLUDED.note, t.note)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_paypal_remittance(uuid, int, text, text, text, text, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_paypal_remittance(uuid, int, text, text, text, text, timestamptz, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Split with friends.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_group_splits (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id      uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  session_id    text NOT NULL UNIQUE REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  host_uid      uuid NOT NULL,
  venmo_handle  text CHECK (venmo_handle IS NULL OR venmo_handle ~ '^[A-Za-z0-9_-]{2,30}$'),
  cashapp_tag   text CHECK (cashapp_tag IS NULL OR cashapp_tag ~ '^[A-Za-z][A-Za-z0-9_]{0,20}$'),
  send_mode     text NOT NULL DEFAULT 'now' CHECK (send_mode IN ('now', 'on_paid')),
  note          text CHECK (note IS NULL OR char_length(note) <= 100),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (venmo_handle IS NOT NULL OR cashapp_tag IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_group_splits_host_idx ON public.exos_group_splits (host_uid);
CREATE INDEX IF NOT EXISTS exos_group_splits_org_idx ON public.exos_group_splits (org_id);

CREATE TABLE IF NOT EXISTS public.exos_group_split_shares (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  split_id     uuid NOT NULL REFERENCES public.exos_group_splits (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL,
  ticket_id    uuid NOT NULL UNIQUE,
  friend_name  text NOT NULL CHECK (char_length(friend_name) BETWEEN 1 AND 80),
  friend_email text NOT NULL CHECK (friend_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND char_length(friend_email) <= 254),
  friend_phone text CHECK (friend_phone IS NULL OR friend_phone ~ '^\+?[0-9]{7,15}$'),
  amount_cents int  NOT NULL CHECK (amount_cents >= 0),
  paid         boolean NOT NULL DEFAULT false,
  paid_at      timestamptz,
  transfer_id  uuid,
  nudge_count  int NOT NULL DEFAULT 0,
  nudged_at    timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_group_split_shares_split_idx ON public.exos_group_split_shares (split_id);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_group_splits','exos_group_split_shares'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- The host's own rows only (and platform admins). Writes go through the RPCs.
ALTER TABLE public.exos_group_splits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_group_split_shares ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_group_splits, public.exos_group_split_shares FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_group_splits, public.exos_group_split_shares TO authenticated;
GRANT ALL ON public.exos_group_splits, public.exos_group_split_shares TO service_role;
DROP POLICY IF EXISTS exos_group_splits_sel ON public.exos_group_splits;
CREATE POLICY exos_group_splits_sel ON public.exos_group_splits FOR SELECT TO authenticated
  USING (host_uid = auth.uid() OR public.exos_is_admin());
DROP POLICY IF EXISTS exos_group_split_shares_sel ON public.exos_group_split_shares;
CREATE POLICY exos_group_split_shares_sel ON public.exos_group_split_shares FOR SELECT TO authenticated
  USING (public.exos_is_admin() OR EXISTS (
    SELECT 1 FROM public.exos_group_splits g WHERE g.id = split_id AND g.host_uid = auth.uid()));

-- Bulk transfer: one exos_create_transfer per item, all or nothing (any
-- error undoes every transfer in the call). Items: [{ ticket_id, email,
-- name? }], at most 50. Returns [{ ticket_id, transfer_id, claim_key }]: the
-- caller is the sender, who may share the link (as exos_transfer_claim_key).
CREATE OR REPLACE FUNCTION public.exos_bulk_create_transfers(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  it    jsonb;
  v_tid uuid;
  v_tr  uuid;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_bulk_create_transfers: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 50 THEN
    RAISE EXCEPTION 'exos_bulk_create_transfers: send 1 to 50 items' USING ERRCODE = '22023';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_tid := (it ->> 'ticket_id')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'exos_bulk_create_transfers: bad ticket id' USING ERRCODE = '22023';
    END;
    v_tr := public.exos_create_transfer(v_tid, it ->> 'email', it ->> 'name');
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'ticket_id', v_tid, 'transfer_id', v_tr,
      'claim_key', (SELECT t.claim_key FROM public.exos_transfers t WHERE t.id = v_tr)));
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_bulk_create_transfers(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_bulk_create_transfers(jsonb) TO authenticated, service_role;

-- The host's split for one of their orders: the split, each share with its
-- claim link path (/claim/<id>?k=<key>) and the transfer's state.
CREATE OR REPLACE FUNCTION public.exos_split_get(p_session_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  g   public.exos_group_splits%ROWTYPE;
  s   public.exos_checkout_sessions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_split_get: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND OR s.buyer_uid IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'exos_split_get: not your order' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO g FROM public.exos_group_splits WHERE session_id = p_session_id;
  RETURN jsonb_build_object(
    'session_id', s.session_id,
    'event_id', s.event_id,
    'amount_cents', s.amount_cents,
    'quantity', s.quantity,
    'currency', s.currency,
    'split', CASE WHEN g.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', g.id, 'venmo_handle', g.venmo_handle, 'cashapp_tag', g.cashapp_tag,
      'send_mode', g.send_mode, 'note', g.note, 'created_at', g.created_at) END,
    'tickets', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'ticket_id', t.id, 'tier_name', t.tier_name, 'status', t.status,
               'mine', t.owner_id = auth.uid(), 'pending_transfer', t.pending_transfer_id IS NOT NULL)
             ORDER BY t.created_at, t.id)
        FROM public.exos_tickets t WHERE t.order_ref = s.session_id), '[]'::jsonb),
    'shares', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', sh.id, 'ticket_id', sh.ticket_id, 'name', sh.friend_name, 'email', sh.friend_email,
               'phone', sh.friend_phone, 'amount_cents', sh.amount_cents, 'paid', sh.paid, 'paid_at', sh.paid_at,
               'nudge_count', sh.nudge_count, 'nudged_at', sh.nudged_at,
               'transfer_id', sh.transfer_id, 'transfer_status', tr.status,
               'claim_path', CASE WHEN tr.id IS NOT NULL AND tr.status = 'pending'
                                  THEN '/claim/' || tr.id || '?k=' || tr.claim_key END)
             ORDER BY sh.created_at, sh.id)
        FROM public.exos_group_split_shares sh
        LEFT JOIN public.exos_transfers tr ON tr.id = sh.transfer_id
       WHERE sh.split_id = g.id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_split_get(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_split_get(text) TO authenticated, service_role;

-- Create the split for one of the host's paid orders, or add friends to it.
--   p_shares: [{ ticket_id, name, email, phone?, amount_cents }] (1 to 49)
-- Each ticket must be the host's, from this order, active, not in transfer and
-- not already in a share. The amounts can't add up to more than the order.
-- Send mode 'now' transfers the new shares' tickets at once (all or nothing).
CREATE OR REPLACE FUNCTION public.exos_split_save(
  p_session_id text,
  p_shares     jsonb,
  p_venmo      text DEFAULT NULL,
  p_cashapp    text DEFAULT NULL,
  p_send_mode  text DEFAULT 'now',
  p_note       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  s        public.exos_checkout_sessions%ROWTYPE;
  g        public.exos_group_splits%ROWTYPE;
  it       jsonb;
  v_tid    uuid;
  v_amt    int;
  v_total  bigint;
  v_phone  text;
  v_email  text;
  v_venmo  text := nullif(regexp_replace(btrim(coalesce(p_venmo, '')), '^@', ''), '');
  v_cash   text := nullif(regexp_replace(btrim(coalesce(p_cashapp, '')), '^\$', ''), '');
  v_items  jsonb := '[]'::jsonb;
  v_res    jsonb;
  r        jsonb;
  v_new    uuid[] := '{}';
  v_sid    uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_split_save: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_send_mode NOT IN ('now', 'on_paid') THEN
    RAISE EXCEPTION 'exos_split_save: send mode is now or on_paid' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_shares) IS DISTINCT FROM 'array' OR jsonb_array_length(p_shares) = 0 OR jsonb_array_length(p_shares) > 49 THEN
    RAISE EXCEPTION 'exos_split_save: add 1 to 49 friends' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND OR s.buyer_uid IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'exos_split_save: not your order' USING ERRCODE = '42501';
  END IF;
  IF s.status NOT IN ('fulfilled', 'partially_refunded') THEN
    RAISE EXCEPTION 'exos_split_save: only a paid order can be split' USING ERRCODE = '22023';
  END IF;
  -- Adding friends later keeps the handles already on the split.
  SELECT * INTO g FROM public.exos_group_splits WHERE session_id = s.session_id FOR UPDATE;
  v_venmo := coalesce(v_venmo, g.venmo_handle);
  v_cash := coalesce(v_cash, g.cashapp_tag);
  IF v_venmo IS NULL AND v_cash IS NULL THEN
    RAISE EXCEPTION 'exos_split_save: add your Venmo or Cash App so friends can pay you' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_group_splits AS t (org_id, event_id, session_id, host_uid, venmo_handle, cashapp_tag, send_mode, note)
  VALUES (s.org_id, s.event_id, s.session_id, v_uid, v_venmo, v_cash, p_send_mode, nullif(left(btrim(coalesce(p_note, '')), 100), ''))
  ON CONFLICT (session_id) DO UPDATE SET
    venmo_handle = coalesce(EXCLUDED.venmo_handle, t.venmo_handle),
    cashapp_tag  = coalesce(EXCLUDED.cashapp_tag, t.cashapp_tag),
    send_mode    = EXCLUDED.send_mode,
    note         = coalesce(EXCLUDED.note, t.note)
  RETURNING * INTO g;

  FOR it IN SELECT * FROM jsonb_array_elements(p_shares) LOOP
    BEGIN
      v_tid := (it ->> 'ticket_id')::uuid;
      v_amt := (it ->> 'amount_cents')::int;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'exos_split_save: each friend needs a ticket and a whole-cent amount' USING ERRCODE = '22023';
    END;
    IF v_amt IS NULL OR v_amt < 0 OR v_amt > s.amount_cents THEN
      RAISE EXCEPTION 'exos_split_save: amount out of range' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.exos_tickets t
                    WHERE t.id = v_tid AND t.order_ref = s.session_id AND t.owner_id = v_uid
                      AND t.status = 'active' AND t.pending_transfer_id IS NULL) THEN
      RAISE EXCEPTION 'exos_split_save: ticket % isn''t yours to send', v_tid USING ERRCODE = '22023';
    END IF;
    v_email := lower(btrim(coalesce(it ->> 'email', '')));
    v_phone := nullif(regexp_replace(coalesce(it ->> 'phone', ''), '[^0-9+]', '', 'g'), '');
    INSERT INTO public.exos_group_split_shares (split_id, org_id, ticket_id, friend_name, friend_email, friend_phone, amount_cents)
    VALUES (g.id, s.org_id, v_tid, btrim(coalesce(it ->> 'name', '')), v_email, v_phone, v_amt)
    RETURNING id INTO v_sid;
    v_new := v_new || v_sid;
    v_items := v_items || jsonb_build_array(jsonb_build_object('ticket_id', v_tid, 'email', v_email, 'name', btrim(it ->> 'name')));
  END LOOP;

  SELECT sum(sh.amount_cents) INTO v_total FROM public.exos_group_split_shares sh WHERE sh.split_id = g.id;
  IF v_total > s.amount_cents THEN
    RAISE EXCEPTION 'exos_split_save: the shares add up to more than you paid' USING ERRCODE = '22023';
  END IF;

  IF g.send_mode = 'now' THEN
    v_res := public.exos_bulk_create_transfers(v_items);
    FOR r IN SELECT * FROM jsonb_array_elements(v_res) LOOP
      UPDATE public.exos_group_split_shares SET transfer_id = (r ->> 'transfer_id')::uuid
       WHERE ticket_id = (r ->> 'ticket_id')::uuid AND id = ANY (v_new);
    END LOOP;
  END IF;

  RETURN public.exos_split_get(p_session_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_split_save(text, jsonb, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_split_save(text, jsonb, text, text, text, text) TO authenticated, service_role;

-- The host ticks a friend paid (or not). In 'on_paid' mode the first tick
-- sends that friend's ticket.
CREATE OR REPLACE FUNCTION public.exos_split_mark_paid(p_share_id uuid, p_paid boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  sh   public.exos_group_split_shares%ROWTYPE;
  g    public.exos_group_splits%ROWTYPE;
  v_res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_split_mark_paid: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO sh FROM public.exos_group_split_shares WHERE id = p_share_id FOR UPDATE;
  IF FOUND THEN SELECT * INTO g FROM public.exos_group_splits WHERE id = sh.split_id; END IF;
  IF NOT FOUND OR g.host_uid IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'exos_split_mark_paid: not your split' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_group_split_shares
     SET paid = coalesce(p_paid, false),
         paid_at = CASE WHEN coalesce(p_paid, false) THEN coalesce(paid_at, now()) ELSE NULL END
   WHERE id = p_share_id;
  -- A ticket still waiting (on_paid, or added before a switch to 'now') goes now.
  IF coalesce(p_paid, false) AND sh.transfer_id IS NULL THEN
    v_res := public.exos_bulk_create_transfers(jsonb_build_array(jsonb_build_object(
      'ticket_id', sh.ticket_id, 'email', sh.friend_email, 'name', sh.friend_name)));
    UPDATE public.exos_group_split_shares SET transfer_id = (v_res -> 0 ->> 'transfer_id')::uuid WHERE id = p_share_id;
  END IF;
  RETURN public.exos_split_get(g.session_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_split_mark_paid(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_split_mark_paid(uuid, boolean) TO authenticated, service_role;

-- The host sent a reminder from their own phone: count it (Exos sends nothing).
CREATE OR REPLACE FUNCTION public.exos_split_nudged(p_share_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_split_nudged: not authenticated' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_group_split_shares sh
     SET nudge_count = least(sh.nudge_count + 1, 1000), nudged_at = now()
    FROM public.exos_group_splits g
   WHERE sh.id = p_share_id AND g.id = sh.split_id AND g.host_uid = auth.uid() AND NOT sh.paid
  RETURNING sh.nudge_count INTO v_n;
  IF v_n IS NULL THEN
    RAISE EXCEPTION 'exos_split_nudged: not your unpaid share' USING ERRCODE = '42501';
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_split_nudged(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_split_nudged(uuid) TO authenticated, service_role;
