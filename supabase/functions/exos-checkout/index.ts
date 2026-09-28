// exos-checkout — create a Stripe Checkout Session for an event/tier (D4-OPS-7 SCAFFOLD).
//
// Signed in, or a GUEST (mig 20260928050000): no JWT plus a guest_email in the
// body. Guest tickets go to the confirmed account with that email, else they're
// parked with a claim link mailed to it (see the migration). Guests get a
// service-role hold with its own anti-bot limits (per-email cart, hashed-IP rate
// limit, a ceiling on live guest holds); organizers can switch guests off per
// event with purchase_limits.guestCheckout = false. Destination charge to the org's connected account + an
// application fee. Records a 'pending' row in exos_checkout_sessions keyed on
// the Stripe session id; the stripe-webhook fulfills it on completion.
//
// Embedded mode (white-label level 3): a body with ui_mode: 'embedded' and a
// return_url (instead of success_url/cancel_url) creates an Embedded Checkout
// session the venue-site iframe (/embed/event/:id) mounts in place, and
// returns { client_secret, session_id } instead of { url, session_id }. The
// return_url must be an allowlisted origin's /embed/return page. Everything
// else (hold, voucher, limits, attribution, price disclosure) is shared.
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY, EXOS_REDIRECT_ORIGINS (origins success/cancel URLs
// may point at; see _shared/redirects.ts). Optional: EXOS_PLATFORM_FEE_BPS (default 300 = 3%, _shared/platformFee.ts),
// EXOS_GUEST_IP_SALT (salt for the hashed guest IP; defaults to a server secret).
// Needs mig 20260924223000 (promoter_id / attribution columns) applied first.
//
// Fee: 3% of every transaction net after Stripe, from the organizer
// (operator, 2026-09-28): the application fee is 3% + Stripe's card fee.
// TODO(operator) before go-live: confirm the charge model (destination vs
// direct) and that 'standard' Connect accounts are the right type.
// Optional: EXOS_STRIPE_FEE_BPS / EXOS_STRIPE_FEE_FIXED_CENTS (default 290 / 30).

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { allInCents, effectiveTierPrice, voucherUnitPrice } from "../_shared/pricing.ts";
import { isAllowedEmbedReturn, isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import { isEmptyAttribution, readAttribution } from "../_shared/attribution.ts";
import { clientIp, hashIp, normalizeGuestEmail } from "../_shared/guest.ts";
import { isCheckoutCurrency } from "../_shared/currency.ts";
import { EXOS_FEE_BPS, STRIPE_CARD_FEE, checkoutApplicationFeeCents } from "../_shared/platformFee.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  // Checked where a charge is made: a guest's free claim needs no Stripe.
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");

  // Authenticate the buyer from their JWT; without one, a guest_email makes it
  // a guest checkout.
  const authHeader = req.headers.get("Authorization") ?? "";
  const sbUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user } } = await sbUser.auth.getUser();

  let p: {
    event_id?: string; tier_id?: string; quantity?: number;
    success_url?: string; cancel_url?: string;
    // 'embedded' → Stripe Embedded Checkout; anything else → hosted (default).
    ui_mode?: string; return_url?: string;
    addons?: { addon_id?: string; quantity?: number }[];
    voucher_code?: string;
    // Promoter code + UTM / fbclid / cart_origin from the landing URL.
    attribution?: Record<string, unknown>;
    // Guest checkout: the email the tickets (or their claim links) go to.
    guest_email?: string;
  };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const guestEmail = user ? null : normalizeGuestEmail(p.guest_email);
  if (!user && p.guest_email === undefined) return json({ error: "unauthorized" }, 401);
  if (!user && !guestEmail) return json({ error: "enter a valid email" }, 400);
  const buyerUid = user?.id ?? null;
  const buyerEmail = (user?.email ?? guestEmail ?? "").toLowerCase();
  const { event_id, tier_id, success_url, cancel_url } = p;
  const embedded = p.ui_mode === "embedded";
  const returnUrl = p.return_url;
  const quantity = p.quantity ?? 1;
  const addonReq = Array.isArray(p.addons) ? p.addons : [];
  const voucherCode = (p.voucher_code ?? "").trim();
  const attrIn = p.attribution && typeof p.attribution === "object" ? p.attribution : {};
  const attribution = readAttribution((k) => (attrIn as Record<string, unknown>)[k]);
  const { promoter: promoterId, ...campaignTags } = attribution;
  if (embedded) {
    if (!event_id || !tier_id || !returnUrl) {
      return json({ error: "missing event_id / tier_id / return_url" }, 400);
    }
  } else if (!event_id || !tier_id || !success_url || !cancel_url) {
    return json({ error: "missing event_id / tier_id / success_url / cancel_url" }, 400);
  }
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (allowed.length === 0) return json({ error: "server misconfigured: EXOS_REDIRECT_ORIGINS unset" }, 500);
  if (embedded) {
    // Only our own /embed/return page on an allowlisted origin.
    if (!isAllowedEmbedReturn(returnUrl, allowed)) {
      return json({ error: "redirect URL not allowed" }, 400);
    }
  } else if (!isAllowedRedirect(success_url, allowed) || !isAllowedRedirect(cancel_url, allowed)) {
    return json({ error: "redirect URL not allowed" }, 400);
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
    return json({ error: "quantity must be 1-10" }, 400);
  }

  // Trusted reads (price/capacity/connected account) + ledger write via service_role.
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: tier, error: tierErr } = await sb
    .from("exos_ticket_tiers")
    .select("id, name, price, price_schedule, capacity, sold, event_id, visibility, tax_rate_id, exos_tax_rules(rate_percent, price_includes_tax), exos_events!inner(id, org_id, name, status, currency)")
    .eq("id", tier_id).eq("event_id", event_id).maybeSingle();
  if (tierErr || !tier) return json({ error: "tier not found" }, 404);

  const ev = (tier as unknown as { exos_events: { org_id: string; name: string; status: string; currency: string | null } }).exos_events;
  if (ev.status !== "published") return json({ error: "event not on sale" }, 409);

  // Voucher (pretix-style access token) — validated server-side. May bypass a
  // sold-out tier and/or pin a price; consumed on fulfillment by a DB trigger
  // (exos_checkout_consume_voucher). Distinct from discount codes.
  let voucherId: string | null = null;
  let bypassCapacity = false;
  let overridePrice: number | null = null;
  // Percent / amount off (mig 20260928060000); at most one price rule per voucher.
  let discountPercent: number | null = null;
  let discountAmount: number | null = null;
  let voucherUnlocksTier = false;
  if (voucherCode) {
    const { data: vRows, error: vErr } = await sb.rpc("exos_check_voucher", {
      p_event_id: event_id, p_code: voucherCode, p_email: buyerEmail || null,
    });
    const v = Array.isArray(vRows) ? vRows[0] : vRows;
    if (vErr || !v?.is_valid) {
      return json({ error: `voucher ${v?.reason ?? "invalid"}` }, 409);
    }
    if (v.restrict_tier_id && v.restrict_tier_id !== tier_id) {
      return json({ error: "voucher is not valid for this ticket type" }, 409);
    }
    // One voucher use buys one ticket (mig 20260924205508); refuse here rather
    // than charging and auto-refunding when fulfillment can't consume enough.
    type VoucherUses = { max_uses: number; used_count: number; discount_percent?: number | null; discount_amount?: number | null };
    let { data: vUses, error: vuErr } = await sb.from("exos_vouchers")
      .select("max_uses, used_count, discount_percent, discount_amount").eq("id", v.voucher_id)
      .maybeSingle<VoucherUses>();
    // Deployed before mig 20260928060000 (no discount columns): plain vouchers still work.
    if (vuErr && (vuErr.code === "42703" || vuErr.code === "PGRST204")) {
      ({ data: vUses } = await sb.from("exos_vouchers")
        .select("max_uses, used_count").eq("id", v.voucher_id).maybeSingle<VoucherUses>());
    }
    const remainingUses = vUses ? vUses.max_uses - vUses.used_count : 0;
    if (quantity > remainingUses) {
      return json({ error: `voucher covers ${Math.max(remainingUses, 0)} more ticket(s)` }, 409);
    }
    voucherId = v.voucher_id;
    voucherUnlocksTier = v.restrict_tier_id === tier_id;
    bypassCapacity = v.can_bypass === true;
    // A capacity-bypass code is an organizer's personal offer (waitlist, comp
    // upgrade); it stays tied to an account.
    if (bypassCapacity && !buyerUid) {
      return json({ error: "sign in to use this code" }, 409);
    }
    overridePrice = v.override_price != null ? Number(v.override_price) : null;
    discountPercent = vUses?.discount_percent != null ? Number(vUses.discount_percent) : null;
    discountAmount = vUses?.discount_amount != null ? Number(vUses.discount_amount) : null;
  }

  // A hidden tier is only sold through a voucher restricted to it (same rule
  // as the free-claim path); otherwise its UUID alone would unlock it.
  const visibility = (tier as unknown as { visibility?: string | null }).visibility;
  if (visibility && visibility !== "public" && !voucherUnlocksTier) {
    return json({ error: "ticket type not available" }, 409);
  }

  // Availability is enforced by a cart HOLD created just before the Stripe
  // session (exos_create_hold — atomically reserves against tier capacity AND
  // any shared quota for a TTL, so two buyers can't both pay for the last seat).
  // A bypass voucher skips the reservation (allowed to exceed caps). See below.

  // Per-person buy limit (maxPerOrder + cumulative maxPerAccount). Same check as
  // the comp path; counts tickets this buyer already holds, so a SECOND purchase
  // that would exceed the limit is refused before a Stripe session is created.
  // A guest's "account" is their email (exos_assert_purchase_limit_email).
  const { error: limitErr } = buyerUid
    ? await sb.rpc("exos_assert_purchase_limit", { p_event_id: event_id, p_buyer: buyerUid, p_qty: quantity })
    : await sb.rpc("exos_assert_purchase_limit_email", { p_event_id: event_id, p_email: buyerEmail, p_qty: quantity });
  if (limitErr) {
    return json({ error: limitErr.message || "purchase limit exceeded" }, 409);
  }

  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", ev.org_id).maybeSingle();
  const payments = (secrets?.payments ?? {}) as { connectedAccountId?: string; chargesEnabled?: boolean };

  const currency = (ev.currency ?? "usd").toLowerCase();
  // Amounts below are minor units = major x 100: two-decimal currencies only
  // (a zero-decimal JPY price would be charged 100 times over).
  if (!isCheckoutCurrency(currency)) {
    return json({ error: `tickets can't be sold in ${currency.toUpperCase()} yet: pick another currency for this event` }, 409);
  }
  // The tier's scheduled price as of now, the same price the storefront shows
  // (early-bird → regular → last-minute), then the voucher's rule: a pinned
  // price, a percent off or an amount off (voucherUnitPrice, shared with the SPA).
  const scheduled = effectiveTierPrice(
    Number(tier.price),
    (tier as unknown as { price_schedule?: unknown }).price_schedule,
  );
  const unitAmount = Math.round(voucherUnitPrice(scheduled, { overridePrice, discountPercent, discountAmount }) * 100);
  // A discount that leaves a paid ticket free is a comp, not a sale.
  if (scheduled > 0 && unitAmount <= 0 && overridePrice == null) {
    return json({ error: "that code takes off more than the ticket price" }, 409);
  }

  // Validate + price add-ons server-side (never trust the client's prices). Each
  // must belong to this event, be public, and have stock. Build the priced
  // snapshot stored on the session (fulfillment reads it to record the purchase).
  type AddonRow = { addon_id: string; quantity: number; unit_price_cents: number; name: string };
  const addonsForSession: AddonRow[] = [];
  const addonLines: { id: string; name: string; quantity: number; unit_face: number; unit_all_in: number; unit_tax: number; line_tax: number; tax_included: boolean }[] = [];
  let addonTotal = 0;
  // recordedTax = the tax portion of the order (inclusive or exclusive), stored
  // on the session for invoices/reporting. Exclusive tax is already inside the
  // all-in unit amounts below, never added as a separate charge.
  let recordedTax = 0;
  // All-in pricing: exclusive tax is computed PER UNIT and folded into each
  // line's unit_amount, so the buyer pays exactly the all-in price the
  // storefront showed (allInCents, shared with the SPA). Returns the all-in unit
  // amount; inclusive tax is only recorded (it's already in the price).
  const allInUnit = (unitCents: number, qty: number, rule: { rate_percent?: number; price_includes_tax?: boolean } | null | undefined): number => {
    const rate = Number(rule?.rate_percent ?? 0);
    if (!rate) return unitCents;
    if (rule?.price_includes_tax === true) {
      recordedTax += taxCents(unitCents * qty, rate, true);
      return unitCents;
    }
    const withTax = allInCents(unitCents, rate);
    const tax = (withTax - unitCents) * qty;
    recordedTax += tax;
    return withTax;
  };
  if (addonReq.length > 0) {
    // Aggregate duplicate addon_ids FIRST so max_per_order + capacity apply to
    // the COMBINED quantity — otherwise a client could split one add-on across
    // entries ([{X,N},{X,N}]) and slip past the per-order/stock ceilings (each
    // entry checked in isolation), then fulfillment bumps sold per entry with no
    // re-check → oversell.
    const wanted = new Map<string, number>();
    for (const req of addonReq) {
      const id = req.addon_id;
      const qty = Number(req.quantity) || 0;
      if (!id || qty < 1) continue;
      wanted.set(id, (wanted.get(id) ?? 0) + qty);
    }
    const ids = [...wanted.keys()];
    if (ids.length > 0) {
      const { data: catalog, error: addErr } = await sb
        .from("exos_event_addons")
        .select("id, name, price, capacity, sold, max_per_order, visibility, event_id, tax_rate_id, exos_tax_rules(rate_percent, price_includes_tax)")
        .eq("event_id", event_id).in("id", ids);
      if (addErr) return json({ error: "could not load add-ons" }, 500);
      const byId = new Map((catalog ?? []).map((a) => [a.id, a]));
      for (const [id, qty] of wanted) {
        const a = byId.get(id);
        if (!a || a.visibility !== "public") return json({ error: "add-on not available" }, 409);
        // Hard upper bound mirroring the exos_order_addons CHECK (quantity BETWEEN
        // 1 AND 50). Without this, an add-on with no max_per_order and unlimited
        // capacity (both defaults) accepts any quantity here, the buyer pays, then
        // fulfillment's INSERT violates the CHECK and rolls back — charged, no
        // tickets, infinite webhook retry. Reject over-cap before charging.
        if (qty > 50) {
          return json({ error: `add-on "${a.name}" limited to 50 per order` }, 409);
        }
        if (a.max_per_order && qty > a.max_per_order) {
          return json({ error: `add-on "${a.name}" limited to ${a.max_per_order} per order` }, 409);
        }
        if (a.capacity > 0 && a.sold + qty > a.capacity) {
          return json({ error: `add-on "${a.name}" is sold out` }, 409);
        }
        const unitCents = Math.round(Number(a.price) * 100);
        const addonRule = (a as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
        const taxBefore = recordedTax;
        const allIn = allInUnit(unitCents, qty, addonRule);
        addonsForSession.push({ addon_id: a.id, quantity: qty, unit_price_cents: unitCents, name: a.name });
        addonLines.push({
          id: a.id, name: a.name, quantity: qty, unit_face: unitCents, unit_all_in: allIn, unit_tax: allIn - unitCents,
          line_tax: recordedTax - taxBefore, tax_included: addonRule?.price_includes_tax === true,
        });
        addonTotal += allIn * qty;
      }
    }
  }

  // Tier tax (after the voucher price override is applied to unitAmount).
  const tierRule = (tier as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
  const ticketTaxBefore = recordedTax;
  const ticketAllIn = allInUnit(unitAmount, quantity, tierRule);
  const ticketLineTax = recordedTax - ticketTaxBefore;

  // addonTotal is already all-in; the exclusive tax sits inside both unit amounts.
  const amountCents = ticketAllIn * quantity + addonTotal;
  // The Exos fee: 3% net after Stripe, from the organizer's share. The
  // platform pays Stripe's card fee under destination charges, so the
  // application fee is 3% plus that fee (_shared/platformFee.ts).
  const feeBps = Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? String(EXOS_FEE_BPS));
  const applicationFee = checkoutApplicationFeeCents(amountCents, {
    bps: feeBps,
    card: {
      bps: Number(Deno.env.get("EXOS_STRIPE_FEE_BPS") ?? String(STRIPE_CARD_FEE.bps)),
      fixedCents: Number(Deno.env.get("EXOS_STRIPE_FEE_FIXED_CENTS") ?? String(STRIPE_CARD_FEE.fixedCents)),
    },
  });

  // Only PAID line items go to Stripe ($0 lines are rejected in payment mode), so
  // a free tier + paid add-ons charges just the add-ons. Ticket quantity is still
  // recorded on the session for minting regardless of the tier's price.
  const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [];
  // All-in: one line per product at its all-in unit price; the tax inside it is
  // disclosed in the line description instead of appearing as an extra line.
  const taxNote = (unitTax: number) =>
    unitTax > 0 ? { description: `Includes ${(unitTax / 100).toFixed(2)} ${currency.toUpperCase()} tax per item` } : {};
  if (ticketAllIn > 0) {
    lineItems.push({
      quantity,
      price_data: {
        currency, unit_amount: ticketAllIn,
        product_data: { name: `${ev.name} — ${tier.name}`, ...taxNote(ticketAllIn - unitAmount) },
      },
    });
  }
  for (const a of addonLines) {
    if (a.unit_all_in > 0) {
      lineItems.push({
        quantity: a.quantity,
        price_data: {
          currency, unit_amount: a.unit_all_in,
          product_data: { name: `${ev.name} — ${a.name}`, ...taxNote(a.unit_tax) },
        },
      });
    }
  }
  // Free: signed-in buyers use the app's free-claim path; a guest claims here
  // with just an email (below), through the same guest hold and limits.
  const freeGuest = lineItems.length === 0 && !buyerUid;
  if (lineItems.length === 0 && buyerUid) {
    return json({ error: "nothing to charge — use the free claim path" }, 400);
  }
  if (!freeGuest) {
    if (!stripeKey) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);
    if (!payments.connectedAccountId || !payments.chargesEnabled) {
      return json({ error: "organizer has not completed payment setup" }, 409);
    }
  }

  // Reserve inventory with a cart hold BEFORE creating the Stripe session, so a
  // buyer who is about to pay actually holds the seats (closes the read-then-
  // charge oversell). Bypass vouchers skip it — they may exceed caps, honored at
  // fulfillment. Held for 30 min; released here on failure, consumed at mint,
  // else swept by the exos_expire_holds cron.
  let holdId: string | null = null;
  if (!bypassCapacity) {
    // A hidden tier's hold re-checks the voucher (mig 20260925003000). Only
    // sent when needed, so public tiers work before that migration is applied.
    // A guest hold is also where the guest rate limits and the organizer's
    // guestCheckout switch are enforced (guests never bypass, see above).
    const { data: hid, error: holdErr } = buyerUid
      ? await sbUser.rpc("exos_create_hold", {
        p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity,
        ...(voucherUnlocksTier ? { p_voucher_code: voucherCode } : {}),
      })
      : await sb.rpc("exos_create_guest_hold", {
        p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity, p_email: buyerEmail,
        p_ip_hash: await hashIp(
          clientIp((h) => req.headers.get(h)),
          Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        ),
        p_voucher_code: voucherUnlocksTier ? voucherCode : null,
      });
    if (holdErr) {
      return json({ error: holdErr.message || "not enough tickets available" }, 409);
    }
    holdId = hid as string;
  }

  // A guest's free tickets: no Stripe. Record the order and fulfil it now;
  // exos_fulfill_checkout parks the tickets on the organizer and mails the
  // guest one keyed claim link per ticket, as for a paid guest order.
  if (freeGuest) {
    const sessionId = `free_${crypto.randomUUID()}`;
    const { error: fInsErr } = await sb.from("exos_checkout_sessions").insert({
      session_id: sessionId, event_id, tier_id, org_id: ev.org_id,
      buyer_uid: null, buyer_email: buyerEmail, guest: true,
      quantity, amount_cents: 0, currency, status: "pending",
      addons: addonsForSession.length > 0 ? addonsForSession : null,
      voucher_id: voucherId, promoter_id: promoterId ?? null,
      attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
    });
    if (fInsErr) {
      console.error("exos-checkout: free guest order not recorded", fInsErr.message);
      await releaseHold(sb, holdId);
      return json({ error: "could not record the order" }, 500);
    }
    if (holdId) {
      const { error: linkErr } = await sb.from("exos_cart_holds").update({ checkout_session_id: sessionId }).eq("id", holdId);
      if (linkErr) console.error("exos-checkout: free hold link failed (non-fatal)", linkErr.message);
    }
    const { data: ids, error: fulErr } = await sb.rpc("exos_fulfill_checkout", { p_session_id: sessionId });
    if (fulErr) {
      console.error("exos-checkout: free guest fulfilment failed", fulErr.message);
      await releaseHold(sb, holdId);
      return json({ error: "could not issue the tickets" }, 409);
    }
    const issued = Array.isArray(ids) ? ids.length : 0;
    if (issued === 0) {
      const { data: row } = await sb.from("exos_checkout_sessions").select("failure_reason").eq("session_id", sessionId).maybeSingle();
      return json({ error: row?.failure_reason || "those tickets are no longer available" }, 409);
    }
    return json({ free: true, issued, email: buyerEmail });
  }

  const stripe = new Stripe(stripeKey!, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "payment",
      // Cards only (Apple Pay and Google Pay come with them). Bank debits and
      // other delayed methods would complete "unpaid", outlive the 30-minute
      // hold and settle days later into seats that may be gone.
      payment_method_types: ["card"],
      line_items: lineItems,
      payment_intent_data: {
        application_fee_amount: applicationFee,
        transfer_data: { destination: payments.connectedAccountId },
      },
      // Embedded: card payments finish in place (the iframe's onComplete);
      // only redirect-based methods come back through return_url.
      ...(embedded
        ? { ui_mode: "embedded" as const, return_url: returnUrl, redirect_on_completion: "if_required" as const }
        : { success_url, cancel_url }),
      // Match the 30-minute seat hold (Stripe's minimum) so nobody can pay after
      // their seats went back to the pool and trigger a refund.
      expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
      customer_email: buyerEmail || undefined,
      metadata: {
        exos_event_id: event_id, exos_tier_id: tier_id, exos_buyer_uid: buyerUid ?? "",
        exos_guest: buyerUid ? "" : "1", exos_promoter: promoterId ?? "",
      },
    });
  } catch (e) {
    console.error("exos-checkout: stripe session create failed", e);
    await releaseHold(sb, holdId);
    return json({ error: "could not create checkout session" }, 502);
  }

  const ledgerRow: Record<string, unknown> = {
    session_id: session.id,
    event_id, tier_id, org_id: ev.org_id,
    buyer_uid: buyerUid, buyer_email: buyerEmail,
    ...(buyerUid ? {} : { guest: true }),
    quantity, amount_cents: amountCents, currency, status: "pending",
    addons: addonsForSession.length > 0 ? addonsForSession : null,
    voucher_id: voucherId,
    tax_cents: recordedTax > 0 ? recordedTax : null,
    promoter_id: promoterId ?? null,
    attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
  };
  let { error: insErr } = await sb.from("exos_checkout_sessions").insert(ledgerRow);
  // Deployed before mig 20260924223000 (no promoter_id / attribution columns):
  // record the sale without attribution rather than failing every checkout.
  if (insErr && (insErr.code === "42703" || insErr.code === "PGRST204")) {
    console.error("exos-checkout: attribution columns missing (apply 20260924223000); recording without them");
    delete ledgerRow.promoter_id;
    delete ledgerRow.attribution;
    ({ error: insErr } = await sb.from("exos_checkout_sessions").insert(ledgerRow));
  }
  if (insErr) {
    console.error("exos-checkout: ledger insert failed", insErr);
    await releaseHold(sb, holdId);
    return json({ error: "could not record session" }, 500);
  }

  // Link the hold to the now-existing session so fulfillment consumes it (and it
  // stops counting against availability once the sale lands). Insert-then-link
  // ordering matters: exos_cart_holds.checkout_session_id FKs the session row.
  if (holdId) {
    const { error: linkErr } = await sb.from("exos_cart_holds")
      .update({ checkout_session_id: session.id }).eq("id", holdId);
    if (linkErr) console.error("exos-checkout: hold link failed (non-fatal)", linkErr);
  }

  // Price-disclosure record (mig 20260926070000): what the buyer is shown on
  // Stripe's page, per line, so the charged amount can be checked against it
  // (NY ACAL 25.07 / FTC fee rule). Exos adds no buyer fee. Non-fatal: the
  // sale is already recorded; a missing record is visible in the export.
  const { error: pdErr } = await sb.rpc("exos_record_price_disclosure", {
    p_session_id: session.id,
    p_currency: currency,
    p_lines: [
      {
        kind: "ticket", item_id: tier_id, name: tier.name, quantity,
        face_unit_cents: unitAmount, tax_cents: ticketLineTax,
        tax_included: tierRule?.price_includes_tax === true,
        fee_cents: 0, unit_all_in_cents: ticketAllIn,
      },
      ...addonLines.map((a) => ({
        kind: "addon", item_id: a.id, name: a.name, quantity: a.quantity,
        face_unit_cents: a.unit_face, tax_cents: a.line_tax, tax_included: a.tax_included,
        fee_cents: 0, unit_all_in_cents: a.unit_all_in,
      })),
    ],
  });
  if (pdErr) console.error("exos-checkout: price disclosure record failed (non-fatal)", pdErr);

  if (embedded) return json({ client_secret: session.client_secret, session_id: session.id });
  return json({ url: session.url, session_id: session.id });
});

// Best-effort release of a reservation when checkout can't complete (Stripe
// error, ledger insert failure). Never throws — a stuck hold self-expires via
// the exos_expire_holds cron regardless.
// deno-lint-ignore no-explicit-any
async function releaseHold(sb: SupabaseClient<any, any, any>, holdId: string | null): Promise<void> {
  if (!holdId) return;
  try {
    await sb.from("exos_cart_holds")
      .update({ status: "released", released_at: new Date().toISOString() })
      .eq("id", holdId).eq("status", "active");
  } catch (e) {
    console.error("exos-checkout: hold release failed (non-fatal)", e);
  }
}

// Mirrors public.exos_tax_cents: inclusive extracts the embedded tax from the
// gross; exclusive computes the tax to add on top of the net.
function taxCents(amount: number, ratePercent: number, inclusive: boolean): number {
  if (!ratePercent) return 0;
  return inclusive
    ? Math.round((amount * ratePercent) / (100 + ratePercent))
    : Math.round((amount * ratePercent) / 100);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
