// exos-pos — venue POS (Phase 3, docs/pos.md).
//
// Walk-up sales at the door (mig 20261107100000): door staff sell tickets for
// cash or as a comp, hand them over (a one-time QR on the staff screen, paper,
// or email), void or refund a sale, and pay cash out of a drawer. Card
// payments are NOT wired: every card action answers 501, a card tender on a
// walk-up is refused, and no card data is ever accepted or stored (a request
// carrying a card-looking field is refused before anything else; the reader
// will handle the card and Exos will only keep an opaque PaymentIntent id in
// exos_pos_payments.terminal_ref, later: docs/pos.md "Card at the door").
//
// Auth: the caller's Supabase JWT (auth.getUser). Every call goes through a
// client carrying that JWT, so the SQL decides who may do what (the role
// checks, the per-device rate limit and the idempotency are all in SQL):
//   catalog              door staff of the event (exos_pos_can_ring)
//   settlement_preview   owner / manager / finance (exos_pos_settlement_summary)
//   walkup_catalog       door staff: ticket types at the door price, what's left,
//                        the questions, the open drawers, can_comp
//   mint_walkup          door staff; comps owner / manager (exos_pos_walkup_sell)
//   recent_sales         door staff (exos_pos_recent_sales)
//   void_order           the seller or an owner / manager, same night, before a
//                        scan (exos_pos_void_order)
//   refund_order         owner / manager; after a scan only with override
//   paid_out             owner / manager or the drawer's holder (exos_pos_paid_out)
//   order_codes          door staff: one-time print codes for the sale's tickets
//   email_order          door staff: email the sale's tickets (account or claim link)
// No service-role key is used.
//
// Actions (POST JSON, at most 64 KB):
//   { action: "mint_walkup", event_id, tier_id, quantity, order_key (UUID per
//     sale), comp_quantity?, payment?: "cash" | "comp", device_id?, drawer_id?,
//     buyer_name?, buyer_email?, answers?, comp_reason? } -> the order
//   { action: "void_order", order_id, reason, drawer_id? }
//   { action: "refund_order", order_id, reason, override?, drawer_id? }
//   { action: "paid_out", drawer_id, amount_cents, reason, key? }
//   { action: "order_codes", order_id } -> { tickets: [{ ticket_id, print_code, … }], skipped }
//   { action: "email_order", order_id, email }
//   { action: "walkup_catalog" | "recent_sales" | "catalog" | "settlement_preview", event_id }
//   { action: "charge" | "collect_payment" | "card_payment" | "capture" | "refund" |
//     "preauth_tab" | "close_tab_payment", ... } -> 501 { error: "not_implemented" }
//   payment "card" on mint_walkup -> 501 { error: "card_not_connected" }
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY. Deploy with JWT verification
// ON. Deploying is operator-gated like every function (CLAUDE.md).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { lineTotals, type PosCategory, PaymentsNotWiredError, WALKUP_CARD_MESSAGE } from "../_shared/pos/index.ts";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Card actions: the terminal integration (later). "refund" is a CARD refund;
// cash sales are refunded with refund_order.
const PAYMENT_ACTIONS = new Set([
  "charge", "collect_payment", "card_payment", "capture", "refund", "preauth_tab", "close_tab_payment",
]);

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
  if (PAYMENT_ACTIONS.has(p.action)) {
    return json({
      error: "not_implemented",
      message: new PaymentsNotWiredError(p.action).message +
        ". Walk-up sales take cash or a comp (mint_walkup); card payments wait for the terminal integration.",
    }, 501);
  }
  if (p.action === "mint_walkup" && String(p.payment ?? "").toLowerCase() === "card") {
    return json({ error: "card_not_connected", message: WALKUP_CARD_MESSAGE }, 501);
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
