import { describe, expect, it } from 'vitest';
import { toCsv } from './csv';
import {
  canSeeMoney,
  centsToDecimal,
  dollarsToCents,
  groupPayouts,
  orderCardFee,
  orderNetAfterRefunds,
  orderStripeFee,
  payoutsCsvRows,
  payoutTotals,
  PAYOUTS_CSV_HEADER,
  SETTLEMENT_CSV_HEADER,
  disputeChargeCents,
  feeTerms,
  settlementCsvRows,
  summarizeSettlement,
  type DisputeMoneyRow,
  type MarketplaceMoneyRow,
  type OrderMoneyRow,
} from './settlement';

// A 40.00 order at 3% + card fee (docs/payments-go-live.md): 1.20 + 1.46 = 2.66.
const order = (o: Partial<OrderMoneyRow> = {}): OrderMoneyRow => ({
  session_id: 'cs_1',
  status: 'fulfilled',
  currency: 'usd',
  created_at: '2026-09-20T12:00:00Z',
  gross_cents: 4000,
  tax_cents: 0,
  application_fee_cents: 266,
  exos_fee_cents: 120,
  card_fee_est_cents: 146,
  card_fee_actual_cents: null,
  fee_free: false,
  organizer_net_cents: 3734,
  refunded_cents: 0,
  payment_intent: 'pi_1',
  transfer_id: null,
  quantity: 2,
  ...o,
});

// A $40 chargeback with Stripe's $15 fee.
const dispute = (d: Partial<DisputeMoneyRow> = {}): DisputeMoneyRow => ({
  session_id: 'cs_1',
  status: 'needs_response',
  amount_cents: 4000,
  fee_cents: 1500,
  recovery_status: 'none',
  recovery_candidate_cents: null,
  created_at: '2026-09-24T00:00:00Z',
  ...d,
});

const mkt = (m: Partial<MarketplaceMoneyRow> = {}): MarketplaceMoneyRow => ({
  order_id: 'mo_1',
  channel: 'evo',
  external_order_id: '19196777',
  quantity: 2,
  currency: 'USD',
  proceeds: '31.51',
  exos_fee: '0.95',
  organizer_net: '30.56',
  state: 'payable',
  ...m,
});

describe('helpers', () => {
  it('dollarsToCents takes numbers and numeric strings, rounds to the cent', () => {
    expect(dollarsToCents('31.51')).toBe(3151);
    expect(dollarsToCents(0.1 + 0.2)).toBe(30);
    expect(dollarsToCents(null)).toBeNull();
    expect(dollarsToCents('')).toBeNull();
    expect(dollarsToCents('abc')).toBeNull();
  });
  it('centsToDecimal formats for spreadsheets', () => {
    expect(centsToDecimal(3734)).toBe('37.34');
    expect(centsToDecimal(5)).toBe('0.05');
    expect(centsToDecimal(-1250)).toBe('-12.50');
    expect(centsToDecimal(null)).toBe('');
  });
  it('orderCardFee is what the organizer was charged: application fee - Exos fee', () => {
    expect(orderCardFee({ application_fee_cents: 266, exos_fee_cents: 120, card_fee_est_cents: 146 })).toEqual({ cents: 146, basis: 'charged' });
    // Capped order: the split covers the card fee first.
    expect(orderCardFee({ application_fee_cents: 50, exos_fee_cents: 0, card_fee_est_cents: 50 })).toEqual({ cents: 50, basis: 'charged' });
    expect(orderCardFee({ application_fee_cents: null, exos_fee_cents: null, card_fee_est_cents: 146 })).toEqual({ cents: 146, basis: 'charged' });
    expect(orderCardFee({ application_fee_cents: null, exos_fee_cents: null, card_fee_est_cents: null })).toEqual({ cents: 0, basis: 'none' });
  });
  it('orderStripeFee (platform side): the actual fee, only in the order currency', () => {
    expect(orderStripeFee({ card_fee_actual_cents: 150, currency: 'usd' })).toBe(150);
    expect(orderStripeFee({ card_fee_actual_cents: 150, currency: 'usd', stripe_fee_currency: 'usd' })).toBe(150);
    expect(orderStripeFee({ card_fee_actual_cents: 95, currency: 'eur', stripe_fee_currency: 'usd' })).toBeNull();
    expect(orderStripeFee({ card_fee_actual_cents: null, currency: 'usd' })).toBeNull();
  });
  it('orderNetAfterRefunds shrinks the net in proportion to the refund', () => {
    expect(orderNetAfterRefunds(order())).toBe(3734);
    expect(orderNetAfterRefunds(order({ refunded_cents: 2000 }))).toBe(1867);
    expect(orderNetAfterRefunds(order({ refunded_cents: 4000 }))).toBe(0);
    // Never more than the gross back.
    expect(orderNetAfterRefunds(order({ refunded_cents: 9999 }))).toBe(0);
    expect(orderNetAfterRefunds(order({ organizer_net_cents: null }))).toBeNull();
  });
  it('orderNetAfterRefunds: a refund that kept the application fee comes out in full', () => {
    // EXOS_REFUND_KEEP_PLATFORM_FEE: 20.00 refunded, fee kept -> 37.34 - 20.00.
    expect(orderNetAfterRefunds(order({ refunded_cents: 2000, refunded_fee_kept_cents: 2000 }))).toBe(1734);
    // One 10.00 refund with the fee returned, one 10.00 that kept it.
    expect(orderNetAfterRefunds(order({ refunded_cents: 2000, refunded_fee_kept_cents: 1000 }))).toBe(3734 - 934 - 1000);
    // The whole order refunded keeping the fee: the organizer is out the fee.
    expect(orderNetAfterRefunds(order({ refunded_cents: 4000, refunded_fee_kept_cents: 4000 }))).toBe(-266);
  });
  it('canSeeMoney: owner / manager / finance / admin', () => {
    expect(['owner', 'manager', 'finance'].every((r) => canSeeMoney(r))).toBe(true);
    expect(canSeeMoney('scanner')).toBe(false);
    expect(canSeeMoney('content')).toBe(false);
    expect(canSeeMoney(null, true)).toBe(true);
  });
});

