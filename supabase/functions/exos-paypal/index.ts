// exos-paypal — PayPal (and Venmo) payments on the platform's PayPal account
// (mig 20261031220000; operator approval 2026-10-30, CLAUDE.md upstream-API
// rule). Orders are created by exos-checkout (processor: 'paypal') from the
// same priced cart as a Stripe session; this function does the rest.
//
// The only PayPal writes anywhere in Exos are order create (exos-checkout),
// capture (here) and refund (here and exos-refund), all through
// _shared/paypal/client.ts, whose allowlist refuses any other POST. Sandbox
// unless EXOS_PAYPAL_ENV=live and the keys are set.
//
// Requests (POST):
//   PayPal webhook (PayPal-Transmission-* headers)
//     Signature checked with PayPal's verify-webhook-signature API
//     (PAYPAL_WEBHOOK_ID), then: CHECKOUT.ORDER.APPROVED (capture it),
//     PAYMENT.CAPTURE.COMPLETED / PENDING / DECLINED / DENIED (record,
//     fulfil, auto-refund an order that can't stand), PAYMENT.CAPTURE.
//     REFUNDED (ledger row, finalize an Exos refund request, void when fully
//     refunded), PAYMENT.CAPTURE.REVERSED (money gone: ledger row + void),
//     CUSTOMER.DISPUTE.CREATED / UPDATED / RESOLVED (exos_record_dispute_event;
//     lost -> void). Idempotent; a 5xx makes PayPal retry.
//   { action: "capture", order_id }   the PayPal page after the buyer approved
//     -> { status, payment_status, session_id }. No JWT needed: the order id
//     only captures an order its buyer approved, and only while the seat hold
//     is live (exos_paypal_capture_gate).
//   { action: "cancel", order_id }     the buyer closed PayPal: release the
//     seats now unless PayPal says the order was approved or paid.
//   { action: "reconcile", days? }     cron secret. Pending PayPal sessions
//     older than 10 minutes are settled from PayPal's order state (approved
//     -> captured; completed -> recorded; never approved for 3 hours ->
//     expired), paid-but-failed sessions are refunded, and a read-only report
//     compares PayPal's transactions with the ledger
//     (_shared/paypal/reconcile.ts). Returns the counts and the report.
//
// Secrets: PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET, PAYPAL_WEBHOOK_ID,
// EXOS_PAYPAL_ENV (live, else sandbox), CRON_SECRET, SUPABASE_URL +
// SUPABASE_SERVICE_ROLE_KEY. PayPal off (no keys) -> 503.
// Deploy with --no-verify-jwt (PayPal can't send a JWT; the webhook
// signature, the order id and the cron secret are the gates).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { createPayPalClient, PayPalError, paypalConfig, type PayPalClient } from "../_shared/paypal/client.ts";
import { captureOrder, type Db, handleWebhook, settleCapture } from "../_shared/paypal/flows.ts";
import { orderCapture, PAYPAL_ORDER_RE } from "../_shared/paypal/model.ts";
import { paypalTxn, reconcilePayPal, type LedgerPayment, type LedgerRefund } from "../_shared/paypal/reconcile.ts";

const log = (msg: string, err?: unknown) => console.error(msg, err ?? "");

// deno-lint-ignore no-explicit-any
function dbOf(sb: SupabaseClient<any, any, any>): Db {
  return {
    rpc: async (fn, args) => {
      const { data, error } = await sb.rpc(fn, args);
      return { data, error };
    },
    rows: async (table, cols, match) => {
      const { data, error } = await sb.from(table).select(cols).match(match).limit(500);
      if (error) throw new Error(`${table}: ${error.message}`);
      return (data ?? []) as unknown as Record<string, unknown>[];
    },
  };
}

