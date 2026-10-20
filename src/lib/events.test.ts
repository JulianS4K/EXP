import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { eventGrossSales, faceValueByCurrency } from './events';

const tiers = (...pairs: Array<[number, number]>) => pairs.map(([price, sold]) => ({ price, sold })) as any;

describe('faceValueByCurrency (organizer dashboard)', () => {
  it('keeps one total per currency instead of adding EUR into USD', () => {
    // Regression: a €300 event and a $200 event used to show as one "$500".
    const out = faceValueByCurrency([
      { currency: 'EUR', ticketTiers: tiers([30, 10]) },
      { currency: 'usd', ticketTiers: tiers([20, 5], [50, 2]) },
      { ticketTiers: tiers([10, 1]) },
    ]);
    expect(out).toEqual([
      { currency: 'EUR', amount: 300 },
      { currency: 'USD', amount: 210 },
    ]);
  });
  it('is empty with no events, and face value is price x sold', () => {
    expect(faceValueByCurrency([])).toEqual([]);
    expect(eventGrossSales({ ticketTiers: tiers([12.5, 4]) })).toBe(50);
  });
});
