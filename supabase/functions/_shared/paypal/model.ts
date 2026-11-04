// PayPal (Orders v2) <-> Exos: pure helpers, no I/O, so Deno and vitest
// (src/lib/paypal.test.ts) load the same code. mig 20261031220000.
//
// Ids. PayPal ids are uppercase alphanumerics (orders, captures, refunds) or
// "PP-D-123" (disputes). The ledger stores them prefixed, which fits the
// existing id CHECKs (^[a-z]{2,5}_…) and can never collide with Stripe's:
//   payment_intent  ppcap_<capture id>
//   refund_id       pprf_<refund id>     (a reversal: pprev_<id>)
//   dispute_id      ppdsp_<id without dashes>
// A PayPal checkout's session id is pp_ + 32 hex.
//
// Money. PayPal amounts are decimal strings ("12.34"); Exos keeps integer
// cents. Conversions are string-exact (no floats) and two-decimal only.

export const PAYPAL_SESSION_RE = /^pp_[0-9a-f]{32}$/;
export const PAYPAL_ORDER_RE = /^[A-Z0-9]{8,40}$/;
export const PAYPAL_ID_RE = /^[A-Za-z0-9]{6,64}$/;

/** Currencies a PayPal checkout may use (two-decimal, PayPal-supported). Venmo is USD only. */
export const PAYPAL_CURRENCIES = new Set(["usd", "eur", "gbp", "cad", "aud"]);

export function newPayPalSessionId(randomHex: () => string = () => crypto.randomUUID().replace(/-/g, "")): string {
  const id = `pp_${randomHex().toLowerCase()}`;
  if (!PAYPAL_SESSION_RE.test(id)) throw new Error("paypal session id: bad random");
  return id;
}

export const ppRef = {
  capture: (id: string) => prefixed("ppcap_", id),
  refund: (id: string) => prefixed("pprf_", id),
  reversal: (id: string) => prefixed("pprev_", id),
  dispute: (id: string) => {
    const clean = String(id ?? "").replace(/[^A-Za-z0-9]/g, "");
    if (!/^[A-Za-z0-9]{3,64}$/.test(clean)) throw new Error("bad PayPal dispute id");
    return "ppdsp_" + clean;
  },
};

function prefixed(prefix: string, id: string): string {
  if (!PAYPAL_ID_RE.test(String(id ?? ""))) throw new Error(`bad PayPal id for ${prefix}`);
  return prefix + id;
}

/** The PayPal capture id inside a ledger reference, or null when it isn't a PayPal one. */
export function captureIdFromRef(ref: string | null | undefined): string | null {
  const m = /^ppcap_([A-Za-z0-9]{6,64})$/.exec(ref ?? "");
  return m ? m[1] : null;
}

export function isPayPalRef(ref: string | null | undefined): boolean {
  return captureIdFromRef(ref) !== null;
}

/** 1234 -> "12.34". Integer cents only. */
export function toPayPalValue(cents: number): string {
  if (!Number.isInteger(cents) || cents < 0) throw new Error(`bad cents ${cents}`);
  const s = String(cents).padStart(3, "0");
  return `${s.slice(0, -2)}.${s.slice(-2)}`;
}

/** "12.34" / "12.3" / "12" -> cents; null for anything else (no floats, no signs). */
export function fromPayPalValue(v: unknown): number | null {
  if (typeof v !== "string") return null;
  const m = /^(\d{1,12})(?:\.(\d{1,2}))?$/.exec(v.trim());
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0") || "0");
}

/** One priced line of a checkout, processor-neutral (see _shared/chargeLines.ts). */
export interface ChargeLine {
  name: string;
  description?: string;
  unitCents: number;
  quantity: number;
}

export interface PayPalOrderInput {
  sessionId: string;
  currency: string;
  amountCents: number;
  lines: readonly ChargeLine[];
  /** Shown on PayPal's page; not the org (the platform is the merchant). */
  brandName?: string;
  description?: string;
  /** Redirect flow only: where PayPal sends the buyer back. */
  returnUrl?: string;
  cancelUrl?: string;
}

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

