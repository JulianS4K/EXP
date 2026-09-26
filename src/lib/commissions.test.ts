import { describe, it, expect } from 'vitest';
import {
  bpsToPercent, commissionCents, effectiveTerms, formatDateOnly, moneyToCents, payoutNetCents, percentToBps,
  summarize, termsLabel, ticketBaseCents, type CommissionRow,
} from './commissions';

describe('commissionCents (mirrors exos_pc_commission_cents)', () => {
  it('percent of the base, floored to the cent', () => {
    expect(commissionCents(2000, 1000, 0)).toBe(200);
    expect(commissionCents(999, 1000, 0)).toBe(99);
    expect(commissionCents(1999, 1250, 0)).toBe(249);
  });
  it('flat per ticket, capped at the base', () => {
    expect(commissionCents(1500, 0, 150)).toBe(150);
    expect(commissionCents(100, 0, 150)).toBe(100);
  });
  it('percent plus flat', () => {
    expect(commissionCents(3000, 2000, 50)).toBe(650);
    expect(commissionCents(1000, 1250, 25)).toBe(150);
  });
  it('comps and free tickets earn nothing', () => {
    expect(commissionCents(0, 1000, 150)).toBe(0);
    expect(commissionCents(-5, 1000, 150)).toBe(0);
  });
});

describe('effectiveTerms', () => {
  it('the event override wins, both parts', () => {
    expect(effectiveTerms({ rateBps: 1000, flatCents: 0 }, { rateBps: 2000, flatCents: 50 }))
      .toEqual({ rateBps: 2000, flatCents: 50, source: 'event' });
    expect(effectiveTerms({ rateBps: 1000, flatCents: 0 }, { rateBps: 0, flatCents: 0 }).rateBps).toBe(0);
    expect(effectiveTerms({ rateBps: 1000, flatCents: 0 }, null).source).toBe('promoter');
  });
});

describe('ticketBaseCents (mirrors exos_pc_accrue_ticket)', () => {
  it('takes out tax and add-ons, per ticket', () => {
    expect(ticketBaseCents({ amountCents: 4400, taxCents: 400, quantity: 2, pricePaidCents: 2200 })).toBe(2000);
    expect(ticketBaseCents({ amountCents: 2500, addonNetCents: 500, quantity: 1, pricePaidCents: 2000 })).toBe(2000);
  });
  it('floors an uneven split', () => {
    expect(ticketBaseCents({ amountCents: 1000, quantity: 3, pricePaidCents: 333 })).toBe(333);
  });
  it('never negative, never above the paid price', () => {
    expect(ticketBaseCents({ amountCents: 0, taxCents: 10, quantity: 1, pricePaidCents: 0 })).toBe(0);
    expect(ticketBaseCents({ amountCents: 5000, quantity: 1, pricePaidCents: 4000 })).toBe(4000);
    expect(ticketBaseCents({ amountCents: 5000, quantity: 0, pricePaidCents: 4000 })).toBe(0);
  });
});

describe('input parsing', () => {
  it('percent → bps', () => {
    expect(percentToBps('10')).toBe(1000);
    expect(percentToBps('12.5%')).toBe(1250);
    expect(percentToBps('0.05')).toBe(5);
    expect(percentToBps('')).toBe(0);
    expect(percentToBps('101')).toBeNull();
    expect(percentToBps('abc')).toBeNull();
    expect(percentToBps('1.234')).toBeNull();
  });
  it('bps → percent', () => {
    expect(bpsToPercent(1000)).toBe('10');
    expect(bpsToPercent(1250)).toBe('12.5');
    expect(bpsToPercent(5)).toBe('0.05');
  });
  it('money → cents', () => {
    expect(moneyToCents('1.50')).toBe(150);
    expect(moneyToCents('$1.5')).toBe(150);
    expect(moneyToCents('2')).toBe(200);
    expect(moneyToCents('')).toBe(0);
    expect(moneyToCents('1000.01')).toBeNull();
    expect(moneyToCents('-1')).toBeNull();
  });
  it('labels', () => {
    expect(termsLabel({ rateBps: 1000, flatCents: 50 })).toBe('10% + $0.50 / ticket');
    expect(termsLabel({ rateBps: 0, flatCents: 0 })).toBe('none');
  });
});

const row = (over: Partial<CommissionRow>): CommissionRow => ({
  id: Math.random().toString(36), currency: 'usd', commissionCents: 200, status: 'accrued',
  payoutId: null, recoveredPayoutId: null, ...over,
});

describe('summarize + payoutNetCents (same buckets as the SQL views)', () => {
  it('owed is accrued less clawbacks', () => {
    const rows = [
      row({ status: 'accrued' }),
      row({ status: 'paid', payoutId: 'p1' }),
      row({ status: 'reversed' }),
      row({ status: 'reversed', payoutId: 'p1' }),
      row({ status: 'reversed', payoutId: 'p1', recoveredPayoutId: 'p2' }),
    ];
    expect(summarize(rows)).toEqual({ accrued: 200, reversed: 600, paid: 200, clawback: 200, owed: 0 });
  });
  it('payout amount = selected − clawback; refuses bad selections', () => {
    const a = row({}); const b = row({});
    expect(payoutNetCents([a, b], 0)).toBe(400);
    expect(payoutNetCents([a, b], 200)).toBe(200);
    expect(payoutNetCents([a], 300)).toBeNull();
    expect(payoutNetCents([], 0)).toBeNull();
    expect(payoutNetCents([a, row({ status: 'reversed' })], 0)).toBeNull();
    expect(payoutNetCents([a, row({ status: 'paid', payoutId: 'p' })], 0)).toBeNull();
    expect(payoutNetCents([a, row({ currency: 'eur' })], 0)).toBeNull();
  });
});

describe('formatDateOnly', () => {
  it('formats a date column without shifting the day', () => {
    expect(formatDateOnly('2026-09-20')).toBe('Sep 20, 2026');
    expect(formatDateOnly('2026-01-05')).toBe('Jan 5, 2026');
    expect(formatDateOnly('nope')).toBe('nope');
  });
});
