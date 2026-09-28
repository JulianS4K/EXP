// What TEvo has paid on an order (Payments / Index, Show, Status), for the
// marketplace payout ledger: marketplaces pay around a week after the event,
// and this is how Exos sees whether TEvo's EvoPay payment for an order came
// through. Read only. Creating, applying, cancelling or refunding a payment
// is forbidden (endpoints.ts): those move money.
//
// A payment row carries card and address-check results (credit_card, avs_*,
// cvv_*), and the status list carries buyer / seller names that can be a
// person's. Neither is kept: normalizeTevoPayment keeps ids, type, state,
// direction and amount only.

/** A payment as TEvo returns it (Payments / Index and Show); only what Exos reads is typed. */
export interface TevoPayment {
  id: number;
  order_link_id?: number | null;
  type?: string;
  state?: string;
  amount?: string | number;
  is_refund?: boolean;
  refunded_from_id?: number | null;
  created_at?: string;
  updated_at?: string;
  [k: string]: unknown;
}

/** A row of Payments / Status (the office's payments across orders). */
export interface TevoPaymentStatusRow {
  id: number;
  order_link_id?: number | null;
  order_group_id?: number | null;
  transaction_type?: string;
  transaction_state?: string;
  payment_amount?: string | number;
  transaction_amount?: string | number;
  is_refund?: boolean;
  buyer_type?: string;
  seller_type?: string;
  created_at?: string;
  updated_at?: string;
  [k: string]: unknown;
}

export interface ExosTevoPayment {
  payment_id: string;
  order_id: string | null;
  /** cash, check, credit_card, evopay, … (Status: EvopayTransaction, …). */
  type: string | null;
  /** pending, completed, captured, … as TEvo says it. */
  state: string | null;
  amount_cents: number | null;
  is_refund: boolean;
  refunded_from_id: string | null;
  created_at: string | null;
  updated_at: string | null;
}

/** "15.0" / 15 / "1,299.50" -> cents, exactly (no float rounding); null if it isn't money. */
export function tevoAmountCents(v: unknown): number | null {
  const s = typeof v === 'number' ? (Number.isFinite(v) ? v.toFixed(2) : '') : typeof v === 'string' ? v.replace(/,/g, '').trim() : '';
  const m = /^(-)?(\d+)(?:\.(\d{1,2})\d*)?$/.exec(s);
  if (!m) return null;
  const cents = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0'));
  return m[1] ? -cents : cents;
}

const id = (v: unknown): string | null => (typeof v === 'number' && Number.isInteger(v)) || (typeof v === 'string' && /^\d+$/.test(v)) ? String(v) : null;
const txt = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : null);

export function normalizeTevoPayment(p: TevoPayment): ExosTevoPayment {
  return {
    payment_id: String(p.id),
    order_id: id(p.order_link_id),
    type: txt(p.type),
    state: txt(p.state),
    amount_cents: tevoAmountCents(p.amount),
    is_refund: p.is_refund === true,
    refunded_from_id: id(p.refunded_from_id),
    created_at: txt(p.created_at),
    updated_at: txt(p.updated_at),
  };
}

export function normalizeTevoPaymentStatus(r: TevoPaymentStatusRow): ExosTevoPayment {
  return {
    payment_id: String(r.id),
    order_id: id(r.order_link_id),
    type: txt(r.transaction_type),
    state: txt(r.transaction_state),
    amount_cents: tevoAmountCents(r.payment_amount ?? r.transaction_amount),
    is_refund: r.is_refund === true,
    refunded_from_id: null,
    created_at: txt(r.created_at),
    updated_at: txt(r.updated_at),
  };
}

/** States in which money has actually moved. Pending ones only affect TEvo's "pending balance". */
const SETTLED = new Set(['completed', 'captured']);

export interface OrderPaymentSummary {
  /** Settled payments minus settled refunds. */
  paid_cents: number;
  pending_cents: number;
  refunded_cents: number;
  /** States Exos doesn't know how to count: a person looks. */
  unknown_states: string[];
}

/** Where an order's money stands, from its payments. */
export function summarizeTevoPayments(payments: ReadonlyArray<ExosTevoPayment>): OrderPaymentSummary {
  const out: OrderPaymentSummary = { paid_cents: 0, pending_cents: 0, refunded_cents: 0, unknown_states: [] };
  for (const p of payments) {
    const amt = Math.abs(p.amount_cents ?? 0);
    const state = (p.state ?? '').toLowerCase();
    if (SETTLED.has(state)) {
      if (p.is_refund) {
        out.refunded_cents += amt;
        out.paid_cents -= amt;
      } else {
        out.paid_cents += amt;
      }
    } else if (state === 'pending') {
      if (!p.is_refund) out.pending_cents += amt;
    } else if (state !== 'cancelled' && state !== 'canceled' && !out.unknown_states.includes(state || '(none)')) {
      out.unknown_states.push(state || '(none)');
    }
  }
  return out;
}