/**
 * The Orders v2 create body: one purchase unit for the platform account,
 * custom_id + invoice_id = our session id (invoice_id makes PayPal refuse a
 * second payment for the same order), items at their all-in unit prices (no
 * fee line: all-in pricing), item_total = amount. Throws when the lines don't
 * add up to amountCents, so the buyer is never asked for a different total
 * than Stripe would charge.
 */
export function paypalOrderBody(o: PayPalOrderInput): Record<string, unknown> {
  const cur = o.currency.toUpperCase();
  if (!PAYPAL_CURRENCIES.has(o.currency.toLowerCase())) throw new Error(`PayPal can't take ${cur}`);
  if (!PAYPAL_SESSION_RE.test(o.sessionId)) throw new Error("bad session id");
  const paid = o.lines.filter((l) => l.unitCents > 0 && l.quantity > 0);
  const total = paid.reduce((n, l) => n + l.unitCents * l.quantity, 0);
  if (total !== o.amountCents || total <= 0) throw new Error(`lines add up to ${total}, order is ${o.amountCents}`);
  const body: Record<string, unknown> = {
    intent: "CAPTURE",
    purchase_units: [{
      reference_id: "default",
      custom_id: o.sessionId,
      invoice_id: o.sessionId,
      ...(o.description ? { description: clip(o.description, 127) } : {}),
      amount: {
        currency_code: cur,
        value: toPayPalValue(total),
        breakdown: { item_total: { currency_code: cur, value: toPayPalValue(total) } },
      },
      items: paid.map((l) => ({
        name: clip(l.name, 127),
        ...(l.description ? { description: clip(l.description, 127) } : {}),
        quantity: String(l.quantity),
        unit_amount: { currency_code: cur, value: toPayPalValue(l.unitCents) },
        category: "DIGITAL_GOODS",
      })),
    }],
  };
  if (o.returnUrl && o.cancelUrl) {
    body.payment_source = {
      paypal: {
        experience_context: {
          brand_name: clip(o.brandName ?? "Exos", 127),
          shipping_preference: "NO_SHIPPING",
          user_action: "PAY_NOW",
          return_url: o.returnUrl,
          cancel_url: o.cancelUrl,
        },
      },
    };
  }
  return body;
}

/** The buyer-approval link of a created order (redirect flow). */
export function approveUrl(order: { links?: { rel?: string; href?: string }[] } | null | undefined): string | null {
  const l = (order?.links ?? []).find((x) => x.rel === "payer-action" || x.rel === "approve");
  return l?.href && /^https:\/\/(www\.)?(sandbox\.)?paypal\.com\//.test(l.href) ? l.href : null;
}

export type CaptureStatus = "COMPLETED" | "PENDING" | "DECLINED" | "DENIED" | "FAILED";
const CAPTURE_STATUSES = new Set(["COMPLETED", "PENDING", "DECLINED", "DENIED", "FAILED"]);

export interface CaptureFacts {
  orderId: string | null;
  captureId: string;
  status: CaptureStatus;
  amountCents: number;
  currency: string;
  feeCents: number | null;
  customId: string | null;
  fundingSource: "paypal" | "venmo" | "card" | null;
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? v as Obj : {});
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** A capture object (from an order, a GET, or a webhook resource) as Exos facts; null if unusable. */
export function captureFacts(capture: unknown, orderId: string | null = null, paymentSource?: unknown): CaptureFacts | null {
  const c = obj(capture);
  const id = str(c.id);
  const status = str(c.status);
  const amount = obj(c.amount);
  const cents = fromPayPalValue(amount.value);
  const currency = str(amount.currency_code);
  if (!id || !PAYPAL_ID_RE.test(id) || !status || !CAPTURE_STATUSES.has(status) || cents == null || !currency) return null;
  const related = obj(obj(c.supplementary_data).related_ids);
  const oid = orderId ?? str(related.order_id);
  const fee = fromPayPalValue(obj(obj(c.seller_receivable_breakdown).paypal_fee).value);
  return {
    orderId: oid && PAYPAL_ORDER_RE.test(oid) ? oid : null,
    captureId: id,
    status: status as CaptureStatus,
    amountCents: cents,
    currency: currency.toLowerCase(),
    feeCents: fee,
    customId: str(c.custom_id),
    fundingSource: fundingSource(paymentSource),
  };
}

