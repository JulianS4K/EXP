// exos-paypal's money flows (mig 20261031220000), with the database and the
// PayPal client passed in, so vitest drives them with a fake DB and a fetch
// mock (src/lib/paypal.test.ts) and never reaches PayPal.
//
//   captureOrder   the buyer approved: gate (live hold), capture with a
//                  PayPal-Request-Id, record + fulfil, auto-refund if the order
//                  can't stand. Idempotent end to end.
//   handleWebhook  verify the signature with PayPal (verify-webhook-signature),
//                  then act on the event; every handler is idempotent, so
//                  PayPal's retries and replays are safe. A 5xx makes PayPal
//                  retry; a 400 is a bad / forged request.
//   refundPayPal   one organizer refund (exos-refund routes PayPal orders here)

import { PayPalError, type PayPalClient } from "./client.ts";
import {
  captureFacts, captureIdFromRef, type CaptureFacts, disputeFacts, HANDLED_EVENTS, orderCapture, ppRef,
  PAYPAL_ORDER_RE, refundFacts, type RefundFacts, toPayPalValue, webhookHeaders,
} from "./model.ts";

export interface DbError { code?: string; message?: string }
export interface Db {
  rpc(fn: string, args: Record<string, unknown>): Promise<{ data: unknown; error: DbError | null }>;
  /** Rows of `table` matching every key in `match` (equality). */
  rows(table: string, cols: string, match: Record<string, string>): Promise<Record<string, unknown>[]>;
}

export type Log = (msg: string, err?: unknown) => void;

export interface CaptureOutcome {
  http: number;
  body: Record<string, unknown>;
}

const autoRefundRequestId = (sessionId: string) => `exos_auto_refund_${sessionId}`;
export const captureRequestId = (sessionId: string) => `exos_cap_${sessionId}`;
export const organizerRefundRequestId = (requestId: string) => `exos_refund_${requestId}`;

/** Record a capture (and fulfil); give the money back when the order can't stand. Throws on a DB error. */
export async function settleCapture(db: Db, pp: PayPalClient, f: CaptureFacts, eventId: string | null, log: Log) {
  if (!f.orderId) throw new Error(`capture ${f.captureId} has no order id`);
  const { data, error } = await db.rpc("exos_paypal_record_capture", {
    p_order_id: f.orderId,
    p_capture_id: f.captureId,
    p_status: f.status,
    p_amount_cents: f.amountCents,
    p_currency: f.currency,
    p_fee_cents: f.feeCents,
    p_funding_source: f.fundingSource,
    p_provider_event_id: eventId,
  });
  if (error) throw Object.assign(new Error(`record_capture: ${error.message}`), { code: error.code });
  const r = (data ?? {}) as { session_id?: string; session_status?: string; payment_status?: string; needs_refund?: boolean };
  if (r.needs_refund && r.session_id && f.status === "COMPLETED") {
    // Full refund of what was captured; the request id makes a retry (or the
    // webhook racing the buyer's return) return the same refund.
    const refund = await pp.refundCapture(f.captureId, {
      note_to_payer: "Your order couldn't be completed, so you have not been charged.",
      custom_id: `auto_${r.session_id}`.slice(0, 127),
    }, autoRefundRequestId(r.session_id));
    const rf = refundFacts(refund);
    if (!rf) throw new Error(`auto-refund for ${r.session_id}: unreadable refund`);
    const { error: rfErr } = await db.rpc("exos_record_refund", {
      p_session_id: r.session_id,
      p_refund_id: ppRef.refund(rf.refundId),
      p_amount_cents: rf.amountCents,
      p_status: rf.status,
      p_payment_intent: ppRef.capture(f.captureId),
      p_reason: "auto-refund: unfulfillable after payment",
      p_currency: rf.currency,
      p_provider_event_id: eventId,
    });
    if (rfErr) throw new Error(`record auto-refund ${r.session_id}: ${rfErr.message}`);
    log(`exos-paypal: auto-refunded ${r.session_id} (${rf.refundId})`);
  }
  return r;
}

