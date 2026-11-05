import { describe, expect, it } from 'vitest';
import {
  buildSettlement, changeDue, drawerCashCents, paidOutProblem, quickCash, reconcileDrawer, reverseOption,
  walkupQuote, WALKUP_VOID_WINDOW_HOURS, type SettlementOrder,
} from './index';

// The same numbers as tests/exos/test_pos_walkup.sql (W2, W5, W7).
describe('walk-up price and tenders', () => {
  it('prices at the door price, tax per unit like checkout', () => {
    expect(walkupQuote({ unitCents: 2500, quantity: 2 })).toEqual(
      { unitTotalCents: 2500, totalCents: 5000, taxCents: 0, compCents: 0, cashDueCents: 5000 });
    // Early bird $15 + 10% exclusive: 16.50 each.
    expect(walkupQuote({ unitCents: 1500, quantity: 2, tax: { ratePercent: 10, priceIncludesTax: false } }))
      .toMatchObject({ unitTotalCents: 1650, totalCents: 3300, taxCents: 300 });
    // Inclusive: the price already has it.
    expect(walkupQuote({ unitCents: 2200, quantity: 3, tax: { ratePercent: 10, priceIncludesTax: true } }))
      .toMatchObject({ unitTotalCents: 2200, totalCents: 6600, taxCents: 600 });
  });

  it('comps cover whole tickets; cash is the rest', () => {
    expect(walkupQuote({ unitCents: 2500, quantity: 2, compQuantity: 1 })).toMatchObject({ compCents: 2500, cashDueCents: 2500 });
    expect(walkupQuote({ unitCents: 2500, quantity: 1, compQuantity: 1 })).toMatchObject({ compCents: 2500, cashDueCents: 0 });
    expect(walkupQuote({ unitCents: 2500, quantity: 1, compQuantity: 5 }).cashDueCents).toBe(0);
    expect(walkupQuote({ unitCents: 0, quantity: 2 })).toMatchObject({ totalCents: 0, cashDueCents: 0 });
  });

  it('change and quick-cash buttons', () => {
    expect(changeDue(2750, 4000)).toEqual({ changeCents: 1250, shortCents: 0 });
    expect(changeDue(2750, 2000)).toEqual({ changeCents: 0, shortCents: 750 });
    expect(quickCash(2750)).toEqual([2750, 3000, 4000, 5000]);
    expect(quickCash(2000)).toEqual([2000, 5000, 10000]);
    expect(quickCash(0)).toEqual([]);
  });
});

describe('void, refund, override', () => {
  const now = Date.parse('2026-11-07T23:00:00Z');
  const sale = { status: 'paid' as const, createdAt: '2026-11-07T21:00:00Z', scanned: 0, rungByMe: true, role: 'scanner' as const, now };
  it('the seller voids the same night before a scan', () => {
    expect(reverseOption(sale)).toEqual({ kind: 'void' });
    expect(reverseOption({ ...sale, rungByMe: false })).toEqual({ kind: 'none', reason: 'not-yours' });
    expect(reverseOption({ ...sale, rungByMe: false, role: 'manager' })).toEqual({ kind: 'void' });
  });
  it('after a scan or the window: a manager refund (override after a scan)', () => {
    expect(reverseOption({ ...sale, scanned: 1 })).toEqual({ kind: 'none', reason: 'needs-manager' });
    expect(reverseOption({ ...sale, scanned: 1, role: 'owner' })).toEqual({ kind: 'refund', override: true });
    const late = { ...sale, createdAt: now - (WALKUP_VOID_WINDOW_HOURS + 1) * 3_600_000 };
    expect(reverseOption(late)).toEqual({ kind: 'none', reason: 'needs-manager' });
    expect(reverseOption({ ...late, role: 'manager' })).toEqual({ kind: 'refund', override: false });
  });
  it('pending sales are cancelled; done sales are done', () => {
    expect(reverseOption({ ...sale, status: 'pending' })).toEqual({ kind: 'cancel' });
    expect(reverseOption({ ...sale, status: 'void' })).toEqual({ kind: 'none', reason: 'done' });
  });
});

describe('drawer with paid-outs', () => {
  it('voided cash went out as a paid-out; the drawer still balances', () => {
    // $100 float, two cash sales of 50.00 and 25.00, the 50.00 voided, a 10.00 paid-out.
    const cash = drawerCashCents({ openFloatCents: 10000, cashInCents: 7500, paidOutCents: 5000 + 1000 });
    expect(cash).toBe(11500);
    expect(reconcileDrawer({ openFloatCents: 10000, cashPayments: [{ amountCents: 5000 }, { amountCents: 2500 }],
      paidOutCents: 6000, countedCents: 11500 })).toMatchObject({ expectedCents: 11500, status: 'balanced' });
    expect(paidOutProblem(1000, cash, 'ice for the bar')).toBeNull();
    expect(paidOutProblem(20000, cash, 'too much')).toBe('too-much');
    expect(paidOutProblem(100, cash, 'x')).toBe('reason');
    expect(paidOutProblem(10.5, cash, 'half cent')).toBe('amount');
  });
});

describe('the walk-up fee setting', () => {
  // Cash walk-ups at the door: default no Exos fee; 'all-tickets' charges them.
  const DOOR: SettlementOrder[] = [
    { id: 'w1', status: 'paid', totalCents: 5000, lines: [{ category: 'ticket', quantity: 2, totalCents: 5000, taxCents: 0 }],
      payments: [{ method: 'cash', amountCents: 5000 }] },
    { id: 'w2', status: 'paid', totalCents: 5000, lines: [{ category: 'ticket', quantity: 2, totalCents: 5000, taxCents: 0 }],
      payments: [{ method: 'cash', amountCents: 2500 }, { method: 'comp', amountCents: 2500 }] },
    { id: 'w3', status: 'void', totalCents: 2500, lines: [{ category: 'ticket', quantity: 1, totalCents: 2500, taxCents: 0 }],
      payments: [] },
  ];
  it('defaults to card tickets only (what the scaffold settlement does)', () => {
    const s = buildSettlement(DOOR, [], { feeBps: 300 });
    expect(s).toMatchObject({ feeBase: 'card-tickets', cashTicketCents: 7500, cardTicketCents: 0, exosFeeCents: 0, organizerNetCents: 7500 });
  });
  it('all-tickets charges cash ticket sales too', () => {
    const s = buildSettlement(DOOR, [], { feeBps: 300, feeBase: 'all-tickets' });
    expect(s).toMatchObject({ feeBaseCents: 7500, exosFeeCents: 225, organizerNetCents: 7275 });
  });
});
