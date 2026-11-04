// The one Stripe auto-refund request for a checkout session that was charged
// but couldn't be fulfilled. stripe-webhook (right after fulfillment fails) and
// exos-reconcile-checkouts (the safety-net sweep) both issue it, so they MUST
// send the same idempotency key AND the same parameters: Stripe then returns
// the first refund instead of creating a second one (and rejects a reused key
// whose parameters differ). Don't add per-caller fields here.
//
// Stripe keeps idempotency keys for 24h. Past that, callers must not rely on
// the key alone — the sweep lists the PaymentIntent's refunds first.

import { type ChargeModel, refundFlags } from "./payouts/commissionMethods.ts";

export function autoRefundIdempotencyKey(sessionId: string): string {
  return `exos_autorefund_${sessionId}`;
}

// chargeModel (mig 20261104190000): how the order was charged, from its
// Checkout metadata (chargeModelFromMetadata), so both callers derive the
// same value. Destination (every order before split at sale): pull the funds
// back from the connected account and return our fee, otherwise the platform
// balance pays the refund. Split at sale: the charge is the platform's and
// nothing was transferred yet, so neither flag applies.
export function autoRefundParams(paymentIntent: string, sessionId: string, chargeModel: ChargeModel = "destination") {
  return {
    payment_intent: paymentIntent,
    reason: "requested_by_customer" as const,
    ...refundFlags(chargeModel, { commissionInFee: true }),
    metadata: { exos_session_id: sessionId, exos_auto: "fulfillment_failed" },
  };
}

export const REFUND_STATUSES = new Set(["pending", "succeeded", "failed", "canceled"]);

export function ledgerRefundStatus(status: string | null | undefined): string {
  return REFUND_STATUSES.has(status ?? "") ? status as string : "pending";
}