/** The (first) capture of an order, with the order's id and funding source. */
export function orderCapture(order: unknown): CaptureFacts | null {
  const o = obj(order);
  const unit = Array.isArray(o.purchase_units) ? obj(o.purchase_units[0]) : {};
  const caps = obj(unit.payments).captures;
  const cap = Array.isArray(caps) && caps.length > 0 ? caps[0] : null;
  if (!cap) return null;
  return captureFacts(cap, str(o.id), o.payment_source);
}

export function fundingSource(ps: unknown): CaptureFacts["fundingSource"] {
  const p = obj(ps);
  if ("venmo" in p) return "venmo";
  if ("card" in p) return "card";
  if ("paypal" in p) return "paypal";
  return null;
}

/** PayPal refund status -> the ledger / refund-request status set. */
export function refundStatus(s: unknown): "pending" | "succeeded" | "failed" | "canceled" {
  switch (s) {
    case "COMPLETED": return "succeeded";
    case "FAILED": return "failed";
    case "CANCELLED": return "canceled";
    default: return "pending";
  }
}

export interface RefundFacts {
  refundId: string;
  captureId: string | null;
  status: ReturnType<typeof refundStatus>;
  amountCents: number;
  currency: string;
  customId: string | null;
}

/** A refund object (refund response or PAYMENT.CAPTURE.REFUNDED / REVERSED resource). */
export function refundFacts(refund: unknown): RefundFacts | null {
  const r = obj(refund);
  const id = str(r.id);
  const amount = obj(r.amount);
  const cents = fromPayPalValue(amount.value);
  const currency = str(amount.currency_code);
  if (!id || !PAYPAL_ID_RE.test(id) || cents == null || !currency) return null;
  let captureId: string | null = null;
  for (const l of Array.isArray(r.links) ? r.links : []) {
    const href = str(obj(l).href);
    const m = href && obj(l).rel === "up" ? /\/v2\/payments\/captures\/([A-Za-z0-9]{6,64})$/.exec(href) : null;
    if (m) captureId = m[1];
  }
  return { refundId: id, captureId, status: refundStatus(r.status), amountCents: cents, currency: currency.toLowerCase(), customId: str(r.custom_id) };
}

/**
 * A PayPal dispute as exos_record_dispute_event arguments. Status mapping
 * (Stripe's vocabulary, which the dispute row and mails use):
 *   OPEN / WAITING_FOR_SELLER_RESPONSE      -> needs_response
 *   WAITING_FOR_BUYER_RESPONSE / UNDER_REVIEW / OTHER -> under_review
 *   RESOLVED, outcome buyer's favour / ACCEPTED -> lost
 *   RESOLVED, anything else                  -> won
 */
export interface DisputeFacts {
  dispute_id: string;
  capture_id: string | null;
  status: string;
  reason: string | null;
  amount_cents: number | null;
  currency: string | null;
  evidence_due_by: string | null;
  raw: Record<string, unknown>;
}

