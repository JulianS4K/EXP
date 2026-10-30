// exos-commerce — Stripe Checkout for what isn't a ticket: gift cards,
// donations, season passes / flex packs and memberships (docs/gift-cards.md,
// docs/giving.md, docs/memberships.md). Mig 20261030130000 / 20261030130500.
//
// Signed in, or signed out with an `email` (receipts and gift cards go there).
// Every purchase is a Stripe Checkout session on the platform account with a
// destination charge to the organizer's connected account and the usual
// application fee (_shared/platformFee.ts), like exos-checkout. The order is
// recorded in exos_commerce_orders and fulfilled by stripe-webhook
// (metadata.exos_kind) through exos_commerce_fulfill. No other third party.
//
// Actions (POST JSON, { action, ... }):
//   gift_card_balance { code }                       -> { last4, balance_cents, currency, org_name, expires_at }
//       10 lookups a minute per account / hashed IP (SQL).
//   buy_gift_card { product_id, amount_cents, recipient_email?, recipient_name?, message?,
//                   email?, success_url, cancel_url } -> { url, session_id }
//   donate { campaign_id, amount_cents, cover_fees?, anonymous?, donor_name?, note?,
//            email?, success_url, cancel_url }        -> { url, session_id }
//   buy_pass { product_id, email?, success_url, cancel_url } -> { url, session_id }
//   buy_membership { product_id, gift_to_email?, gift_message?, email?, success_url, cancel_url }
//       -> { url, session_id }  (month / year: a subscription; once or a gift: one payment)
//   membership_portal { membership_id, return_url } -> { url }  (holder only, subscriptions)
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY, EXOS_REDIRECT_ORIGINS. Optional:
// EXOS_GUEST_IP_SALT, EXOS_PLATFORM_FEE_BPS, EXOS_STRIPE_FEE_BPS,
// EXOS_STRIPE_FEE_FIXED_CENTS. Deploy with JWT verification OFF (signed-out
// buyers); the JWT is checked here when present.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import { clientIp, hashIp, normalizeGuestEmail } from "../_shared/guest.ts";
import { isCheckoutCurrency } from "../_shared/currency.ts";
import { EXOS_FEE_BPS, STRIPE_CARD_FEE, checkoutApplicationFeeCents, exosFeeBpsAt } from "../_shared/platformFee.ts";
import { coverFeesCents, normalizeGiftCardCode, parseDonationCents } from "../_shared/commerce.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
  let p: Body;
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  if (!p || typeof p !== "object" || typeof p.action !== "string") return json({ error: "missing action" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  const sbUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await sbUser.auth.getUser();
  const sb = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const bucket = user ? `u:${user.id}` : `ip:${await hashIp(clientIp((h) => req.headers.get(h)), salt)}`;

  if (p.action === "gift_card_balance") {
    const code = normalizeGiftCardCode(p.code);
    if (!code) return json({ error: "that gift card code isn't valid (check for a typo)" }, 400);
    const { data, error } = await sb.rpc("exos_gift_card_quote", { p_code: code, p_bucket: bucket });
    if (error) return json({ error: "could not check the gift card" }, 503);
    const q = data as Record<string, unknown>;
    if (q?.error && !String(q.error).includes("no balance")) return json({ error: q.error }, 404);
    return json({
      last4: q.last4, balance_cents: q.balance_cents, initial_cents: q.initial_cents,
      currency: q.currency, org_name: q.org_name, expires_at: q.expires_at,
    });
  }

  const buyerEmail = (user?.email ?? normalizeGuestEmail(p.email) ?? "").toLowerCase();
  if (!buyerEmail) return json({ error: user ? "your account has no email" : "enter a valid email" }, 400);
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));

  if (p.action === "membership_portal") {
    if (!user) return json({ error: "sign in" }, 401);
    if (!isAllowedRedirect(p.return_url, allowed)) return json({ error: "redirect URL not allowed" }, 400);
    const { data: m } = await sb.from("exos_fan_memberships")
      .select("id, holder_uid, stripe_customer_id, stripe_subscription_id").eq("id", String(p.membership_id ?? "")).maybeSingle();
    if (!m || m.holder_uid !== user.id) return json({ error: "membership not found" }, 404);
    if (!m.stripe_customer_id || !m.stripe_subscription_id) return json({ error: "this membership has no billing to manage" }, 409);
    const stripe = stripeClient();
    if (!stripe) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);
    try {
      const portal = await stripe.billingPortal.sessions.create({ customer: m.stripe_customer_id, return_url: p.return_url });
      return json({ url: portal.url });
    } catch (e) {
      console.error("exos-commerce: portal failed", e);
      return json({ error: "could not open billing" }, 502);
    }
  }

  if (!isAllowedRedirect(p.success_url, allowed) || !isAllowedRedirect(p.cancel_url, allowed)) {
    return json({ error: "redirect URL not allowed" }, 400);
  }

  // Each purchase resolves to: the org, a currency, Stripe line items and the
  // order details exos_commerce_fulfill needs.
  let orgId: string;
  let currency: string;
  let kind: "gift_card" | "donation" | "pass" | "membership";
  let productId: string | null = null;
  let amountCents: number;
  let details: Record<string, unknown> = {};
  const lines: Stripe.Checkout.SessionCreateParams.LineItem[] = [];
  let subscription: { interval: "month" | "year"; name: string; unit: number } | null = null;

  if (p.action === "buy_gift_card") {
    if (!UUID_RE.test(String(p.product_id ?? ""))) return json({ error: "missing product_id" }, 400);
    const { data: prod } = await sb.from("exos_gift_card_products")
      .select("id, org_id, name, currency, amount_type, amounts_cents, min_cents, max_cents, active")
      .eq("id", p.product_id).maybeSingle();
    if (!prod || !prod.active) return json({ error: "gift card not available" }, 404);
    const amt = Number(p.amount_cents);
    const ok = Number.isInteger(amt) && (prod.amount_type === "fixed"
      ? (prod.amounts_cents as number[]).includes(amt)
      : amt >= prod.min_cents && amt <= prod.max_cents);
    if (!ok) return json({ error: "that amount isn't offered for this gift card" }, 400);
    const recipient = p.recipient_email ? normalizeGuestEmail(p.recipient_email) : null;
    if (p.recipient_email && !recipient) return json({ error: "recipient email isn't valid" }, 400);
    orgId = prod.org_id; currency = prod.currency; kind = "gift_card"; productId = prod.id; amountCents = amt;
    details = {
      amount_cents: amt, recipient_email: recipient,
      recipient_name: typeof p.recipient_name === "string" ? p.recipient_name.slice(0, 120) : null,
      message: typeof p.message === "string" ? p.message.slice(0, 1000) : null,
    };
    lines.push({ quantity: 1, price_data: { currency, unit_amount: amt, product_data: { name: `Gift card: ${prod.name}` } } });
  } else if (p.action === "donate") {
    const amt = parseDonationCents(p.amount_cents);
    if (amt === null) return json({ error: "donation must be between 1.00 and 100,000.00" }, 400);
    const { data: c } = await sb.from("exos_public_giving_campaigns")
      .select("id, org_id, name, currency, open, cover_fees, cover_fees_bps").eq("id", String(p.campaign_id ?? "")).maybeSingle();
    if (!c || !c.open) return json({ error: "this campaign isn't taking donations" }, 409);
    const cover = p.cover_fees === true && c.cover_fees ? coverFeesCents(amt, c.cover_fees_bps) : 0;
    orgId = c.org_id; currency = c.currency; kind = "donation"; productId = c.id; amountCents = amt + cover;
    details = {
      campaign_id: c.id, amount_cents: amt, cover_fees_cents: cover, anonymous: p.anonymous === true,
      donor_name: typeof p.donor_name === "string" ? p.donor_name.slice(0, 120) : null,
      note: typeof p.note === "string" ? p.note.slice(0, 1000) : null,
    };
    lines.push({ quantity: 1, price_data: { currency, unit_amount: amt, product_data: { name: `Donation: ${c.name}` } } });
    if (cover > 0) {
      lines.push({ quantity: 1, price_data: { currency, unit_amount: cover, product_data: { name: "Covering the card fees" } } });
    }
  } else if (p.action === "buy_pass") {
    const { data: prod } = await sb.from("exos_pass_products")
      .select("id, org_id, name, kind, price_cents, currency, active, max_sold, sold, sales_end")
      .eq("id", String(p.product_id ?? "")).maybeSingle();
    if (!prod || !prod.active) return json({ error: "pass not available" }, 404);
    if (prod.sales_end && Date.parse(prod.sales_end) <= Date.now()) return json({ error: "this pass is no longer on sale" }, 409);
    if (prod.max_sold != null && prod.sold >= prod.max_sold) return json({ error: "sold out" }, 409);
    orgId = prod.org_id; currency = prod.currency; kind = "pass"; productId = prod.id; amountCents = prod.price_cents;
    details = {};
    lines.push({
      quantity: 1,
      price_data: { currency, unit_amount: prod.price_cents, product_data: { name: `${prod.kind === "flex" ? "Flex pack" : "Season pass"}: ${prod.name}` } },
    });
  } else if (p.action === "buy_membership") {
    if (!user) return json({ error: "sign in to buy a membership" }, 401);
    const { data: prod } = await sb.from("exos_membership_products")
      .select("id, org_id, name, price_cents, currency, billing, active, giftable").eq("id", String(p.product_id ?? "")).maybeSingle();
    if (!prod || !prod.active) return json({ error: "membership not available" }, 404);
    const giftTo = p.gift_to_email ? normalizeGuestEmail(p.gift_to_email) : null;
    if (p.gift_to_email && !giftTo) return json({ error: "gift email isn't valid" }, 400);
    if (giftTo && !prod.giftable) return json({ error: "this membership can't be given as a gift" }, 409);
    orgId = prod.org_id; currency = prod.currency; kind = "membership"; productId = prod.id; amountCents = prod.price_cents;
    details = giftTo
      ? { gift_to_email: giftTo, gift_message: typeof p.gift_message === "string" ? p.gift_message.slice(0, 1000) : null,
          gift_from_name: typeof p.gift_from_name === "string" ? p.gift_from_name.slice(0, 120) : null }
      : {};
    if (!giftTo && (prod.billing === "month" || prod.billing === "year")) {
      subscription = { interval: prod.billing, name: `Membership: ${prod.name}`, unit: prod.price_cents };
    } else {
      lines.push({ quantity: 1, price_data: { currency, unit_amount: prod.price_cents, product_data: { name: `Membership: ${prod.name}${giftTo ? " (gift)" : ""}` } } });
    }
  } else {
    return json({ error: "unknown action" }, 400);
  }

  if (!isCheckoutCurrency(currency)) return json({ error: `can't take payments in ${currency.toUpperCase()} yet` }, 409);
  if (amountCents < 50) return json({ error: "amount too small for a card payment" }, 400);
  if (!user && !normalizeGuestEmail(p.email)) return json({ error: "enter a valid email" }, 400);
  if (!user && !(await rateOk(sb, `commerce:${bucket}`, 10))) return json({ error: "too many attempts, try again in a minute" }, 429);

  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", orgId).maybeSingle();
  const payments = (secrets?.payments ?? {}) as { connectedAccountId?: string; chargesEnabled?: boolean };
  if (!payments.connectedAccountId || !payments.chargesEnabled) return json({ error: "organizer has not completed payment setup" }, 409);
  const stripe = stripeClient();
  if (!stripe) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);

  const { data: billing } = await sb.from("exos_org_billing").select("fee_free_until").eq("org_id", orgId).maybeSingle();
  const feeBps = exosFeeBpsAt((billing as { fee_free_until?: string } | null)?.fee_free_until, new Date(),
    Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? String(EXOS_FEE_BPS)));
  const card = {
    bps: Number(Deno.env.get("EXOS_STRIPE_FEE_BPS") ?? String(STRIPE_CARD_FEE.bps)),
    fixedCents: Number(Deno.env.get("EXOS_STRIPE_FEE_FIXED_CENTS") ?? String(STRIPE_CARD_FEE.fixedCents)),
  };
  const applicationFee = checkoutApplicationFeeCents(amountCents, { bps: feeBps, card });
  const metadata = { exos_kind: kind, exos_org_id: orgId, exos_product_id: productId ?? "", exos_buyer_uid: user?.id ?? "" };

  let session: Stripe.Checkout.Session;
  try {
    if (subscription) {
      session = await stripe.checkout.sessions.create({
        mode: "subscription",
        line_items: [{
          quantity: 1,
          price_data: { currency, unit_amount: subscription.unit, recurring: { interval: subscription.interval }, product_data: { name: subscription.name } },
        }],
        subscription_data: {
          // Percent of each renewal, so the fee follows the price.
          application_fee_percent: Math.min(100, Math.round((applicationFee / amountCents) * 10000) / 100),
          transfer_data: { destination: payments.connectedAccountId },
          metadata,
        },
        success_url: p.success_url, cancel_url: p.cancel_url,
        customer_email: buyerEmail, metadata,
        expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
      });
    } else {
      session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card"],
        line_items: lines,
        payment_intent_data: {
          application_fee_amount: applicationFee,
          transfer_data: { destination: payments.connectedAccountId },
          metadata,
        },
        success_url: p.success_url, cancel_url: p.cancel_url,
        customer_email: buyerEmail, metadata,
        expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
      });
    }
  } catch (e) {
    console.error("exos-commerce: stripe session create failed", e);
    return json({ error: "could not create checkout session" }, 502);
  }

  const { error: insErr } = await sb.from("exos_commerce_orders").insert({
    session_id: session.id, org_id: orgId, kind, product_id: productId,
    buyer_uid: user?.id ?? null, buyer_email: buyerEmail, amount_cents: amountCents, currency,
    details, application_fee_cents: applicationFee,
  });
  if (insErr) {
    console.error("exos-commerce: order insert failed", insErr.message);
    try { await stripe.checkout.sessions.expire(session.id); } catch { /* the session expires by itself */ }
    return json({ error: "could not record the order" }, 500);
  }
  return json({ url: session.url, session_id: session.id });
});

function stripeClient(): Stripe | null {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  return key ? new Stripe(key, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" }) : null;
}

// deno-lint-ignore no-explicit-any
async function rateOk(sb: any, bucketKey: string, limit: number): Promise<boolean> {
  const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucketKey.slice(0, 200), p_limit: limit });
  return !error && data !== false;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
