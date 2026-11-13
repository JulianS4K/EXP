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
// Free tier (max capacity 150 or less, operator 2026-10-29): no Exos fee,
// only the card fee (exos_event_fee_terms + exosFeeBpsForEvent).
// TODO(operator) before go-live: confirm the charge model (destination vs
// direct) and that 'standard' Connect accounts are the right type.
// Optional: EXOS_STRIPE_FEE_BPS / EXOS_STRIPE_FEE_FIXED_CENTS (default 290 / 30).
//
// Checkout records (mig 20260929131000): the session row also keeps the ad
// click ids / browser ids and consent the SPA sent (_shared/adIds.ts), the
// request's hashed IP and User-Agent, and the fee split behind the
// application fee (checkoutFeeSplit). Before that migration is applied the
// row is recorded without them.
//
// Organizer fee rules (mig 20261027100000, docs/fees.md): the event's
// passed-on fees are folded into each all-in unit price (allInCents, the same
// function the storefront and the feeds use), so Stripe charges exactly what
// the buyer was shown; no fee line is added. Every fee line, passed on and
// absorbed, is stored in exos_checkout_fee_snapshots (not on the buyer-readable
// session row) and copied to
// exos_order_fees at fulfillment. Not the Exos platform fee above.
//
// Reserved seating (mig 20261030140000, docs/seating.md): a seated tier is
// bought with seat_ids (the picked seats; the quantity is their count). The
// cart hold is created as usual, then exos_hold_seats claims the seats for it
// (409 with the taken seat's name if someone got there first); fulfillment
// gives each ticket its seat. Seated orders always take a hold (no capacity
// bypass) and a free seated order is issued here for signed-in buyers too.
// Before the migration nothing is seated and seat_ids is refused.
//
// Timed entry (mig 20261030150000, docs/series-timed-entry.md): a ticket type
// sold by time slot needs slot_id ('YYYYMMDDTHHMM'). The cart hold is put on
// the slot (exos_attach_hold_slot, race-safe) and the slot rides on the
// session row; fulfillment counts it in the same transaction as the tier. A
// free timed ticket goes through the free path below for signed-in buyers too
// (exos_claim_free_tickets can't pick a slot).
//
// exos: gift cards + giving (mig 20261030130000, docs/gift-cards.md,
// docs/giving.md). Optional body fields: gift_card_code and donation
// { campaign_id, amount_cents }. A donation is its own Stripe line after the
// tax (no fees, never taxed). A gift card pays last: the Stripe session gets a
// one-off coupon for its part, the card is held right after the session row is
// written and captured by exos_fulfill_checkout; an order the card covers in
// full skips Stripe and is fulfilled here. amount_cents on the session stays
// what Stripe charges; gift_card_cents is the rest of the order's value.
//
// exos: memberships (mig 20261030130500, docs/memberships.md): a member
// presale refuses non-members (403, reason member_presale); a member's
// discount applies after any code, before fees and tax, on up to 1 + guest
// allowance tickets, and the session records membership_id.
//
// PayPal / Venmo (mig 20261031220000; operator approval 2026-10-30): a body
// with processor: 'paypal' runs everything above unchanged (price, voucher,
// limits, fee rules, tax, the hold, the session row, the price disclosure)
// and creates a PayPal Orders v2 order on the PLATFORM's PayPal account
// instead of a Stripe session. The order's items are mapped from the same
// charge lines as Stripe's line_items (_shared/chargeLines.ts), so the two
// can't charge different totals. Returns { processor: 'paypal', session_id,
// paypal_order_id, approve_url? }; the buyer approves on the PayPal page
// (/pay/paypal, no Stripe on it: docs/pci.md) and exos-paypal captures.
// Needs the org's opt-in (exos_org_payment_methods.paypal_enabled) and
// PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET (sandbox unless EXOS_PAYPAL_ENV=live,
// _shared/paypal/client.ts). The fee split uses PayPal's rate in the card-fee
// slot (EXOS_PAYPAL_FEE_BPS / EXOS_PAYPAL_FEE_FIXED_CENTS, default 349 / 49).
// paypal_flow: 'redirect' adds PayPal's return/cancel URLs (success_url /
// cancel_url) and returns approve_url; the default ('buttons') is for the
// JS SDK buttons, which also offer Venmo.
//
// Cash App Pay (Stripe): offered next to cards when EXOS_STRIPE_CASHAPP=on,
// the org switched it on (exos_org_payment_methods.cashapp_enabled) and the
// event is in USD. It settles at once like a card, so the webhook and the
// 30-minute hold work unchanged.
//
// Integration (#70 x #77): a gift card can't be combined with PayPal yet (the
// PayPal order would charge the whole order); a PayPal order carries the slot
// and the membership like a Stripe one; the donation is a charge line, so
// Stripe and PayPal charge it the same.

// Commission methods (mig 20261104190000, docs/payouts.md): with
// EXOS_SPLIT_AT_SALE=on or EXOS_PLATFORM_FEE_COMMISSIONS=on (both default
// off), a Stripe order asks exos_commission_checkout_plan how it is charged:
//   destination (every order today, and whenever a switch is off): exactly
//     as before, application_fee_amount + transfer_data;
//   platform_fee: the same destination charge with the promoter's commission
//     added to application_fee_amount;
//   split (split_at_sale + the org owner's switch): a separate charge on the
//     platform with a transfer_group; exos-promoter-payouts transfers the
//     organizer's share and the commissions after the holdback.
// The buyer pays the same all-in price either way. The plan is recorded with
// the session (exos_record_commission_plan); an order charged a new way whose
// plan can't be recorded is expired, never left without one. With both
// switches off no plan is asked for and nothing here changes.

// Checkout questions (mig 20261106110000, docs/checkout-questions.md): a body
// `answers` ({ order: {...}, tickets: [{...}] }) is checked against the event's
// questions with _shared/questions.ts before any hold or payment (400, reason
// "answers"), then stored on the pending order (exos_record_checkout_answers)
// on every path: Stripe, PayPal, a full gift card, a guest's free claim. The
// tickets take them as they're minted (a trigger), so nothing waits on the
// browser. An event without questions changes nothing.

