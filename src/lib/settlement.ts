// Organizer money: per-event settlement and the org's marketplace payouts.
// PURE aggregation + CSV rows (no Supabase import, so it unit-tests without a
// client); the reads live in ./settlementApi.ts. Read-only: nothing here moves
// money or writes a row.
//
// Sources (all owner / manager / finance through RLS):
//   exos_order_money              one row per Exos checkout, integer cents
//                                 (mig 20260929131000)
//   exos_marketplace_order_money  one row per marketplace order, numeric
//                                 dollars (mig 20260929070000)
//   exos_promoter_commissions     per ticket, cents (mig 20260926020000)
//   exos_org_payouts / _lines     marketplace payouts to the org, dollars
//
// Money rules this mirrors (docs/payments-go-live.md, docs/payouts.md):
//   * An Exos checkout is a Stripe destination charge: the organizer's account
//     gets gross − application fee, and the application fee is the Exos fee
//     plus the card-fee estimate. Stripe pays that out to the organizer; Exos
//     never holds it.
//   * A refund pulls the refunded share back from the organizer and, by
//     default, Exos returns its application fee in the same proportion
//     (refund_application_fee), so the organizer's net after refunds is
//     net × (1 − refunded / gross).
//   * Marketplace orders are paid by Exos: organizer_net = proceeds − exos_fee,
//     through exos_org_payouts. Cancelled orders don't count.

// ── Rows as the views return them ────────────────────────────────────────

export interface OrderMoneyRow {
  session_id: string;
  status: string;
  currency: string | null;
  created_at: string | null;
  fulfilled_at?: string | null;
  gross_cents: number | null;
  tax_cents: number | null;
  application_fee_cents: number | null;
  exos_fee_cents: number | null;
  card_fee_est_cents: number | null;
  card_fee_actual_cents: number | null;
  fee_free?: boolean | null;
  organizer_net_cents: number | null;
  refunded_cents: number | null;
  payment_intent?: string | null;
  transfer_id?: string | null;
  /** Tickets in the order (exos_checkout_sessions.quantity), when readable. */
  quantity?: number | null;
}

export interface MarketplaceMoneyRow {
  order_id: string;
  channel: string;
  external_order_id: string | null;
  quantity: number | null;
  currency: string | null;
  proceeds: number | string | null;
  exos_fee: number | string | null;
  organizer_net: number | string | null;
  state: string | null;
}

export interface CommissionMoneyRow {
  status: string;
  commission_cents: number | null;
  currency?: string | null;
}

// ── Helpers ──────────────────────────────────────────────────────────────

/** Checkouts where money was taken (a refund doesn't undo the sale row). */
export const PAID_ORDER_STATUSES = ['fulfilled', 'partially_refunded', 'refunded'] as const;

/** Marketplace states that no longer count as a sale. */
export const CANCELLED_MARKETPLACE_STATES = ['cancelled', 'clawback_due', 'clawed_back'] as const;

const int = (n: unknown): number => {
  const v = Number(n);
  return Number.isFinite(v) ? Math.trunc(v) : 0;
};

/** Numeric dollars (as PostgREST returns numeric: number or string) → cents. */
export function dollarsToCents(v: number | string | null | undefined): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