describe('summarizeSettlement', () => {
  it('zero orders: all zeros, the event currency, nothing mixed', () => {
    const s = summarizeSettlement({ orders: [], currency: 'eur' });
    expect(s.currency).toBe('EUR');
    expect(s.exos.orders).toBe(0);
    expect(s.exos.tickets).toBeNull();
    expect(s.exos.grossCents).toBe(0);
    expect(s.exos.stripeFeeActualOrders).toBe(0);
    expect(s.marketplace.orders).toBe(0);
    expect(s.organizerNetCents).toBe(0);
    expect(s.organizerNetAfterCommissionsCents).toBe(0);
    expect(s.mixedCurrencies).toBe(false);
  });

  it('adds up paid orders and skips pending / expired / failed', () => {
    const s = summarizeSettlement({
      orders: [
        order(),
        order({ session_id: 'cs_2', gross_cents: 2000, tax_cents: 160, application_fee_cents: 148, exos_fee_cents: 60, card_fee_est_cents: 88, organizer_net_cents: 1852, quantity: 1 }),
        order({ session_id: 'cs_3', status: 'pending' }),
        order({ session_id: 'cs_4', status: 'expired' }),
        order({ session_id: 'cs_5', status: 'failed' }),
      ],
    });
    expect(s.exos.orders).toBe(2);
    expect(s.exos.tickets).toBe(3);
    expect(s.exos.grossCents).toBe(6000);
    expect(s.exos.taxCents).toBe(160);
    expect(s.exos.exosFeeCents).toBe(180);
    expect(s.exos.cardFeeCents).toBe(234);
    expect(s.exos.organizerNetCents).toBe(5586);
    expect(s.exos.organizerNetAfterRefundsCents).toBe(5586);
    expect(s.currency).toBe('USD');
  });

  it('refunds: partial and full, net after refunds in proportion', () => {
    const s = summarizeSettlement({
      orders: [
        order({ status: 'partially_refunded', refunded_cents: 2000 }),
        order({ session_id: 'cs_2', status: 'refunded', refunded_cents: 4000 }),
      ],
    });
    expect(s.exos.orders).toBe(2);
    expect(s.exos.grossCents).toBe(8000);
    expect(s.exos.refundedCents).toBe(6000);
    expect(s.exos.organizerNetCents).toBe(7468);
    expect(s.exos.organizerNetAfterRefundsCents).toBe(1867);
  });

  it('card fees: what the organizer was charged, so gross - Exos fee - card fee = net', () => {
    const s = summarizeSettlement({
      orders: [order({ card_fee_actual_cents: 150 }), order({ session_id: 'cs_2' })],
    });
    expect(s.exos.cardFeeCents).toBe(292);
    expect(s.exos.grossCents - s.exos.exosFeeCents - s.exos.cardFeeCents).toBe(s.exos.organizerNetCents);
    // Stripe's actual fee is kept apart (platform side).
    expect(s.exos.stripeFeeActualCents).toBe(150);
    expect(s.exos.stripeFeeActualOrders).toBe(1);
  });

  it('an EUR order on a USD platform: the money adds up, the USD fee stays out of it', () => {
    // The simulation's S1 order (scratchpad sim/ledger s10): 49.98 EUR, Stripe's fee 0.95 USD.
    const s = summarizeSettlement({
      currency: 'EUR',
      orders: [order({
        currency: 'eur', gross_cents: 4998, application_fee_cents: 325, exos_fee_cents: 150, card_fee_est_cents: 175,
        card_fee_actual_cents: 95, stripe_fee_currency: 'usd', organizer_net_cents: 4998 - 325,
      })],
    });
    expect(s.exos.cardFeeCents).toBe(175);
    expect(s.exos.grossCents - s.exos.exosFeeCents - s.exos.cardFeeCents - s.exos.organizerNetCents).toBe(0);
    expect(s.exos.stripeFeeActualOrders).toBe(0);
  });

  it('orders without a fee record count in gross but not in fees or net', () => {
    const s = summarizeSettlement({
      orders: [
        order(),
        order({ session_id: 'old', application_fee_cents: null, exos_fee_cents: null, card_fee_est_cents: null, organizer_net_cents: null }),
      ],
    });
    expect(s.exos.orders).toBe(2);
    expect(s.exos.grossCents).toBe(8000);
    expect(s.exos.ordersWithoutFees).toBe(1);
    expect(s.exos.exosFeeCents).toBe(120);
    expect(s.exos.organizerNetCents).toBe(3734);
  });

  it('fee-free orders are counted', () => {
    const s = summarizeSettlement({ orders: [order({ fee_free: true, exos_fee_cents: 0, application_fee_cents: 146, organizer_net_cents: 3854 })] });
    expect(s.exos.feeFreeOrders).toBe(1);
    expect(s.exos.exosFeeCents).toBe(0);
  });

  it('marketplace rows: dollars to cents, cancelled ones left out, unpriced flagged', () => {
    const s = summarizeSettlement({
      orders: [order()],
      marketplace: [
        mkt(),
        mkt({ order_id: 'mo_2', state: 'paid', proceeds: 50, exos_fee: 1.5, organizer_net: 48.5, quantity: 1 }),
        mkt({ order_id: 'mo_3', state: 'cancelled' }),
        mkt({ order_id: 'mo_4', state: 'clawed_back' }),
        mkt({ order_id: 'mo_5', state: 'needs_price', proceeds: null, exos_fee: null, organizer_net: null, quantity: 4 }),
      ],
    });
    expect(s.marketplace.orders).toBe(3);
    expect(s.marketplace.tickets).toBe(7);
    expect(s.marketplace.cancelledOrders).toBe(2);
    expect(s.marketplace.unpricedOrders).toBe(1);
    expect(s.marketplace.proceedsCents).toBe(8151);
    expect(s.marketplace.exosFeeCents).toBe(245);
    expect(s.marketplace.organizerNetCents).toBe(7906);
    expect(s.marketplace.paidCents).toBe(4850);
    expect(s.organizerNetCents).toBe(3734 + 7906);
  });

  it('promoter commissions: accrued and paid count, reversed ones don\'t', () => {
    const s = summarizeSettlement({
      orders: [order()],
      commissions: [
        { status: 'accrued', commission_cents: 400, currency: 'usd' },
        { status: 'paid', commission_cents: 300, currency: 'usd' },
        { status: 'reversed', commission_cents: 999, currency: 'usd' },
      ],
    });
    expect(s.commissions).toEqual({ tickets: 2, accruedCents: 700, paidCents: 300 });
    expect(s.organizerNetAfterCommissionsCents).toBe(3734 - 700);
  });

  it('flags mixed currencies', () => {
    const s = summarizeSettlement({ orders: [order(), order({ session_id: 'cs_2', currency: 'eur' })] });
    expect(s.mixedCurrencies).toBe(true);
  });
});

