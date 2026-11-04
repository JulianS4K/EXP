// Posh webhook payloads (exos-posh-webhook, mig 20261029150000).
//
// Posh sends "Order Created" and "Pending Order Created" webhooks to a URL the
// organizer sets in Posh (Organization Settings -> API Webhooks). Posh doesn't
// publish the payload format, and none was found in public examples
// (2026-10-29: Posh's own guide, Zapier / Make / n8n templates, GitHub). So
// this parser is TOLERANT: it looks for each field under the names webhook
// senders commonly use (snake_case and camelCase, at the top level or under
// data / payload / order, with buyer / event / tickets sub-objects) and leaves
// out anything it can't find. The database re-checks every value
// (exos_posh_ingest), so a wrong guess drops a field; it never takes a seat
// that isn't there. docs/marketplace/posh.md lists what is verified.
//
// Pure: no I/O, so the Deno tests (payload_test.ts) cover it.

export type PoshKind = "order_created" | "pending_order_created";

export interface PoshOrder {
  order_id?: string;
  event_id?: string;
  event_slug?: string;
  event_name?: string;
  quantity?: number;
  buyer_name?: string;
  buyer_email?: string;
  ticket_label?: string;
  codes: string[];
  total?: number;
  currency?: string;
  created_at?: string;
}

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

function str(v: unknown, max = 200): string | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  if (typeof v !== "string") return undefined;
  const s = v.trim();
  return s && s.length <= max ? s : undefined;
}

/** First non-empty string among `keys` on any of `objs` (in order). */
function pick(objs: Obj[], keys: string[], max = 200): string | undefined {
  for (const o of objs) {
    for (const k of keys) {
      const v = str(o[k], max);
      if (v !== undefined) return v;
    }
  }
  return undefined;
}

function sub(o: Obj | undefined, key: string): Obj | undefined {
  const v = o?.[key];
  return isObj(v) ? v : undefined;
}

/**
 * The request body as an object: JSON, or a form post (with the JSON in a
 * `payload` / `data` field when there is one). null when it is neither.
 */
