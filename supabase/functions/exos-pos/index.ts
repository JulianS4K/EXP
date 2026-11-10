// exos-pos — venue POS (Phase 3, docs/pos.md).
//
// Walk-up sales at the door (mig 20261107100000): door staff sell tickets for
// cash or as a comp, hand them over (a one-time QR on the staff screen, paper,
// or email), void or refund a sale, and pay cash out of a drawer.
//
// Card at the door (mig 20261107130000, docs/pos.md "Card at the door"):
// Stripe Terminal, behind EXOS_POS_CARD=on (and a live Stripe key only with
// EXOS_POS_CARD_LIVE=on too). Off: every card action answers 501 as before.
// On: a walk-up with payment "card" starts a pending sale; card_payment makes
// the card_present PaymentIntent (destination charge + application fee, like
// exos-checkout) and sends it to a smart reader (server-driven) or hands its
// client secret to a Terminal SDK; card_status / capture poll it, capture
// once the reader authorized and complete the sale with the PaymentIntent as
// terminal_ref; card_cancel or a decline cancels it (places back). A void /
// refund of a card sale refunds the card at Stripe and writes the reversal
// ledger row. stripe-webhook completes or releases a sale whose door app went
// away. No card data is ever accepted or stored: a request carrying a
// card-looking field is refused before anything else; the reader handles the
// card and Exos keeps only the PaymentIntent id.
//
// Kiosk mode (mig 20261113100000, docs/pos.md "Kiosk mode"): a self-serve
// screen sells one event's public ticket types by card on its own reader.
// kiosk_* actions carry no staff JWT: the body's kiosk_token (the credential
// exos_pos_kiosk_enter showed once) is resolved in SQL first by every
// service-role core (_exos_pos_kiosk_*), which then reach the card walk-up
// path as the member who started the kiosk:
//   kiosk_state   the event, its public types, questions, the reader; card.on
//   kiosk_begin   { tier_id, quantity, order_key, answers } -> pending sale
//   kiosk_charge  { order_id } -> the PaymentIntent on the kiosk's reader
//   kiosk_status  { order_id } -> waiting | succeeded | declined | canceled
//   kiosk_cancel  { order_id } -> the reader stopped, the sale cancelled
//   kiosk_codes   { order_id } -> the ticket QR codes (10 minutes after paying)
//   kiosk_email   { order_id, email } -> queued mail
//   kiosk_exit    { pin } -> leaves kiosk mode (a pending card sale is cancelled)
// With EXOS_POS_CARD off only kiosk_state and kiosk_exit answer (the screen
// says it's unavailable). No cash, comps, voids or refunds at a kiosk.
//
// Auth: the caller's Supabase JWT (auth.getUser). Cash / comp calls go through
// a client carrying that JWT, so the SQL decides who may do what (the role
// checks, the per-device rate limit and the idempotency are all in SQL):
//   catalog              door staff of the event (exos_pos_can_ring)
//   settlement_preview   owner / manager / finance (exos_pos_settlement_summary)
//   walkup_catalog       door staff: ticket types at the door price, what's left,
//                        the questions, the open drawers, can_comp; with the card
//                        switch on, the readers the member may charge on
//   mint_walkup          door staff; comps owner / manager (exos_pos_walkup_sell)
//   recent_sales         door staff (exos_pos_recent_sales)
//   void_order           the seller or an owner / manager, same night, before a
//                        scan (exos_pos_void_order)
//   refund_order         owner / manager; after a scan only with override
//   paid_out             owner / manager or the drawer's holder (exos_pos_paid_out)
//   order_codes          door staff: one-time print codes for the sale's tickets
//   email_order          door staff: email the sale's tickets (account or claim link)
// Card calls use the service role, but every one goes first through a
// service-role-only SQL core that takes the caller's id and checks the role
// and the rate limit BEFORE any Stripe call (_exos_pos_card_*,
// _exos_pos_terminal_*):
//   terminal_location    owner / manager: the org's Stripe Terminal Location
//   register_reader      owner / manager: a smart reader by its registration code
//   connection_token     door staff of the event (Terminal SDK), scoped to the location
//   card_payment         the seller / owner / manager of the pending sale
//   card_status, capture door staff of the event (polling); captures when ready
//   card_cancel          the seller / owner / manager
//
// Actions (POST JSON, at most 64 KB):
//   { action: "mint_walkup", event_id, tier_id, quantity, order_key (UUID per
//     sale), comp_quantity?, payment?: "cash" | "comp" | "card", device_id?, drawer_id?,
//     buyer_name?, buyer_email?, answers?, comp_reason?, skip_questions? } -> the order (pending for card)
//     Required checkout questions must be answered unless skip_questions is
//     true: the seller's explicit skip, logged in SQL (mig 20261108110000).
//   { action: "card_payment", order_id, mode?: "reader" | "sdk", reader_device_id? }
//     -> { order_id, card: { status, payment_intent, client_secret? (sdk) } }
//   { action: "card_status" | "capture", order_id } -> { state, order?, decline_code? }
//   { action: "card_cancel", order_id, reason? } -> { state, order }
//   { action: "connection_token", event_id } -> { secret, location_id }
//   { action: "terminal_location", org_id | event_id, display_name?, address? }
//   { action: "register_reader", org_id | event_id, registration_code, label, event_only? }
//   { action: "void_order", order_id, reason, drawer_id? }
//   { action: "refund_order", order_id, reason, override?, drawer_id? }
//   { action: "paid_out", drawer_id, amount_cents, reason, key? }
//   { action: "order_codes", order_id } -> { tickets: [{ ticket_id, print_code, … }], skipped }
//   { action: "email_order", order_id, email }
//   { action: "walkup_catalog" | "recent_sales" | "catalog" | "settlement_preview", event_id }
//   { action: "charge" | "collect_payment" | "refund" | "preauth_tab" | "close_tab_payment", ... }
//     -> 501 { error: "not_implemented" } (tabs and bar cards aren't built)
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY. Card at the door also:
// SUPABASE_SERVICE_ROLE_KEY (platform-injected), STRIPE_SECRET_KEY,
// EXOS_POS_CARD=on. Optional: EXOS_POS_CARD_LIVE=on (a live key),
// EXOS_POS_CARD_ON_BEHALF_OF=on (the connected account as settlement
// merchant), EXOS_STRIPE_TERMINAL_FEE_BPS / _FIXED_CENTS (default 270 / 5),
// EXOS_REFUND_KEEP_PLATFORM_FEE=true. Deploy with JWT verification ON.
// Deploying is operator-gated like every function (CLAUDE.md).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { lineTotals, type PosCategory, PaymentsNotWiredError, WALKUP_CARD_MESSAGE } from "../_shared/pos/index.ts";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import {
  advanceCard, cancelCard, type CardDb, CardDbError, type CardFlowOpts, type CardPlan, type CardRefundState, cardSwitch, type CardSwitch,
  isRegistrationCode, refundCardSale, startCardPayment, terminalAddress, terminalCardFee, type TerminalStripe,
} from "../_shared/pos/stripeTerminal.ts";
import { posStripe, terminalStripe } from "../_shared/pos/stripeAdapter.ts";
import { isCheckoutCurrency } from "../_shared/currency.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Not built (tabs, bar / merch cards): always 501. A card walk-up is
// refunded with void_order / refund_order.
const PAYMENT_ACTIONS = new Set(["charge", "collect_payment", "refund", "preauth_tab", "close_tab_payment"]);
// Card at the door (mig 20261107130000): 501 unless EXOS_POS_CARD=on.
const CARD_ACTIONS = new Set([
  "card_payment", "capture", "card_status", "card_cancel", "connection_token", "register_reader", "terminal_location",
]);
const CARD_OFF_MESSAGE = "Card at the door is switched off (EXOS_POS_CARD). Walk-up sales take cash or a comp.";
// Kiosk mode (mig 20261113100000): the kiosk's credential, never a staff JWT.
const KIOSK_ACTIONS = new Set([
  "kiosk_state", "kiosk_begin", "kiosk_charge", "kiosk_status", "kiosk_cancel", "kiosk_codes", "kiosk_email", "kiosk_exit",
]);
const KIOSK_TOKEN_RE = /^exk_[0-9a-f]{64}$/;
const KIOSK_OFF_MESSAGE = "This kiosk is unavailable: card payments are switched off. Please buy at the box office.";