/** The buyer approved the PayPal order: capture it. */
export async function captureOrder(db: Db, pp: PayPalClient, orderId: string, log: Log, eventId: string | null = null): Promise<CaptureOutcome> {
  if (!PAYPAL_ORDER_RE.test(orderId)) return { http: 400, body: { error: "bad order id" } };
  const { data: gate, error: gErr } = await db.rpc("exos_paypal_capture_gate", { p_order_id: orderId });
  if (gErr) {
    if (gErr.code === "P0002") return { http: 404, body: { error: "order not found" } };
    throw new Error(`capture gate: ${gErr.message}`);
  }
  const g = (gate ?? {}) as { ok?: boolean; session_id?: string; status?: string; reason?: string };
  if (!g.ok) {
    if (g.status === "fulfilled" || g.status === "partially_refunded" || g.status === "refunded") {
      return { http: 200, body: { status: g.status, session_id: g.session_id } };
    }
    const msg = g.reason === "hold_expired"
      ? "Your reservation ran out before payment, so you were not charged. Please start again."
      : "This order can't be paid any more.";
    return { http: 409, body: { status: g.status, session_id: g.session_id, error: msg } };
  }
  let order: Record<string, unknown>;
  try {
    order = await pp.captureOrder(orderId, captureRequestId(g.session_id!));
  } catch (e) {
    if (e instanceof PayPalError && e.has("ORDER_ALREADY_CAPTURED")) {
      order = await pp.getOrder(orderId);
    } else if (e instanceof PayPalError && e.has("INSTRUMENT_DECLINED")) {
      // PayPal's guidance: send the buyer back to pick another funding source.
      return { http: 402, body: { error: "That payment method was declined. Pick another one.", retry: true, session_id: g.session_id } };
    } else if (e instanceof PayPalError && e.definitive) {
      log(`exos-paypal: capture of ${orderId} refused`, e);
      return { http: 409, body: { error: "PayPal didn't take the payment.", session_id: g.session_id } };
    } else {
      throw e;
    }
  }
  const f = orderCapture(order);
  if (!f) return { http: 502, body: { error: "PayPal didn't confirm the payment yet; check My Tickets shortly.", session_id: g.session_id } };
  if (f.customId && f.customId !== g.session_id) {
    log(`exos-paypal: order ${orderId} capture is for ${f.customId}, not ${g.session_id}`);
    return { http: 409, body: { error: "order mismatch" } };
  }
  const r = await settleCapture(db, pp, { ...f, orderId }, eventId, log);
  return { http: 200, body: { status: r.session_status, payment_status: r.payment_status, session_id: r.session_id } };
}

async function sessionForCapture(db: Db, captureId: string): Promise<{ session_id: string; amount_cents?: number } | null> {
  const rows = await db.rows("exos_order_payments", "session_id", { provider: "paypal", payment_intent: ppRef.capture(captureId) });
  const sid = rows[0]?.session_id;
  return typeof sid === "string" ? { session_id: sid } : null;
}

