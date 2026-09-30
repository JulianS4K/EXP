// Daily Stripe reconciliation (exos-reconcile-stripe, mig 20261001101000):
// the platform account's balance transactions for a window vs what Exos
// recorded (exos_order_payments, exos_order_refunds, exos_disputes). Pure, no
// imports, so Deno and vitest (src/lib/reconcile.test.ts) both load it.
//
// Directions:
//   Stripe -> Exos  every charge / refund / dispute movement Stripe booked must
//                   have its Exos row, with the same amount (and fee, once
//                   Exos recorded one).
//   Exos -> Stripe  every succeeded Exos payment / refund created inside the
//                   window (less a margin at both ends, so a row written a
//                   minute after its charge doesn't flap at the boundary) must
//                   have a Stripe movement.
// Everything else on the balance (transfers to organizers, payouts to the
// bank, Stripe fees billed separately) isn't an order movement and is only
// counted.

type Id = string | { id?: string | null } | null | undefined;

/** One row of exos_stripe_balance_txns. */
export interface StripeTxnRow {
  id: string;
  type: string;
  reporting_category: string | null;
  amount_cents: number;
  fee_cents: number;
  net_cents: number;
  currency: string;
  source_id: string | null;
  payment_intent: string | null;
  status: string | null;
  created: string;
  available_on: string | null;
}

export interface ExosPaymentRow {
  session_id: string;
  org_id: string | null;
  payment_intent: string | null;
  charge_id: string | null;
  balance_txn_id: string | null;
  amount_cents: number;
  currency: string;
  status: string;
  stripe_fee_cents: number | null;
  created_at: string;
}

export interface ExosRefundRow {
  session_id: string;
  org_id: string | null;
  refund_id: string | null;
  amount_cents: number;
  currency: string;
  status: string;
  created_at: string;
}

export interface ExosDisputeRow {
  dispute_id: string;
  session_id: string | null;
  org_id: string | null;
}

export const ISSUE_KINDS = [
  "stripe_payment_missing", // Stripe charged, Exos has no payment row
  "exos_payment_missing", // Exos has a succeeded payment, Stripe has no charge in the window
  "payment_status_mismatch", // Stripe charged, the Exos payment row isn't succeeded
  "amount_mismatch", // charge amount / currency differs from the Exos payment
  "fee_mismatch", // Stripe's fee differs from the fee Exos recorded
  "stripe_refund_missing", // Stripe refunded, Exos has no refund row
  "exos_refund_missing", // Exos has a succeeded refund, Stripe has no refund movement in the window
  "refund_amount_mismatch", // refund amount / currency differs
  "stripe_dispute_missing", // Stripe moved money for a dispute Exos never recorded
] as const;
export type IssueKind = typeof ISSUE_KINDS[number];

export interface ReconcileIssue {
  kind: IssueKind;
  /** Unique per kind: the Stripe object id, else the Exos session / refund. */
  key: string;
  stripe_id: string | null;
  session_id: string | null;
  org_id: string | null;
  /** When the underlying movement happened (Stripe's created, or the Exos row's). */
  occurred_at: string;
  detail: Record<string, unknown>;
}

export interface ReconcileStats {
  txns: number;
  charges: number;
  refunds: number;
  disputes: number;
  other: number;
  matched_payments: number;
  matched_refunds: number;
  matched_disputes: number;
  issues: number;
  by_kind: Partial<Record<IssueKind, number>>;
}

export const CHARGE_TYPES = new Set(["charge", "payment"]);
export const REFUND_TYPES = new Set(["refund", "payment_refund"]);

function idOf(v: Id): string | null {
  if (typeof v === "string") return v || null;
  return v && typeof v.id === "string" && v.id ? v.id : null;
}
function int(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}
function iso(unix: unknown): string | null {
  return typeof unix === "number" && unix > 0 ? new Date(unix * 1000).toISOString() : null;
}

export interface BalanceTxnLike {
  id?: string | null;
  type?: string | null;
  reporting_category?: string | null;
  amount?: number | null;
  fee?: number | null;
  net?: number | null;
  currency?: string | null;
  status?: string | null;
  created?: number | null;
  available_on?: number | null;
  // With expand[]=data.source: the Charge / Refund / Dispute object.
  source?: string | { id?: string | null; object?: string | null; payment_intent?: Id } | null;
}