// Field names that could only hold card data. Refused anywhere in the body.
const CARD_FIELD_RE = /^(card(_?number)?|pan|cc(_?num(ber)?)?|cvc|cvv|cvv2|csc|exp(iry|iration)?(_?(month|year|date))?|exp_(month|year)|track_?[12]?|magstripe|cardholder(_?name)?)$/i;

type ItemRow = {
  id: string;
  category: PosCategory;
  name: string;
  sku: string | null;
  price_cents: number;
  active: boolean;
  is_86d: boolean;
  inventory_count: number | null;
  sort_order: number;
  exos_tax_rules: { rate_percent: number; price_includes_tax: boolean } | null;
};

/** True when any key, at any depth, names a card field. */
function hasCardField(v: unknown, depth = 0): boolean {
  if (depth > 6 || v === null || typeof v !== "object") return false;
  if (Array.isArray(v)) return v.some((x) => hasCardField(x, depth + 1));
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (CARD_FIELD_RE.test(k)) return true;
    if (hasCardField(x, depth + 1)) return true;
  }
  return false;
}

/** A Postgres error from an RPC, as an HTTP answer (the SQL message is ours, never another org's data). */
function dbError(e: { code?: string; message?: string; hint?: string } | null): Response {
  const code = e?.code ?? "";
  const msg = e?.message ?? "request failed";
  const hint = e?.hint ?? null;
  const status = code === "42501" ? 403
    : code === "P0002" ? 404
    : code === "54000" ? 429
    : code === "0A000" ? 501
    : code === "22023" || code === "22P02" ? 400
    : code === "23514" || code === "23505" || code === "55000" || code === "XP409" || code === "XP410" ? 409
    : 500;
  if (status === 500) return json({ error: "request failed" }, 500);
  return json({ error: hint ?? (status === 403 ? "forbidden" : status === 404 ? "not_found" : "refused"), message: msg }, status);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return json({ error: "not configured" }, 503);

  const text = await readCapped(req, MAX_BODY_BYTES);
  if (text === null) return json({ error: "body too large" }, 413);
  // deno-lint-ignore no-explicit-any
  let p: any;
  try { p = JSON.parse(text || "{}"); } catch { return json({ error: "invalid JSON" }, 400); }
  if (!p || typeof p !== "object" || typeof p.action !== "string") return json({ error: "missing action" }, 400);
  // Never card data: refused before the caller is even looked up, never logged.
  if (hasCardField(p)) {
    return json({ error: "card_data_refused", message: "Card data is never accepted: the card reader handles the card." }, 400);
  }
  // Kiosk mode (mig 20261113100000): no staff JWT, the kiosk's own credential.
  if (KIOSK_ACTIONS.has(p.action)) return await kioskAction(p, cardSwitch((k) => Deno.env.get(k)));
  if (PAYMENT_ACTIONS.has(p.action)) {
    return json({
      error: "not_implemented",
      message: new PaymentsNotWiredError(p.action).message +
        ". Walk-up sales take cash, a comp or a card on a reader (mint_walkup); tabs and bar cards aren't built.",
    }, 501);
  }
  const sw = cardSwitch((k) => Deno.env.get(k));
  const cardWalkup = p.action === "mint_walkup" && String(p.payment ?? "").toLowerCase() === "card";
  if (!sw.on && (CARD_ACTIONS.has(p.action) || cardWalkup)) {
    return cardWalkup
      ? json({ error: "card_not_connected", message: WALKUP_CARD_MESSAGE }, 501)
      : json({ error: "not_implemented", message: sw.reason === "live-not-allowed"
        ? "Card at the door with a live Stripe key also needs EXOS_POS_CARD_LIVE=on." : CARD_OFF_MESSAGE }, 501);
  }

  const sb = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  const uuid = (k: string, required = true): string | null | Response => {
    const v = p[k];
    if (v === undefined || v === null || v === "") return required ? json({ error: `missing or bad ${k}` }, 400) : null;
    return typeof v === "string" && UUID_RE.test(v) ? v.toLowerCase() : json({ error: `missing or bad ${k}` }, 400);
  };
  const str = (k: string, max: number): string | null => (typeof p[k] === "string" && p[k].trim() ? String(p[k]).slice(0, max) : null);
  const int = (k: string, dflt: number | null = null): number | null => {
    const v = p[k];
    if (v === undefined || v === null || v === "") return dflt;
    const n = typeof v === "string" && /^-?\d+$/.test(v) ? Number(v) : v;
    return typeof n === "number" && Number.isInteger(n) ? n : NaN;
  };
  const rpc = async (fn: string, args: Record<string, unknown>): Promise<Response> => {
    const { data, error } = await sb.rpc(fn, args);
    return error ? dbError(error) : json({ data });
  };

  // Card at the door: service-role cores (each checks the caller's role and
  // rate limit in SQL before any Stripe call), then Stripe.
  if (sw.on && (CARD_ACTIONS.has(p.action) || cardWalkup || p.action === "void_order" || p.action === "refund_order"
      || p.action === "walkup_catalog")) {
    const card = await cardAction(p, user.id, sb, sw.live, { uuid, str, int });
    if (card) return card;
  }

  switch (p.action) {
    case "mint_walkup": {
      const ev = uuid("event_id"); if (ev instanceof Response) return ev;
      const tier = uuid("tier_id"); if (tier instanceof Response) return tier;
      const key = uuid("order_key"); if (key instanceof Response) return key;
      const dev = uuid("device_id", false); if (dev instanceof Response) return dev;
      const drawer = uuid("drawer_id", false); if (drawer instanceof Response) return drawer;
      const qty = int("quantity");
      const comp = int("comp_quantity", 0);
      if (!Number.isInteger(qty) || !Number.isInteger(comp)) return json({ error: "quantity and comp_quantity are whole numbers" }, 400);
      const payment = String(p.payment ?? "cash").toLowerCase();
      if (payment !== "cash" && payment !== "comp") return json({ error: "payment must be cash or comp" }, 400);
      const answers = p.answers && typeof p.answers === "object" && !Array.isArray(p.answers) ? p.answers : null;
      return rpc("exos_pos_walkup_sell", {
        p_event_id: ev, p_tier_id: tier, p_quantity: qty, p_order_key: key, p_comp_quantity: comp, p_payment: payment,
        p_device_id: dev, p_drawer_id: drawer, p_buyer_name: str("buyer_name", 80), p_buyer_email: str("buyer_email", 254),
        p_answers: answers, p_comp_reason: str("comp_reason", 200),
        // The seller's explicit skip (the 13-argument sale, mig 20261108110000).
        ...(p.skip_questions === true ? { p_skip_questions: true } : {}),
      });
    }
    case "void_order":
    case "refund_order": {
      const order = uuid("order_id"); if (order instanceof Response) return order;
      const drawer = uuid("drawer_id", false); if (drawer instanceof Response) return drawer;
      const reason = str("reason", 300);
      if (!reason) return json({ error: "a reason is required" }, 400);
      return p.action === "void_order"
        ? rpc("exos_pos_void_order", { p_order_id: order, p_reason: reason, p_drawer_id: drawer })
        : rpc("exos_pos_refund_order", { p_order_id: order, p_reason: reason, p_override: p.override === true, p_drawer_id: drawer });
    }
    case "paid_out": {
      const drawer = uuid("drawer_id"); if (drawer instanceof Response) return drawer;
      const key = uuid("key", false); if (key instanceof Response) return key;
      const amount = int("amount_cents");
      if (!Number.isInteger(amount)) return json({ error: "amount_cents is a whole number of cents" }, 400);
      return rpc("exos_pos_paid_out", { p_drawer_id: drawer, p_amount_cents: amount, p_reason: str("reason", 300) ?? "", p_key: key });
    }
    case "order_codes": {
      const order = uuid("order_id"); if (order instanceof Response) return order;
      const { data, error } = await sb.rpc("exos_pos_order_codes", { p_order_id: order });
      if (error) return dbError(error);
      return json({ data }, 200, { "cache-control": "no-store" });
    }
    case "email_order": {
      const order = uuid("order_id"); if (order instanceof Response) return order;
      const email = str("email", 254);
      if (!email) return json({ error: "an email is required" }, 400);
      return rpc("exos_pos_order_email", { p_order_id: order, p_email: email });
    }
  }

  const eventId = typeof p.event_id === "string" ? p.event_id : "";
  if (!UUID_RE.test(eventId)) return json({ error: "missing or bad event_id" }, 400);

  if (p.action === "walkup_catalog") return rpc("exos_pos_walkup_catalog", { p_event_id: eventId });
  if (p.action === "recent_sales") {
    const limit = int("limit", 20);
    return rpc("exos_pos_recent_sales", { p_event_id: eventId, p_limit: Number.isInteger(limit) ? limit : 20 });
  }

  if (p.action === "catalog") {
    const { data: canRing, error: roleErr } = await sb.rpc("exos_pos_can_ring", { p_event_id: eventId });
    if (roleErr) return json({ error: "role check failed" }, 500);
    if (canRing !== true) return json({ error: "forbidden" }, 403);

    const { data: ev } = await sb.from("exos_events").select("org_id").eq("id", eventId).maybeSingle();
    const orgId = (ev as { org_id?: string } | null)?.org_id;
    if (!orgId) return json({ error: "event not found" }, 404);

    const { data, error } = await sb
      .from("exos_pos_items")
      .select("id, category, name, sku, price_cents, active, is_86d, inventory_count, sort_order, exos_tax_rules(rate_percent, price_includes_tax)")
      .eq("org_id", orgId)
      .or(`event_id.eq.${eventId},event_id.is.null`)
      .order("category")
      .order("sort_order")
      .order("name");
    if (error) return json({ error: "catalog read failed" }, 500);

    const items = ((data ?? []) as unknown as ItemRow[]).map((i) => {
      const tax = i.exos_tax_rules
        ? { rate_percent: Number(i.exos_tax_rules.rate_percent), price_includes_tax: i.exos_tax_rules.price_includes_tax === true }
        : null;
      const all_in_cents = lineTotals({
        category: i.category,
        unitPriceCents: i.price_cents,
        quantity: 1,
        tax: tax ? { ratePercent: tax.rate_percent, priceIncludesTax: tax.price_includes_tax } : null,
      }).totalCents;
      return {
        id: i.id, category: i.category, name: i.name, sku: i.sku, price_cents: i.price_cents, all_in_cents, tax,
        active: i.active, is_86d: i.is_86d, inventory_count: i.inventory_count,
      };
    });
    return json({ event_id: eventId, items });
  }

  if (p.action === "settlement_preview") {
    const { data, error } = await sb.rpc("exos_pos_settlement_summary", { p_event_id: eventId });
    if (error) {
      return error.code === "42501" ? json({ error: "forbidden" }, 403) : json({ error: "settlement read failed" }, 500);
    }
    return json({ preview: true, summary: data });
  }

  return json({ error: "unknown action" }, 400);
});

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