/** Cents → "12.34" for CSV (no currency symbol, so spreadsheets sum it). */
export function centsToDecimal(cents: number | null | undefined): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return '';
  const neg = cents < 0;
  const abs = Math.abs(Math.round(cents));
  return `${neg ? '-' : ''}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

export type CardFeeBasis = 'actual' | 'estimate' | 'none';

/** One order's card fee: Stripe's actual fee once recorded, else the estimate. */
export function orderCardFee(o: Pick<OrderMoneyRow, 'card_fee_actual_cents' | 'card_fee_est_cents'>): { cents: number; basis: CardFeeBasis } {
  if (o.card_fee_actual_cents !== null && o.card_fee_actual_cents !== undefined) {
    return { cents: int(o.card_fee_actual_cents), basis: 'actual' };
  }
  if (o.card_fee_est_cents !== null && o.card_fee_est_cents !== undefined) {
    return { cents: int(o.card_fee_est_cents), basis: 'estimate' };
  }
  return { cents: 0, basis: 'none' };
}

/**
 * The organizer's net on one order after refunds: the application fee comes
 * back in proportion to the refund, so the net shrinks in the same proportion.
 * null when the order has no fee record (checkouts before mig 20260929131000).
 */
export function orderNetAfterRefunds(o: Pick<OrderMoneyRow, 'gross_cents' | 'organizer_net_cents' | 'refunded_cents'>): number | null {
  if (o.organizer_net_cents === null || o.organizer_net_cents === undefined) return null;
  const net = int(o.organizer_net_cents);
  const gross = int(o.gross_cents);
  const refunded = Math.min(Math.max(int(o.refunded_cents), 0), Math.max(gross, 0));
  if (gross <= 0 || refunded === 0) return net;
  return net - Math.round((net * refunded) / gross);
}

const isPaid = (o: OrderMoneyRow) => (PAID_ORDER_STATUSES as readonly string[]).includes(o.status);
const isCancelledMarketplace = (m: MarketplaceMoneyRow) =>
  (CANCELLED_MARKETPLACE_STATES as readonly string[]).includes(m.state ?? '');

// ── The per-event settlement ─────────────────────────────────────────────

export interface Settlement {
  currency: string;
  /** More than one currency among the rows: the totals mix them. */
  mixedCurrencies: boolean;
  exos: {
    orders: number;
    /** null when no order carried a quantity. */
    tickets: number | null;
    grossCents: number;
    taxCents: number;
    refundedCents: number;
    exosFeeCents: number;
    cardFeeCents: number;
    cardFeeBasis: 'actual' | 'estimate' | 'mixed' | 'none';
    cardFeeActualOrders: number;
    cardFeeEstimateOrders: number;
    /** Orders without a fee record: not in the fee or net totals. */
    ordersWithoutFees: number;
    organizerNetCents: number;
    organizerNetAfterRefundsCents: number;
    feeFreeOrders: number;
  };
  marketplace: {
    orders: number;
    tickets: number;
    proceedsCents: number;
    exosFeeCents: number;
    organizerNetCents: number;
    cancelledOrders: number;
    /** No proceeds reported yet (state needs_price / null amounts). */
    unpricedOrders: number;
    paidCents: number;
  };
  commissions: {
    tickets: number;
    accruedCents: number;
    paidCents: number;
  };
  /** Exos net after refunds + marketplace net. */
  organizerNetCents: number;
  /** The same, less promoter commissions (accrued and paid). */
  organizerNetAfterCommissionsCents: number;
}

export function summarizeSettlement(input: {
  orders: OrderMoneyRow[];
  marketplace?: MarketplaceMoneyRow[];
  commissions?: CommissionMoneyRow[];
  /** The event's currency; the fallback when there are no rows. */
  currency?: string;
}): Settlement {
  const orders = (input.orders ?? []).filter(isPaid);
  const marketplace = input.marketplace ?? [];
  const commissions = input.commissions ?? [];

  const currencies = new Set<string>();
  const addCur = (c: string | null | undefined) => {
    if (c) currencies.add(c.toUpperCase());
  };

  let tickets: number | null = null;
  let gross = 0, tax = 0, refunded = 0, exosFee = 0, cardFee = 0, net = 0, netAfter = 0;
  let actual = 0, estimate = 0, withoutFees = 0, feeFree = 0;
  for (const o of orders) {
    addCur(o.currency);
    if (o.quantity !== null && o.quantity !== undefined) tickets = (tickets ?? 0) + int(o.quantity);
    gross += int(o.gross_cents);
    tax += int(o.tax_cents);
    refunded += int(o.refunded_cents);
    if (o.fee_free) feeFree++;
    const after = orderNetAfterRefunds(o);
    if (after === null) {
      withoutFees++;
      continue;
    }
    exosFee += int(o.exos_fee_cents);
    const card = orderCardFee(o);
    cardFee += card.cents;
    if (card.basis === 'actual') actual++;
    else if (card.basis === 'estimate') estimate++;
    net += int(o.organizer_net_cents);
    netAfter += after;
  }

  const mk = { orders: 0, tickets: 0, proceedsCents: 0, exosFeeCents: 0, organizerNetCents: 0, cancelledOrders: 0, unpricedOrders: 0, paidCents: 0 };
  for (const m of marketplace) {
    if (isCancelledMarketplace(m)) {
      mk.cancelledOrders++;
      continue;
    }
    addCur(m.currency);
    mk.orders++;
    mk.tickets += int(m.quantity);
    const proceeds = dollarsToCents(m.proceeds);
    const orgNet = dollarsToCents(m.organizer_net);
    if (proceeds === null || orgNet === null || m.state === 'needs_price') mk.unpricedOrders++;
    mk.proceedsCents += proceeds ?? 0;
    mk.exosFeeCents += dollarsToCents(m.exos_fee) ?? 0;
    mk.organizerNetCents += orgNet ?? 0;
    if (m.state === 'paid') mk.paidCents += orgNet ?? 0;
  }

  const cm = { tickets: 0, accruedCents: 0, paidCents: 0 };
  for (const c of commissions) {
    if (c.status === 'reversed') continue;
    addCur(c.currency);
    cm.tickets++;
    cm.accruedCents += int(c.commission_cents);
    if (c.status === 'paid') cm.paidCents += int(c.commission_cents);
  }

  const counted = actual + estimate;
  const cardFeeBasis = counted === 0 ? 'none' : actual === counted ? 'actual' : estimate === counted ? 'estimate' : 'mixed';
  const organizerNetCents = netAfter + mk.organizerNetCents;
  const fallback = (input.currency || [...currencies][0] || 'USD').toUpperCase();

  return {
    currency: fallback,
    mixedCurrencies: currencies.size > 1,
    exos: {
      orders: orders.length,
      tickets,
      grossCents: gross,
      taxCents: tax,
      refundedCents: refunded,
      exosFeeCents: exosFee,
      cardFeeCents: cardFee,
      cardFeeBasis,
      cardFeeActualOrders: actual,
      cardFeeEstimateOrders: estimate,
      ordersWithoutFees: withoutFees,
      organizerNetCents: net,
      organizerNetAfterRefundsCents: netAfter,
      feeFreeOrders: feeFree,
    },
    marketplace: mk,
    commissions: cm,
    organizerNetCents,
    organizerNetAfterCommissionsCents: organizerNetCents - cm.accruedCents,
  };
}

// ── CSV: one row per order (Exos checkouts, then marketplace orders) ─────

export const SETTLEMENT_CSV_HEADER = [
  'source', 'order_id', 'status', 'created_at', 'currency', 'tickets',
  'gross', 'tax', 'refunded', 'exos_fee', 'card_fee', 'card_fee_basis',
  'organizer_net', 'organizer_net_after_refunds', 'stripe_payment_intent', 'stripe_transfer',
];

export function settlementCsvRows(orders: OrderMoneyRow[], marketplace: MarketplaceMoneyRow[] = []): (string | number | null)[][] {
  const rows: (string | number | null)[][] = [];
  const paid = [...orders].filter(isPaid).sort((a, b) => (a.created_at ?? '').localeCompare(b.created_at ?? ''));
  for (const o of paid) {
    const card = orderCardFee(o);
    const hasFees = o.organizer_net_cents !== null && o.organizer_net_cents !== undefined;
    rows.push([
      'exos',
      o.session_id,
      o.status,
      o.created_at ?? '',
      (o.currency ?? '').toUpperCase(),
      o.quantity ?? '',
      centsToDecimal(int(o.gross_cents)),
      centsToDecimal(int(o.tax_cents)),
      centsToDecimal(int(o.refunded_cents)),
      hasFees ? centsToDecimal(int(o.exos_fee_cents)) : '',
      hasFees && card.basis !== 'none' ? centsToDecimal(card.cents) : '',
      hasFees ? card.basis : 'none',
      hasFees ? centsToDecimal(int(o.organizer_net_cents)) : '',
      centsToDecimal(orderNetAfterRefunds(o)),
      o.payment_intent ?? '',
      o.transfer_id ?? '',
    ]);
  }
  for (const m of marketplace) {
    rows.push([
      m.channel,
      m.external_order_id ?? m.order_id,
      m.state ?? '',
      '',
      (m.currency ?? '').toUpperCase(),
      m.quantity ?? '',
      centsToDecimal(dollarsToCents(m.proceeds)),
      '',
      '',
      centsToDecimal(dollarsToCents(m.exos_fee)),
      '',
      'none',
      centsToDecimal(dollarsToCents(m.organizer_net)),
      isCancelledMarketplace(m) ? '0.00' : centsToDecimal(dollarsToCents(m.organizer_net)),
      '',
      '',
    ]);
  }
  return rows;
}

// ── Org payouts ──────────────────────────────────────────────────────────

export interface PayoutLineRow {
  id: string;
  payout_id: string;
  order_id: string;
  kind: 'sale' | 'clawback' | string;
  amount: number | string;
  created_at?: string | null;
  /** From the joined exos_marketplace_orders, when readable. */
  channel?: string | null;
  external_order_id?: string | null;
  event_id?: string | null;
  event_name?: string | null;
}

export interface PayoutRow {
  id: string;
  currency: string;
  amount: number | string;
  status: string;
  stripe_transfer_id: string | null;
  error: string | null;
  created_at: string;
  updated_at?: string | null;
  sent_at: string | null;
}

export interface PayoutWithLines extends PayoutRow {
  amountCents: number;
  lines: (PayoutLineRow & { amountCents: number })[];
  sales: number;
  clawbacks: number;
}

/** Group lines under their payouts, newest payout first, cents computed. */
export function groupPayouts(payouts: PayoutRow[], lines: PayoutLineRow[]): PayoutWithLines[] {
  const byPayout = new Map<string, (PayoutLineRow & { amountCents: number })[]>();
  for (const l of lines) {
    const list = byPayout.get(l.payout_id) ?? [];
    list.push({ ...l, amountCents: dollarsToCents(l.amount) ?? 0 });
    byPayout.set(l.payout_id, list);
  }
  return [...payouts]
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''))
    .map((p) => {
      const ls = (byPayout.get(p.id) ?? []).sort((a, b) => (a.created_at ?? '').localeCompare(b.created_at ?? ''));
      return {
        ...p,
        amountCents: dollarsToCents(p.amount) ?? 0,
        lines: ls,
        sales: ls.filter((l) => l.kind === 'sale').length,
        clawbacks: ls.filter((l) => l.kind === 'clawback').length,
      };
    });
}

export interface PayoutTotals {
  currency: string;
  sentCents: number;
  pendingCents: number;
  failedCents: number;
  count: number;
}

/** Totals per currency: sent, on the way (planned / sending), failed. */
export function payoutTotals(payouts: PayoutWithLines[]): PayoutTotals[] {
  const m = new Map<string, PayoutTotals>();
  for (const p of payouts) {
    const cur = (p.currency || 'USD').toUpperCase();
    const t = m.get(cur) ?? { currency: cur, sentCents: 0, pendingCents: 0, failedCents: 0, count: 0 };
    t.count++;
    if (p.status === 'sent') t.sentCents += p.amountCents;
    else if (p.status === 'planned' || p.status === 'sending') t.pendingCents += p.amountCents;
    else if (p.status === 'failed') t.failedCents += p.amountCents;
    m.set(cur, t);
  }
  return [...m.values()];
}

export const PAYOUTS_CSV_HEADER = [
  'payout_id', 'payout_status', 'payout_created_at', 'payout_sent_at', 'currency', 'payout_amount',
  'stripe_transfer', 'line_kind', 'line_amount', 'channel', 'marketplace_order', 'event',
];

/** One row per payout line; a payout with no lines gets one row of its own. */
export function payoutsCsvRows(payouts: PayoutWithLines[]): (string | number | null)[][] {
  const rows: (string | number | null)[][] = [];
  for (const p of payouts) {
    const head = [
      p.id, p.status, p.created_at ?? '', p.sent_at ?? '', (p.currency || '').toUpperCase(),
      centsToDecimal(p.amountCents), p.stripe_transfer_id ?? '',
    ];
    if (p.lines.length === 0) {
      rows.push([...head, '', '', '', '', '']);
      continue;
    }
    for (const l of p.lines) {
      rows.push([
        ...head,
        l.kind,
        centsToDecimal(l.amountCents),
        l.channel ?? '',
        l.external_order_id ?? l.order_id,
        l.event_name ?? l.event_id ?? '',
      ]);
    }
  }
  return rows;
}

/** Org roles that see money (RLS enforces the same). */
export function canSeeMoney(role: string | null | undefined, isAdmin = false): boolean {
  return isAdmin || role === 'owner' || role === 'manager' || role === 'finance';
}