// Group buy v2, "pay separately" (mig 20261108120000, docs/organizer-guide.md
// "Group buys"): a body with group_seat (a seat link's token) buys exactly that
// seat, one ticket of the group's type, as a normal order of the buyer's; a
// body with group_cover (the group id, its host only) buys every unpaid seat.
// Everything above applies unchanged (price, fees, codes, limits, questions,
// guest proof) except the hold: instead of a new one, the checkout claims the
// seat's hold (exos_group_claim; "seat already taken" for a second friend) and
// attaches it to the order it records (exos_group_attach). A failure gives the
// seat back to the group, not to sale (exos_group_unclaim). The order is
// fulfilled only while the seat's hold is live and its own, so a payment after
// the group's deadline fails and is auto-refunded. No seats, add-ons, gift
// cards or donations on a group seat; nothing here changes otherwise.
// Group pay 2 (mig 20261110110000): a timed type's group order takes the
// group's slot (its holds are already on it) and a price-step type's the
// price each seat locked at the start (exos_group_checkout_ctx), never the
// current step or anything the client sends.
// Paused (operator 2026-11-09, mig 20261111120000): a group body gets 403
// group_pay_off unless EXOS_GROUP_PAY=on (unset = off) AND the SQL switch
// group_pay_enabled is on; the env check comes right after the body is parsed.
import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { allInCents, effectiveTierPrice, voucherUnitPrice } from "../_shared/pricing.ts";
import {
  addonPassedOnFees, feeTotals, orderFeeLines, parseFeeRules, tierPassedOnFees, unitFeeTotals, type FeeRule, type UnitFee,
} from "../_shared/fees.ts";
import { isAllowedEmbedReturn, isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import { isEmptyAttribution, readAttribution } from "../_shared/attribution.ts";
import { inAppRecordFor } from "../_shared/inAppBrowser.ts";
import { clientIp, hashIp, normalizeGuestEmail } from "../_shared/guest.ts";
import { capacityLeft } from "../_shared/capacity.ts";
import { newProofToken, proofTokenHash, withProofFragment } from "../_shared/orderProof.ts";
import { isCheckoutCurrency } from "../_shared/currency.ts";
import {
  EXOS_FEE_BPS, FREE_TIER_FEE_BPS, FREE_TIER_MAX_CAPACITY, STRIPE_CARD_FEE, checkoutApplicationFeeCents, checkoutFeeSplit,
  exosFeeBpsForEvent, isFeeFreeAt,
} from "../_shared/platformFee.ts";
import { isEmptyAdIds, normalizeConsent, readAdIds, truncateUserAgent } from "../_shared/adIds.ts";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import {
  giftCardApplied, giftCardOrderFee, memberPriceApplies, memberUnitCents, normalizeAnyGiftCardCode, parseDonationCents,
} from "../_shared/commerce.ts";
import { chargeTotalCents, stripeLineItems, type ChargeLine } from "../_shared/chargeLines.ts";
import { createPayPalClient, paypalConfig } from "../_shared/paypal/client.ts";
import { approveUrl, newPayPalSessionId, PAYPAL_CURRENCIES, paypalOrderBody } from "../_shared/paypal/model.ts";
import { PAYPAL_FEE } from "../_shared/platformFee.ts";
import {
  checkoutChargeMetadata, commissionEnv, needsCommissionPlan, parsePlan, paymentIntentData, planChangesCharge,
  type CommissionPlan,
} from "../_shared/payouts/commissionMethods.ts";
import { validateAnswers, type NormalizedAnswers, type QuestionDef } from "../_shared/questions.ts";
import { GROUP_PAY_OFF, gateGroupClaim, groupPayOffGate } from "../_shared/groupGate.ts";

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
    // Ad click ids + browser ids (mig 20260929131000) and marketing consent.
    ad_ids?: Record<string, unknown>;
    consent?: string;
    // Reserved seating (mig 20261030140000): the picked seats of a seated tier.
    seat_ids?: unknown;
    // timed entry (mig 20261030150000): the chosen time slot.
    slot_id?: string;
    // exos: gift cards + giving (mig 20261030130000).
    gift_card_code?: string;
    donation?: { campaign_id?: string; amount_cents?: number };
    // 'paypal' -> a PayPal / Venmo order instead of a Stripe session.
    processor?: string;
    paypal_flow?: string;
    // The page's own answer to "which in-app browser is this?" (mig 20261105140000).
    in_app_browser?: string;
    // exos: checkout questions (mig 20261106110000): { order: {...}, tickets: [{...}] }.
    answers?: unknown;
    // exos: group pay (mig 20261108120000): a seat link's token, or the group (host's cover).
    group_seat?: string;
    group_cover?: string;
    // exos: Spanish (mig 20261114130000): the language the buyer has the app in.
    lang?: string;
  };
  // Streaming cap: a huge or endless body is never read in full.
  const raw = await readCapped(req, MAX_BODY_BYTES);
  if (raw === null) return json({ error: "request body too large" }, 413);
  try { p = JSON.parse(raw); } catch { return json({ error: "invalid JSON" }, 400); }
  // exos: group pay off (operator 2026-11-09, mig 20261111120000): a group
  // body is refused here, first: before the rate gate, any DB claim or Stripe.
  const groupOff = groupPayOffGate(p, Deno.env.get("EXOS_GROUP_PAY"));
  if (groupOff) return json(groupOff.body, groupOff.status);
  const guestEmail = user ? null : normalizeGuestEmail(p.guest_email);
  if (!user && p.guest_email === undefined) return json({ error: "unauthorized" }, 401);
  if (!user && !guestEmail) return json({ error: "enter a valid email" }, 400);
  const buyerUid = user?.id ?? null;
  const buyerEmail = (user?.email ?? guestEmail ?? "").toLowerCase();
  // exos: group pay — the seat (or the host's cover) decides the event, type and quantity
  // (after the sign-in / guest-email checks: no database read for a stranger).
  const groupIn = await groupCheckout(p, user?.id ?? null);
  if ("error" in groupIn) return json(groupIn.error, groupIn.status);
  const group = groupIn.ref;
  // exos: group pay — a group seat's hold belongs to the group: a checkout that
  // fails gives the seat back to the group (never to sale before the deadline).
  // deno-lint-ignore no-explicit-any
  const releaseHold = async (c: SupabaseClient<any, any, any>, id: string | null): Promise<void> => {
    if (group && id) return await unclaimGroup(c, group, buyerUid, buyerEmail);
    return await releaseCartHold(c, id);
  };
  const { event_id, tier_id, success_url, cancel_url } = p;
  const embedded = p.ui_mode === "embedded";
  const usePayPal = p.processor === "paypal";
  if (p.processor !== undefined && p.processor !== "stripe" && !usePayPal) return json({ error: "unknown processor" }, 400);
  // The PayPal page is its own page, never the embed (docs/pci.md).
  if (usePayPal && embedded) return json({ error: "PayPal isn't available in the embedded checkout" }, 400);
  const returnUrl = p.return_url;
  // Reserved seating: seat ids are "<section>-<row>-<key>"; a seated order's
  // quantity is its seat count.
  const seatIds = Array.isArray(p.seat_ids)
    ? [...new Set(p.seat_ids.filter((x): x is string => typeof x === "string" && /^[A-Za-z0-9-]{5,40}$/.test(x)))]
    : [];
  if (Array.isArray(p.seat_ids) && seatIds.length !== p.seat_ids.length) return json({ error: "invalid seat_ids" }, 400);
  const quantity = seatIds.length > 0 ? seatIds.length : (p.quantity ?? 1);
  const addonReq = Array.isArray(p.addons) ? p.addons : [];
  const voucherCode = (p.voucher_code ?? "").trim();
  const attrIn = p.attribution && typeof p.attribution === "object" ? p.attribution : {};
  const attribution = readAttribution((k) => (attrIn as Record<string, unknown>)[k]);
  const { promoter: promoterId, ...campaignTags } = attribution;
  // Checkout records (mig 20260929131000): sanitized here, whatever the client sent.
  const adIdsIn = p.ad_ids && typeof p.ad_ids === "object" ? p.ad_ids : {};
  const adIds = readAdIds((k) => (adIdsIn as Record<string, unknown>)[k]);
  const consentMarketing = normalizeConsent(p.consent);
  const userAgent = truncateUserAgent(req.headers.get("user-agent"));
  // Instagram / Facebook / ... in-app browser, or 'none' (mig 20261105140000):
  // the request's user agent first, then the page's hint (_shared/inAppBrowser.ts).
  const inAppBrowser = inAppRecordFor(req.headers.get("user-agent"), p.in_app_browser);
  // exos: Spanish (mig 20261114130000): 'en' or 'es', else not recorded.
  const buyerLang = p.lang === "es" || p.lang === "en" ? p.lang : null;
  if (embedded) {
    if (!event_id || !tier_id || !returnUrl) {
      return json({ error: "missing event_id / tier_id / return_url" }, 400);
    }
  } else if (!event_id || !tier_id || !success_url || !cancel_url) {
    return json({ error: "missing event_id / tier_id / success_url / cancel_url" }, 400);
  }
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (allowed.length === 0) return json({ error: "server misconfigured: EXOS_REDIRECT_ORIGINS unset" }, 500);
  // The event's org may also send buyers back to its own verified domains
  // (custom domains, mig 20261016130000). Missing view: env list only.
  {
    const sbDom = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: ev0 } = await sbDom.from("exos_events").select("org_id").eq("id", event_id).maybeSingle();
    const orgId0 = (ev0 as { org_id?: string } | null)?.org_id;
    if (orgId0) {
      const { data: doms } = await sbDom.from("exos_public_org_domains").select("domain").eq("org_id", orgId0).limit(3);
      for (const d of (doms ?? []) as { domain?: string }[]) {
        if (typeof d.domain === "string" && /^[a-z0-9.-]{3,253}$/.test(d.domain)) allowed.push(`https://${d.domain}`);
      }
    }
  }
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

  // Reserved seating (mig 20261030140000). Read on its own so a database
  // without the column reads as general admission.
  let seated = false;
  {
    const { data: st, error: stErr } = await sb.from("exos_ticket_tiers").select("seated").eq("id", tier_id).maybeSingle();
    seated = !stErr && (st as { seated?: boolean } | null)?.seated === true;
  }
  if (seated && seatIds.length === 0) return json({ error: "pick your seats first", reason: "seats_required" }, 400);
  if (!seated && seatIds.length > 0) return json({ error: "this ticket type isn't sold as seats" }, 400);

  const ev = (tier as unknown as { exos_events: { org_id: string; name: string; status: string; currency: string | null } }).exos_events;
  if (ev.status !== "published") return json({ error: "event not on sale" }, 409);
  // Another platform sells this event (mig 20261016100000): Exos doesn't take
  // money for it. An older database without the column reads as 'exos'.
  {
    const { data: be } = await sb.from("exos_events").select("ticket_backend").eq("id", event_id).maybeSingle();
    const backend = (be as { ticket_backend?: string } | null)?.ticket_backend ?? "exos";
    if (backend !== "exos") return json({ error: "tickets for this event are sold on another site", reason: "external_backend" }, 409);
  }
  // Last call (mig 20261029100000): near sell-out only the primary checkout
  // sells. When that isn't Exos, refuse here, before a voucher could bypass
  // the (already empty) count. Before the migration (no RPC) nothing changes.
  {
    const { data: sale } = await sb.rpc("exos_public_event_sale", { p_event_id: event_id });
    const row = (Array.isArray(sale) ? sale[0] : sale) as
      | { last_call?: boolean; sells_on?: string; sells_on_url?: string | null }
      | null
      | undefined;
    if (row?.last_call && row.sells_on && row.sells_on !== "exos") {
      return json({
        error: `the last tickets are on sale at ${row.sells_on === "luma" ? "Luma" : "Eventbrite"}`,
        reason: "last_call", sells_on: row.sells_on, sells_on_url: row.sells_on_url ?? null,
      }, 409);
    }
  }

  // timed entry (mig 20261030150000): is this tier sold by time slot? Before
  // the migration the table is missing: nothing is timed.
  let timedSlot: string | null = null;
  {
    const { data: te, error: teErr } = await sb.from("exos_timed_entry").select("tier_ids").eq("event_id", event_id).maybeSingle();
    if (teErr && !["42P01", "PGRST205"].includes(String(teErr.code))) {
      console.error("exos-checkout: timed entry read failed", teErr.message);
      return json({ error: "could not check time slots, try again" }, 503);
    }
    const timedTiers = (te as { tier_ids?: unknown } | null)?.tier_ids;
    const timed = Array.isArray(timedTiers) && timedTiers.includes(tier_id);
    const slotIn = typeof p.slot_id === "string" ? p.slot_id.trim() : "";
    if (timed && !/^\d{8}T\d{4}$/.test(slotIn)) return json({ error: "pick a date and time slot", reason: "slot_required" }, 400);
    if (!timed && slotIn) return json({ error: "this ticket type isn't sold by time slot" }, 400);
    timedSlot = timed ? slotIn : null;
  }

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
  // Codes need an account (mig 20260929080000): a guest can't try codes here
  // either, so guessing stays on the per-account throttle.
  if (voucherCode && !user) return json({ error: "sign in to use a code" }, 401);
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
    // Reserved seating: a seated order always holds its seats.
    bypassCapacity = v.can_bypass === true && !seated;
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

  // exos: memberships (mig 20261030130500) — a member presale gates the tier
  // (guests and non-members wait), and a member gets their discount on up to
  // 1 + guest allowance tickets. Before the migration: no-op.
  let member: { membership_id: string; discount_percent: number } | null = null;
  {
    const { data: mc, error: mcErr } = await sb.rpc("exos_member_checkout", {
      p_event_id: event_id, p_tier_id: tier_id, p_buyer: buyerUid,
    });
    if (mcErr && mcErr.code !== "PGRST202") {
      console.error("exos-checkout: member check failed", mcErr.message);
      return json({ error: "could not price the order, try again" }, 503);
    }
    const m = mc as { presale_blocked?: boolean; membership_id?: string; discount_percent?: number; guest_allowance?: number } | null;
    if (m?.presale_blocked) return json({ error: "Tickets are on presale for members right now.", reason: "member_presale" }, 403);
    if (m?.membership_id && Number(m.discount_percent) > 0 && memberPriceApplies(quantity, Number(m.guest_allowance ?? 0))) {
      member = { membership_id: m.membership_id, discount_percent: Number(m.discount_percent) };
    }
  }

  // exos: checkout questions (mig 20261106110000, docs/checkout-questions.md):
  // the buyer's answers are checked with the shared rules (_shared/questions.ts)
  // before any hold or payment exists, stored on the pending order right after
  // its row is written (recordAnswers, below), and attached to the tickets as
  // they're minted. Never kept only in the browser.
  const qCheck = await checkAnswers(sb, event_id!, tier_id!, quantity, p.answers);
  if ("error" in qCheck) return json(qCheck.error, qCheck.status);
  const orderAnswers = qCheck.answers;

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
  // Extra methods the org switched on (mig 20261031220000). Missing table or
  // row: neither.
  let orgMethods = { paypal: false, cashapp: false };
  {
    const { data: pm } = await sb.from("exos_org_payment_methods").select("paypal_enabled, cashapp_enabled")
      .eq("org_id", ev.org_id).maybeSingle();
    const row = pm as { paypal_enabled?: boolean; cashapp_enabled?: boolean } | null;
    orgMethods = { paypal: row?.paypal_enabled === true, cashapp: row?.cashapp_enabled === true };
  }
  const ppCfg = usePayPal ? paypalConfig((k) => Deno.env.get(k)) : null;

  const currency = (ev.currency ?? "usd").toLowerCase();
  // Amounts below are minor units = major x 100: two-decimal currencies only
  // (a zero-decimal JPY price would be charged 100 times over).
  if (!isCheckoutCurrency(currency)) {
    return json({ error: `tickets can't be sold in ${currency.toUpperCase()} yet: pick another currency for this event` }, 409);
  }
  if (usePayPal) {
    if (!orgMethods.paypal) return json({ error: "this organizer doesn't take PayPal" }, 409);
    // Gift cards (mig 20261030130000) pay through a Stripe coupon; a PayPal
    // order would charge the whole order.
    if (p.gift_card_code) return json({ error: "a gift card can't be combined with PayPal yet: pay by card" }, 409);
    if (!PAYPAL_CURRENCIES.has(currency)) return json({ error: `PayPal can't take ${currency.toUpperCase()}` }, 409);
  }
  // The event's fee rules in effect (org rules unless opted out, then the
  // event's own). Before the migration the view is missing: no rules, as
  // before. Any other read error stops the sale rather than charging a price
  // the storefront didn't show.
  let feeRules: FeeRule[] = [];
  let feeRulesRead = false;
  {
    const { data: fr, error: frErr } = await sb.from("exos_effective_fee_rules").select("*")
      .eq("event_id", event_id).order("rank", { ascending: true });
    if (frErr && !["42P01", "PGRST205", "PGRST200"].includes(String(frErr.code))) {
      console.error("exos-checkout: fee rules read failed", frErr.message);
      return json({ error: "could not price the order, try again" }, 503);
    }
    if (!frErr) {
      feeRules = parseFeeRules(fr ?? []);
      feeRulesRead = true;
    }
  }
  const ticketFees: UnitFee[] = tierPassedOnFees(feeRules, tier_id);
  const addonFees: UnitFee[] = addonPassedOnFees(feeRules);

  // The tier's price as of now, the same price the storefront shows
  // (early-bird → regular → last-minute), then the voucher's rule: a pinned
  // price, a percent off or an amount off (voucherUnitPrice, shared with the SPA).
  // exos: price steps (mig 20261106130000, docs/price-steps.md): the current
  // step comes from the one SQL function the storefront, the feeds and the
  // APIs read (exos_tier_current_price); it is locked on the hold below.
  // Boundary rule: CAP, an order can't take more than the step has left.
  // Before the migration (no function): the old schedule rule.
  let priceStep: { step_id?: string | null; price_cents?: number; step_remaining?: number | null } | null = null;
  // exos: group pay 2 — a group seat pays the price it locked at the start.
  if (group?.lock) {
    priceStep = { step_id: group.lock.stepId, price_cents: group.lock.priceCents, step_remaining: null };
  } else {
    const { data: cp, error: cpErr } = await sb.rpc("exos_tier_current_price", { p_tier_id: tier_id });
    if (cpErr && !["PGRST202", "42883"].includes(String(cpErr.code))) {
      console.error("exos-checkout: price step read failed", cpErr.message);
      return json({ error: "could not price the order, try again" }, 503);
    }
    if (!cpErr && cp && typeof cp === "object") priceStep = cp as typeof priceStep;
  }
  if (priceStep?.step_id && priceStep.step_remaining != null && quantity > priceStep.step_remaining) {
    const left = Math.max(priceStep.step_remaining, 0);
    return json({
      error: `only ${left} left at this price: buy ${left} now and the rest at the next price`,
      reason: "price_step_remaining", remaining: left, price_cents: priceStep.price_cents ?? null,
    }, 409);
  }
  const scheduled = priceStep && Number.isInteger(priceStep.price_cents)
    ? Number(priceStep.price_cents) / 100
    : effectiveTierPrice(
      Number(tier.price),
      (tier as unknown as { price_schedule?: unknown }).price_schedule,
    );
  const codeUnitAmount = Math.round(voucherUnitPrice(scheduled, { overridePrice, discountPercent, discountAmount }) * 100);
  // exos: memberships — promo first, then the member discount (half up once); fees and tax follow on it.
  const unitAmount = member ? memberUnitCents(codeUnitAmount, member.discount_percent) : codeUnitAmount;
  // A discount that leaves a paid ticket free is a comp, not a sale.
  if (scheduled > 0 && unitAmount <= 0 && overridePrice == null) {
    return json({ error: "that code takes off more than the ticket price" }, 409);
  }

  // Validate + price add-ons server-side (never trust the client's prices). Each
  // must belong to this event, be public, and have stock. Build the priced
  // snapshot stored on the session (fulfillment reads it to record the purchase).
  type AddonRow = { addon_id: string; quantity: number; unit_price_cents: number; name: string };
  const addonsForSession: AddonRow[] = [];
  const addonLines: {
    id: string; name: string; quantity: number; unit_face: number; unit_all_in: number;
    unit_tax: number; unit_fee: number; line_tax: number; tax_included: boolean;
  }[] = [];
  let addonTotal = 0;
  // recordedTax = the tax portion of the order (inclusive or exclusive), stored
  // on the session for invoices/reporting. Exclusive tax is already inside the
  // all-in unit amounts below, never added as a separate charge.
  let recordedTax = 0;
  // All-in pricing: the passed-on fees and the exclusive tax are computed PER
  // UNIT and folded into each line's unit_amount, so the buyer pays exactly the
  // all-in price the storefront showed (allInCents, shared with the SPA).
  // Returns the all-in unit amount; inclusive tax is only recorded (it's
  // already in the price, and in a taxable fee).
  const allInUnit = (
    unitCents: number, qty: number,
    rule: { rate_percent?: number; price_includes_tax?: boolean } | null | undefined,
    fees: readonly UnitFee[],
  ): number => {
    const rate = Number(rule?.rate_percent ?? 0);
    const f = unitFeeTotals(unitCents, fees);
    if (!rate) return unitCents + f.total;
    if (rule?.price_includes_tax === true) {
      recordedTax += taxCents((unitCents + f.taxable) * qty, rate, true);
      return unitCents + f.total;
    }
    const withTax = allInCents(unitCents, rate, fees);
    const tax = (withTax - unitCents - f.total) * qty;
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
        // 1 AND 50). Without this, an add-on with no max_per_order and a large
        // capacity accepts any quantity here, the buyer pays, then
        // fulfillment's INSERT violates the CHECK and rolls back — charged, no
        // tickets, infinite webhook retry. Reject over-cap before charging.
        if (qty > 50) {
          return json({ error: `add-on "${a.name}" limited to 50 per order` }, 409);
        }
        if (a.max_per_order && qty > a.max_per_order) {
          return json({ error: `add-on "${a.name}" limited to ${a.max_per_order} per order` }, 409);
        }
        // Capacity 0 is closed, never unlimited (mig 20261105100000).
        if (capacityLeft(a.capacity, a.sold) < qty) {
          return json({ error: `add-on "${a.name}" is sold out` }, 409);
        }
        const unitCents = Math.round(Number(a.price) * 100);
        const addonRule = (a as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
        const taxBefore = recordedTax;
        const allIn = allInUnit(unitCents, qty, addonRule, addonFees);
        const unitFee = unitFeeTotals(unitCents, addonFees).total;
        addonsForSession.push({ addon_id: a.id, quantity: qty, unit_price_cents: unitCents, name: a.name });
        addonLines.push({
          id: a.id, name: a.name, quantity: qty, unit_face: unitCents, unit_all_in: allIn,
          unit_tax: allIn - unitCents - unitFee, unit_fee: unitFee,
          line_tax: recordedTax - taxBefore, tax_included: addonRule?.price_includes_tax === true,
        });
        addonTotal += allIn * qty;
      }
    }
  }

  // Tier tax (after the voucher price override is applied to unitAmount).
  const tierRule = (tier as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
  const ticketTaxBefore = recordedTax;
  const ticketAllIn = allInUnit(unitAmount, quantity, tierRule, ticketFees);
  const ticketLineTax = recordedTax - ticketTaxBefore;
  const ticketUnitFee = unitFeeTotals(unitAmount, ticketFees).total;

  // Every fee line of the order, passed on and absorbed (exos_order_fees at
  // fulfillment). The passed-on lines are exactly what the unit prices above
  // folded in.
  const feeLines = orderFeeLines(feeRules, {
    tierId: tier_id, ticketUnitCents: unitAmount, quantity,
    addons: addonLines.map((a) => ({ id: a.id, unitCents: a.unit_face, quantity: a.quantity })),
  });
  {
    const inPrices = ticketUnitFee * quantity + addonLines.reduce((n, a) => n + a.unit_fee * a.quantity, 0);
    if (feeTotals(feeLines).passedOn !== inPrices) {
      console.error("exos-checkout: fee breakdown != fees in the prices", feeTotals(feeLines).passedOn, inPrices);
    }
  }
  const feeRecord0 = feeRulesRead ? { fee_breakdown: feeLines } : {};

  // exos: giving — add-a-donation to one of the org's campaigns that offers it
  // at checkout, in the event's currency. Its own line after tax, no fees.
  let donationCents = 0;
  let donationCampaign: { id: string; name: string } | null = null;
  if (p.donation && typeof p.donation === "object") {
    const amt = parseDonationCents(p.donation.amount_cents);
    if (amt === null) return json({ error: "donation must be between 1.00 and 100,000.00" }, 400);
    const { data: camp } = await sb.from("exos_giving_campaigns")
      .select("id, name, org_id, currency, active, checkout_add_on, starts_at, ends_at")
      .eq("id", String(p.donation.campaign_id ?? "")).maybeSingle();
    const now = Date.now();
    if (!camp || camp.org_id !== ev.org_id || !camp.active || !camp.checkout_add_on || camp.currency !== currency
      || (camp.starts_at && Date.parse(camp.starts_at) > now) || (camp.ends_at && Date.parse(camp.ends_at) <= now)) {
      return json({ error: "that campaign isn't taking donations here" }, 409);
    }
    donationCents = amt;
    donationCampaign = { id: camp.id, name: camp.name };
  }

  // addonTotal is already all-in; the exclusive tax sits inside both unit amounts.
  const amountCents = ticketAllIn * quantity + addonTotal + donationCents;

  // exos: gift cards — quoted now (nothing reserved), held after the session
  // row exists. Rate-limited per account or hashed IP in SQL.
  const giftCode = p.gift_card_code ? normalizeAnyGiftCardCode(p.gift_card_code) /* exos: imported codes too (mig 20261102110000) */ : null;
  if (p.gift_card_code && !giftCode) return json({ error: "that gift card code isn't valid (check for a typo)" }, 400);
  const giftBucket = buyerUid
    ? `u:${buyerUid}`
    : `ip:${await hashIp(clientIp((h) => req.headers.get(h)), Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)}`;
  let giftCents = 0;
  let giftLast4 = "";
  // Only a card bought online through Stripe paid the Exos fee when it was sold.
  let giftFeePaidAtSale = false;
  if (giftCode) {
    const { data: gq, error: gqErr } = await sb.rpc("exos_gift_card_quote", {
      p_code: giftCode, p_bucket: giftBucket, p_org_id: ev.org_id, p_currency: currency, p_amount_cents: amountCents,
    });
    if (gqErr) return json({ error: "could not check the gift card, try again" }, 503);
    const q = gq as { error?: string | null; applicable_cents?: number; last4?: string; fee_paid_at_sale?: boolean } | null;
    if (q?.error) return json({ error: q.error }, 409);
    giftCents = giftCardApplied(amountCents, Number(q?.applicable_cents ?? 0));
    if (giftCents <= 0) return json({ error: "this gift card can't pay for this order" }, 409);
    giftLast4 = String(q?.last4 ?? "");
    giftFeePaidAtSale = q?.fee_paid_at_sale === true;
  }
  // What the card is charged. The Exos fee also covers the gift card part
  // unless the card's own online sale already paid it (giftCardOrderFee).
  const chargeCents = amountCents - giftCents;
  const giftFull = giftCents > 0 && chargeCents === 0;
  const commerceRecord: Record<string, unknown> = {
    ...(giftCents > 0 ? { gift_card_cents: giftCents } : {}),
    ...(donationCampaign ? { donation_cents: donationCents, donation_campaign_id: donationCampaign.id } : {}),
    ...(member ? { membership_id: member.membership_id, member_discount_percent: member.discount_percent } : {}),
  };
  // The Exos fee: 3% net after Stripe, from the organizer's share. The
  // platform pays Stripe's card fee under destination charges, so the
  // application fee is 3% plus that fee (_shared/platformFee.ts).
  // No Exos fee during the org's first 6 months (exos_org_billing); card processing still applies.
  const { data: billing } = await sb.from("exos_org_billing").select("fee_free_until").eq("org_id", ev.org_id).maybeSingle();
  const feeFreeUntil = (billing as { fee_free_until?: string } | null)?.fee_free_until;
  const feeNow = new Date();
  // The free tier (mig 20261029090000): no Exos fee on an event with a max
  // capacity of 150 or less. Before that migration (no RPC) the event is
  // charged as before.
  // Judged on max(max capacity, sold + this order): selling past the cap
  // (e.g. a bypass voucher) ends the free tier with the order that crosses.
  const { data: feeTerms } = await sb.rpc("exos_event_fee_terms", {
    p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity,
  });
  const terms = (feeTerms ?? null) as
    | {
      max_capacity?: number | null; sold?: number; order_admissions?: number;
      free_tier_max_capacity?: number; free_tier_fee_bps?: number;
    }
    | null;
  const feeBps = exosFeeBpsForEvent({
    maxCapacity: terms ? terms.max_capacity ?? null : null,
    soldCount: terms?.sold ?? 0,
    orderAdmissions: terms?.order_admissions ?? quantity,
    feeFreeUntil,
    now: feeNow,
    bps: Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? String(EXOS_FEE_BPS)),
    freeTierMaxCapacity: terms?.free_tier_max_capacity ?? FREE_TIER_MAX_CAPACITY,
    freeTierFeeBps: terms?.free_tier_fee_bps ?? FREE_TIER_FEE_BPS,
  });
  // PayPal's rate sits in the card-fee slot for a PayPal order: the
  // organizer's share is worked out exactly as for a Stripe sale.
  const cardFee = usePayPal
    ? {
      bps: Number(Deno.env.get("EXOS_PAYPAL_FEE_BPS") ?? String(PAYPAL_FEE.bps)),
      fixedCents: Number(Deno.env.get("EXOS_PAYPAL_FEE_FIXED_CENTS") ?? String(PAYPAL_FEE.fixedCents)),
    }
    : {
      bps: Number(Deno.env.get("EXOS_STRIPE_FEE_BPS") ?? String(STRIPE_CARD_FEE.bps)),
      fixedCents: Number(Deno.env.get("EXOS_STRIPE_FEE_FIXED_CENTS") ?? String(STRIPE_CARD_FEE.fixedCents)),
    };
  // exos: gift cards — a box-office / comp / API card never paid the Exos fee,
  // so its part of the order owes it too: added to the application fee as far
  // as the card charge allows, the rest recorded as owed (exos_fee_owed_cents;
  // all of it on an order such a card pays in full). Without a gift card this
  // is exactly checkoutApplicationFeeCents / checkoutFeeSplit as before.
  const giftFee = giftCardOrderFee(chargeCents, giftCents, giftFeePaidAtSale, { bps: feeBps, card: cardFee });
  const applicationFee = giftCents > 0 ? giftFee.applicationFeeCents : checkoutApplicationFeeCents(chargeCents, { bps: feeBps, card: cardFee });
  // The same fee, broken down for the order record (mig 20260929131000).
  // Recorded only, never sent to Stripe: application_fee_amount stays
  // applicationFee above.
  const feeSplit = giftCents > 0 ? giftFee : checkoutFeeSplit(chargeCents, { bps: feeBps, card: cardFee });
  const feeRecord = feeSplit.applicationFeeCents === applicationFee
    ? {
      application_fee_cents: feeSplit.applicationFeeCents,
      exos_fee_cents: feeSplit.exosFeeCents,
      card_fee_est_cents: feeSplit.cardFeeEstCents,
      fee_bps: feeSplit.feeBps,
      fee_free: isFeeFreeAt(feeFreeUntil, feeNow),
      ...(giftFee.owedCents > 0 ? { exos_fee_owed_cents: giftFee.owedCents } : {}),
    }
    : {};

  // Only PAID line items go to Stripe ($0 lines are rejected in payment mode), so
  // a free tier + paid add-ons charges just the add-ons. Ticket quantity is still
  // recorded on the session for minting regardless of the tier's price.
  // One list for both processors (_shared/chargeLines.ts): Stripe's
  // line_items and PayPal's items are mapped from it.
  const chargeLines: ChargeLine[] = [];
  // All-in: one line per product at its all-in unit price; the passed-on fees
  // and the tax inside it are disclosed in the line description instead of
  // appearing as extra lines.
  const money = (c: number) => `${(c / 100).toFixed(2)} ${currency.toUpperCase()}`;
  const feeNames = (fees: readonly UnitFee[], unit: number) =>
    fees.filter((f) => unitFeeTotals(unit, [f]).total > 0).map((f) => String(f.name ?? "fee").toLowerCase());
  const taxNote = (unitTax: number, unitFee = 0, names: string[] = []) => {
    const parts = [
      ...(unitFee > 0 ? [`${money(unitFee)} ${names.join(" + ") || "fees"}`] : []),
      ...(unitTax > 0 ? [`${money(unitTax)} tax`] : []),
    ];
    return parts.length ? { description: `Includes ${parts.join(" and ")} per item` } : {};
  };
  if (ticketAllIn > 0) {
    chargeLines.push({
      quantity, unitCents: ticketAllIn,
      name: `${ev.name} — ${tier.name}${member ? " (member price)" : ""}`,
      ...taxNote(ticketAllIn - unitAmount - ticketUnitFee, ticketUnitFee, feeNames(ticketFees, unitAmount)),
    });
  }
  for (const a of addonLines) {
    if (a.unit_all_in > 0) {
      chargeLines.push({
        quantity: a.quantity, unitCents: a.unit_all_in,
        name: `${ev.name} — ${a.name}`, ...taxNote(a.unit_tax, a.unit_fee, feeNames(addonFees, a.unit_face)),
      });
    }
  }
  // exos: giving — the donation line (no fees, no tax).
  if (donationCampaign) {
    chargeLines.push({ quantity: 1, unitCents: donationCents, name: `Donation: ${donationCampaign.name}` });
  }
  const lineItems = stripeLineItems(chargeLines, currency) as Stripe.Checkout.SessionCreateParams.LineItem[];
  if (chargeTotalCents(chargeLines) !== amountCents) {
    console.error("exos-checkout: charge lines != order total", chargeTotalCents(chargeLines), amountCents);
    return json({ error: "could not price the order, try again" }, 503);
  }
  // Free: signed-in buyers use the app's free-claim path; a guest claims here
  // with just an email (below), through the same guest hold and limits.
  // Reserved seating and timed entry: free seats, and a signed-in buyer's free
  // timed ticket, are issued here for everyone (the free-claim RPC can't hold
  // seats or pick a slot).
  const freeGuest = lineItems.length === 0 && (!buyerUid || seated || timedSlot !== null);
  // exos: group pay — a group seat is a paid order.
  if (group && (lineItems.length === 0 || giftFull)) {
    return json({ error: "a group seat is paid by card, Apple Pay, Google Pay or PayPal", reason: "group_free" }, 409);
  }
  if (lineItems.length === 0 && !freeGuest) {
    return json({ error: "nothing to charge — use the free claim path" }, 400);
  }
  if (!freeGuest && !giftFull) {
    if (usePayPal) {
      if (!ppCfg) return json({ error: "PayPal is switched off" }, 503);
    } else if (!stripeKey) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);
    // PayPal money lands on the platform, but the organizer still has to be
    // a verified (Stripe Connect) organizer before Exos sells for them.
    if (!payments.connectedAccountId || !payments.chargesEnabled) {
      return json({ error: "organizer has not completed payment setup" }, 409);
    }
  }

  // Price-disclosure record (mig 20260926070000): what the buyer is shown on
  // Stripe's page, per line, so the charged amount can be checked against it
  // (NY ACAL 25.07 / FTC fee rule). Exos adds no buyer fee; fee_cents is the
  // organizer's passed-on fees inside each line (fee rules). Non-fatal: the
  // sale is already recorded; a missing record is visible in the export.
  // exos: a donation is its own line; a gift card part counts as paid when the
  // charge is recorded (exos_record_price_charged).
  const recordDisclosure = async (sid: string): Promise<void> => {
    const { error: pdErr } = await sb.rpc("exos_record_price_disclosure", {
      p_session_id: sid,
      p_currency: currency,
      p_lines: [
        {
          kind: "ticket", item_id: tier_id, name: tier.name, quantity,
          face_unit_cents: unitAmount, tax_cents: ticketLineTax,
          tax_included: tierRule?.price_includes_tax === true,
          fee_cents: ticketUnitFee * quantity, unit_all_in_cents: ticketAllIn,
        },
        ...addonLines.map((a) => ({
          kind: "addon", item_id: a.id, name: a.name, quantity: a.quantity,
          face_unit_cents: a.unit_face, tax_cents: a.line_tax, tax_included: a.tax_included,
          fee_cents: a.unit_fee * a.quantity, unit_all_in_cents: a.unit_all_in,
        })),
        ...(donationCampaign
          ? [{
            kind: "donation", item_id: donationCampaign.id, name: `Donation: ${donationCampaign.name}`, quantity: 1,
            face_unit_cents: donationCents, tax_cents: 0, tax_included: false, fee_cents: 0, unit_all_in_cents: donationCents,
          }]
          : []),
      ],
    });
    if (pdErr) console.error("exos-checkout: price disclosure record failed (non-fatal)", pdErr);
  };

  // Salted hash of the request IP: the guest hold's rate-limit key and the
  // checkout record's client_ip_hash (the IP itself is never stored).
  const ipHash = await hashIp(
    clientIp((h) => req.headers.get(h)),
    Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  // Proof of email (mig 20261105100000): a guest's tickets (or those of an
  // account whose email isn't confirmed) are released only once the buyer
  // proves the email (a mailed code) or a phone (an SMS code) on this page.
  // The browser keeps the token; the order keeps only its SHA-256, so the
  // code alone (in a mistyped inbox) does nothing.
  const needsProof = !buyerUid || !user?.email_confirmed_at;
  const proofToken = needsProof ? newProofToken() : null;
  const checkoutRecord: Record<string, unknown> = {
    // exos: price steps — the step this order is priced at (its tickets count against it).
    ...(priceStep?.step_id ? { price_step_id: priceStep.step_id } : {}),
    ad_ids: isEmptyAdIds(adIds) ? null : adIds,
    consent_marketing: consentMarketing,
    client_ip_hash: ipHash,
    user_agent: userAgent,
    in_app_browser: inAppBrowser,
    ...(proofToken ? { proof_token_hash: await proofTokenHash(proofToken) } : {}),
    // exos: Spanish: the order's language picks the language of its mail.
    ...(buyerLang ? { lang: buyerLang } : {}),
  };
  const proofOut = proofToken ? { proof_token: proofToken } : {};
  // The same token on the way back, in the return URL's fragment (#pt=), for
  // in-app browsers that block the localStorage the page keeps it in
  // (_shared/orderProof.ts withProofFragment). A fragment never reaches a
  // server; Stripe and PayPal keep the URL, and the token alone releases
  // nothing (the mailed code is still needed). Validated as success_url was.
  const successBack = success_url && proofToken ? withProofFragment(success_url, proofToken) : success_url;

  // Reserve inventory with a cart hold BEFORE creating the Stripe session, so a
  // buyer who is about to pay actually holds the seats (closes the read-then-
  // charge oversell). Bypass vouchers skip it — they may exceed caps, honored at
  // fulfillment. Held for 30 min; released here on failure, consumed at mint,
  // else swept by the exos_expire_holds cron.
  let holdId: string | null = null;
  if (!bypassCapacity || group) {
    // A hidden tier's hold re-checks the voucher (mig 20260925003000). Only
    // sent when needed, so public tiers work before that migration is applied.
    // A guest hold is also where the guest rate limits and the organizer's
    // guestCheckout switch are enforced (guests never bypass, see above).
    // exos: group pay — the seat's own hold, claimed for this buyer, behind
    // the rate limits and the "your page is already open" check
    // (_shared/groupGate.ts), all before any Stripe call.
    let groupHold: string | null = null;
    if (group) {
      const gate = await gateGroupClaim(group, ipHash, {
        rateHit: async (bucket, limit) => {
          const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: limit });
          if (error) throw new Error(error.message);
          return data === true;
        },
        claim: async () => await sb.rpc("exos_group_claim", {
          p_token: group.seat, p_group_id: group.cover, p_buyer: buyerUid, p_email: buyerEmail,
          p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity,
        }),
        openSession: async (id) => {
          if (!stripeKey) return null;
          const st = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
          const cs = await st.checkout.sessions.retrieve(id);
          return { status: cs.status, url: cs.url, client_secret: cs.client_secret };
        },
        reason: groupReason,
      }, { embedded, signedIn: !!buyerUid });
      if (!("hold" in gate)) return json(gate.body, gate.status);
      groupHold = gate.hold;
    }
    const { data: hid, error: holdErr } = group
      ? { data: groupHold as unknown, error: null }
      : buyerUid
      ? await sbUser.rpc("exos_create_hold", {
        p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity,
        ...(voucherUnlocksTier ? { p_voucher_code: voucherCode } : {}),
      })
      : await sb.rpc("exos_create_guest_hold", {
        p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity, p_email: buyerEmail,
        p_ip_hash: ipHash,
        p_voucher_code: voucherUnlocksTier ? voucherCode : null,
      });
    if (holdErr) {
      return json({
        error: holdErr.message || "not enough tickets available",
        ...(group ? { reason: groupReason(holdErr.code) } : {}),
      }, 409);
    }
    holdId = hid as string;
    // timed entry (mig 20261030150000): the hold also takes the slot places.
    // exos: group pay 2 — a group's holds are on its slot from the start.
    if (timedSlot && !group) {
      const { error: slotErr } = await sb.rpc("exos_attach_hold_slot", { p_hold_id: holdId, p_slot_id: timedSlot });
      if (slotErr) {
        await releaseHold(sb, holdId);
        const msg = String(slotErr.message ?? "").replace(/^exos_attach_hold_slot: /, "");
        return json({ error: msg || "that time slot is full", reason: "slot_unavailable" }, 409);
      }
    }
  }

  // exos: price steps — lock the step's price on the hold, under a lock on the
  // type's steps: the step must still be the current one at this price with
  // room for the order; otherwise the buyer is told the new price (nothing is
  // charged). The Stripe amount below is this price; the webhook mints at it.
  if (holdId && priceStep?.step_id && !group?.lock) {
    const { error: lockErr } = await sb.rpc("exos_hold_lock_price", {
      p_hold_id: holdId, p_step_id: priceStep.step_id, p_price_cents: priceStep.price_cents,
    });
    if (lockErr) {
      await releaseHold(sb, holdId);
      const changed = lockErr.code === "XP409";
      const msg = String(lockErr.message ?? "");
      return json({
        error: changed ? "the price just changed: check the new price and try again" : msg.replace(/^price_step_remaining: /, ""),
        reason: changed ? "price_changed" : lockErr.code === "XP410" ? "price_step_remaining" : "price_lock_failed",
      }, 409);
    }
  }

  // Reserved seating: claim the picked seats for this hold (race-safe in SQL).
  if (seated) {
    if (!holdId) return json({ error: "could not hold your seats" }, 409);
    const { data: held, error: seatErr } = await sb.rpc("exos_hold_seats", { p_hold_id: holdId, p_seat_ids: seatIds });
    if (seatErr) {
      await releaseHold(sb, holdId);
      const taken = seatErr.code === "XS409";
      return json({ error: seatErr.message || "those seats are no longer available", ...(taken ? { reason: "seat_taken" } : {}) }, 409);
    }
    const labels = ((held as { seats?: { label?: string }[] } | null)?.seats ?? [])
      .map((x) => x.label).filter((x): x is string => typeof x === "string");
    // The ticket line (its name may end " (member price)", #70).
    const pd = lineItems.find((l) => (l.price_data?.product_data?.name ?? "").startsWith(`${ev.name} — ${tier.name}`))
      ?.price_data?.product_data;
    if (pd && labels.length > 0) {
      pd.description = [pd.description, `Seats: ${labels.join("; ")}`].filter(Boolean).join(". ").slice(0, 500);
    }
  }

  // A guest's free tickets: no Stripe. Record the order and fulfil it now;
  // exos_fulfill_checkout parks the tickets on the organizer and mails the
  // guest one keyed claim link per ticket, as for a paid guest order.
  if (freeGuest) {
    const sessionId = `free_${crypto.randomUUID()}`;
    const fInsErr = await insertSessionRow(sb, {
      session_id: sessionId, event_id, tier_id, org_id: ev.org_id,
      // Reserved seating / timed entry: a signed-in buyer lands here only for
      // free seats or a free timed ticket; the order is theirs, not a guest's.
      buyer_uid: buyerUid, buyer_email: buyerEmail, guest: !buyerUid,
      ...(timedSlot ? { slot_id: timedSlot } : {}),
      quantity, amount_cents: 0, currency, status: "pending",
      addons: addonsForSession.length > 0 ? addonsForSession : null,
      voucher_id: voucherId, promoter_id: promoterId ?? null,
      attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
      ...checkoutRecord,
      ...feeRecord0,
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
    // exos: checkout questions — before the tickets are minted.
    const fAnsErr = await recordAnswers(sb, sessionId, orderAnswers);
    if (fAnsErr) {
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", sessionId).eq("status", "pending");
      return json({ error: fAnsErr, reason: "answers" }, 400);
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
    return json({ free: true, issued, email: buyerEmail, session_id: sessionId, ...proofOut });
  }

  // exos: gift cards — the card covers the whole order: no Stripe. Record the
  // order, hold the card, fulfil now (fulfillment captures the hold; a failure
  // gives it back through the session's status trigger).
  if (giftFull) {
    const sessionId = `gc_${crypto.randomUUID().replaceAll("-", "")}`;
    const gInsErr = await insertSessionRow(sb, {
      session_id: sessionId, event_id, tier_id, org_id: ev.org_id,
      buyer_uid: buyerUid, buyer_email: buyerEmail, ...(buyerUid ? {} : { guest: true }),
      // Timed entry: fulfillment counts the slot from the session row.
      ...(timedSlot ? { slot_id: timedSlot } : {}),
      quantity, amount_cents: 0, currency, status: "pending",
      addons: addonsForSession.length > 0 ? addonsForSession : null,
      voucher_id: voucherId, tax_cents: recordedTax > 0 ? recordedTax : null, promoter_id: promoterId ?? null,
      attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
      ...checkoutRecord, ...commerceRecord, ...feeRecord, ...feeRecord0,
    });
    if (gInsErr) {
      console.error("exos-checkout: gift card order not recorded", gInsErr.message);
      await releaseHold(sb, holdId);
      return json({ error: "could not record the order" }, 500);
    }
    if (holdId) await sb.from("exos_cart_holds").update({ checkout_session_id: sessionId }).eq("id", holdId);
    // exos: checkout questions — before the card is held and the tickets minted.
    const gAnsErr = await recordAnswers(sb, sessionId, orderAnswers);
    if (gAnsErr) {
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", sessionId).eq("status", "pending");
      return json({ error: gAnsErr, reason: "answers" }, 400);
    }
    const { error: ghErr } = await sb.rpc("exos_gift_card_hold", {
      p_code: giftCode, p_session_id: sessionId, p_amount_cents: giftCents, p_bucket: giftBucket,
      p_org_id: ev.org_id, p_currency: currency,
    });
    if (ghErr) {
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", sessionId).eq("status", "pending");
      return json({ error: ghErr.message || "the gift card balance changed, please try again" }, 409);
    }
    await recordDisclosure(sessionId);
    const { data: ids, error: fulErr } = await sb.rpc("exos_fulfill_checkout", { p_session_id: sessionId });
    if (fulErr) {
      // Unexpected: the session stays pending and exos_gift_card_release_stale
      // gives the hold back later.
      console.error("exos-checkout: gift card fulfilment failed", fulErr.message);
      return json({ error: "could not issue the tickets" }, 500);
    }
    const issued = Array.isArray(ids) ? ids.length : 0;
    if (issued === 0) {
      const { data: row } = await sb.from("exos_checkout_sessions").select("failure_reason").eq("session_id", sessionId).maybeSingle();
      return json({ error: row?.failure_reason || "those tickets are no longer available" }, 409);
    }
    await sb.rpc("exos_record_price_charged", { p_session_id: sessionId, p_amount_cents: 0, p_currency: currency });
    return json({ paid_with_gift_card: true, session_id: sessionId, issued, gift_card_cents: giftCents, ...proofOut });
  }

  // PayPal / Venmo: the same priced order, as a PayPal order.
  if (usePayPal) {
    const sessionId = newPayPalSessionId();
    const redirect = p.paypal_flow === "redirect";
    let order: Record<string, unknown>;
    try {
      const pp = createPayPalClient(ppCfg!);
      order = await pp.createOrder(paypalOrderBody({
        sessionId, currency, amountCents, lines: chargeLines,
        brandName: Deno.env.get("EXOS_PAYPAL_BRAND_NAME") ?? "Exos",
        description: ev.name,
        ...(redirect ? { returnUrl: successBack, cancelUrl: cancel_url } : {}),
      }), sessionId);
    } catch (e) {
      console.error("exos-checkout: paypal order create failed", e);
      await releaseHold(sb, holdId);
      return json({ error: "could not start PayPal checkout" }, 502);
    }
    const orderId = typeof order.id === "string" ? order.id : "";
    const ppRow: Record<string, unknown> = {
      session_id: sessionId,
      event_id, tier_id, org_id: ev.org_id,
      buyer_uid: buyerUid, buyer_email: buyerEmail,
      ...(buyerUid ? {} : { guest: true }),
      // Timed entry / memberships, as on the Stripe row.
      ...(timedSlot ? { slot_id: timedSlot } : {}),
      quantity, amount_cents: amountCents, currency, status: "pending",
      processor: "paypal", paypal_order_id: orderId,
      addons: addonsForSession.length > 0 ? addonsForSession : null,
      voucher_id: voucherId,
      tax_cents: recordedTax > 0 ? recordedTax : null,
      promoter_id: promoterId ?? null,
      attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
      ...checkoutRecord,
      ...commerceRecord,
      ...feeRecord,
      ...feeRecord0,
    };
    // A PayPal row without its processor columns would read as Stripe: fail
    // instead (the migration must be applied before PayPal is switched on).
    const ppErr = /^[A-Z0-9]{8,40}$/.test(orderId)
      ? await insertSessionRow(sb, ppRow, { strict: true })
      : { message: "PayPal returned no order id" };
    if (ppErr) {
      console.error("exos-checkout: paypal session not recorded", ppErr);
      await releaseHold(sb, holdId);
      return json({ error: "could not record session" }, 500);
    }
    // exos: group pay — the seat's hold now belongs to this order.
    const pgErr = group ? await attachGroup(sb, sessionId, group) : null;
    if (pgErr) {
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", sessionId).eq("status", "pending");
      return json(pgErr, 409);
    }
    // exos: checkout questions — on the order before the buyer approves.
    const pAnsErr = await recordAnswers(sb, sessionId, orderAnswers);
    if (pAnsErr) {
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", sessionId).eq("status", "pending");
      return json({ error: pAnsErr, reason: "answers" }, 400);
    }
    if (holdId) {
      const { error: linkErr } = await sb.from("exos_cart_holds").update({ checkout_session_id: sessionId }).eq("id", holdId);
      if (linkErr) console.error("exos-checkout: hold link failed (non-fatal)", linkErr);
    }
    await recordDisclosure(sessionId);
    return json({
      processor: "paypal", session_id: sessionId, paypal_order_id: orderId, ...proofOut,
      ...(redirect ? { approve_url: approveUrl(order as { links?: { rel?: string; href?: string }[] }) } : {}),
    });
  }

  const stripe = new Stripe(stripeKey!, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
  // Commission methods: how this order is charged. Asked only when a platform
  // switch is on; any problem means the destination charge, as before.
  let commissionPlan: CommissionPlan | null = null;
  if (needsCommissionPlan(commissionEnv((k) => Deno.env.get(k))) && chargeCents > 0) {
    const cEnv = commissionEnv((k) => Deno.env.get(k));
    const addonNet = addonsForSession.reduce((n, a) => n + a.quantity * a.unit_price_cents, 0);
    const { data: cp, error: cpErr } = await sb.rpc("exos_commission_checkout_plan", {
      p_event_id: event_id, p_tier_id: tier_id, p_promoter_code: promoterId ?? null, p_quantity: quantity,
      p_charge_cents: chargeCents, p_addon_net_cents: addonNet, p_tax_cents: recordedTax,
      p_application_fee_cents: applicationFee, p_processor: "stripe",
      p_split_on: cEnv.splitAtSale, p_fee_on: cEnv.platformFeeCommissions,
    });
    if (cpErr) console.error("exos-checkout: commission plan unavailable; destination charge as before", cpErr.message);
    else commissionPlan = parsePlan(cp);
  }
  // Cash App Pay next to cards: platform switch + org opt-in + USD.
  const cashApp = Deno.env.get("EXOS_STRIPE_CASHAPP") === "on" && orgMethods.cashapp && currency === "usd";

  // exos: gift cards — line items can't be negative, so the card's part is a
  // one-off coupon on the platform account (the receipt still lists every line).
  let giftCoupon: string | null = null;
  if (giftCents > 0) {
    try {
      const c = await stripe.coupons.create({
        amount_off: giftCents, currency, duration: "once", max_redemptions: 1,
        name: `Gift card ending ${giftLast4}`.slice(0, 40),
      });
      giftCoupon = c.id;
    } catch (e) {
      console.error("exos-checkout: gift card coupon failed", e);
      await releaseHold(sb, holdId);
      return json({ error: "could not apply the gift card, try again" }, 502);
    }
  }

  // The hold lasts until this moment + 10 minutes (mig 20261105100000): a
  // payment Stripe accepts just before the page closes, whose webhook is
  // late, still lands on a seat held for it. Recorded on the session row.
  const stripeExpiresAt = Math.floor(Date.now() / 1000) + 30 * 60;
  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "payment",
      // Cards only (Apple Pay and Google Pay come with them). Bank debits and
      // other delayed methods would complete "unpaid", outlive the 30-minute
      // hold and settle days later into seats that may be gone.
      // Cash App Pay (mig 20261031220000) settles at once too; USD only.
      payment_method_types: cashApp ? ["card", "cashapp"] : ["card"],
      line_items: lineItems,
      ...(giftCoupon ? { discounts: [{ coupon: giftCoupon }] } : {}),
      // Destination charge (application fee + transfer), unless the
      // commission plan says split at sale or a commission in the fee.
      payment_intent_data: paymentIntentData(commissionPlan, {
        applicationFeeCents: applicationFee, destination: payments.connectedAccountId!,
      }),
      // Embedded: card payments finish in place (the iframe's onComplete);
      // only redirect-based methods come back through return_url.
      ...(embedded
        ? { ui_mode: "embedded" as const, return_url: returnUrl, redirect_on_completion: "if_required" as const }
        : { success_url: successBack, cancel_url }),
      // Stripe's minimum (30 minutes), set explicitly: the seat hold runs to
      // this + 10 minutes, so nobody pays after their seats went back to the
      // pool, and a late webhook still finds its seat.
      expires_at: stripeExpiresAt,
      customer_email: buyerEmail || undefined,
      // exos: Spanish: Stripe's own page in the buyer's language (else Stripe's default, the browser's).
      ...(buyerLang === "es" ? { locale: "es" as const } : {}),
      billing_address_collection: "auto", // buyer location (mig 20261106140000): country + postal code, never "required"
      metadata: {
        exos_event_id: event_id, exos_tier_id: tier_id, exos_buyer_uid: buyerUid ?? "",
        exos_guest: buyerUid ? "" : "1", exos_promoter: promoterId ?? "",
        ...(timedSlot ? { exos_slot: timedSlot } : {}),
        ...(giftCents > 0 ? { exos_gift_card_cents: String(giftCents), exos_gift_card_last4: giftLast4 } : {}),
        ...(donationCampaign ? { exos_donation_cents: String(donationCents) } : {}),
        ...checkoutChargeMetadata(commissionPlan),
      },
    });
  } catch (e) {
    console.error("exos-checkout: stripe session create failed", e);
    await releaseHold(sb, holdId);
    return json({ error: "could not create checkout session" }, 502);
  }

  const ledgerRow: Record<string, unknown> = {
    session_id: session.id,
    provider_expires_at: new Date((session.expires_at || stripeExpiresAt) * 1000).toISOString(),
    event_id, tier_id, org_id: ev.org_id,
    buyer_uid: buyerUid, buyer_email: buyerEmail,
    ...(buyerUid ? {} : { guest: true }),
    quantity, amount_cents: chargeCents, currency, status: "pending",
    addons: addonsForSession.length > 0 ? addonsForSession : null,
    voucher_id: voucherId,
    // timed entry (mig 20261030150000)
    ...(timedSlot ? { slot_id: timedSlot } : {}),
    tax_cents: recordedTax > 0 ? recordedTax : null,
    promoter_id: promoterId ?? null,
    attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
    ...checkoutRecord,
    ...commerceRecord,
    ...feeRecord,
    ...feeRecord0,
  };
  const insErr = await insertSessionRow(sb, ledgerRow);
  if (insErr) {
    console.error("exos-checkout: ledger insert failed", insErr);
    await releaseHold(sb, holdId);
    return json({ error: "could not record session" }, 500);
  }
  // exos: group pay — the seat's hold now belongs to this order; if the seat
  // was taken meanwhile, nobody can pay on this page.
  const sgErr = group ? await attachGroup(sb, session.id, group) : null;
  if (sgErr) {
    try { await stripe.checkout.sessions.expire(session.id); } catch (e) { console.error("exos-checkout: expire failed", e); }
    await releaseHold(sb, holdId);
    await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", session.id).eq("status", "pending");
    return json(sgErr, 409);
  }
  // exos: checkout questions — on the pending order before the buyer pays, so a
  // buyer who pays and comes back later (or a late webhook) loses nothing.
  const sAnsErr = await recordAnswers(sb, session.id, orderAnswers);
  if (sAnsErr) {
    try { await stripe.checkout.sessions.expire(session.id); } catch (e) { console.error("exos-checkout: expire failed", e); }
    await releaseHold(sb, holdId);
    await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", session.id).eq("status", "pending");
    return json({ error: sAnsErr, reason: "answers" }, 400);
  }

  // The commission plan sits next to the session. An order charged a new way
  // (split, or a commission in the fee) must have it: otherwise expire it.
  if (commissionPlan) {
    const { data: recorded, error: recErr } = await sb.rpc("exos_record_commission_plan", {
      p_session_id: session.id, p_plan: commissionPlan,
    });
    if ((recErr || recorded !== true) && planChangesCharge(commissionPlan)) {
      console.error("exos-checkout: commission plan not recorded; expiring", session.id, recErr?.message);
      try { await stripe.checkout.sessions.expire(session.id); } catch (e) { console.error("exos-checkout: expire failed", e); }
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", session.id).eq("status", "pending");
      return json({ error: "could not start checkout, try again" }, 503);
    }
    if (recErr) console.error("exos-checkout: commission plan not recorded (destination charge, non-fatal)", recErr.message);
  }

  // Link the hold to the now-existing session so fulfillment consumes it (and it
  // stops counting against availability once the sale lands). Insert-then-link
  // ordering matters: exos_cart_holds.checkout_session_id FKs the session row.
  if (holdId) {
    const { error: linkErr } = await sb.from("exos_cart_holds")
      .update({ checkout_session_id: session.id }).eq("id", holdId);
    if (linkErr) console.error("exos-checkout: hold link failed (non-fatal)", linkErr);
  }

  // exos: gift cards — the card's part leaves the balance now. If it moved
  // since the quote, the buyer never saw the Stripe page: expire it.
  if (giftCents > 0) {
    const { error: ghErr } = await sb.rpc("exos_gift_card_hold", {
      p_code: giftCode, p_session_id: session.id, p_amount_cents: giftCents, p_bucket: giftBucket,
      p_org_id: ev.org_id, p_currency: currency,
    });
    if (ghErr) {
      try { await stripe.checkout.sessions.expire(session.id); } catch (e) { console.error("exos-checkout: expire failed", e); }
      await releaseHold(sb, holdId);
      await sb.from("exos_checkout_sessions").update({ status: "expired" }).eq("session_id", session.id).eq("status", "pending");
      return json({ error: ghErr.message || "the gift card balance changed, please try again" }, 409);
    }
  }

  await recordDisclosure(session.id);

  if (embedded) return json({ client_secret: session.client_secret, session_id: session.id, ...proofOut });
  return json({ url: session.url, session_id: session.id, ...proofOut });
});