export function disputeFacts(resource: unknown): DisputeFacts | null {
  const d = obj(resource);
  const rawId = str(d.dispute_id);
  if (!rawId || !/^[A-Za-z0-9-]{4,64}$/.test(rawId)) return null;
  const txs = Array.isArray(d.disputed_transactions) ? d.disputed_transactions : [];
  const capture = str(obj(txs[0]).seller_transaction_id);
  const ps = str(d.status) ?? "";
  const outcome = str(obj(d.dispute_outcome).outcome_code) ?? "";
  const status = ps === "RESOLVED"
    ? (outcome === "RESOLVED_BUYER_FAVOUR" || outcome === "ACCEPTED" ? "lost" : "won")
    : ps === "OPEN" || ps === "WAITING_FOR_SELLER_RESPONSE" ? "needs_response" : "under_review";
  const amount = obj(d.dispute_amount);
  const reason = str(d.reason);
  const due = str(d.seller_response_due_date);
  return {
    dispute_id: ppRef.dispute(rawId),
    capture_id: capture && PAYPAL_ID_RE.test(capture) ? capture : null,
    status,
    reason: reason ? reason.toLowerCase().replace(/[^a-z_]/g, "_").slice(0, 60) : null,
    amount_cents: fromPayPalValue(amount.value),
    currency: str(amount.currency_code)?.toLowerCase() ?? null,
    evidence_due_by: due && !Number.isNaN(Date.parse(due)) ? new Date(due).toISOString() : null,
    // Allowlisted: no buyer messages, evidence or addresses.
    raw: { provider: "paypal", id: rawId, status: ps, outcome: outcome || null, reason: reason ?? null, life_cycle_stage: str(d.dispute_life_cycle_stage) },
  };
}

/** The webhook events exos-paypal acts on. Anything else is acknowledged and ignored. */
export const HANDLED_EVENTS = new Set([
  "CHECKOUT.ORDER.APPROVED",
  "PAYMENT.CAPTURE.COMPLETED",
  "PAYMENT.CAPTURE.PENDING",
  "PAYMENT.CAPTURE.DECLINED",
  "PAYMENT.CAPTURE.DENIED",
  "PAYMENT.CAPTURE.REFUNDED",
  "PAYMENT.CAPTURE.REVERSED",
  "CUSTOMER.DISPUTE.CREATED",
  "CUSTOMER.DISPUTE.UPDATED",
  "CUSTOMER.DISPUTE.RESOLVED",
]);

/** The transmission headers PayPal signs a webhook with; null when one is missing or off. */
export interface WebhookHeaders {
  auth_algo: string;
  cert_url: string;
  transmission_id: string;
  transmission_sig: string;
  transmission_time: string;
}

export function webhookHeaders(get: (name: string) => string | null): WebhookHeaders | null {
  const h = {
    auth_algo: get("paypal-auth-algo") ?? "",
    cert_url: get("paypal-cert-url") ?? "",
    transmission_id: get("paypal-transmission-id") ?? "",
    transmission_sig: get("paypal-transmission-sig") ?? "",
    transmission_time: get("paypal-transmission-time") ?? "",
  };
  if (Object.values(h).some((v) => v === "" || v.length > 2048)) return null;
  if (!/^SHA\d+withRSA$/.test(h.auth_algo)) return null;
  if (!certUrlAllowed(h.cert_url)) return null;
  return h;
}

/** Only PayPal's own API hosts serve the signing certificate. */
export function certUrlAllowed(url: string): boolean {
  try {
    const u = new URL(url);
    return u.protocol === "https:" && /^api(-m)?\.(sandbox\.)?paypal\.com$/.test(u.hostname);
  } catch {
    return false;
  }
}

/**
 * The verify-webhook-signature request body. The event goes in as the RAW
 * text PayPal sent: re-serializing parsed JSON can change number / unicode
 * formatting and make a genuine event fail verification.
 */
export function verifyBody(h: WebhookHeaders, webhookId: string, rawEvent: string): string {
  return `{"auth_algo":${JSON.stringify(h.auth_algo)},"cert_url":${JSON.stringify(h.cert_url)},` +
    `"transmission_id":${JSON.stringify(h.transmission_id)},"transmission_sig":${JSON.stringify(h.transmission_sig)},` +
    `"transmission_time":${JSON.stringify(h.transmission_time)},"webhook_id":${JSON.stringify(webhookId)},` +
    `"webhook_event":${rawEvent}}`;
}