// The body as text, or null past `max` bytes (stops reading there).
async function readCappedText(req: Request, max: number): Promise<string | null> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const parts: Uint8Array[] = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) { await reader.cancel(); return null; }
    parts.push(value);
  }
  const all = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { all.set(p, o); o += p.byteLength; }
  return new TextDecoder().decode(all);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
  const cfg = paypalConfig((k) => Deno.env.get(k));
  if (!cfg) return json({ error: "PayPal is switched off" }, 503);
  const pp = createPayPalClient(cfg);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const db = dbOf(sb);

  // Bodies here are small (a webhook event, an order id): cap them.
  const raw = await readCappedText(req, 256 * 1024);
  if (raw === null) return json({ error: "body too large" }, 413);

  if (req.headers.get("paypal-transmission-id")) {
    const out = await handleWebhook(db, pp, (h) => req.headers.get(h), raw, !!cfg.webhookId, log);
    return new Response(out.body, { status: out.http, headers: { "content-type": "application/json" } });
  }

  let p: { action?: string; order_id?: string; days?: number };
  try { p = JSON.parse(raw); } catch { return json({ error: "invalid JSON" }, 400); }
  if (!p || typeof p !== "object") return json({ error: "invalid body" }, 400);

  if (p.action === "capture") {
    const orderId = typeof p.order_id === "string" ? p.order_id : "";
    try {
      const out = await captureOrder(db, pp, orderId, log);
      return json(out.body, out.http);
    } catch (e) {
      log(`exos-paypal: capture ${orderId} didn't complete`, e);
      // Safe to retry: the capture is keyed on the session (PayPal-Request-Id).
      return json({ error: "PayPal didn't answer; try again (you won't be charged twice)", retry: true }, 502);
    }
  }

  if (p.action === "cancel") {
    const orderId = typeof p.order_id === "string" ? p.order_id : "";
    if (!PAYPAL_ORDER_RE.test(orderId)) return json({ error: "bad order id" }, 400);
    const { data: s } = await sb.from("exos_checkout_sessions").select("session_id, status")
      .eq("paypal_order_id", orderId).maybeSingle();
    if (!s) return json({ error: "order not found" }, 404);
    if (s.status !== "pending") return json({ status: s.status });
    try {
      const order = await pp.getOrder(orderId);
      if (order.status === "APPROVED" || order.status === "COMPLETED") return json({ status: "pending", paypal: order.status });
    } catch (e) {
      if (!(e instanceof PayPalError && e.status === 404)) return json({ error: "PayPal didn't answer" }, 502);
    }
    await expireSession(sb, s.session_id as string, "buyer left PayPal");
    return json({ status: "expired" });
  }

  if (p.action === "reconcile") {
    const denied = requireCronSecret(req);
    if (denied) return denied;
    return json(await reconcile(sb, db, pp, Math.min(Math.max(Number(p.days ?? 3) || 3, 1), 31)));
  }

  return json({ error: "unknown action" }, 400);
});

// deno-lint-ignore no-explicit-any
async function expireSession(sb: SupabaseClient<any, any, any>, sessionId: string, reason: string) {
  await sb.from("exos_checkout_sessions").update({ status: "expired", failure_reason: reason })
    .eq("session_id", sessionId).eq("status", "pending");
  await sb.from("exos_cart_holds").update({ status: "released", released_at: new Date().toISOString() })
    .eq("checkout_session_id", sessionId).eq("status", "active");
}

const GRACE_MS = 10 * 60 * 1000;
const NEVER_APPROVED_MS = 3 * 60 * 60 * 1000;
const MARGIN_MS = 60 * 60 * 1000;