// ---------------------------------------------------------------------------
// Card at the door (mig 20261107130000). Only reached with EXOS_POS_CARD on.
// Answers null to let the cash / comp path handle the request (a void of a
// cash sale, say).
// ---------------------------------------------------------------------------

type Helpers = {
  uuid: (k: string, required?: boolean) => string | null | Response;
  str: (k: string, max: number) => string | null;
  int: (k: string, dflt?: number | null) => number | null;
};

// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any, any, any>;

/** The service-role client as stripeTerminal.ts's CardDb. */
function cardDb(svc: Svc): CardDb {
  return {
    rpc: async (fn, args) => {
      const { data, error } = await svc.rpc(fn, args);
      return { data, error: error ? { code: error.code, message: error.message, hint: error.hint } : null };
    },
  };
}

/** A Stripe error as the door sees it (Stripe's message; never card data, never another org's). */
function stripeError(e: unknown): Response {
  const msg = String((e as { message?: string } | null)?.message ?? "the card service didn't answer").slice(0, 300);
  console.error("exos-pos: stripe", (e as { type?: string })?.type ?? "", (e as { code?: string })?.code ?? "");
  return json({ error: "card_service", message: msg }, 502);
}

async function cardAction(
  // deno-lint-ignore no-explicit-any
  p: any, actor: string, sb: Svc, live: boolean, h: Helpers,
): Promise<Response | null> {
  const url = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!service || !key) return json({ error: "not configured", message: "card at the door needs the service role and a Stripe key" }, 503);
  const svc: Svc = createClient(url, service, { auth: { persistSession: false } });
  const db = cardDb(svc);
  let stripe: TerminalStripe | null = null;
  // deno-lint-ignore no-explicit-any
  let raw: any = null;
  const st = () => {
    if (!stripe) {
      raw = posStripe(key);
      stripe = terminalStripe(raw);
    }
    return stripe;
  };
  const opts: CardFlowOpts = {
    cardFee: terminalCardFee((k) => Deno.env.get(k)),
    onBehalfOf: (Deno.env.get("EXOS_POS_CARD_ON_BEHALF_OF") ?? "").toLowerCase() === "on",
    keepPlatformFee: Deno.env.get("EXOS_REFUND_KEEP_PLATFORM_FEE") === "true",
  };
  const core = async <T>(fn: string, args: Record<string, unknown>): Promise<{ data: T } | Response> => {
    const { data, error } = await svc.rpc(fn, args);
    return error ? dbError(error) : { data: data as T };
  };
  // The org to set up: org_id, or the org of event_id (the door app knows the
  // event). Only a lookup: the role check is the SQL core's, by org.
  const orgOf = async (): Promise<string | Response> => {
    const o = h.uuid("org_id", false); if (o instanceof Response) return o;
    if (o) return o;
    const ev = h.uuid("event_id"); if (ev instanceof Response) return ev;
    const { data } = await svc.from("exos_events").select("org_id").eq("id", ev).maybeSingle();
    const org = (data as { org_id?: string } | null)?.org_id;
    return org ?? json({ error: "forbidden", message: "only an owner or manager sets up card readers" }, 403);
  };

  try {
    switch (p.action) {
      case "walkup_catalog": {
        // The cash catalog, plus the readers this member may charge on.
        const eventId = h.uuid("event_id"); if (eventId instanceof Response) return eventId;
        const { data: cat, error } = await sb.rpc("exos_pos_walkup_catalog", { p_event_id: eventId });
        if (error) return dbError(error);
        const { data: rd, error: rdErr } = await sb.rpc("exos_pos_card_readers", { p_event_id: eventId });
        if (rdErr) return dbError(rdErr);
        const r = rd as { can_manage: boolean; locations: { livemode: boolean }[]; readers: { device_id: string; label: string; device_type: string | null; livemode: boolean }[] };
        const readers = (r.readers ?? []).filter((x) => x.livemode === live).map(({ device_id, label, device_type }) => ({ device_id, label, device_type }));
        const hasLocation = (r.locations ?? []).some((l) => l.livemode === live);
        return json({ data: { ...(cat as Record<string, unknown>), card: {
          connected: readers.length > 0, switched_on: true, readers, has_location: hasLocation, can_manage: r.can_manage === true,
          // TODO(native app, docs/pos.md "Card at the door"): Tap to Pay on iPhone needs the native
          // wrapper (Terminal iOS SDK + Apple's entitlement); it uses connection_token and
          // card_payment mode "sdk". Hidden until that app exists.
          tap_to_pay: false,
          message: readers.length > 0 ? "Charge the card on a reader." : r.can_manage
            ? "No card reader yet: add one below." : "No card reader yet: ask an owner or manager to add one.",
        } } });
      }

      case "mint_walkup": {
        const ev = h.uuid("event_id"); if (ev instanceof Response) return ev;
        const tier = h.uuid("tier_id"); if (tier instanceof Response) return tier;
        const okey = h.uuid("order_key"); if (okey instanceof Response) return okey;
        const dev = h.uuid("device_id", false); if (dev instanceof Response) return dev;
        const qty = h.int("quantity");
        const comp = h.int("comp_quantity", 0);
        if (!Number.isInteger(qty)) return json({ error: "quantity is a whole number" }, 400);
        if (comp !== 0) return json({ error: "a card sale has no comps: comp them in a sale of their own" }, 400);
        const answers = p.answers && typeof p.answers === "object" && !Array.isArray(p.answers) ? p.answers : null;
        const r = await core<unknown>("_exos_pos_walkup_begin_card", {
          p_actor: actor, p_event_id: ev, p_tier_id: tier, p_quantity: qty, p_order_key: okey, p_device_id: dev,
          p_buyer_name: h.str("buyer_name", 80), p_buyer_email: h.str("buyer_email", 254), p_answers: answers, p_live: live,
          ...(p.skip_questions === true ? { p_skip_questions: true } : {}), // mig 20261108110000
        });
        return r instanceof Response ? r : json({ data: r.data });
      }

      case "card_payment": {
        const order = h.uuid("order_id"); if (order instanceof Response) return order;
        const mode = String(p.mode ?? "reader").toLowerCase();
        if (mode !== "reader" && mode !== "sdk") return json({ error: "mode is reader or sdk" }, 400);
        const reader = h.uuid("reader_device_id", mode === "reader"); if (reader instanceof Response) return reader;
        const plan = await core<CardPlan>("_exos_pos_card_begin", {
          p_actor: actor, p_order: order, p_mode: mode, p_reader_device: reader, p_live: live,
        });
        if (plan instanceof Response) return plan;
        if (!plan.data.done && !isCheckoutCurrency(plan.data.currency)) {
          return json({ error: "refused", message: `cards can't be taken in ${plan.data.currency.toUpperCase()} yet` }, 409);
        }
        const r = await startCardPayment(db, st(), plan.data, opts);
        return json({ data: { order_id: order, card: { status: r.status, mode, payment_intent: r.payment_intent,
          ...(r.client_secret ? { client_secret: r.client_secret } : {}) } } }, 200, { "cache-control": "no-store" });
      }

      case "card_status":
      case "capture": {
        const order = h.uuid("order_id"); if (order instanceof Response) return order;
        const lk = await core<CardLookup>("_exos_pos_card_lookup", { p_actor: actor, p_order: order, p_need: "read", p_rate: true });
        if (lk instanceof Response) return lk;
        return await pollCard(db, st(), order, lk.data, live, svc, actor);
      }

      case "card_cancel": {
        const order = h.uuid("order_id"); if (order instanceof Response) return order;
        const lk = await core<CardLookup>("_exos_pos_card_lookup", { p_actor: actor, p_order: order, p_need: "act", p_rate: true });
        if (lk instanceof Response) return lk;
        if (!lk.data.is_card) return json({ error: "not-card", message: "this sale isn't a card sale" }, 409);
        if (lk.data.order_status !== "pending") return await orderNow(svc, order, actor, "done");
        const r = await cancelCard(db, st(), order, lk.data, h.str("reason", 300) ?? "cancelled at the door");
        return json({ data: r });
      }

      case "void_order":
      case "refund_order": {
        const order = h.uuid("order_id"); if (order instanceof Response) return order;
        const drawer = h.uuid("drawer_id", false); if (drawer instanceof Response) return drawer;
        const reason = h.str("reason", 300);
        if (!reason) return json({ error: "a reason is required" }, 400);
        const lk = await core<CardLookup>("_exos_pos_card_lookup", { p_actor: actor, p_order: order, p_need: "read", p_rate: false });
        if (lk instanceof Response) return lk;
        // A pending card sale: cancel it (the reader, the PaymentIntent, the places).
        if (lk.data.is_card && lk.data.order_status === "pending") {
          if (p.action !== "void_order") return json({ error: "refused", message: "this sale isn't paid" }, 409);
          const act = await core<CardLookup>("_exos_pos_card_lookup", { p_actor: actor, p_order: order, p_need: "act", p_rate: true });
          if (act instanceof Response) return act;
          const r = await cancelCard(db, st(), order, act.data, reason);
          return json({ data: { ...(r.order as Record<string, unknown> ?? {}), card_state: r.state } });
        }
        // Cash / comp (and a card sale that never completed): as before. A
        // completed card sale (also one already reversed: the replay retries a
        // refund still pending) goes through the card path.
        if (!(lk.data.is_card && lk.data.status === "succeeded")) return null;
        // A card sale: the walk-up void / refund rules and the ledger row, then the card refund.
        const rev = await core<Record<string, unknown> & { card_refund: CardRefundState | null }>("_exos_pos_card_reverse", {
          p_actor: actor, p_order: order, p_kind: p.action === "void_order" ? "void" : "refund", p_reason: reason,
          p_override: p.override === true, p_drawer: drawer,
        });
        if (rev instanceof Response) return rev;
        const cr = rev.data.card_refund;
        if (!cr) return json({ data: rev.data });
        const refund = await refundCardSale(db, st(), order, cr, opts);
        return json({ data: { ...rev.data, card_refund: { ...cr, status: refund.status, refund_ref: refund.id ?? cr.refund_ref,
          ...(refund.error ? { error: refund.error } : {}) } } });
      }

      case "connection_token": {
        const ev = h.uuid("event_id"); if (ev instanceof Response) return ev;
        const chk = await core<{ location_id: string }>("_exos_pos_terminal_token_check", { p_actor: actor, p_event: ev, p_live: live });
        if (chk instanceof Response) return chk;
        st();
        const tok = await raw.terminal.connectionTokens.create({ location: chk.data.location_id });
        return json({ data: { secret: tok.secret, location_id: chk.data.location_id } }, 200, { "cache-control": "no-store" });
      }

      case "terminal_location": {
        const org = await orgOf(); if (org instanceof Response) return org;
        const chk = await core<{ org_name: string; location: { stripe_location_id: string; display_name: string } | null }>(
          "_exos_pos_terminal_manage_check", { p_actor: actor, p_org: org, p_live: live });
        if (chk instanceof Response) return chk;
        if (chk.data.location) return json({ data: { location: chk.data.location, created: false } });
        const addr = terminalAddress(p.address);
        if ("error" in addr) return json({ error: "address", message: addr.error }, 400);
        const name = (h.str("display_name", 100) ?? chk.data.org_name ?? "Box office").trim().slice(0, 100) || "Box office";
        st();
        const loc = await raw.terminal.locations.create(
          { display_name: name, address: addr.address, metadata: { exos_org_id: org } },
          { idempotencyKey: `exos_pos_location_${org}_${live ? "live" : "test"}_${await shortHash(JSON.stringify([name, addr.address]))}` },
        );
        const saved = await core<unknown>("_exos_pos_terminal_save_location", {
          p_actor: actor, p_org: org, p_live: live, p_stripe_location: loc.id, p_display: name, p_address: addr.address,
        });
        return saved instanceof Response ? saved : json({ data: { location: saved.data, created: true } });
      }

      case "register_reader": {
        const org = await orgOf(); if (org instanceof Response) return org;
        // Org-wide unless event_only: then only at event_id.
        const ev = p.event_only === true ? h.uuid("event_id") : null; if (ev instanceof Response) return ev;
        const code = typeof p.registration_code === "string" ? p.registration_code.trim() : "";
        if (!isRegistrationCode(code)) return json({ error: "registration_code", message: "type the code the reader shows (three words)" }, 400);
        const label = (h.str("label", 80) ?? "Card reader").trim() || "Card reader";
        const chk = await core<{ location: { stripe_location_id: string } | null }>(
          "_exos_pos_terminal_manage_check", { p_actor: actor, p_org: org, p_live: live });
        if (chk instanceof Response) return chk;
        if (!chk.data.location) return json({ error: "no-location", message: "set up the card location (the venue's address) first" }, 409);
        st();
        // The registration code is never stored or logged.
        const rdr = await raw.terminal.readers.create(
          { registration_code: code, label, location: chk.data.location.stripe_location_id, metadata: { exos_org_id: org } },
          { idempotencyKey: `exos_pos_reader_${org}_${await shortHash(code)}` },
        );
        const saved = await core<unknown>("_exos_pos_terminal_save_reader", {
          p_actor: actor, p_org: org, p_live: live, p_stripe_reader: rdr.id, p_label: label,
          p_device_type: rdr.device_type ?? null, p_event: ev,
        });
        return saved instanceof Response ? saved : json({ data: saved.data });
      }
    }
  } catch (e) {
    if (e instanceof CardDbError) return dbError(e.db);
    return stripeError(e);
  }
  return null;
}