/** Record one refund (any origin), finalize an Exos refund request, void when fully refunded. */
export async function settleRefund(db: Db, sessionId: string, rf: RefundFacts, captureId: string, eventId: string, kind: "refund" | "reversal") {
  const ref = kind === "reversal" ? ppRef.reversal(rf.refundId) : ppRef.refund(rf.refundId);
  const status = kind === "reversal" ? "succeeded" : rf.status;
  const { error } = await db.rpc("exos_record_refund", {
    p_session_id: sessionId,
    p_refund_id: ref,
    p_amount_cents: rf.amountCents,
    p_status: status,
    p_payment_intent: ppRef.capture(captureId),
    p_reason: kind === "reversal" ? "paypal reversal" : "paypal refund",
    p_currency: rf.currency,
    p_provider_event_id: eventId,
  });
  if (error) throw new Error(`record_refund ${ref}: ${error.message}`);
  const m = /^exos_refund_([0-9a-f-]{36})$/.exec(rf.customId ?? "");
  if (m && kind === "refund") {
    const { error: fErr } = await db.rpc("exos_refund_finalize", {
      p_request_id: m[1], p_stripe_refund_id: ref, p_status: status, p_error: null,
    });
    if (fErr && fErr.code !== "P0002") throw new Error(`refund_finalize ${m[1]}: ${fErr.message}`);
  }
  // Void the order once SUCCEEDED refunds cover it (a partial refund leaves
  // the tickets: which to cancel is an organizer call), or on any reversal.
  const sess = await db.rows("exos_checkout_sessions", "amount_cents", { session_id: sessionId });
  const done = await db.rows("exos_order_refunds", "amount_cents", { session_id: sessionId, status: "succeeded" });
  const refunded = done.reduce((n, r) => n + Number(r.amount_cents ?? 0), 0);
  const amount = Number(sess[0]?.amount_cents ?? 0);
  if (kind === "reversal" || (amount > 0 && refunded >= amount)) {
    const { error: vErr } = await db.rpc("exos_refund_checkout", {
      p_session_id: sessionId, p_reason: kind === "reversal" ? "paypal reversal" : "paypal refund",
    });
    if (vErr) throw new Error(`refund_checkout ${sessionId}: ${vErr.message}`);
  }
}

export interface WebhookResult { http: number; body: string }