// Columns added by mig 20260929131000 (checkout records). Nice to have, never
// worth losing a sale over.
const RECORD_COLUMNS = [
  "ad_ids", "consent_marketing", "client_ip_hash", "user_agent", "in_app_browser",
  "application_fee_cents", "exos_fee_cents", "card_fee_est_cents", "fee_bps", "fee_free",
  // mig 20261105100000 (hold timing, proof of email)
  "provider_expires_at", "proof_token_hash",
];

// Insert the checkout session row. Deployed before a migration that adds
// columns, it records the sale without them rather than failing every
// checkout: first without the checkout-record columns (mig 20260929131000;
// also on a CHECK violation from one of them), then without attribution
// (mig 20260924223000). Returns the final error, if any.
async function insertSessionRow(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>,
  row: Record<string, unknown>,
  // strict: no fallbacks (a PayPal row must keep every column it was given).
  opts: { strict?: boolean } = {},
) {
  const missingColumn = (e: { code?: string } | null) => !!e && (e.code === "42703" || e.code === "PGRST204");
  // The fee lines (absorbed ones included) go to their own service-role-only
  // table, not the session row the buyer can read (mig 20261027100000).
  const feeLines = row.fee_breakdown;
  delete row.fee_breakdown;
  let { error } = await sb.from("exos_checkout_sessions").insert(row);
  // in_app_browser (mig 20261105140000) is reporting only: before that
  // migration, drop just it, even from a strict (PayPal) row.
  if (missingColumn(error) && "in_app_browser" in row && /in_app_browser/.test(error?.message ?? "")) {
    console.error("exos-checkout: in_app_browser column missing (apply 20261105140000); recording without it");
    delete row.in_app_browser;
    ({ error } = await sb.from("exos_checkout_sessions").insert(row));
  }
  // exos: Spanish: lang (mig 20261114130000) only picks the mail's language:
  // before that migration, drop just it, even from a strict (PayPal) row.
  if (missingColumn(error) && "lang" in row && /\blang\b/.test(error?.message ?? "")) {
    console.error("exos-checkout: lang column missing (apply 20261114130000); recording without it");
    delete row.lang;
    ({ error } = await sb.from("exos_checkout_sessions").insert(row));
  }
  if (error && opts.strict) return error;
  if (error && (missingColumn(error) || error.code === "23514") && RECORD_COLUMNS.some((k) => k in row)) {
    console.error("exos-checkout: checkout-record columns refused (apply 20260929131000?); recording without them", error.message);
    for (const k of RECORD_COLUMNS) delete row[k];
    ({ error } = await sb.from("exos_checkout_sessions").insert(row));
  }
  if (missingColumn(error) && ("promoter_id" in row || "attribution" in row)) {
    console.error("exos-checkout: attribution columns missing (apply 20260924223000); recording without them");
    delete row.promoter_id;
    delete row.attribution;
    ({ error } = await sb.from("exos_checkout_sessions").insert(row));
  }
  if (!error && Array.isArray(feeLines)) {
    // Best effort: without a snapshot, fulfillment records the absorbed fees
    // from the current rules (exos_record_order_fees).
    const { error: snapErr } = await sb.from("exos_checkout_fee_snapshots")
      .insert({ session_id: row.session_id, lines: feeLines });
    if (snapErr) console.error("exos-checkout: fee snapshot not recorded (non-fatal)", snapErr.message);
  }
  return error;
}