// deno-lint-ignore no-explicit-any
async function reconcile(sb: SupabaseClient<any, any, any>, db: Db, pp: PayPalClient, days: number) {
  const out = { checked: 0, captured: 0, recorded: 0, expired: 0, refunded: 0, errors: 0, report: null as unknown };
  const now = Date.now();

  // 1. Pending PayPal sessions: PayPal's order state is the truth.
  const { data: pending } = await sb.from("exos_checkout_sessions")
    .select("session_id, paypal_order_id, created_at")
    .eq("processor", "paypal").eq("status", "pending")
    .lt("created_at", new Date(now - GRACE_MS).toISOString())
    .order("created_at", { ascending: true }).limit(25);
  for (const row of pending ?? []) {
    out.checked++;
    const orderId = row.paypal_order_id as string;
    try {
      const order = await pp.getOrder(orderId);
      if (order.status === "APPROVED") {
        const r = await captureOrder(db, pp, orderId, log);
        if (r.http === 200) out.captured++;
      } else if (order.status === "COMPLETED") {
        const f = orderCapture(order);
        if (f) { await settleCapture(db, pp, { ...f, orderId }, null, log); out.recorded++; }
      } else if (order.status === "VOIDED" || now - Date.parse(row.created_at as string) > NEVER_APPROVED_MS) {
        await expireSession(sb, row.session_id as string, `paypal order ${String(order.status).toLowerCase()}`);
        out.expired++;
      }
    } catch (e) {
      if (e instanceof PayPalError && e.status === 404) {
        await expireSession(sb, row.session_id as string, "paypal order not found");
        out.expired++;
      } else {
        out.errors++;
        log(`exos-paypal: reconcile ${row.session_id}`, e);
      }
    }
  }

  // 2. Paid but not issued, no refund yet: settleCapture refunds (same request id).
  const { data: stuck } = await sb.from("exos_checkout_sessions")
    .select("session_id, paypal_order_id").eq("processor", "paypal").in("status", ["failed", "expired"])
    .gt("created_at", new Date(now - 30 * 86400_000).toISOString()).limit(200);
  for (const row of stuck ?? []) {
    const pays = await db.rows("exos_order_payments", "payment_intent", { session_id: row.session_id as string, status: "succeeded" });
    if (pays.length === 0) continue;
    const rfs = await db.rows("exos_order_refunds", "status", { session_id: row.session_id as string });
    if (rfs.some((r) => r.status === "succeeded" || r.status === "pending")) continue;
    try {
      const order = await pp.getOrder(row.paypal_order_id as string);
      const f = orderCapture(order);
      if (f && f.status === "COMPLETED") {
        await settleCapture(db, pp, { ...f, orderId: row.paypal_order_id as string }, null, log);
        out.refunded++;
      }
    } catch (e) {
      out.errors++;
      log(`exos-paypal: reconcile refund ${row.session_id}`, e);
    }
  }

  // 3. The report: PayPal's transactions vs the ledger (read-only).
  const end = new Date(now - 3 * 3600_000);
  const start = new Date(end.getTime() - days * 86400_000);
  try {
    const txns = [];
    for (let page = 1; page <= 20; page++) {
      const res = await pp.listTransactions({ start: start.toISOString(), end: end.toISOString(), page });
      const list = Array.isArray(res.transaction_details) ? res.transaction_details : [];
      for (const d of list) { const t = paypalTxn(d); if (t) txns.push(t); }
      if (page >= Number(res.total_pages ?? 1)) break;
    }
    const { data: pays } = await sb.from("exos_order_payments")
      .select("session_id, payment_intent, amount_cents, currency, status, created_at").eq("provider", "paypal")
      .gte("created_at", start.toISOString()).lte("created_at", end.toISOString()).limit(10_000);
    const { data: rfs } = await sb.from("exos_order_refunds")
      .select("session_id, refund_id, amount_cents, currency, status, created_at").eq("provider", "paypal")
      .gte("created_at", start.toISOString()).lte("created_at", end.toISOString()).limit(10_000);
    out.report = reconcilePayPal(txns, (pays ?? []) as LedgerPayment[], (rfs ?? []) as LedgerRefund[], {
      from: new Date(start.getTime() + MARGIN_MS).toISOString(),
      to: new Date(end.getTime() - MARGIN_MS).toISOString(),
    });
  } catch (e) {
    out.errors++;
    log("exos-paypal: transaction report failed", e);
  }
  return out;
}