/** Verify, then act. `cfgWebhookId` null = misconfigured (500, PayPal retries). */
export async function handleWebhook(
  db: Db, pp: PayPalClient, get: (h: string) => string | null, raw: string, hasWebhookId: boolean, log: Log,
): Promise<WebhookResult> {
  if (!hasWebhookId) return { http: 500, body: "server misconfigured: PAYPAL_WEBHOOK_ID unset" };
  const h = webhookHeaders(get);
  if (!h) return { http: 400, body: "missing or bad PayPal transmission headers" };
  let ok = false;
  try {
    ok = await pp.verifyWebhook(h, raw);
  } catch (e) {
    log("exos-paypal: signature check didn't complete", e);
    return { http: 500, body: "verification error" };
  }
  if (!ok) {
    log("exos-paypal: webhook signature did not verify");
    return { http: 400, body: "invalid signature" };
  }
  const ev = JSON.parse(raw) as { id?: string; event_type?: string; resource?: unknown };
  const type = String(ev.event_type ?? "");
  const eventId = typeof ev.id === "string" ? ev.id.slice(0, 100) : null;
  if (!HANDLED_EVENTS.has(type)) return { http: 200, body: JSON.stringify({ received: true, ignored: type }) };
  const res = ev.resource;
  try {
    switch (type) {
      case "CHECKOUT.ORDER.APPROVED": {
        // The buyer approved but their page never asked us to capture.
        const id = String((res as { id?: string } | null)?.id ?? "");
        const out = await captureOrder(db, pp, id, log, eventId);
        if (out.http >= 500) return { http: 500, body: "capture pending" };
        break;
      }
      case "PAYMENT.CAPTURE.COMPLETED":
      case "PAYMENT.CAPTURE.PENDING":
      case "PAYMENT.CAPTURE.DECLINED":
      case "PAYMENT.CAPTURE.DENIED": {
        const f = captureFacts(res);
        if (!f) { log(`exos-paypal: ${type} unreadable, ignored`); break; }
        if (!f.orderId) {
          const s = await sessionForCapture(db, f.captureId);
          const rows = s ? await db.rows("exos_checkout_sessions", "paypal_order_id", { session_id: s.session_id }) : [];
          f.orderId = typeof rows[0]?.paypal_order_id === "string" ? rows[0].paypal_order_id as string : null;
        }
        if (!f.orderId) { log(`exos-paypal: ${type} for capture ${f.captureId}: not an Exos order`); break; }
        try {
          await settleCapture(db, pp, f, eventId, log);
        } catch (e) {
          if ((e as { code?: string }).code === "P0002") { log(`exos-paypal: ${type}: order ${f.orderId} isn't ours`); break; }
          throw e;
        }
        break;
      }
      case "PAYMENT.CAPTURE.REFUNDED":
      case "PAYMENT.CAPTURE.REVERSED": {
        const rf = refundFacts(res);
        const captureId = rf?.captureId ?? null;
        if (!rf || !captureId) { log(`exos-paypal: ${type} without a capture link, ignored`); break; }
        const s = await sessionForCapture(db, captureId);
        if (!s) { log(`exos-paypal: ${type} for capture ${captureId}: no Exos payment`); break; }
        await settleRefund(db, s.session_id, rf, captureId, eventId ?? rf.refundId, type === "PAYMENT.CAPTURE.REVERSED" ? "reversal" : "refund");
        break;
      }
      case "CUSTOMER.DISPUTE.CREATED":
      case "CUSTOMER.DISPUTE.UPDATED":
      case "CUSTOMER.DISPUTE.RESOLVED": {
        const d = disputeFacts(res);
        if (!d || !d.capture_id) { log(`exos-paypal: ${type} unreadable, ignored`); break; }
        const s = await sessionForCapture(db, d.capture_id);
        if (!s) { log(`exos-paypal: dispute ${d.dispute_id}: no Exos payment`); break; }
        const { data: stored, error } = await db.rpc("exos_record_dispute_event", {
          p_session_id: s.session_id,
          p_dispute_id: d.dispute_id,
          p_status: d.status,
          p_reason: d.reason,
          p_amount_cents: d.amount_cents,
          p_provider_event_id: eventId,
          p_charge_id: null,
          p_payment_intent: ppRef.capture(d.capture_id),
          p_fee_cents: null,
          p_currency: d.currency,
          p_evidence_due_by: d.evidence_due_by,
          p_evidence_submitted: null,
          p_livemode: pp.env === "live",
          p_raw: d.raw,
        });
        if (error) throw new Error(`record_dispute_event: ${error.message}`);
        if (stored === "lost") {
          const { error: vErr } = await db.rpc("exos_refund_checkout", {
            p_session_id: s.session_id, p_reason: `paypal dispute lost (${d.reason ?? "unknown"})`,
          });
          if (vErr) throw new Error(`lost-dispute void: ${vErr.message}`);
        }
        break;
      }
    }
  } catch (e) {
    log(`exos-paypal: ${type} handler error`, e);
    return { http: 500, body: "handler error" };
  }
  return { http: 200, body: JSON.stringify({ received: true }) };
}

export interface PayPalRefundClaim {
  request_id: string;
  amount_cents: number;
  payment_intent: string; // ppcap_…
  session_id: string;
  currency: string;
}

/**
 * Send one claimed organizer refund to PayPal. Returns PayPal's answer, or
 * throws a PayPalError (exos-refund decides definitive vs retry). The
 * request id is exos_refund_<request id>, as the Stripe idempotency key.
 */
export async function refundPayPal(pp: PayPalClient, c: PayPalRefundClaim): Promise<RefundFacts & { ref: string }> {
  const captureId = captureIdFromRef(c.payment_intent);
  if (!captureId) throw new Error("not a PayPal payment");
  const refund = await pp.refundCapture(captureId, {
    amount: { value: toPayPalValue(c.amount_cents), currency_code: c.currency.toUpperCase() },
    custom_id: organizerRefundRequestId(c.request_id),
    note_to_payer: "Refund from the event organizer",
  }, organizerRefundRequestId(c.request_id));
  const rf = refundFacts(refund);
  if (!rf) throw new Error("unreadable PayPal refund");
  return { ...rf, ref: ppRef.refund(rf.refundId) };
}