// exos: checkout questions (mig 20261106110000). The event's questions for this
// tier, and the body's answers checked against them (_shared/questions.ts, the
// same rules as the SQL). { answers: undefined } when the event asks nothing
// (or the migration isn't applied yet).
async function checkAnswers(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>, eventId: string, tierId: string, quantity: number, raw: unknown,
): Promise<{ answers: NormalizedAnswers | undefined } | { error: Record<string, unknown>; status: number }> {
  const { data, error } = await sb.rpc("_exos_checkout_question_ctx", {
    p_event_id: eventId, p_tier_id: tierId, p_quantity: quantity,
  });
  if (error) {
    if (["PGRST202", "42883"].includes(String(error.code))) return { answers: undefined };
    console.error("exos-checkout: questions read failed", error.message);
    return { error: { error: "could not check your answers, try again" }, status: 503 };
  }
  const ctx = (data ?? {}) as { questions?: QuestionDef[]; ticket_tiers?: string[] };
  const questions = Array.isArray(ctx.questions) ? ctx.questions : [];
  if (questions.length === 0) return { answers: undefined };
  const r = validateAnswers(questions, raw ?? null, { ticketTiers: ctx.ticket_tiers ?? [tierId], require: true });
  if (!r.ok) {
    const first = r.problems[0];
    const q = questions.find((x) => x.id === first?.question_id);
    return {
      error: {
        error: q ? `"${q.label}"${first.ticket ? ` (ticket ${first.ticket})` : ""}: ${problemWords(first.code)}` : "check your answers",
        reason: "answers", problems: r.problems,
      },
      status: 400,
    };
  }
  return { answers: r.answers };
}