export function parseBody(text: string, contentType: string | null): Obj | null {
  const ct = (contentType ?? "").toLowerCase();
  const asJson = (t: string): Obj | null => {
    try {
      const v = JSON.parse(t);
      return isObj(v) ? v : Array.isArray(v) && isObj(v[0]) ? v[0] : null;
    } catch {
      return null;
    }
  };
  if (!ct.includes("application/x-www-form-urlencoded")) {
    const j = asJson(text);
    if (j || ct.includes("json") || /^\s*[[{]/.test(text)) return j;
  }
  if (!text.includes("=")) return null;
  try {
    const form = new URLSearchParams(text);
    const inner = form.get("payload") ?? form.get("data");
    if (inner) return asJson(inner);
    const out: Obj = {};
    for (const [k, v] of form) out[k] = v;
    return Object.keys(out).length ? out : null;
  } catch {
    return null;
  }
}

/** The objects to look in, most specific first. */
function layers(body: Obj): { order: Obj[]; all: Obj[] } {
  const data = sub(body, "data") ?? sub(body, "payload") ?? sub(body, "object");
  const dataObj = data ? (sub(data, "object") ?? data) : undefined;
  const order = sub(body, "order") ?? (dataObj && sub(dataObj, "order")) ?? sub(body, "pendingOrder") ??
    (dataObj && sub(dataObj, "pendingOrder")) ?? sub(body, "pending_order") ?? (dataObj && sub(dataObj, "pending_order"));
  const explicit = [order].filter(isObj);
  const all = [...explicit, dataObj, body].filter(isObj);
  return { order: explicit, all };
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

const EVENT_NAMES = new Set(["ordercreated", "pendingordercreated", "orderpending", "pendingorder", "neworder",
  "newpendingorder", "orderapproved", "ordercompleted", "ordercreatedwebhook", "pendingordercreatedwebhook"]);

const PENDING_STATUS =/^(pending|pendingapproval|awaitingapproval|requiresapproval|needsapproval|approvalrequired|unapproved|requested)$/;

/**
 * Which webhook it is. The payload's own type / event / status field wins;
 * then the URL's hint (/<token>/pending or /<token>/order, for an organizer
 * who gives each Posh webhook its own URL); then Order Created.
 */
export function detectKind(body: Obj, hint?: string | null): PoshKind {
  const { all } = layers(body);
  const typeKeys = ["type", "event_type", "eventType", "webhook_type", "webhookType", "webhook_event", "webhookEvent",
    "trigger", "topic", "action", "event_name_type", "kind"];
  for (const o of [body, ...all]) {
    for (const k of [...typeKeys, "event"]) {
      const v = o[k];
      if (typeof v !== "string") continue;
      const n = norm(v);
      // "event" may be the event's own name ("Pending Party"): only an exact
      // webhook name counts there.
      if (k === "event" && !EVENT_NAMES.has(n)) continue;
      if (n.includes("pending")) return "pending_order_created";
      if (/(ordercreated|createdorder|neworder|orderapproved|ordercompleted|ordercomplete|orderpaid|purchase|ticketpurchased)/.test(n)) {
        return "order_created";
      }
    }
  }
  const status = pick(all, ["status", "order_status", "orderStatus", "approval_status", "approvalStatus", "state"]);
  if (status && PENDING_STATUS.test(norm(status))) return "pending_order_created";
  if (all.some((o) => o.requires_approval === true || o.requiresApproval === true || o.pending === true || o.isPending === true)) {
    // ...unless it says it is approved now.
    if (!all.some((o) => o.approved === true || o.isApproved === true)) return "pending_order_created";
  }
  const h = (hint ?? "").toLowerCase();
  if (h === "pending") return "pending_order_created";
  return "order_created";
}

const SLUG_IN_URL = /posh\.vip\/e\/([^/?#\s]+)/i;

function money(v: unknown, cents: boolean): number | undefined {
  let n: number | undefined;
  if (typeof v === "number" && Number.isFinite(v)) n = v;
  else if (typeof v === "string") {
    const s = v.replace(/[$€£,\s]/g, "").replace(/^[A-Za-z]{3}/, "");
    if (/^\d{1,9}(\.\d{1,4})?$/.test(s)) n = Number(s);
  }
  if (n === undefined || n < 0) return undefined;
  n = cents ? n / 100 : n;
  return n < 10_000_000 ? Math.round(n * 100) / 100 : undefined;
}

function when(v: unknown): string | undefined {
  if (typeof v === "number" && Number.isFinite(v) && v > 0) {
    const d = new Date(v < 1e12 ? v * 1000 : v);
    return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
  }
  const s = str(v, 40);
  if (!s) return undefined;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

function fullName(o: Obj): string | undefined {
  const direct = pick([o], ["name", "full_name", "fullName", "display_name", "displayName"], 80);
  if (direct) return direct;
  const first = pick([o], ["first_name", "firstName", "firstname", "given_name"], 80);
  const last = pick([o], ["last_name", "lastName", "lastname", "family_name"], 80);
  const both = [first, last].filter(Boolean).join(" ");
  return both || undefined;
}

const TICKET_ARRAYS = ["tickets", "items", "line_items", "lineItems", "ticket_list", "ticketList", "order_items",
  "orderItems", "attendees", "ticketTypes", "ticket_types"];
const CODE_KEYS = ["code", "ticket_code", "ticketCode", "barcode", "bar_code", "qr_code", "qrCode", "qr", "qr_value",
  "qrValue", "scan_code", "scanCode", "ticket_number", "ticketNumber", "ticket_id", "ticketId"];
const QTY_KEYS = ["quantity", "qty", "count", "ticket_count", "ticketCount", "tickets_count", "ticketsCount",
  "num_tickets", "numTickets", "number_of_tickets", "numberOfTickets", "total_tickets", "totalTickets"];

function intIn(objs: Obj[], keys: string[]): number | undefined {
  const v = pick(objs, keys, 12);
  if (v === undefined || !/^\d{1,4}$/.test(v)) return undefined;
  const n = Number(v);
  return n >= 1 && n <= 100 ? n : undefined;
}

/** What the payload says about the order. Every field is optional. */
export function extractOrder(body: Obj): PoshOrder {
  const { order, all } = layers(body);
  const out: PoshOrder = { codes: [] };

  // Order id: explicit keys anywhere; a bare id only on an order object.
  out.order_id = pick(all, ["order_id", "orderId", "order_number", "orderNumber", "order_code", "orderCode",
    "confirmation_code", "confirmationCode"], 128) ?? pick(order, ["id", "_id", "number"], 128);
  if (out.order_id && !/^[A-Za-z0-9_.:-]{1,128}$/.test(out.order_id)) out.order_id = undefined;

  // The event.
  const evObjs = all.map((o) => sub(o, "event")).filter(isObj);
  out.event_id = pick(all, ["event_id", "eventId", "posh_event_id", "poshEventId"], 128) ?? pick(evObjs, ["id", "_id"], 128);
  const url = pick([...all, ...evObjs], ["event_url", "eventUrl", "url", "link", "event_link", "eventLink"], 500);
  out.event_slug = pick(all, ["event_slug", "eventSlug", "event_url_slug"], 160) ?? pick(evObjs, ["slug", "url_slug", "urlSlug"], 160) ??
    (url ? SLUG_IN_URL.exec(url)?.[1] : undefined);
  out.event_name = pick(all, ["event_name", "eventName", "event_title", "eventTitle"], 200) ?? pick(evObjs, ["name", "title"], 200);

  // The buyer.
  const buyerKeys = ["buyer", "customer", "purchaser", "account", "user", "attendee", "contact", "guest"];
  const buyers = all.flatMap((o) => buyerKeys.map((k) => sub(o, k))).filter(isObj);
  out.buyer_email = pick(all, ["buyer_email", "buyerEmail", "customer_email", "customerEmail", "purchaser_email",
    "purchaserEmail", "email", "email_address", "emailAddress"], 254) ?? pick(buyers, ["email", "email_address", "emailAddress"], 254);
  if (out.buyer_email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(out.buyer_email)) out.buyer_email = undefined;
  out.buyer_name = pick(all, ["buyer_name", "buyerName", "customer_name", "customerName", "purchaser_name",
    "purchaserName", "attendee_name", "attendeeName"], 80);
  if (!out.buyer_name) {
    for (const b of buyers) {
      out.buyer_name = fullName(b);
      if (out.buyer_name) break;
    }
  }
  if (!out.buyer_name) {
    const first = pick(all, ["first_name", "firstName"], 80);
    const last = pick(all, ["last_name", "lastName"], 80);
    out.buyer_name = [first, last].filter(Boolean).join(" ") || undefined;
  }

  // Tickets: per-ticket codes, names, quantities.
  const items: Obj[] = [];
  for (const o of all) {
    for (const k of TICKET_ARRAYS) {
      const v = o[k];
      if (Array.isArray(v)) {
        for (const x of v.slice(0, 200)) if (isObj(x)) items.push(x);
      }
    }
    if (items.length) break;
  }
  const names: string[] = [];
  let itemQty = 0;
  for (const it of items) {
    const tt = sub(it, "ticket_type") ?? sub(it, "ticketType") ?? sub(it, "ticket") ?? sub(it, "type");
    const nm = pick([it], ["ticket_name", "ticketName", "ticket_type_name", "ticketTypeName", "name", "title", "tier"], 80) ??
      (tt ? pick([tt], ["name", "title"], 80) : undefined) ?? pick([it], ["ticket_type", "ticketType", "type"], 80);
    if (nm && !names.includes(nm)) names.push(nm);
    const q = intIn([it], ["quantity", "qty", "count"]);
    const nested = (["codes", "barcodes", "qr_codes", "qrCodes"] as const).map((k) => it[k]).find(Array.isArray) as unknown[] | undefined;
    const itemCodes = nested ? nested.map((c) => str(c, 128) ?? (isObj(c) ? pick([c], CODE_KEYS, 128) : undefined)).filter((c): c is string => !!c)
      : [pick([it], CODE_KEYS, 128)].filter((c): c is string => !!c);
    out.codes.push(...itemCodes);
    itemQty += q ?? Math.max(itemCodes.length, 1);
  }
  const topCodes = all.map((o) => o.codes ?? o.barcodes ?? o.ticket_codes ?? o.ticketCodes).find(Array.isArray) as unknown[] | undefined;
  if (!out.codes.length && topCodes) {
    out.codes.push(...topCodes.map((c) => str(c, 128)).filter((c): c is string => !!c));
  }
  if (!out.codes.length && !items.length) {
    const one = pick(all, ["ticket_code", "ticketCode", "barcode", "qr_code", "qrCode"], 128);
    if (one) out.codes.push(one);
  }
  out.codes = [...new Set(out.codes)].slice(0, 100);
  out.quantity = intIn(all, QTY_KEYS) ?? (itemQty > 0 ? Math.min(itemQty, 100) : undefined) ??
    (out.codes.length ? out.codes.length : undefined);

  const label = names.join(", ") || pick(all, ["ticket_name", "ticketName", "ticket_type", "ticketType", "tier_name", "tierName"], 80);
  out.ticket_label = label ? label.slice(0, 80) : undefined;

  // Money (shown to the organizer; Exos takes no fee on it).
  for (const o of all) {
    for (const k of ["total_cents", "totalCents", "amount_cents", "amountCents"]) {
      if (out.total === undefined && o[k] !== undefined) out.total = money(o[k], true);
    }
  }
  if (out.total === undefined) {
    for (const o of all) {
      for (const k of ["total", "total_price", "totalPrice", "order_total", "orderTotal", "grand_total", "grandTotal", "amount", "price"]) {
        const v = o[k];
        if (out.total === undefined && v !== undefined && !isObj(v)) out.total = money(v, false);
        if (out.total === undefined && isObj(v)) out.total = money(v.amount ?? v.value, false);
      }
    }
  }
  const cur = pick(all, ["currency", "currency_code", "currencyCode"], 8);
  out.currency = cur && /^[A-Za-z]{3}$/.test(cur) ? cur.toLowerCase() : undefined;
  for (const o of all) {
    for (const k of ["created_at", "createdAt", "purchased_at", "purchasedAt", "order_date", "orderDate", "timestamp", "date"]) {
      if (!out.created_at && o[k] !== undefined) out.created_at = when(o[k]);
    }
  }

  // Drop the undefined keys (the RPC treats a missing key as unknown).
  for (const k of Object.keys(out) as (keyof PoshOrder)[]) {
    if (out[k] === undefined) delete out[k];
  }
  return out;
}

// Personal data the door and attendee views don't need: removed before the
// payload is stored for replay. Name and email stay (the order keeps them).
const PII_KEY = /(phone|mobile|cell|sms|address|street|city|zip|postal|postcode|birth|dob|age$|gender|instagram|twitter|tiktok|social|answer|question|custom_?field|survey|ip_?addr|^ip$|user_?agent|card|last_?4|payment_method|paymentmethod|stripe|password|token|secret|ssn|passport|license)/i;

export function redact(v: unknown, depth = 0): unknown {
  if (depth > 8) return "[cut]";
  if (Array.isArray(v)) return v.slice(0, 200).map((x) => redact(x, depth + 1));
  if (isObj(v)) {
    const out: Obj = {};
    for (const [k, x] of Object.entries(v)) {
      out[k] = PII_KEY.test(k) && !/email/i.test(k) ? "[removed]" : redact(x, depth + 1);
    }
    return out;
  }
  if (typeof v === "string") return v.length > 2000 ? v.slice(0, 2000) : v;
  return v;
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The URL after the function name: /<token>[/pending|/order], or
 * /replay/<log id>. Tokens are 64 hex characters (32 random bytes).
 */
export function route(pathname: string):
  | { kind: "hook"; token: string; hint: "pending" | "order" | null }
  | { kind: "replay"; logId: string }
  | null {
  const parts = pathname.split("/").filter(Boolean);
  const i = parts.indexOf("exos-posh-webhook");
  const rest = i >= 0 ? parts.slice(i + 1) : parts;
  if (rest[0] === "replay" && rest.length === 2 && /^[0-9a-f-]{36}$/i.test(rest[1])) return { kind: "replay", logId: rest[1] };
  if (rest.length < 1 || rest.length > 2 || !/^[0-9a-f]{64}$/.test(rest[0])) return null;
  const h = rest[1]?.toLowerCase();
  if (rest.length === 2 && h !== "pending" && h !== "order") return null;
  return { kind: "hook", token: rest[0], hint: (h as "pending" | "order" | undefined) ?? null };
}