describe('settlementCsvRows', () => {
  it('one row per paid order, oldest first, then marketplace orders', () => {
    const rows = settlementCsvRows(
      [
        order({ session_id: 'b', created_at: '2026-09-21T00:00:00Z', card_fee_actual_cents: 150, transfer_id: 'tr_1' }),
        order({ session_id: 'a', created_at: '2026-09-20T00:00:00Z', status: 'partially_refunded', refunded_cents: 1000 }),
        order({ session_id: 'p', status: 'pending' }),
        order({ session_id: 'old', created_at: '2026-09-22T00:00:00Z', organizer_net_cents: null, application_fee_cents: null, exos_fee_cents: null, card_fee_est_cents: null }),
      ],
      [mkt(), mkt({ order_id: 'mo_2', external_order_id: null, state: 'cancelled' })],
    );
    expect(rows.map((r) => r[1])).toEqual(['a', 'b', 'old', '19196777', 'mo_2']);
    for (const r of rows) expect(r).toHaveLength(SETTLEMENT_CSV_HEADER.length);
    const [a, b, old, m1, m2] = rows;
    expect(a.slice(6, 14)).toEqual(['40.00', '0.00', '10.00', '1.20', '1.46', 'charged', '37.34', '28.00']);
    // The organizer's CSV has the card fee charged, not Stripe's actual.
    expect(b.slice(10, 12)).toEqual(['1.46', 'charged']);
    expect(b[15]).toBe('tr_1');
    expect(old.slice(9, 14)).toEqual(['', '', 'none', '', '']);
    expect(m1[0]).toBe('evo');
    expect(m1.slice(6, 14)).toEqual(['31.51', '', '', '0.95', '', 'none', '30.56', '30.56']);
    expect(m2[13]).toBe('0.00');
  });
  it('adds the invoice number of each checkout (none for marketplace orders)', () => {
    const rows = settlementCsvRows(
      [order({ session_id: 'a' }), order({ session_id: 'free', created_at: '2026-09-23T00:00:00Z' })],
      [mkt()],
      new Map([['a', 'INV-000007']]),
    );
    const col = SETTLEMENT_CSV_HEADER.indexOf('invoice_number');
    expect(col).toBe(16);
    expect(rows.map((r) => r[col])).toEqual(['INV-000007', '', '']);
  });
  it('adds dispute columns per order: latest status, summed amounts, what it costs you', () => {
    const rows = settlementCsvRows(
      [order({ session_id: 'a' }), order({ session_id: 'b', created_at: '2026-09-21T00:00:00Z' }), order({ session_id: 'c', created_at: '2026-09-22T00:00:00Z' })],
      [mkt()],
      new Map(),
      [
        dispute({ session_id: 'a', status: 'lost', recovery_status: 'recovery_pending', recovery_candidate_cents: 5500, created_at: '2026-09-25T00:00:00Z' }),
        dispute({ session_id: 'a', status: 'warning_closed', amount_cents: 0, fee_cents: 0, created_at: '2026-09-24T00:00:00Z' }),
        dispute({ session_id: 'b', status: 'lost', recovery_status: 'not_recovered' }),
      ],
    );
    expect(SETTLEMENT_CSV_HEADER.slice(-4)).toEqual(['dispute_status', 'dispute_amount', 'dispute_fee', 'dispute_charged_to_you']);
    for (const r of rows) expect(r).toHaveLength(SETTLEMENT_CSV_HEADER.length);
    expect(rows[0].slice(-4)).toEqual(['lost', '40.00', '15.00', '55.00']);
    expect(rows[1].slice(-4)).toEqual(['lost', '40.00', '15.00', '0.00']);
    expect(rows[2].slice(-4)).toEqual(['', '', '', '']);
    expect(rows[3].slice(-4)).toEqual(['', '', '', '']);
  });
  it('zero orders: no rows, and the CSV is just the header', () => {
    expect(settlementCsvRows([])).toEqual([]);
    expect(toCsv(SETTLEMENT_CSV_HEADER, [])).toBe(SETTLEMENT_CSV_HEADER.join(','));
  });
});

