// Monthly (recurring) donations: the Stripe side, shared by exos-commerce
// (donate_monthly, cancel_recurring_donation, complete_campaign) and exos-api
// (POST /v1/giving-campaigns/:id/recurring-donations, DELETE
// /v1/recurring-donations/:id, POST /v1/giving-campaigns/:id/complete).
// Mig 20261102110000, docs/giving.md "Monthly gifts".
//
// Stripe is our own processor, so these writes are allowed; they use the
// platform's STRIPE_SECRET_KEY (a test key in test mode: nothing here knows
// or cares which) and refuse when it is unset. A monthly gift is a Stripe
// Checkout session in subscription mode on the platform account with a
// destination charge to the organizer's connected account and the usual
// application fee as a percent of each charge, exactly like a membership
// subscription (exos-commerce). The plan row is written first (pending) so
// its id rides in the subscription's metadata: stripe-webhook can tie every
// invoice to it, even one that lands before checkout.session.completed.

import type Stripe from "https://esm.sh/stripe@16?target=deno";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { EXOS_FEE_BPS, STRIPE_CARD_FEE, checkoutApplicationFeeCents, exosFeeBpsAt } from "./platformFee.ts";
import { coverFeesCents, parseDonationCents } from "./commerce.ts";
import { isCheckoutCurrency } from "./currency.ts";

export interface MonthlyDonationInput {
  campaignId: string;
  amountCents: unknown;
  coverFees?: boolean;
  anonymous?: boolean;
  donorName?: string | null;
  note?: string | null;
  donorEmail: string;
  donorUid: string | null;
  successUrl: string;
  cancelUrl: string;
  /** 'online' (exos-commerce) or 'api' (a partner's key). */
  source: "online" | "api";
  /** exos-api: only a campaign of this org. */
  orgId?: string;
}

export type MonthlyDonationResult =
  | { ok: true; url: string | null; session_id: string; recurring_id: string; amount_cents: number; cover_fees_cents: number; currency: string }
  | { ok: false; status: number; error: string };

const fail = (status: number, error: string): MonthlyDonationResult => ({ ok: false, status, error });

/** Open the Checkout session for a monthly gift. Never throws. */
export async function createMonthlyDonation(
  sb: SupabaseClient, stripe: Stripe | null, env: (k: string) => string | undefined, p: MonthlyDonationInput,
): Promise<MonthlyDonationResult> {
  if (!stripe) return fail(503, "payments aren't configured (STRIPE_SECRET_KEY unset)");
  const amt = parseDonationCents(p.amountCents);
  if (amt === null) return fail(400, "amount_cents must be whole cents between 100 and 10000000");
  let q = sb.from("exos_public_giving_campaigns")
    .select("id, org_id, name, currency, open, cover_fees, cover_fees_bps").eq("id", p.campaignId);
  if (p.orgId) q = q.eq("org_id", p.orgId);
  const { data: c, error: cErr } = await q.maybeSingle();
  if (cErr) return fail(503, "could not read the campaign");
  if (!c) return fail(p.orgId ? 404 : 409, p.orgId ? "campaign not found or not active" : "this campaign isn't taking donations");
  if (!c.open) return fail(409, "this campaign isn't taking donations right now");
  if (!isCheckoutCurrency(c.currency)) return fail(409, `can't take payments in ${String(c.currency).toUpperCase()} yet`);
  const cover = p.coverFees === true && c.cover_fees ? coverFeesCents(amt, c.cover_fees_bps) : 0;
  const total = amt + cover;

  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", c.org_id).maybeSingle();
  const payments = (secrets?.payments ?? {}) as { connectedAccountId?: string; chargesEnabled?: boolean };
  if (!payments.connectedAccountId || !payments.chargesEnabled) return fail(409, "organizer has not completed payment setup");

  const { data: billing } = await sb.from("exos_org_billing").select("fee_free_until").eq("org_id", c.org_id).maybeSingle();
  const feeBps = exosFeeBpsAt((billing as { fee_free_until?: string } | null)?.fee_free_until, new Date(),
    Number(env("EXOS_PLATFORM_FEE_BPS") ?? String(EXOS_FEE_BPS)));
  const card = {
    bps: Number(env("EXOS_STRIPE_FEE_BPS") ?? String(STRIPE_CARD_FEE.bps)),
    fixedCents: Number(env("EXOS_STRIPE_FEE_FIXED_CENTS") ?? String(STRIPE_CARD_FEE.fixedCents)),
  };
  const applicationFee = checkoutApplicationFeeCents(total, { bps: feeBps, card });

  // The plan first: its id goes into the subscription's metadata.
  const { data: plan, error: pErr } = await sb.from("exos_recurring_donations").insert({
    org_id: c.org_id, campaign_id: c.id, amount_cents: amt, cover_fees_cents: cover, currency: c.currency,
    donor_uid: p.donorUid, donor_email: p.donorEmail, anonymous: p.anonymous === true,
    donor_name: typeof p.donorName === "string" ? p.donorName.slice(0, 120) : null,
    note: typeof p.note === "string" ? p.note.slice(0, 1000) : null, source: p.source,
  }).select("id").single();
  if (pErr || !plan) return fail(500, "could not record the monthly gift");
  const recurringId = plan.id as string;
  const metadata = {
    exos_kind: "recurring_donation", exos_org_id: c.org_id, exos_product_id: c.id,
    exos_buyer_uid: p.donorUid ?? "", exos_recurring_id: recurringId,
  };

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "subscription",
      line_items: [
        { quantity: 1, price_data: { currency: c.currency, unit_amount: amt, recurring: { interval: "month" },
          product_data: { name: `Monthly gift: ${c.name}` } } },
        ...(cover > 0 ? [{ quantity: 1, price_data: { currency: c.currency, unit_amount: cover, recurring: { interval: "month" as const },
          product_data: { name: "Covering the card fees" } } }] : []),
      ],
      subscription_data: {
        application_fee_percent: Math.min(100, Math.round((applicationFee / total) * 10000) / 100),
        transfer_data: { destination: payments.connectedAccountId },
        metadata,
      },
      success_url: p.successUrl, cancel_url: p.cancelUrl,
      customer_email: p.donorEmail, metadata,
      expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
    });
  } catch (e) {
    console.error("recurringDonation: stripe session create failed", e);
    await sb.from("exos_recurring_donations").delete().eq("id", recurringId).eq("status", "pending");
    return fail(502, "could not create checkout session");
  }

  const { error: oErr } = await sb.from("exos_commerce_orders").insert({
    session_id: session.id, org_id: c.org_id, kind: "recurring_donation", product_id: c.id,
    buyer_uid: p.donorUid, buyer_email: p.donorEmail, amount_cents: total, currency: c.currency,
    details: { recurring_id: recurringId, campaign_id: c.id, amount_cents: amt, cover_fees_cents: cover },
    application_fee_cents: applicationFee,
  });
  if (oErr) {
    console.error("recurringDonation: order insert failed", oErr.message);
    try { await stripe.checkout.sessions.expire(session.id); } catch { /* it expires by itself */ }
    await sb.from("exos_recurring_donations").delete().eq("id", recurringId).eq("status", "pending");
    return fail(500, "could not record the order");
  }
  await sb.from("exos_recurring_donations").update({ session_id: session.id }).eq("id", recurringId);
  return { ok: true, url: session.url, session_id: session.id, recurring_id: recurringId, amount_cents: amt,
    cover_fees_cents: cover, currency: c.currency };
}