/** Map one Stripe balance transaction (source expanded or not) to its snapshot row; null when unusable. */
export function txnRow(bt: BalanceTxnLike): StripeTxnRow | null {
  if (typeof bt.id !== "string" || !/^[a-z]{2,5}_[A-Za-z0-9]{1,200}$/.test(bt.id)) return null;
  const created = iso(bt.created);
  if (!created) return null;
  const src = bt.source;
  const pi = src && typeof src === "object" ? idOf(src.payment_intent) : null;
  return {
    id: bt.id,
    type: typeof bt.type === "string" ? bt.type : "unknown",
    reporting_category: typeof bt.reporting_category === "string" ? bt.reporting_category : null,
    amount_cents: int(bt.amount),
    fee_cents: int(bt.fee),
    net_cents: int(bt.net),
    currency: (typeof bt.currency === "string" ? bt.currency : "usd").toLowerCase(),
    source_id: idOf(src as Id),
    payment_intent: pi,
    status: typeof bt.status === "string" ? bt.status : null,
    created,
    available_on: iso(bt.available_on),
  };
}

export function isDisputeTxn(t: StripeTxnRow): boolean {
  if (t.reporting_category === "dispute" || t.reporting_category === "dispute_reversal") return true;
  return t.type === "adjustment" && !!t.source_id && /^(dp|du)_/.test(t.source_id);
}

export interface ReconcileInput {
  txns: StripeTxnRow[];
  payments: ExosPaymentRow[];
  refunds: ExosRefundRow[];
  disputes: ExosDisputeRow[];
  /** The window the txns cover: [from, to). */
  from: string;
  to: string;
  /** Exos rows this close to either end aren't checked for a missing Stripe movement. Default 1 h. */
  marginMs?: number;
}

