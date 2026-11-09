// Organizer mistake simulations, pure logic (tests/exos/sim_organizer.sql has
// the SQL side). The refund panel parses what staff type into cents before
// exos-refund sends it; the server bounds the amount by what's left, so a
// misread amount is a real (if bounded) over-refund.
import { describe, expect, it } from 'vitest';
import { parseAmountToCents, planOrderAmount, planTicketRefund, ticketShares } from '../refunds';
import { bracketErrors, tieredAmount } from '../dealMath';
import { majorCents, parseGiftCardFile } from '../givingTables';

describe('SIM-ORG-T1 refund amounts typed wrong', () => {
  it('refuses a decimal comma instead of reading it as a thousands separator (FIXED)', () => {
    // "1,00" used to parse as $100.00 and "12,5" as $125.00.
    for (const s of ['1,00', '12,5', '12,50', '1,0000', ',100', '1,,000', '1,000,00']) expect(parseAmountToCents(s)).toBeNull();
  });
  it('still reads real thousands separators', () => {
    expect(parseAmountToCents('1,000')).toBe(100000);
    expect(parseAmountToCents('$12,345.67')).toBe(1234567);
    expect(parseAmountToCents('1,000,000')).toBe(100000000);
  });
  it('refuses negative, sub-cent and scientific amounts', () => {
    for (const s of ['-10', '10.001', '1e2', '$-5', '10.', ' . ']) expect(parseAmountToCents(s)).toBeNull();
  });
});

describe('SIM-ORG-T2 refunding more than is left', () => {
  const preview = {
    refundableCents: 5000,
    tickets: [
      { ticketId: 't1', shareCents: 3000, refundedCents: 1000 },
      { ticketId: 't2', shareCents: 3000, refundedCents: 0 },
    ],
  } as unknown as Parameters<typeof planTicketRefund>[0];
  it('an order amount over the remainder is refused', () => {
    expect(planOrderAmount(5000, 5001).ok).toBe(false);
    expect(planOrderAmount(5000, 5000).ok).toBe(true);
  });
  it('a ticket amount over what is left on it is refused; the same ticket twice is refused', () => {
    expect(planTicketRefund(preview, [{ ticketId: 't1', amountCents: 2001 }]).ok).toBe(false);
    expect(planTicketRefund(preview, [{ ticketId: 't1' }, { ticketId: 't1' }]).ok).toBe(false);
    const ok = planTicketRefund(preview, [{ ticketId: 't1' }]);
    expect(ok.ok && ok.totalCents).toBe(2000);
  });
  it('the per-ticket total is still capped by the order', () => {
    expect(planTicketRefund(preview, [{ ticketId: 't1' }, { ticketId: 't2' }]).ok).toBe(true);
    const tight = { ...preview, refundableCents: 4999 } as typeof preview;
    expect(planTicketRefund(tight, [{ ticketId: 't1' }, { ticketId: 't2' }]).ok).toBe(false);
  });
  it('shares never sum past the pool', () => {
    for (const [pool, n] of [[10001, 3], [1, 2], [0, 4], [99999, 7]]) {
      expect(ticketShares(pool, n).reduce((a, b) => a + b, 0)).toBe(pool);
    }
  });
});

describe('SIM-ORG-T3 deal brackets typed out of order', () => {
  it('the order the organizer typed them in does not change the payout', () => {
    const typed = { basis: 'amount' as const, tiers: [{ threshold: 5000000, percentage: 95 }, { threshold: 2000000, percentage: 90 }] };
    const sorted = { basis: 'amount' as const, tiers: [{ threshold: 2000000, percentage: 90 }, { threshold: 5000000, percentage: 95 }] };
    expect(tieredAmount(6000000, 0, 80, typed).amount).toBe(tieredAmount(6000000, 0, 80, sorted).amount);
    expect(tieredAmount(6000000, 0, 80, typed).amount).toBe(80 * 20000 + 90 * 30000 + 95 * 10000);
  });
  it('an overlapping bracket (same threshold twice) is refused', () => {
    expect(bracketErrors([{ basis: 'amount', threshold: 2000000, percentage: 90 }, { basis: 'amount', threshold: 2000000, percentage: 85 }]).length)
      .toBeGreaterThan(0);
  });
});

describe('SIM-ORG-T4 gift-card balances from a European export', () => {
  it('a decimal comma is refused, not read as 100x the balance (FIXED)', () => {
    // "25,00" used to become 250000 cents ($2,500) on the imported card.
    expect(majorCents('25,00')).toBeNull();
    expect(majorCents('€ 12,5')).toBeNull();
    expect(majorCents('1,250.50')).toBe(125050);
    expect(majorCents('1,250')).toBe(125000);
    const p = parseGiftCardFile('code,balance\nGIFTAAA111,"25,00"\nGIFTBBB222,25.00\n');
    expect(p.cards.map((c) => c.balance_cents)).toEqual([2500]);
    expect(p.errors.length).toBe(1);
  });
});
