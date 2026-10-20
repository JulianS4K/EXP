import { describe, expect, it } from 'vitest';
import { FIGURES, historyDays, isSoldTicket, salesByDay, ticketFigures } from './eventFigures';

const at = (iso: string) => ({ toDate: () => new Date(iso) });
const now = new Date(2026, 9, 20, 15, 0, 0); // local time, Oct 20 2026

// One event: 3 paid, 1 free comp, 1 used, 1 voided (refunded in full), 1 transferred.
const tickets = [
  { status: 'active', pricePaid: 20, purchaseDate: at(new Date(2026, 9, 18, 10).toISOString()) },
  { status: 'active', pricePaid: 20, purchaseDate: at(new Date(2026, 9, 18, 23).toISOString()) },
  { status: 'used', pricePaid: 20, purchaseDate: at(new Date(2026, 9, 19, 9).toISOString()) },
  { status: 'active', pricePaid: 0, purchaseDate: at(new Date(2026, 9, 20, 8).toISOString()) },
  { status: 'voided', pricePaid: 20, purchaseDate: at(new Date(2026, 9, 20, 9).toISOString()) },
  { status: 'transferred', pricePaid: 20, purchaseDate: at(new Date(2026, 6, 1, 9).toISOString()) },
];

describe('event figures', () => {
  it('"Tickets sold" is every ticket but voided ones (the analytics rule)', () => {
    expect(tickets.filter(isSoldTicket)).toHaveLength(5);
    expect(ticketFigures(tickets)).toEqual({ sold: 5, sales: 80, checkedIn: 1 });
  });

  it('the chart leaves voided tickets out, so its total is the header figure', () => {
    const days = historyDays(tickets, now);
    const b = salesByDay(tickets, days, now);
    expect(b[b.length - 1].cumulative).toBe(ticketFigures(tickets).sold);
    expect(b[b.length - 1].daily).toBe(1); // the free one today; the voided one isn't counted
  });

  it('the 30-day window counts only what falls in it', () => {
    const b = salesByDay(tickets, 30, now);
    expect(b).toHaveLength(30);
    expect(b[b.length - 1].cumulative).toBe(4); // July's transfer is outside
    expect(b[b.length - 3].daily).toBe(2);
  });

  it('full history reaches back to the first sale, 30 to 365 days', () => {
    expect(historyDays(tickets, now)).toBe(112); // Jul 1 .. Oct 20
    expect(historyDays([], now)).toBe(30);
    expect(historyDays([{ status: 'active', purchaseDate: at(new Date(2026, 9, 19).toISOString()) }], now)).toBe(30);
    expect(historyDays([{ status: 'active', purchaseDate: at('2020-01-01T00:00:00Z') }], now)).toBe(365);
  });

  it('every figure has a distinct label and a hint', () => {
    const labels = Object.values(FIGURES).map((f) => f.label);
    expect(new Set(labels).size).toBe(labels.length);
    for (const f of Object.values(FIGURES)) expect(f.hint.length).toBeGreaterThan(20);
    // "net" is only used for figures after fees
    expect(FIGURES.salesAfterRefunds.label.toLowerCase()).not.toContain('net');
  });
});
