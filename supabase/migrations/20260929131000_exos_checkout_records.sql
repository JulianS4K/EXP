-- ============================================================================
-- Migration 20260929131000 — Exos (Bridge / D4): checkout records — ad click
--                            ids per checkout, and the fee split per order
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_checkout_sessions (+ad_ids, +consent_marketing,
--              +client_ip_hash, +user_agent, +application_fee_cents,
--              +exos_fee_cents, +card_fee_est_cents, +fee_bps, +fee_free)
--              TABLE exos_order_payments (+stripe_fee_cents, +net_cents,
--              +transfer_id, +balance_txn_id, +application_fee_id,
--              +application_fee_cents, +fees_recorded_at)
--              FUNCTION _exos_ad_ids_ok (new, CHECK helper)
--              FUNCTION exos_record_payment_fees (new, service role only)
--              VIEW exos_order_money (new, security_invoker)
--           R: exos_order_refunds, exos_has_org_role
-- Pre-reqs: 20260924223000 (attribution columns), 20260702123100 (payment
--           ledger), 20260616230000 (tax_cents).
--
-- A. Ad click ids (marketing audit, "top 3 small fixes" #3). Checkout kept
--    only fbclid + UTM + cart_origin (attribution, mig 20260924223000). Now
--    exos-checkout also stores, per checkout:
--      * ad_ids: gclid, gbraid, wbraid, ttclid, rdt_cid, ScCid, twclid,
--        msclkid, fbclid from the landing URL, plus the browser ids fbp /
--        fbc (Meta cookies) and ga_client_id (from _ga), which the SPA reads
--        only with marketing consent. Sanitized by
--        supabase/functions/_shared/adIds.ts; the CHECK below repeats the
--        rule (known keys, [A-Za-z0-9._-]{1,256} values).
--      * consent_marketing: the visitor's consent at checkout
--        (granted / denied / unknown).
--      * client_ip_hash: the request IP, salted SHA-256 (same salt and
--        function as the guest rate limit, _shared/guest.ts); never the IP.
--      * user_agent: the request's User-Agent, at most 512 chars.
--    These are for a later server-side conversions feed (Meta CAPI, Google
--    Ads, TikTok Events API). Readable exactly like attribution: the buyer's
--    own rows and org owner / manager / finance (exos_checkout_sel). anon has
--    no access to the table.
--
-- B. Fee split per order (money audit §4 gap #1). The application fee, the
--    Exos part, the card-fee estimate, Stripe's actual fee, the organizer's
--    net and the transfer id lived only in Stripe.
--      * exos_checkout_sessions gets the split exos-checkout computed when it
--        created the Stripe session (_shared/platformFee.ts checkoutFeeSplit):
--        application_fee_cents = exos_fee_cents + card_fee_est_cents, fee_bps
--        (the Exos rate applied) and fee_free (the org was in its fee-free
--        window).
--      * exos_order_payments gets what Stripe actually did, written after
--        fulfilment by stripe-webhook (best effort, never failing it) and
--        backfilled by exos-reconcile-checkouts, through
--        exos_record_payment_fees: stripe_fee_cents (balance transaction
--        fee), net_cents (what the platform keeps: application fee - Stripe
--        fee), transfer_id, balance_txn_id, application_fee_id.
--      * exos_order_money: one row per checkout with gross, tax, application
--        fee, Exos fee, card fee (estimate and actual), organizer net
--        (gross - application fee) and succeeded refunds. Org owner /
--        manager / finance only.
--
-- Nothing here changes what is charged, fulfilment or its idempotency.
-- Re-run safe (IF NOT EXISTS, named constraints guarded, CREATE OR REPLACE).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. Ad ids on the checkout session
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS ad_ids            jsonb,
  ADD COLUMN IF NOT EXISTS consent_marketing text,
  ADD COLUMN IF NOT EXISTS client_ip_hash    text,
  ADD COLUMN IF NOT EXISTS user_agent        text;

-- Same rule as _shared/adIds.ts: an object of known keys with opaque
-- [A-Za-z0-9._-]{1,256} string values (the cookie and GA ids fit it too).
CREATE OR REPLACE FUNCTION public._exos_ad_ids_ok(p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p IS NULL OR (
    jsonb_typeof(p) = 'object'
    AND length(p::text) <= 4000
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_each(p) e
       WHERE e.key <> ALL (ARRAY['gclid','gbraid','wbraid','ttclid','rdt_cid','ScCid','twclid',
                                 'msclkid','fbclid','fbp','fbc','ga_client_id'])
          OR jsonb_typeof(e.value) <> 'string'
          OR length(e.value #>> '{}') NOT BETWEEN 1 AND 256
          OR (e.value #>> '{}') !~ '^[A-Za-z0-9._-]+$'
    )
  )
$$;
-- A CHECK helper (pure): whoever writes the table needs it (service role,
-- definer functions); same grants as _exos_store_content_ok.
REVOKE ALL ON FUNCTION public._exos_ad_ids_ok(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_ad_ids_ok(jsonb) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_ad_ids_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_ad_ids_chk CHECK (public._exos_ad_ids_ok(ad_ids));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_consent_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_consent_chk
      CHECK (consent_marketing IS NULL OR consent_marketing IN ('granted','denied','unknown'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_ip_hash_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_ip_hash_chk
      CHECK (client_ip_hash IS NULL OR client_ip_hash ~ '^[0-9a-f]{64}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_user_agent_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_user_agent_chk
      CHECK (user_agent IS NULL OR length(user_agent) <= 512);
  END IF;
END $$;

COMMENT ON COLUMN public.exos_checkout_sessions.ad_ids IS
  'Ad click ids (gclid, gbraid, wbraid, ttclid, rdt_cid, ScCid, twclid, msclkid, fbclid) and browser ids (fbp, fbc, ga_client_id; read only with consent) at checkout. _shared/adIds.ts. mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.consent_marketing IS
  'Marketing-cookie consent at checkout: granted / denied / unknown. mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.client_ip_hash IS
  'Salted SHA-256 of the checkout request IP (_shared/guest.ts hashIp); never the IP. mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.user_agent IS
  'User-Agent of the checkout request, at most 512 chars. mig 20260929131000.';

-- ---------------------------------------------------------------------------
-- B1. The fee split on the checkout session (written at create)
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS application_fee_cents int,
  ADD COLUMN IF NOT EXISTS exos_fee_cents        int,
  ADD COLUMN IF NOT EXISTS card_fee_est_cents    int,
  ADD COLUMN IF NOT EXISTS fee_bps               int,
  ADD COLUMN IF NOT EXISTS fee_free              boolean;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_fee_split_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_fee_split_chk CHECK (
        (application_fee_cents IS NULL OR application_fee_cents BETWEEN 0 AND amount_cents)
        AND (exos_fee_cents IS NULL OR exos_fee_cents >= 0)
        AND (card_fee_est_cents IS NULL OR card_fee_est_cents >= 0)
        AND (fee_bps IS NULL OR fee_bps BETWEEN 0 AND 10000)
        AND (application_fee_cents IS NULL OR exos_fee_cents IS NULL OR card_fee_est_cents IS NULL
             OR application_fee_cents = exos_fee_cents + card_fee_est_cents));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_checkout_sessions.application_fee_cents IS
  'Stripe application_fee_amount set at checkout = exos_fee_cents + card_fee_est_cents (_shared/platformFee.ts checkoutFeeSplit). mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.exos_fee_cents IS
  'The Exos part of the application fee (3%; 0 in the fee-free window). mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.card_fee_est_cents IS
  'The Stripe card-fee part of the application fee, estimated at checkout (2.9% + 30c unless overridden). Actual: exos_order_payments.stripe_fee_cents. mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.fee_bps IS
  'Exos rate applied at checkout, in basis points (0 in the fee-free window). mig 20260929131000.';
COMMENT ON COLUMN public.exos_checkout_sessions.fee_free IS
  'The org was inside its fee-free window (exos_org_billing.fee_free_until) at checkout. mig 20260929131000.';

-- ---------------------------------------------------------------------------
-- B2. What Stripe actually took, on the payment row (written after fulfilment)
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_order_payments
  ADD COLUMN IF NOT EXISTS stripe_fee_cents      int,
  ADD COLUMN IF NOT EXISTS net_cents             int,
  ADD COLUMN IF NOT EXISTS transfer_id           text,
  ADD COLUMN IF NOT EXISTS balance_txn_id        text,
  ADD COLUMN IF NOT EXISTS application_fee_id    text,
  ADD COLUMN IF NOT EXISTS application_fee_cents int,
  ADD COLUMN IF NOT EXISTS fees_recorded_at      timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_order_payments_fees_chk') THEN
    ALTER TABLE public.exos_order_payments
      ADD CONSTRAINT exos_order_payments_fees_chk CHECK (
        (stripe_fee_cents IS NULL OR stripe_fee_cents >= 0)
        AND (application_fee_cents IS NULL OR application_fee_cents >= 0));
  END IF;
END $$;

-- The reconcile backfill reads settled payments with no fee record yet.
CREATE INDEX IF NOT EXISTS exos_order_payments_fees_todo_idx
  ON public.exos_order_payments (created_at)
  WHERE fees_recorded_at IS NULL AND status = 'succeeded';

COMMENT ON COLUMN public.exos_order_payments.stripe_fee_cents IS
  'Stripe''s actual fee on the charge (balance_transaction.fee). mig 20260929131000.';
COMMENT ON COLUMN public.exos_order_payments.net_cents IS
  'What the platform keeps on the charge: application fee - Stripe fee. mig 20260929131000.';
COMMENT ON COLUMN public.exos_order_payments.transfer_id IS
  'Stripe transfer (tr_...) of the organizer''s share (destination charge). mig 20260929131000.';

-- Record the Stripe fee actuals on a payment, found by its PaymentIntent.
-- Service role only (stripe-webhook, exos-reconcile-checkouts). Idempotent:
-- a replay writes the same values; a NULL never erases a value already there.
-- Returns true when a payment row was updated.
CREATE OR REPLACE FUNCTION public.exos_record_payment_fees(
  p_payment_intent        text,
  p_charge_id             text DEFAULT NULL,
  p_balance_txn_id        text DEFAULT NULL,
  p_stripe_fee_cents      int  DEFAULT NULL,
  p_application_fee_id    text DEFAULT NULL,
  p_application_fee_cents int  DEFAULT NULL,
  p_transfer_id           text DEFAULT NULL,
  p_net_cents             int  DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id_re constant text := '^[A-Za-z0-9_]{1,255}$';   -- (Postgres caps a repeat at 255)
  v_pay   public.exos_order_payments%ROWTYPE;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_payment_fees: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_payment_intent IS NULL OR p_payment_intent !~ v_id_re
     OR (p_charge_id IS NOT NULL AND p_charge_id !~ v_id_re)
     OR (p_balance_txn_id IS NOT NULL AND p_balance_txn_id !~ v_id_re)
     OR (p_application_fee_id IS NOT NULL AND p_application_fee_id !~ v_id_re)
     OR (p_transfer_id IS NOT NULL AND p_transfer_id !~ v_id_re) THEN
    RAISE EXCEPTION 'exos_record_payment_fees: malformed Stripe id' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_stripe_fee_cents, 0) < 0 OR coalesce(p_application_fee_cents, 0) < 0 THEN
    RAISE EXCEPTION 'exos_record_payment_fees: negative fee' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_pay FROM public.exos_order_payments
   WHERE provider = 'stripe' AND payment_intent = p_payment_intent
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE public.exos_order_payments SET
    -- charge_id is unique: only fill it when it's free.
    charge_id             = CASE
                              WHEN charge_id IS NULL AND p_charge_id IS NOT NULL
                                   AND NOT EXISTS (SELECT 1 FROM public.exos_order_payments o
                                                    WHERE o.charge_id = p_charge_id)
                              THEN p_charge_id ELSE charge_id END,
    balance_txn_id        = coalesce(p_balance_txn_id, balance_txn_id),
    stripe_fee_cents      = coalesce(p_stripe_fee_cents, stripe_fee_cents),
    application_fee_id    = coalesce(p_application_fee_id, application_fee_id),
    application_fee_cents = coalesce(p_application_fee_cents, application_fee_cents),
    transfer_id           = coalesce(p_transfer_id, transfer_id),
    net_cents             = coalesce(p_net_cents, net_cents),
    fees_recorded_at      = now(),
    updated_at            = now()
  WHERE id = v_pay.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_payment_fees(text, text, text, int, text, int, text, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_payment_fees(text, text, text, int, text, int, text, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- B3. exos_order_money: the money on each checkout
-- ---------------------------------------------------------------------------
-- security_invoker: the caller's RLS on exos_checkout_sessions / payments /
-- refunds applies, and the WHERE keeps it to org owner / manager / finance
-- (a buyer can read their own session row, but not this view of it; a
-- scanner reads nothing). The service role and the owner read every row.
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
         p.stripe_fee_cents                    AS card_fee_actual_cents,
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
      SELECT op.stripe_fee_cents, op.net_cents, op.payment_intent, op.transfer_id, op.balance_txn_id
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

COMMENT ON VIEW public.exos_order_money IS
  'Per checkout: gross, tax, application fee (= Exos fee + card fee estimate), actual Stripe fee, organizer net (gross - application fee), platform net, succeeded refunds. Org owner / manager / finance only. mig 20260929131000.';