type CardLookup = {
  order_id: string;
  order_status: "pending" | "paid" | "void" | "refunded";
  is_card: boolean;
  card_tender_cents: number;
  status: string | null;
  mode: "reader" | "sdk" | null;
  payment_intent_id: string | null;
  reader_id: string | null;
  livemode: boolean | null;
  amount_cents: number | null;
};

/** The order as the door shows it (after a card step that didn't return it). */
async function orderNow(svc: Svc, order: string, actor: string, state: string): Promise<Response> {
  const { data, error } = await svc.rpc("_exos_pos_order_json", { p_order: order, p_actor: actor });
  if (error) return dbError(error);
  return json({ data: { state, order: data } });
}

/** card_status / capture: read the PaymentIntent and move the sale along. */
async function pollCard(db: CardDb, stripe: TerminalStripe, order: string, lk: CardLookup, live: boolean, svc: Svc, actor: string): Promise<Response> {
  if (!lk.is_card) return json({ error: "not-card", message: "this sale isn't a card sale" }, 409);
  if (lk.livemode !== live) return json({ error: "refused", message: "this sale was started in the other Stripe mode" }, 409);
  const done = lk.status === "succeeded" || lk.status === "declined" || lk.status === "canceled" || lk.status === "refunded";
  if (done || !lk.payment_intent_id) {
    return await orderNow(svc, order, actor, lk.status === "succeeded" ? "succeeded" : lk.status === "refunded" ? "refunded"
      : lk.status === "declined" || lk.status === "canceled" ? lk.status : "waiting");
  }
  const pi = await stripe.retrievePaymentIntent(lk.payment_intent_id);
  // A server-driven reader reports a decline on its action before the PaymentIntent does.
  const action = lk.mode === "reader" && lk.reader_id && pi.status === "requires_payment_method"
    ? (await stripe.retrieveReader(lk.reader_id).catch(() => null))?.action ?? null : null;
  const r = await advanceCard(db, stripe, order, pi, { via: "door", action });
  if (r.state === "waiting") return json({ data: { state: "waiting", order_id: order } });
  return json({ data: r });
}