/** Compare one window of Stripe balance transactions with the Exos ledger. Deterministic (sorted output). */
export function reconcile(input: ReconcileInput): { issues: ReconcileIssue[]; stats: ReconcileStats } {
  const margin = input.marginMs ?? 60 * 60 * 1000;
  const checkFrom = new Date(input.from).getTime() + margin;
  const checkTo = new Date(input.to).getTime() - margin;

  const byCharge = new Map<string, ExosPaymentRow>();
  const byBt = new Map<string, ExosPaymentRow>();
  const byPi = new Map<string, ExosPaymentRow>();
  for (const p of input.payments) {
    if (p.charge_id) byCharge.set(p.charge_id, p);
    if (p.balance_txn_id) byBt.set(p.balance_txn_id, p);
    if (p.payment_intent) byPi.set(p.payment_intent, p);
  }
  const refundById = new Map<string, ExosRefundRow>();
  for (const r of input.refunds) if (r.refund_id) refundById.set(r.refund_id, r);
  const disputeById = new Map<string, ExosDisputeRow>();
  for (const d of input.disputes) disputeById.set(d.dispute_id, d);

  const issues = new Map<string, ReconcileIssue>();
  const add = (i: ReconcileIssue) => {
    const k = `${i.kind}|${i.key}`;
    if (!issues.has(k)) issues.set(k, i);
  };
  const stats: ReconcileStats = {
    txns: input.txns.length, charges: 0, refunds: 0, disputes: 0, other: 0,
    matched_payments: 0, matched_refunds: 0, matched_disputes: 0, issues: 0, by_kind: {},
  };
  const seenPayments = new Set<ExosPaymentRow>();
  const seenRefunds = new Set<string>();

  for (const t of input.txns) {
    if (CHARGE_TYPES.has(t.type)) {
      stats.charges++;
      const p = (t.source_id && byCharge.get(t.source_id)) || byBt.get(t.id) ||
        (t.payment_intent ? byPi.get(t.payment_intent) : undefined);
      const stripeId = t.source_id ?? t.id;
      if (!p) {
        add({
          kind: "stripe_payment_missing", key: stripeId, stripe_id: stripeId, session_id: null, org_id: null,
          occurred_at: t.created,
          detail: { txn: t.id, type: t.type, amount_cents: t.amount_cents, fee_cents: t.fee_cents, currency: t.currency, payment_intent: t.payment_intent },
        });
        continue;
      }
      stats.matched_payments++;
      seenPayments.add(p);
      const base = { stripe_id: stripeId, session_id: p.session_id, org_id: p.org_id, occurred_at: t.created };
      if (p.status !== "succeeded") {
        add({ kind: "payment_status_mismatch", key: stripeId, ...base, detail: { txn: t.id, exos_status: p.status } });
      }
      if (p.amount_cents !== t.amount_cents || p.currency.toLowerCase() !== t.currency) {
        add({
          kind: "amount_mismatch", key: stripeId, ...base,
          detail: { txn: t.id, stripe_amount_cents: t.amount_cents, stripe_currency: t.currency, exos_amount_cents: p.amount_cents, exos_currency: p.currency.toLowerCase() },
        });
      }
      if (p.stripe_fee_cents != null && p.stripe_fee_cents !== t.fee_cents) {
        add({
          kind: "fee_mismatch", key: stripeId, ...base,
          detail: { txn: t.id, stripe_fee_cents: t.fee_cents, exos_fee_cents: p.stripe_fee_cents },
        });
      }
    } else if (REFUND_TYPES.has(t.type)) {
      stats.refunds++;
      const stripeId = t.source_id ?? t.id;
      const r = t.source_id ? refundById.get(t.source_id) : undefined;
      if (!r) {
        const p = t.payment_intent ? byPi.get(t.payment_intent) : undefined;
        add({
          kind: "stripe_refund_missing", key: stripeId, stripe_id: stripeId, session_id: p?.session_id ?? null,
          org_id: p?.org_id ?? null, occurred_at: t.created,
          detail: { txn: t.id, type: t.type, amount_cents: -t.amount_cents, currency: t.currency, payment_intent: t.payment_intent },
        });
        continue;
      }
      stats.matched_refunds++;
      seenRefunds.add(r.refund_id!);
      if (r.amount_cents !== Math.abs(t.amount_cents) || r.currency.toLowerCase() !== t.currency) {
        add({
          kind: "refund_amount_mismatch", key: stripeId, stripe_id: stripeId, session_id: r.session_id, org_id: r.org_id,
          occurred_at: t.created,
          detail: { txn: t.id, stripe_amount_cents: Math.abs(t.amount_cents), stripe_currency: t.currency, exos_amount_cents: r.amount_cents, exos_currency: r.currency.toLowerCase() },
        });
      }
    } else if (isDisputeTxn(t)) {
      stats.disputes++;
      const did = t.source_id;
      if (did && disputeById.has(did)) {
        stats.matched_disputes++;
        continue;
      }
      const key = did ?? t.id;
      add({
        kind: "stripe_dispute_missing", key, stripe_id: key, session_id: null, org_id: null, occurred_at: t.created,
        detail: { txn: t.id, amount_cents: t.amount_cents, fee_cents: t.fee_cents, currency: t.currency, reporting_category: t.reporting_category },
      });
    } else {
      stats.other++;
    }
  }

  const inCheckWindow = (at: string) => {
    const ms = new Date(at).getTime();
    return Number.isFinite(ms) && ms >= checkFrom && ms < checkTo;
  };
  for (const p of input.payments) {
    if (p.status !== "succeeded" || p.amount_cents <= 0 || seenPayments.has(p) || !inCheckWindow(p.created_at)) continue;
    const key = p.payment_intent ?? p.charge_id ?? p.session_id;
    add({
      kind: "exos_payment_missing", key, stripe_id: p.payment_intent ?? p.charge_id, session_id: p.session_id, org_id: p.org_id,
      occurred_at: p.created_at, detail: { amount_cents: p.amount_cents, currency: p.currency.toLowerCase(), charge_id: p.charge_id },
    });
  }
  for (const r of input.refunds) {
    if (r.status !== "succeeded" || r.amount_cents <= 0 || !inCheckWindow(r.created_at)) continue;
    if (r.refund_id && seenRefunds.has(r.refund_id)) continue;
    const key = r.refund_id ?? `${r.session_id}:${r.created_at}`;
    add({
      kind: "exos_refund_missing", key, stripe_id: r.refund_id, session_id: r.session_id, org_id: r.org_id,
      occurred_at: r.created_at, detail: { amount_cents: r.amount_cents, currency: r.currency.toLowerCase() },
    });
  }

  const out = [...issues.values()].sort((a, b) => a.kind.localeCompare(b.kind) || a.key.localeCompare(b.key));
  stats.issues = out.length;
  for (const i of out) stats.by_kind[i.kind] = (stats.by_kind[i.kind] ?? 0) + 1;
  return { issues: out, stats };
}

/** The window for a daily run: the last `days` whole days up to `now`, as ISO strings. */
export function reconcileWindow(now: Date, days: number): { from: string; to: string } {
  const d = Math.min(Math.max(Math.trunc(days) || 1, 1), 90);
  return { from: new Date(now.getTime() - d * 86_400_000).toISOString(), to: now.toISOString() };
}
