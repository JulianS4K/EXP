import { describe, expect, it } from 'vitest';
import {
  newRefundNonce,
  parseAmount,
  parseAmountToCents,
  planOrderAmount,
  planTicketRefund,
  ticketPoolCents,
  ticketBadge,
  ticketShares,
} from './refunds';

describe('ticketBadge (event report)', () => {
  it('reads "voided", not "refunded", until a refund for the ticket succeeded', () => {
    expect(ticketBadge({ status: 'voided' }, false)).toBe('voided');
    expect(ticketBadge({ status: 'voided' }, true)).toBe('refunded');
    expect(ticketBadge({ status: 'voided', releasedAt: new Date() }, true)).toBe('released');
    expect(ticketBadge({ status: 'used' }, false)).toBe('used');
    expect(ticketBadge({ status: 'active' }, false)).toBe('active');
  });
});

describe('ticketPoolCents / ticketShares (mirror exos_refund_ticket_state)', () => {
  it('takes the add-on lines out of the order total', () => {
    expect(ticketPoolCents(10001, [{ quantity: 1, unit_price_cents: 1000 }])).toBe(9001);
    expect(ticketPoolCents(5000, null)).toBe(5000);
    expect(ticketPoolCents(500, [{ quantity: 2, unit_price_cents: 1000 }])).toBe(0);
  });
  it('splits evenly in cents with leftovers on the first tickets', () => {
    expect(ticketShares(9001, 3)).toEqual([3001, 3000, 3000]);
    expect(ticketShares(10, 4)).toEqual([3, 3, 2, 2]);
    expect(ticketShares(0, 2)).toEqual([0, 0]);
    expect(ticketShares(100, 0)).toEqual([]);
  });
  it('shares always add back up to the pool', () => {
    for (const [pool, n] of [[9999, 7], [1, 3], [123457, 10]]) {
      expect(ticketShares(pool, n).reduce((a, b) => a + b, 0)).toBe(pool);
    }
  });
});

describe('parseAmountToCents', () => {
  it('reads plain dollar amounts', () => {
    expect(parseAmountToCents('12.34')).toBe(1234);
    expect(parseAmountToCents('$12')).toBe(1200);
    expect(parseAmountToCents('12.3')).toBe(1230);
    expect(parseAmountToCents('1,000.01')).toBe(100001);
    expect(parseAmountToCents('0.01')).toBe(1);
  });
  it('rejects junk, zero and sub-cent amounts', () => {
    for (const s of ['', 'abc', '0', '0.00', '-5', '1.234', '1e3', '.5']) expect(parseAmountToCents(s)).toBeNull();
  });
  it('reads a decimal comma as a decimal, never as a thousands separator', () => {
    // Regression: "12,50" used to become 1250.00 (commas were deleted).
    expect(parseAmountToCents('12,50')).toBe(1250);
    expect(parseAmountToCents('12.50')).toBe(1250);
    expect(parseAmountToCents('12,5')).toBe(1250);
    expect(parseAmountToCents('€12,50', 'EUR')).toBe(1250);
    expect(parseAmountToCents('12,50 EUR', 'eur')).toBe(1250);
    expect(parseAmountToCents('12,50 €')).toBe(1250);
  });
  it('reads either thousands style when both marks are present', () => {
    expect(parseAmountToCents('1,234.56')).toBe(123456);
    expect(parseAmountToCents('1.234,56')).toBe(123456);
    expect(parseAmountToCents('1 234,56')).toBe(123456);
    expect(parseAmountToCents("1'234.56")).toBe(123456);
    expect(parseAmountToCents('1,234,567')).toBe(123456700);
    expect(parseAmountToCents('1.234.567,8')).toBe(123456780);
  });
  it('refuses ambiguous or malformed grouping instead of guessing', () => {
    const amb = parseAmount('1,234');
    expect(amb.ok).toBe(false);
    expect('error' in amb && amb.error).toMatch(/ambiguous/);
    for (const s of ['1,234', '1.234', '1,23,4', '12,345.6.7', '1.234.56', '1,2345', '12 50', '1,234,56', '1.2,34', '12,50 USD']) {
      expect(parseAmountToCents(s, 'EUR')).toBeNull();
    }
  });
});

const preview = {
  refundableCents: 9001,
  tickets: [
    { ticketId: 't1', status: 'active', shareCents: 3001, refundedCents: 1000, refundableCents: 2001, tierName: null, attendeeName: null },
    { ticketId: 't2', status: 'active', shareCents: 3000, refundedCents: 0, refundableCents: 3000, tierName: null, attendeeName: null },
    { ticketId: 't3', status: 'voided', shareCents: 3000, refundedCents: 3000, refundableCents: 0, tierName: null, attendeeName: null },
  ],
};

describe('planTicketRefund', () => {
  it('full = what is left on each ticket, and those get voided', () => {
    const r = planTicketRefund(preview, [{ ticketId: 't1' }, { ticketId: 't2' }]);
    expect(r).toEqual({ ok: true, totalCents: 5001, voids: ['t1', 't2'], items: [{ ticketId: 't1' }, { ticketId: 't2' }] });
  });
  it('partial keeps the ticket valid; exactly the rest voids it', () => {
    const p = planTicketRefund(preview, [{ ticketId: 't2', amountCents: 500 }]);
    expect(p.ok && p.voids).toEqual([]);
    const f = planTicketRefund(preview, [{ ticketId: 't1', amountCents: 2001 }]);
    expect(f.ok && f.voids).toEqual(['t1']);
  });
  it("can't exceed a ticket, the order, or pick bad tickets", () => {
    expect(planTicketRefund(preview, [{ ticketId: 't1', amountCents: 2002 }]).ok).toBe(false);
    expect(planTicketRefund(preview, [{ ticketId: 't3' }]).ok).toBe(false);
    expect(planTicketRefund(preview, [{ ticketId: 'nope' }]).ok).toBe(false);
    expect(planTicketRefund(preview, [{ ticketId: 't2' }, { ticketId: 't2' }]).ok).toBe(false);
    expect(planTicketRefund(preview, [{ ticketId: 't2', amountCents: 0 }]).ok).toBe(false);
    expect(planTicketRefund(preview, []).ok).toBe(false);
    expect(planTicketRefund({ ...preview, refundableCents: 4000 }, [{ ticketId: 't1' }, { ticketId: 't2' }]).ok).toBe(false);
  });
});

describe('planOrderAmount', () => {
  it('allows up to what is left', () => {
    expect(planOrderAmount(9001, 9001)).toMatchObject({ ok: true, totalCents: 9001 });
    expect(planOrderAmount(9001, 9002).ok).toBe(false);
    expect(planOrderAmount(9001, null).ok).toBe(false);
    expect(planOrderAmount(0, 1).ok).toBe(false);
  });
  it('quotes limits in the order currency', () => {
    expect(planOrderAmount(500, 600, 'EUR')).toMatchObject({ ok: false, error: expect.stringContaining('€5.00') });
    expect(planTicketRefund({ ...preview, currency: 'EUR' }, [{ ticketId: 't1', amountCents: 2002 }])).toMatchObject({
      ok: false,
      error: expect.stringContaining('€20.01'),
    });
  });
});

describe('newRefundNonce', () => {
  it('matches the server nonce format and is unique', () => {
    const a = newRefundNonce();
    expect(a).toMatch(/^[A-Za-z0-9:_.-]{8,200}$/);
    expect(newRefundNonce()).not.toBe(a);
  });
});