async function shortHash(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d.slice(0, 8), (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// Kiosk mode (mig 20261113100000). The credential is resolved in SQL by every
// core, before any Stripe call; the kiosk sees its own sale only, trimmed.
// ---------------------------------------------------------------------------

/** What a kiosk screen may see of its sale (no seller, device, key or buyer data). */
function kioskOrder(o: unknown): Record<string, unknown> | null {
  if (!o || typeof o !== "object") return null;
  const r = o as Record<string, unknown>;
  const card = r.card && typeof r.card === "object" ? r.card as Record<string, unknown> : null;
  return {
    id: r.id, status: r.status, currency: r.currency, total_cents: r.total_cents, tax_cents: r.tax_cents,
    tier_name: r.tier_name, quantity: r.quantity,
    ticket_count: Array.isArray(r.ticket_ids) ? r.ticket_ids.length : 0,
    ...(card ? { card: { status: card.status ?? null, decline_code: card.decline_code ?? null } } : {}),
  };
}

// deno-lint-ignore no-explicit-any
async function kioskAction(p: any, sw: CardSwitch): Promise<Response> {
  const token = typeof p.kiosk_token === "string" ? p.kiosk_token : "";
  if (!KIOSK_TOKEN_RE.test(token)) return json({ error: "kiosk-ended", message: "This kiosk session has ended." }, 403);
  const url = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!service) return json({ error: "not configured" }, 503);
  const svc: Svc = createClient(url, service, { auth: { persistSession: false } });
  const core = async <T>(fn: string, args: Record<string, unknown>): Promise<{ data: T } | Response> => {
    const { data, error } = await svc.rpc(fn, { p_token: token, ...args });
    return error ? dbError(error) : { data: data as T };
  };
  const orderId = (): string | Response => {
    const v = p.order_id;
    return typeof v === "string" && UUID_RE.test(v) ? v.toLowerCase() : json({ error: "missing or bad order_id" }, 400);
  };

  if (p.action === "kiosk_state") {
    const r = await core<Record<string, unknown>>("_exos_pos_kiosk_state", { p_live: sw.live });
    if (r instanceof Response) return r;
    const reader = (r.data.reader ?? {}) as { ready?: boolean };
    const available = sw.on && reader.ready === true;
    return json({ data: { ...r.data, card: { on: sw.on, available,
      message: !sw.on ? KIOSK_OFF_MESSAGE : available ? "Pay by card on the reader." : "This kiosk's card reader isn't ready. Please buy at the box office." } } },
      200, { "cache-control": "no-store" });
  }

  const key = Deno.env.get("STRIPE_SECRET_KEY");
  // deno-lint-ignore no-explicit-any
  let raw: any = null;
  let stripe: TerminalStripe | null = null;
  const st = (): TerminalStripe => {
    if (!stripe) {
      raw = posStripe(key!);
      stripe = terminalStripe(raw);
    }
    return stripe;
  };
  const db = cardDb(svc);
  const opts: CardFlowOpts = {
    cardFee: terminalCardFee((k) => Deno.env.get(k)),
    onBehalfOf: (Deno.env.get("EXOS_POS_CARD_ON_BEHALF_OF") ?? "").toLowerCase() === "on",
    keepPlatformFee: Deno.env.get("EXOS_REFUND_KEEP_PLATFORM_FEE") === "true",
  };

  try {
    if (p.action === "kiosk_exit") {
      const pin = typeof p.pin === "string" ? p.pin.slice(0, 12) : "";
      const r = await core<{ ok: boolean; ended?: boolean; error?: string; attempts_left?: number; retry_after_seconds?: number;
        actor?: string; pending?: string[] }>("_exos_pos_kiosk_exit", { p_pin: pin });
      if (r instanceof Response) return r;
      const { actor, pending, ...answer } = r.data;
      // A card sale still on the reader: stop it and give the places back.
      if (r.data.ok && actor && Array.isArray(pending) && pending.length > 0 && sw.on && key) {
        for (const order of pending.slice(0, 5)) {
          const { data: lk } = await svc.rpc("_exos_pos_card_lookup", { p_actor: actor, p_order: order, p_need: "act", p_rate: false });
          const l = lk as CardLookup | null;
          if (l?.is_card && l.order_status === "pending") {
            await cancelCard(db, st(), order, l, "kiosk closed by staff").catch((e) => console.error("exos-pos: kiosk exit cancel", String(e)));
          }
        }
      }
      // Always 200: { ok: false, error } is an answer the PIN pad shows, not a failure.
      return json({ data: answer });
    }

    if (!sw.on) return json({ error: "kiosk_unavailable", message: KIOSK_OFF_MESSAGE }, 501);
    if (!key) return json({ error: "not configured", message: "card payments need a Stripe key" }, 503);

    switch (p.action) {
      case "kiosk_begin": {
        const tier = typeof p.tier_id === "string" && UUID_RE.test(p.tier_id) ? p.tier_id.toLowerCase() : null;
        const okey = typeof p.order_key === "string" && UUID_RE.test(p.order_key) ? p.order_key.toLowerCase() : null;
        const qty = p.quantity;
        if (!tier || !okey || !Number.isInteger(qty)) return json({ error: "tier_id, quantity and order_key are required" }, 400);
        const answers = p.answers && typeof p.answers === "object" && !Array.isArray(p.answers) ? p.answers : null;
        const r = await core<unknown>("_exos_pos_kiosk_begin", {
          p_tier: tier, p_quantity: qty, p_order_key: okey, p_answers: answers, p_live: sw.live,
        });
        return r instanceof Response ? r : json({ data: kioskOrder(r.data) }, 200, { "cache-control": "no-store" });
      }
      case "kiosk_charge": {
        const order = orderId(); if (order instanceof Response) return order;
        const plan = await core<CardPlan>("_exos_pos_kiosk_charge", { p_order: order, p_live: sw.live });
        if (plan instanceof Response) return plan;
        if (!plan.data.done && !isCheckoutCurrency(plan.data.currency)) {
          return json({ error: "refused", message: `cards can't be taken in ${plan.data.currency.toUpperCase()} yet` }, 409);
        }
        const r = await startCardPayment(db, st(), plan.data, opts);
        return json({ data: { order_id: order, state: plan.data.done ? "succeeded" : "waiting", status: r.status } },
          200, { "cache-control": "no-store" });
      }
      case "kiosk_status": {
        const order = orderId(); if (order instanceof Response) return order;
        const lk = await core<CardLookup>("_exos_pos_kiosk_lookup", { p_order: order });
        if (lk instanceof Response) return lk;
        const l = lk.data;
        if (!l.is_card) return json({ error: "not-card" }, 409);
        if (l.livemode !== sw.live) return json({ error: "refused", message: "this sale was started in the other Stripe mode" }, 409);
        const done = l.status === "succeeded" || l.status === "declined" || l.status === "canceled" || l.status === "refunded";
        if (done || !l.payment_intent_id) {
          const state = l.status === "succeeded" || l.status === "refunded" || l.status === "declined" || l.status === "canceled"
            ? l.status : "waiting";
          return json({ data: { state, order_id: order, ticket_ready: l.status === "succeeded" } }, 200, { "cache-control": "no-store" });
        }
        const pi = await st().retrievePaymentIntent(l.payment_intent_id);
        const action = l.reader_id && pi.status === "requires_payment_method"
          ? (await st().retrieveReader(l.reader_id).catch(() => null))?.action ?? null : null;
        const r = await advanceCard(db, st(), order, pi, { via: "door", action });
        return json({ data: { state: r.state, order_id: order, decline_code: r.decline_code ?? null,
          ...(r.order ? { order: kioskOrder(r.order) } : {}) } }, 200, { "cache-control": "no-store" });
      }
      case "kiosk_cancel": {
        const order = orderId(); if (order instanceof Response) return order;
        const lk = await core<CardLookup>("_exos_pos_kiosk_lookup", { p_order: order });
        if (lk instanceof Response) return lk;
        if (!lk.data.is_card || lk.data.order_status !== "pending") {
          return json({ data: { state: lk.data.status ?? "done", order_id: order } });
        }
        const r = await cancelCard(db, st(), order, lk.data, "cancelled at the kiosk");
        return json({ data: { state: r.state, order_id: order } });
      }
      case "kiosk_codes": {
        const order = orderId(); if (order instanceof Response) return order;
        const r = await core<{ tickets?: unknown[]; skipped?: unknown[] }>("_exos_pos_kiosk_codes", { p_order: order });
        return r instanceof Response ? r : json({ data: r.data }, 200, { "cache-control": "no-store" });
      }
      case "kiosk_email": {
        const order = orderId(); if (order instanceof Response) return order;
        const email = typeof p.email === "string" ? p.email.trim().slice(0, 254) : "";
        if (!email) return json({ error: "an email is required" }, 400);
        const r = await core<{ emailed: number }>("_exos_pos_kiosk_email", { p_order: order, p_email: email });
        return r instanceof Response ? r : json({ data: { emailed: r.data.emailed } });
      }
    }
  } catch (e) {
    if (e instanceof CardDbError) return dbError(e.db);
    return stripeError(e);
  }
  return json({ error: "unknown action" }, 400);
}
