// PayPal reconciliation report (exos-paypal action "reconcile", mig
// 20261031220000): the platform PayPal account's transactions for a window
// (Transaction Search, GET /v1/reporting/transactions, read-only) vs the
// Exos ledger rows with provider 'paypal'. Pure, so vitest loads it.
//
// Directions, as for Stripe (_shared/reconcile.ts):
//   PayPal -> Exos  every Exos checkout payment / refund PayPal booked
//                   (invoice_id = our pp_ session id) has its ledger row, with
//                   the same amount and currency
//   Exos -> PayPal  every succeeded Exos PayPal payment / refund created
//                   inside the window (less a margin at both ends) shows up
// Transaction Search lags up to a few hours behind; run it for a window that
// ended at least that long ago. Other balance movements (withdrawals, hand
// payouts to organizers, fees billed separately) are only counted.

import { PAYPAL_SESSION_RE, fromPayPalValue } from "./model.ts";

export interface PayPalTxn {
  id: string;
  eventCode: string;
  status: string;
  amountCents: number; // signed: refunds are negative
  currency: string;
  feeCents: number | null;
  invoiceId: string | null;
  at: string;
}

/** One transaction_details[] entry of Transaction Search; null when unusable. */
export function paypalTxn(detail: unknown): PayPalTxn | null {
  const ti = (detail as { transaction_info?: Record<string, unknown> } | null)?.transaction_info;
  if (!ti) return null;
  const id = typeof ti.transaction_id === "string" ? ti.transaction_id : "";
  const amt = (ti.transaction_amount ?? {}) as { value?: string; currency_code?: string };
  const raw = typeof amt.value === "string" ? amt.value.trim() : "";
  const neg = raw.startsWith("-");
  const cents = fromPayPalValue(neg ? raw.slice(1) : raw);
  if (!/^[A-Za-z0-9]{6,64}$/.test(id) || cents == null || !amt.currency_code) return null;
  const fee = (ti.fee_amount ?? {}) as { value?: string };
  const feeRaw = typeof fee.value === "string" ? fee.value.replace(/^-/, "") : "";
  return {
    id,
    eventCode: String(ti.transaction_event_code ?? ""),
    status: String(ti.transaction_status ?? ""),
    amountCents: neg ? -cents : cents,
    currency: amt.currency_code.toLowerCase(),
    feeCents: fromPayPalValue(feeRaw),
    invoiceId: typeof ti.invoice_id === "string" ? ti.invoice_id : null,
    at: String(ti.transaction_initiation_date ?? ""),
  };
}

export interface LedgerPayment {
  session_id: string;
  payment_intent: string | null; // ppcap_…
  amount_cents: number;
  currency: string;
  status: string;
  created_at: string;
}

export interface LedgerRefund {
  session_id: string;
  refund_id: string | null; // pprf_… / pprev_…
  amount_cents: number;
  currency: string;
  status: string;
  created_at: string;
}

export type PayPalIssueKind =
  | "paypal_payment_missing" // PayPal booked it, Exos has no row
  | "exos_payment_missing"   // Exos says succeeded, PayPal has no such capture
  | "amount_mismatch"
  | "paypal_refund_missing"
  | "exos_refund_missing"
  | "refund_amount_mismatch";

export interface PayPalIssue {
  kind: PayPalIssueKind;
  key: string;
  session_id: string | null;
  detail: Record<string, unknown>;
}

export interface PayPalReport {
  checked: { paypal: number; payments: number; refunds: number; other: number };
  issues: PayPalIssue[];
}

/**
 * Diff a window. `from` / `to` bound the Exos rows checked for a missing
 * PayPal movement (callers pass the window less a margin).
 */
export function reconcilePayPal(
  txns: readonly PayPalTxn[],
  payments: readonly LedgerPayment[],
  refunds: readonly LedgerRefund[],
  window: { from: string; to: string },
): PayPalReport {
  const issues: PayPalIssue[] = [];
  const payByRef = new Map(payments.filter((p) => p.payment_intent).map((p) => [p.payment_intent as string, p]));
  const refByRef = new Map(refunds.filter((r) => r.refund_id).map((r) => [r.refund_id as string, r]));
  const seenPay = new Set<string>();
  const seenRef = new Set<string>();
  let other = 0;
  for (const t of txns) {
    const ours = t.invoiceId != null && PAYPAL_SESSION_RE.test(t.invoiceId);
    if (!ours || t.status === "D") { other++; continue; }
    if (t.amountCents > 0) {
      const ref = `ppcap_${t.id}`;
      seenPay.add(ref);
      const p = payByRef.get(ref);
      if (!p) {
        issues.push({ kind: "paypal_payment_missing", key: ref, session_id: t.invoiceId, detail: { amount_cents: t.amountCents, currency: t.currency, status: t.status } });
      } else if (p.amount_cents !== t.amountCents || p.currency !== t.currency) {
        issues.push({ kind: "amount_mismatch", key: ref, session_id: p.session_id, detail: { exos: p.amount_cents, paypal: t.amountCents, currency: t.currency } });
      }
    } else if (t.amountCents < 0) {
      const amount = -t.amountCents;
      const r = refByRef.get(`pprf_${t.id}`) ?? refByRef.get(`pprev_${t.id}`);
      if (r && r.refund_id) seenRef.add(r.refund_id);
      if (!r) {
        issues.push({ kind: "paypal_refund_missing", key: `pprf_${t.id}`, session_id: t.invoiceId, detail: { amount_cents: amount, currency: t.currency, event_code: t.eventCode } });
      } else if (r.amount_cents !== amount) {
        issues.push({ kind: "refund_amount_mismatch", key: r.refund_id as string, session_id: r.session_id, detail: { exos: r.amount_cents, paypal: amount } });
      }
    } else {
      other++;
    }
  }
  const lo = Date.parse(window.from), hi = Date.parse(window.to);
  const inWindow = (at: string) => { const t = Date.parse(at); return t >= lo && t <= hi; };
  for (const p of payments) {
    if (p.status === "succeeded" && p.payment_intent && inWindow(p.created_at) && !seenPay.has(p.payment_intent)) {
      issues.push({ kind: "exos_payment_missing", key: p.payment_intent, session_id: p.session_id, detail: { amount_cents: p.amount_cents } });
    }
  }
  for (const r of refunds) {
    if (r.status === "succeeded" && r.refund_id && inWindow(r.created_at) && !seenRef.has(r.refund_id)) {
      issues.push({ kind: "exos_refund_missing", key: r.refund_id, session_id: r.session_id, detail: { amount_cents: r.amount_cents } });
    }
  }
  return { checked: { paypal: txns.length, payments: payments.length, refunds: refunds.length, other }, issues };
}