function problemWords(code: string): string {
  return code === "required" ? "an answer is required" : code.replace(/_/g, " ");
}

// Store the checked answers on the pending order (exos_record_checkout_answers
// checks them again). Returns null when stored (or nothing to store), else a
// message for the buyer.
async function recordAnswers(
  // deno-lint-ignore no-explicit-any
  sb: SupabaseClient<any, any, any>, sessionId: string, answers: NormalizedAnswers | undefined,
): Promise<string | null> {
  if (answers === undefined) return null;
  const { error } = await sb.rpc("exos_record_checkout_answers", { p_session_id: sessionId, p_answers: answers });
  if (!error) return null;
  console.error("exos-checkout: answers not recorded", error.message);
  return error.code === "22023" ? String(error.message ?? "check your answers") : "could not save your answers, try again";
}

// exos: group pay (mig 20261108120000). A body's group_seat / group_cover,
// checked and resolved to the group's event, type and quantity (written into
// the body, so everything after prices exactly that). ref null: not a group order.
// lock: the face price (and step) the seats locked at the start, for a
// price-step type (mig 20261110110000); null: priced as any order.
type GroupRef = {
  seat: string | null; cover: string | null;
  lock: { priceCents: number; stepId: string | null } | null;
};
const GROUP_REASONS: Record<string, string> = {
  XG404: "group_link", XG403: "group_host", XG410: "group_closed", XG411: "group_paid",
  XG409: "seat_taken", XG412: "group_changed", XG400: "group_link", XG429: "seat_checkout_open",
  XGOFF: "group_pay_off",
};
function groupReason(code: unknown): string {
  return GROUP_REASONS[String(code ?? "")] ?? "group";
}
async function groupCheckout(
  p: {
    group_seat?: string; group_cover?: string; event_id?: string; tier_id?: string; quantity?: number;
    seat_ids?: unknown; slot_id?: string; gift_card_code?: string; donation?: unknown; addons?: unknown[];
  },
  uid: string | null,
): Promise<{ ref: GroupRef | null } | { error: Record<string, unknown>; status: number }> {
  if (p.group_seat === undefined && p.group_cover === undefined) return { ref: null };
  const seat = typeof p.group_seat === "string" && /^[0-9a-f]{32}$/.test(p.group_seat) ? p.group_seat : null;
  const cover = typeof p.group_cover === "string" && /^[0-9a-f-]{36}$/i.test(p.group_cover) ? p.group_cover.toLowerCase() : null;
  if ((seat === null) === (cover === null)) return { error: { error: "this group link isn't valid", reason: "group_link" }, status: 400 };
  if (cover && !uid) return { error: { error: "sign in to cover the rest", reason: "group_host" }, status: 401 };
  if (p.seat_ids !== undefined || p.slot_id || p.gift_card_code || p.donation || (Array.isArray(p.addons) && p.addons.length > 0)) {
    return { error: { error: "a group seat is just the ticket: no seats, add-ons, gift cards or donations" }, status: 400 };
  }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await sb.rpc("exos_group_checkout_ctx", { p_token: seat, p_group_id: cover, p_buyer: uid });
  const ctx = data as {
    event_id?: string; tier_id?: string; quantity?: number;
    slot_id?: string | null; unit_price_cents?: number | null; price_step_id?: string | null;
  } | null;
  // exos: group pay off — the SQL switch (group_pay_enabled) answers XGOFF.
  if (error?.code === "XGOFF") return { error: { ...GROUP_PAY_OFF }, status: 403 };
  if (error || !ctx?.event_id || !ctx.tier_id || !ctx.quantity) {
    return { error: { error: error?.message || "this group link isn't valid", reason: groupReason(error?.code) }, status: 409 };
  }
  p.event_id = ctx.event_id;
  p.tier_id = ctx.tier_id;
  p.quantity = ctx.quantity;
  // exos: group pay 2 — the group's slot, and the price its seats locked.
  if (typeof ctx.slot_id === "string" && /^\d{8}T\d{4}$/.test(ctx.slot_id)) p.slot_id = ctx.slot_id;
  const lock = Number.isInteger(ctx.unit_price_cents) && Number(ctx.unit_price_cents) > 0
    ? { priceCents: Number(ctx.unit_price_cents), stepId: typeof ctx.price_step_id === "string" ? ctx.price_step_id : null }
    : null;
  return { ref: { seat, cover, lock } };
}
// The order just recorded takes the claimed seat(s)' holds; an error body if
// the seat was taken meanwhile.
// deno-lint-ignore no-explicit-any
async function attachGroup(sb: SupabaseClient<any, any, any>, sessionId: string, g: GroupRef): Promise<Record<string, unknown> | null> {
  const { error } = await sb.rpc("exos_group_attach", { p_session_id: sessionId, p_token: g.seat, p_group_id: g.cover });
  if (!error) return null;
  console.error("exos-checkout: group attach failed", error.message);
  return { error: error.message || "seat already taken", reason: groupReason(error.code) };
}
// deno-lint-ignore no-explicit-any
async function unclaimGroup(sb: SupabaseClient<any, any, any>, g: GroupRef, uid: string | null, email: string): Promise<void> {
  try {
    await sb.rpc("exos_group_unclaim", { p_token: g.seat, p_group_id: g.cover, p_buyer: uid, p_email: email || null });
  } catch (e) {
    console.error("exos-checkout: group unclaim failed (non-fatal)", e);
  }
}

// Best-effort release of a reservation when checkout can't complete (Stripe
// error, ledger insert failure). Never throws — a stuck hold self-expires via
// the exos_expire_holds cron regardless. (A group seat's checkout calls
// unclaimGroup instead: see the handler's releaseHold.)
// deno-lint-ignore no-explicit-any
async function releaseCartHold(sb: SupabaseClient<any, any, any>, holdId: string | null): Promise<void> {
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
