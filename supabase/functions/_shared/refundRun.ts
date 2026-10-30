// Steps 2 + 3 of an organizer refund, after exos_refund_claim (step 1) has
// reserved the amount: the Stripe refund, then exos_refund_finalize.
// Shared by exos-refund (the dashboard) and exos-api (POST /orders/:id/refunds)
// so a refund over the API is the dashboard's refund. Money rules: mig
// 20260926040000; Stripe parameters: ./organizer-refund.ts.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type ClaimedRequest,
  isDefinitiveStripeRejection,
  organizerRefundIdempotencyKey,
  organizerRefundParams,
  requestStatusFromStripe,
} from "./organizer-refund.ts";

/** What exos_refund_claim answers. */
export type Claim = ClaimedRequest & {
  status: string;
  stripe_refund_id: string | null;
  existing: boolean;
  currency: string;
};

export type Outcome = {
  session_id: string;
  request_id?: string;
  status: string;
  amount_cents?: number;
  voided?: number;
  stripe_refund_id?: string | null;
  error?: string;
};

/** Steps 2 + 3 for one claimed request. Never throws. */
// deno-lint-ignore no-explicit-any
export async function refundClaim(sb: SupabaseClient<any, any, any>, stripe: Stripe, c: Claim, keepFee: boolean): Promise<Outcome> {
  const base = { session_id: c.session_id, request_id: c.request_id, amount_cents: c.amount_cents };
  // A retried nonce whose request already has Stripe's answer: nothing to do.
  if (c.existing && c.status !== "claimed") {
    return { ...base, status: c.status, voided: 0, stripe_refund_id: c.stripe_refund_id };
  }

  let refund: Stripe.Refund | null = null;
  try {
    // A claimed request from an earlier attempt may already have a refund
    // (idempotency keys expire after 24h): look for it before creating one.
    if (c.existing) {
      for await (const rf of stripe.refunds.list({ payment_intent: c.payment_intent, limit: 100 })) {
        if (rf.metadata?.exos_refund_request_id === c.request_id) { refund = rf; break; }
      }
    }
    refund ??= await stripe.refunds.create(
      organizerRefundParams(c, keepFee),
      { idempotencyKey: organizerRefundIdempotencyKey(c.request_id) },
    );
  } catch (e) {
    const msg = (e as Error).message ?? "stripe error";
    if (isDefinitiveStripeRejection(e)) {
      const { error } = await sb.rpc("exos_refund_finalize", {
        p_request_id: c.request_id, p_stripe_refund_id: null, p_status: "failed", p_error: msg,
      });
      if (error) console.error(`refund: finalize(failed) ${c.request_id}`, error);
      return { ...base, status: "failed", error: msg };
    }
    console.error(`refund: stripe refund for ${c.request_id} not confirmed`, e);
    return { ...base, status: "claimed", error: "Stripe didn't answer; try again (it won't refund twice)" };
  }

  const status = requestStatusFromStripe(refund.status);
  const { data, error } = await sb.rpc("exos_refund_finalize", {
    p_request_id: c.request_id,
    p_stripe_refund_id: refund.id,
    p_status: status,
    p_error: refund.failure_reason ?? null,
  });
  if (error) {
    // The refund exists; stripe-webhook's charge.refunded finalizes it by metadata.
    console.error(`refund: finalize ${c.request_id} (refund ${refund.id}) failed`, error);
    return { ...base, status, stripe_refund_id: refund.id, error: "refund sent; bookkeeping will catch up" };
  }
  const f = data as { voided?: number } | null;
  return { ...base, status, voided: f?.voided ?? 0, stripe_refund_id: refund.id };
}
