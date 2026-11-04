// Steps 2 + 3 of an organizer refund, after exos_refund_claim (step 1) has
// reserved the amount: the Stripe refund (or, for an order paid with PayPal /
// Venmo, mig 20261031220000, the PayPal refund), then exos_refund_finalize.
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
import { PayPalError, type PayPalClient } from "./paypal/client.ts";
import { refundPayPal } from "./paypal/flows.ts";
import {
  findSplitReversal, type RefundMode, type RefundPrep, refundPrepAction, splitReversalKey,
} from "./payouts/commissionMethods.ts";
import { durably, STRIPE_TIMEOUT_MS } from "./payouts/promoterTransfers.ts";
import { withTimeout } from "./feeActuals.ts";
import { isPayPalRef } from "./paypal/model.ts";

/** The processors a refund may need, each only when its keys are set. */
export type RefundProcessors = { stripe: Stripe | null; pp: PayPalClient | null };

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

/** Steps 2 + 3 for one claimed request. Never throws. A bare Stripe client
 *  means Stripe only (no PayPal keys). */
export async function refundClaim(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>,
  procs: Stripe | RefundProcessors,
  c: Claim,
  keepFee: boolean,
): Promise<Outcome> {
  const p: RefundProcessors = procs instanceof Stripe ? { stripe: procs, pp: null } : procs;
  const base = { session_id: c.session_id, request_id: c.request_id, amount_cents: c.amount_cents };
  // A retried nonce whose request already has Stripe's answer: nothing to do.
  if (c.existing && c.status !== "claimed") {
    return { ...base, status: c.status, voided: 0, stripe_refund_id: c.stripe_refund_id };
  }
  // Paid with PayPal / Venmo: refund at PayPal.
  if (isPayPalRef(c.payment_intent)) {
    if (!p.pp) return { ...base, status: "claimed", error: "PayPal is switched off; try again once it's back" };
    return await refundClaimPayPal(sb, p.pp, c, base);
  }
  if (!p.stripe) return { ...base, status: "claimed", error: "Stripe is switched off; try again once it's back" };
  const stripe = p.stripe;
  // How to refund this order (mig 20261104190000), decided once per request
  // in SQL so every retry sends the same parameters. A split order whose
  // share was already paid to the organizer first takes their part back
  // from that transfer (a reversal), or the refund is refused: Exos never
  // pays for it out of its own balance.
  const act = refundPrepAction(await prepareCharge(sb, c.request_id));
  if (act.action === "retry") return { ...base, status: "claimed", error: act.message };
  if (act.action === "refuse") {
    const { error } = await sb.rpc("exos_refund_finalize", {
      p_request_id: c.request_id, p_stripe_refund_id: null, p_status: "failed", p_error: act.message.slice(0, 500),
    });
    if (error) console.error(`refund: finalize(refused) ${c.request_id}`, error);
    return { ...base, status: "failed", error: act.message };
  }
  let mode: RefundMode = "split";
  if (act.action === "reverse_then_refund") {
    const r = act.taken ? "taken" : await reverseOrganizerShare(sb, stripe, act, c.request_id);
    if (r === "failed") {
      const msg = "Exos couldn't take your share of this refund back from your Stripe payout, so the refund was refused.";
      const { error } = await sb.rpc("exos_refund_finalize", {
        p_request_id: c.request_id, p_stripe_refund_id: null, p_status: "failed", p_error: msg,
      });
      if (error) console.error(`refund: finalize(reversal failed) ${c.request_id}`, error);
      return { ...base, status: "failed", error: msg };
    }
    if (r !== "taken") return { ...base, status: "claimed", error: "Taking your share back from Stripe didn't finish; try again (it won't happen twice)" };
  } else {
    mode = act.mode;
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
      organizerRefundParams(c, keepFee, mode),
      { idempotencyKey: organizerRefundIdempotencyKey(c.request_id) },
    );
  } catch (e) {
    const msg = (e as Error).message ?? "stripe error";
    if (isDefinitiveStripeRejection(e)) {
      // A reversal already took the organizer's part: it's owed back to them.
      if (act.action === "reverse_then_refund") {
        const { error: uErr } = await sb.rpc("exos_split_reversal_unused", { p_request_id: c.request_id });
        if (uErr) console.error(`refund: reversal credit for ${c.request_id} failed`, uErr);
      }
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

/** exos_refund_charge_prepare's answer; before that migration, 'standard'; null on any other error (retry). */
async function prepareCharge(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>,
  requestId: string,
): Promise<RefundPrep | null> {
  const { data, error } = await sb.rpc("exos_refund_charge_prepare", { p_request_id: requestId });
  if (error) {
    const missing = error.code === "42883" || error.code === "PGRST202";
    return missing ? { mode: "standard" } : null;
  }
  return (data ?? { mode: "standard" }) as RefundPrep;
}

/**
 * Take the organizer's part of a split refund back from their transfer:
 * lease the reversal row, reconcile first if an earlier attempt may have
 * reached Stripe, then one reversal with key exos-ctr:<id>, recorded durably.
 * 'taken', 'failed' (Stripe refused: the refund is refused), or 'retry'.
 */
async function reverseOrganizerShare(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>,
  stripe: Stripe,
  r: { reversalId: string; transferId: string; amountCents: number },
  requestId: string,
): Promise<"taken" | "failed" | "retry"> {
  const { data: cl, error: clErr } = await sb.rpc("exos_split_reversal_claim", { p_id: r.reversalId });
  if (clErr) return "retry";
  const claim = cl as { ok: boolean; error?: string; lease_token?: string; needs_reconcile?: boolean };
  if (!claim.ok) return claim.error === "taken" ? "taken" : claim.error === "failed" ? "failed" : "retry";
  const mark = async (status: "taken" | "reconciled" | "failed", reversalId: string | null, err: string | null = null) => {
    const { data, error } = await sb.rpc("exos_split_reversal_mark", {
      p_id: r.reversalId, p_lease_token: claim.lease_token, p_status: status, p_reversal_id: reversalId, p_error: err,
    });
    return !error && data === true;
  };
  try {
    if (claim.needs_reconcile) {
      const list = await withTimeout<Stripe.ApiList<Stripe.TransferReversal>>(
        Promise.resolve(stripe.transfers.listReversals(r.transferId, { limit: 100 })), STRIPE_TIMEOUT_MS, "stripe reversal list");
      const found = findSplitReversal(r.reversalId, list.data.map((x) => ({ id: x.id, metadata: (x.metadata ?? {}) as Record<string, string> })));
      if (found) return (await durably(() => mark("taken", found))) ? "taken" : "retry";
      if (!(await mark("reconciled", null))) return "retry";
    }
    const rev = await withTimeout<Stripe.TransferReversal>(stripe.transfers.createReversal(
      r.transferId,
      { amount: r.amountCents, metadata: { exos_split_reversal_id: r.reversalId, exos_refund_request_id: requestId } },
      { idempotencyKey: splitReversalKey(r.reversalId) },
    ), STRIPE_TIMEOUT_MS, "stripe reversal");
    return (await durably(() => mark("taken", rev.id))) ? "taken" : "retry";
  } catch (e) {
    if (isDefinitiveStripeRejection(e)) {
      await mark("failed", null, String((e as Error).message ?? "stripe refused").slice(0, 300));
      return "failed";
    }
    // It may have reached Stripe: the next attempt reconciles first.
    console.error(`refund: reversal for ${requestId} not confirmed`, e);
    return "retry";
  }
}

// The PayPal leg of refundClaim: same states as Stripe's. A definitive "no"
// (4xx) finalizes 'failed'; anything else leaves the request claimed, and a
// retry reuses PayPal-Request-Id exos_refund_<request id>.
async function refundClaimPayPal(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>,
  pp: PayPalClient,
  c: Claim,
  base: { session_id: string; request_id: string; amount_cents: number },
): Promise<Outcome> {
  let rf: Awaited<ReturnType<typeof refundPayPal>>;
  try {
    rf = await refundPayPal(pp, { ...c, currency: c.currency || "usd" });
  } catch (e) {
    const msg = (e as Error).message ?? "paypal error";
    if (e instanceof PayPalError && e.definitive) {
      const { error } = await sb.rpc("exos_refund_finalize", {
        p_request_id: c.request_id, p_stripe_refund_id: null, p_status: "failed", p_error: msg,
      });
      if (error) console.error(`refund: finalize(failed) ${c.request_id}`, error);
      return { ...base, status: "failed", error: msg };
    }
    console.error(`refund: paypal refund for ${c.request_id} not confirmed`, e);
    return { ...base, status: "claimed", error: "PayPal didn't answer; try again (it won't refund twice)" };
  }
  const { data, error } = await sb.rpc("exos_refund_finalize", {
    p_request_id: c.request_id, p_stripe_refund_id: rf.ref, p_status: rf.status, p_error: null,
  });
  if (error) {
    console.error(`refund: finalize ${c.request_id} (paypal refund ${rf.refundId}) failed`, error);
    return { ...base, status: rf.status, stripe_refund_id: rf.ref, error: "refund sent; bookkeeping will catch up" };
  }
  const f = data as { voided?: number } | null;
  return { ...base, status: rf.status, voided: f?.voided ?? 0, stripe_refund_id: rf.ref };
}