/** True for Stripe's "already gone" answers to a subscription cancel. */
export function alreadyCancelled(e: unknown): boolean {
  const code = (e as { code?: string })?.code;
  return code === "resource_missing" || /canceled|cancelled/i.test((e as Error)?.message ?? "");
}

/**
 * Stop a monthly gift: mark it asked-for, cancel the subscription in Stripe
 * (now: the next charge never happens), mark it cancelled. The webhook's
 * customer.subscription.deleted lands too; either is enough. Throws on a
 * Stripe failure (the plan keeps cancel_requested_at; retrying is safe).
 */
export async function cancelMonthlyDonation(
  sb: SupabaseClient, stripe: Stripe | null, orgId: string | null, id: string, reason: string,
): Promise<Record<string, unknown>> {
  const { data, error } = await sb.rpc("exos_recurring_donation_cancel", { p_org_id: orgId, p_id: id, p_reason: reason });
  if (error) throw error;
  const sub = (data as { subscription_id?: string | null }).subscription_id ?? null;
  if (sub) {
    if (!stripe) throw Object.assign(new Error("payments aren't configured (STRIPE_SECRET_KEY unset)"), { status: 503 });
    try {
      await stripe.subscriptions.cancel(sub);
    } catch (e) {
      if (!alreadyCancelled(e)) throw Object.assign(new Error("Stripe didn't cancel the subscription; try again"), { status: 502 });
    }
  }
  const { data: done, error: dErr } = await sb.rpc("exos_recurring_donation_cancelled", { p_id: id });
  if (dErr) throw dErr;
  return done as Record<string, unknown>;
}

/** Cancel the subscriptions a completed campaign returned. Best effort: returns the ones Stripe refused. */
export async function cancelSubscriptions(stripe: Stripe | null, subs: string[]): Promise<string[]> {
  const left: string[] = [];
  for (const s of subs) {
    if (!/^sub_[A-Za-z0-9]{1,250}$/.test(s)) continue;
    if (!stripe) { left.push(s); continue; }
    try { await stripe.subscriptions.cancel(s); } catch (e) { if (!alreadyCancelled(e)) left.push(s); }
  }
  return left;
}
