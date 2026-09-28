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

// ── TEvo's seller fee ───────────────────────────────────────────────
//
// TEvo takes 3% of the order total from the seller (order.fee), rounded to
// the nearest cent, half up, per order (not per ticket). Checked on
// 2026-09-28 against every stored order the S4K office sold: 4,371 of 4,371
// match, May to September, to both buyers (Ticket Evolution, Victory Live),
// including 41 exact half-cent cases (21.50 -> 0.65). Purchases carry fee
// 0. `service_fee` is a different thing: the buyer's fee.

export const TEVO_SELLER_FEE_BPS = 300;

/** 3% of the order total in cents, rounded half up: 3248 -> 97, 95760 -> 2873, 2150 -> 65. */
export function tevoSellerFeeCents(totalCents: number): number {
  if (!Number.isInteger(totalCents) || totalCents <= 0) return 0;
  return Math.floor((totalCents * TEVO_SELLER_FEE_BPS + 5000) / 10000);
}

export interface TevoFeeCheck {
  total_cents: number | null;
  /** order.fee as TEvo reported it; null if the order didn't carry one. */
  fee_cents: number | null;
  expected_fee_cents: number | null;
  /** The fee Exos uses: TEvo's when present, else the standard 3%. */
  used_fee_cents: number;
  /** false when TEvo's fee differs from 3%: the payout ledger flags it for a person. */
  matches_standard: boolean;
}

export function tevoFeeCheck(order: { total?: unknown; fee?: unknown }): TevoFeeCheck {
  const total = tevoAmountCents(order.total);
  const fee = tevoAmountCents(order.fee);
  const expected = total == null ? null : tevoSellerFeeCents(total);
  return {
    total_cents: total,
    fee_cents: fee,
    expected_fee_cents: expected,
    used_fee_cents: Math.max(0, fee ?? expected ?? 0),
    matches_standard: fee == null || expected == null || fee === expected,
  };
}