describe('lost disputes in the organizer net', () => {
  it('a lost dispute Exos recovers comes off the net (amount + fee); an absorbed one does not', () => {
    const base = summarizeSettlement({ orders: [order(), order({ session_id: 'cs_2' })] });
    const s = summarizeSettlement({
      orders: [order(), order({ session_id: 'cs_2' })],
      disputes: [
        dispute({ status: 'lost', recovery_status: 'recovery_pending', recovery_candidate_cents: 5500 }),
        dispute({ session_id: 'cs_2', status: 'lost', recovery_status: 'not_recovered' }),
        dispute({ session_id: 'cs_2', status: 'needs_response' }),
        dispute({ session_id: 'cs_2', status: 'won' }),
      ],
    });
    expect(s.disputes).toEqual({ open: 1, lost: 2, chargedCents: 5500, absorbed: 1 });
    expect(s.organizerNetCents).toBe(base.organizerNetCents - 5500);
    expect(s.organizerNetAfterCommissionsCents).toBe(base.organizerNetAfterCommissionsCents - 5500);
    // the Exos-checkout tiles are unchanged
    expect(s.exos.organizerNetAfterRefundsCents).toBe(base.exos.organizerNetAfterRefundsCents);
  });
  it('without a recovery figure, uses amount + fee; recovered counts too', () => {
    expect(disputeChargeCents(dispute({ status: 'lost', recovery_status: 'recovered' }))).toBe(5500);
    expect(disputeChargeCents(dispute({ status: 'lost', recovery_status: 'none' }))).toBe(5500);
    expect(disputeChargeCents(dispute({ status: 'needs_response' }))).toBe(0);
  });
});

