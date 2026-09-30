import { describe, expect, it } from 'vitest';
import { toCsv } from './csv';
import {
  canSeeMoney,
  centsToDecimal,
  dollarsToCents,
  groupPayouts,
  orderCardFee,
  orderNetAfterRefunds,
  payoutsCsvRows,
  payoutTotals,
  PAYOUTS_CSV_HEADER,
  SETTLEMENT_CSV_HEADER,
  settlementCsvRows,
  summarizeSettlement,
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
  it('orderCardFee prefers the actual fee, else the estimate', () => {
    expect(orderCardFee({ card_fee_actual_cents: 150, card_fee_est_cents: 146 })).toEqual({ cents: 150, basis: 'actual' });
    expect(orderCardFee({ card_fee_actual_cents: null, card_fee_est_cents: 146 })).toEqual({ cents: 146, basis: 'estimate' });
    expect(orderCardFee({ card_fee_actual_cents: null, card_fee_est_cents: null })).toEqual({ cents: 0, basis: 'none' });
  });
  it('orderNetAfterRefunds shrinks the net in proportion to the refund', () => {
    expect(orderNetAfterRefunds(order())).toBe(3734);
    expect(orderNetAfterRefunds(order({ refunded_cents: 2000 }))).toBe(1867);
    expect(orderNetAfterRefunds(order({ refunded_cents: 4000 }))).toBe(0);
    // Never more than the gross back.
    expect(orderNetAfterRefunds(order({ refunded_cents: 9999 }))).toBe(0);
    expect(orderNetAfterRefunds(order({ organizer_net_cents: null }))).toBeNull();
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
    expect(s.exos.cardFeeBasis).toBe('none');
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
    expect(s.exos.cardFeeBasis).toBe('estimate');
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

  it('card fees: actual when recorded, else the estimate, and says which', () => {
    const mixed = summarizeSettlement({
      orders: [order({ card_fee_actual_cents: 150 }), order({ session_id: 'cs_2' })],
    });
    expect(mixed.exos.cardFeeCents).toBe(296);
    expect(mixed.exos.cardFeeBasis).toBe('mixed');
    expect(mixed.exos.cardFeeActualOrders).toBe(1);
    expect(mixed.exos.cardFeeEstimateOrders).toBe(1);
    const actual = summarizeSettlement({ orders: [order({ card_fee_actual_cents: 150 })] });
    expect(actual.exos.cardFeeBasis).toBe('actual');
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
    expect(a.slice(6, 14)).toEqual(['40.00', '0.00', '10.00', '1.20', '1.46', 'estimate', '37.34', '28.00']);
    expect(b.slice(10, 12)).toEqual(['1.50', 'actual']);
    expect(b[15]).toBe('tr_1');
    expect(old.slice(9, 14)).toEqual(['', '', 'none', '', '']);
    expect(m1[0]).toBe('evo');
    expect(m1.slice(6, 14)).toEqual(['31.51', '', '', '0.95', '', 'none', '30.56', '30.56']);
    expect(m2[13]).toBe('0.00');
  });
  it('zero orders: no rows, and the CSV is just the header', () => {
    expect(settlementCsvRows([])).toEqual([]);
    expect(toCsv(SETTLEMENT_CSV_HEADER, [])).toBe(SETTLEMENT_CSV_HEADER.join(','));
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