describe('feeTerms', () => {
  const now = new Date('2026-10-20T12:00:00Z');
  it('inside the free period: the end date, then the rate', () => {
    const t = feeTerms('2027-03-28T00:00:00Z', now);
    expect(t.inFreePeriod).toBe(true);
    expect(t.rate).toBe('3%');
    expect(t.text).toContain('No Exos fee until Mar 28, 2027, then 3% of each order');
    expect(t.text).toContain('2.9% + 30¢');
  });
  it('after it, or unreadable: the rate', () => {
    expect(feeTerms('2026-09-01T00:00:00Z', now).text).toMatch(/^Exos fee: 3% of each order \(your fee-free period ended Sep 1, 2026\)/);
    const u = feeTerms(undefined, now);
    expect(u.inFreePeriod).toBe(false);
    expect(u.text).toMatch(/^Exos fee: 3% of each order.*first 6 months/);
  });
});

describe('payouts', () => {
  const payouts = [
    { id: 'p1', currency: 'USD', amount: '30.56', status: 'sent', stripe_transfer_id: 'tr_9', error: null, created_at: '2026-09-10T00:00:00Z', sent_at: '2026-09-10T01:00:00Z' },
    { id: 'p2', currency: 'USD', amount: 18.2, status: 'planned', stripe_transfer_id: null, error: null, created_at: '2026-09-20T00:00:00Z', sent_at: null },
    { id: 'p3', currency: 'USD', amount: '5.00', status: 'failed', stripe_transfer_id: null, error: 'no account', created_at: '2026-09-15T00:00:00Z', sent_at: null },
  ];
  const lines = [
    { id: 'l1', payout_id: 'p1', order_id: 'o1', kind: 'sale', amount: '30.56', channel: 'evo', external_order_id: '191', event_name: 'Fall Party' },
    { id: 'l2', payout_id: 'p2', order_id: 'o2', kind: 'sale', amount: '48.50', created_at: '2026-09-20T00:00:00Z' },
    { id: 'l3', payout_id: 'p2', order_id: 'o1', kind: 'clawback', amount: '-30.30', created_at: '2026-09-20T00:00:01Z' },
  ];

  it('groups lines under payouts, newest payout first', () => {
    const g = groupPayouts(payouts, lines);
    expect(g.map((p) => p.id)).toEqual(['p2', 'p3', 'p1']);
    expect(g[0].amountCents).toBe(1820);
    expect(g[0].sales).toBe(1);
    expect(g[0].clawbacks).toBe(1);
    expect(g[0].lines.map((l) => l.amountCents)).toEqual([4850, -3030]);
    expect(g[1].lines).toEqual([]);
  });

  it('totals per currency by status', () => {
    expect(payoutTotals(groupPayouts(payouts, lines))).toEqual([
      { currency: 'USD', sentCents: 3056, pendingCents: 1820, failedCents: 500, count: 3 },
    ]);
    expect(payoutTotals([])).toEqual([]);
  });

  it('CSV: a row per line, a lone row for a payout without lines', () => {
    const rows = payoutsCsvRows(groupPayouts(payouts, lines));
    expect(rows).toHaveLength(4);
    for (const r of rows) expect(r).toHaveLength(PAYOUTS_CSV_HEADER.length);
    expect(rows[0].slice(0, 2)).toEqual(['p2', 'planned']);
    expect(rows[1].slice(7, 9)).toEqual(['clawback', '-30.30']);
    expect(rows[2].slice(0, 9)).toEqual(['p3', 'failed', '2026-09-15T00:00:00Z', '', 'USD', '5.00', '', '', '']);
    expect(rows[3].slice(6)).toEqual(['tr_9', 'sale', '30.56', 'evo', '191', 'Fall Party']);
  });
});
