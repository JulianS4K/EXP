// Tiered deal brackets (supabase/functions/_shared/finance/dealBrackets.ts).
// The FIXTURES are also checked against the SQL twin, _exos_bracket_amount,
// in tests/exos/test_finance_extras.sql: keep the two lists in step.

import { describe, expect, it } from 'vitest';
import {
  bracketErrors, bracketsFromJson, describeBrackets, sortBrackets, tieredAmount, tieredReachAt, type Brackets,
} from './dealMath';
import { computeDeals, type DealTerms } from './dealMath';
import { settle, showPnl, type SettlementInputs } from './dealMath';

const amount = (...tiers: [number, number][]): Brackets => ({ basis: 'amount', tiers: tiers.map(([threshold, percentage]) => ({ threshold, percentage })) });
const tickets = (...tiers: [number, number][]): Brackets => ({ basis: 'tickets', tiers: tiers.map(([threshold, percentage]) => ({ threshold, percentage })) });

// [name, base, sold, default %, brackets, expected]
export const FIXTURES: [string, number, number, number, Brackets, number][] = [
  ['85% to $20k, 90% above', 3_000_000, 0, 85, amount([2_000_000, 90]), 2_600_000],
  ['exactly at the threshold', 2_000_000, 0, 85, amount([2_000_000, 90]), 1_700_000],
  ['one cent past the threshold', 2_000_001, 0, 85, amount([2_000_000, 90]), 1_700_001],
  ['a single tier from 0', 12_345, 0, 85, amount([0, 80]), 9_876],
  ['unsorted input', 6_000_000, 0, 85, amount([5_000_000, 95], [0, 80], [2_000_000, 90]), 5_250_000],
  ['threshold above the base', 100, 0, 85, amount([10_000_000, 90]), 85],
  ['half a cent rounds up', 3, 0, 50, amount([1_000_000, 60]), 2],
  ['ticket basis', 1_000_001, 1_500, 85, tickets([1_000, 90]), 866_667],
  ['ticket basis, nothing sold', 50_000, 0, 85, tickets([1_000, 90]), 42_500],
  ['ticket basis, below the first threshold', 1_000_000, 999, 85, tickets([1_000, 90]), 850_000],
  ['ticket basis, exactly at the threshold', 1_000_000, 1_000, 85, tickets([1_000, 90]), 850_000],
  ['zero base', 0, 10, 85, amount([0, 90]), 0],
];

describe('tieredAmount', () => {
  for (const [name, base, sold, def, b, want] of FIXTURES) {
    it(name, () => expect(tieredAmount(base, sold, def, b).amount).toBe(want));
  }

  it('reports each tier with its units', () => {
    const r = tieredAmount(3_000_000, 0, 85, amount([2_000_000, 90]));
    expect(r.tiers).toEqual([
      { from: 0, to: 2_000_000, percentage: 85, units: 2_000_000, amount: 1_700_000 },
      { from: 2_000_000, to: null, percentage: 90, units: 1_000_000, amount: 900_000 },
    ]);
  });

  it('a single bracket at 0 equals the plain percentage', () => {
    for (const x of [1, 99, 12_345, 987_654_321]) {
      expect(tieredAmount(x, 0, 10, amount([0, 72.5])).amount).toBe(Math.floor(x * 0.725 + 0.5 + 1e-9));
    }
  });

  it('never decreases as the base grows', () => {
    const b = amount([100, 50], [200, 0], [300, 100]);
    let prev = -1;
    for (let x = 0; x <= 400; x++) {
      const a = tieredAmount(x, 0, 20, b).amount;
      expect(a).toBeGreaterThanOrEqual(prev);
      prev = a;
    }
  });

  it('takes negative and fractional bases as 0 / rounded', () => {
    expect(tieredAmount(-500, 0, 85, amount([0, 90])).amount).toBe(0);
    expect(tieredAmount(100.4, 0, 50, amount([0, 50])).amount).toBe(50);
  });
});

describe('tieredReachAt', () => {
  it('finds the smallest base reaching a guarantee', () => {
    const b = amount([2_000_000, 90]);
    const at = tieredReachAt(1_800_000, 0, 85, b)!;
    expect(tieredAmount(at, 0, 85, b).amount).toBeGreaterThanOrEqual(1_800_000);
    expect(tieredAmount(at - 1, 0, 85, b).amount).toBeLessThan(1_800_000);
    expect(at).toBe(2_111_111);
  });
  it('is 0 for nothing and null when the rate is 0 everywhere', () => {
    expect(tieredReachAt(0, 0, 85, amount([0, 90]))).toBe(0);
    expect(tieredReachAt(100, 0, 0, amount([0, 0]))).toBeNull();
  });
});

describe('bracketErrors', () => {
  it('accepts a good set in any order', () => {
    expect(bracketErrors([{ basis: 'amount', threshold: 5, percentage: 90 }, { basis: 'amount', threshold: 0, percentage: 85.125 }])).toEqual([]);
  });
  it('refuses overlaps (a repeated threshold), mixed bases, bad numbers and too many', () => {
    expect(bracketErrors([{ basis: 'amount', threshold: 5, percentage: 90 }, { basis: 'amount', threshold: 5, percentage: 95 }])[0]).toMatch(/strictly increasing/);
    expect(bracketErrors([{ basis: 'amount', threshold: 1, percentage: 90 }, { basis: 'tickets', threshold: 5, percentage: 95 }])).toContain('every bracket of an offer has the same basis');
    expect(bracketErrors([{ basis: 'amount', threshold: -1, percentage: 90 }])[0]).toMatch(/threshold/);
    expect(bracketErrors([{ basis: 'amount', threshold: 1.5, percentage: 90 }])[0]).toMatch(/threshold/);
    expect(bracketErrors([{ basis: 'amount', threshold: 1, percentage: 101 }])[0]).toMatch(/percentage/);
    expect(bracketErrors([{ basis: 'amount', threshold: 1, percentage: 1.2345 }])[0]).toMatch(/percentage/);
    expect(bracketErrors([{ basis: 'gross', threshold: 1, percentage: 1 }])[0]).toMatch(/basis/);
    expect(bracketErrors(Array.from({ length: 21 }, (_, i) => ({ basis: 'amount', threshold: i, percentage: 1 })))).toContain('at most 20 brackets per offer');
  });
});

describe('helpers', () => {
  it('sorts by threshold', () => {
    expect(sortBrackets([{ threshold: 9 }, { threshold: 1 }, { threshold: 5 }]).map((b) => b.threshold)).toEqual([1, 5, 9]);
  });
  it('describes tiers', () => {
    const money = (c: number) => `$${c / 100}`;
    expect(describeBrackets(85, amount([2_000_000, 90]), money)).toBe('85% to $20000, 90% above $20000');
    expect(describeBrackets(85, tickets([0, 80], [500, 90]), money)).toBe('80% to 500 tickets, 90% above 500 tickets');
  });
  it('reads the database shape', () => {
    expect(bracketsFromJson({ basis: 'tickets', tiers: [{ threshold: '10', percentage: '90.5' }] })).toEqual(tickets([10, 90.5]));
    expect(bracketsFromJson({ basis: 'tickets', tiers: [] })).toBeNull();
    expect(bracketsFromJson(null)).toBeNull();
  });
});

const terms = (t: Partial<DealTerms>): DealTerms => ({
  dealType: 'versus', guarantee: 0, percentage: 85, expensesCap: null, promoterProfitPercent: 0, bonuses: [],
  merchArtistPercent: null, deposit: 0, depositPaid: false, ...t,
});

describe('deal math with brackets', () => {
  const base = { paidSold: 0, dealExpenses: 1_000_000, merchIncome: 0 };
  it('versus: the tiered percentage of net after expenses, against the guarantee', () => {
    const [r] = computeDeals({ ...base, netBoxOffice: 4_000_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ guarantee: 500_000, brackets: amount([2_000_000, 90]) }) }] });
    expect(r.percentageAmount).toBe(1_700_000 + 900_000);
    expect(r.payout).toBe(2_600_000);
    expect(r.splitPoint).toBe(1_000_000 + tieredReachAt(500_000, 0, 85, amount([2_000_000, 90]))!);
  });
  it('door and plus use the tiers too; flat ignores them', () => {
    const door = computeDeals({ ...base, netBoxOffice: 3_000_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ dealType: 'door', brackets: amount([2_000_000, 90]) }) }] })[0];
    expect(door.payout).toBe(2_600_000);
    const plus = computeDeals({ ...base, dealExpenses: 0, netBoxOffice: 3_100_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ dealType: 'plus', guarantee: 100_000, brackets: amount([0, 50], [1_000_000, 100]) }) }] })[0];
    // split point = 100,000; overage 3,000,000: 50% of 1,000,000 + 100% of 2,000,000.
    expect(plus.percentageAmount).toBe(2_500_000);
    const flat = computeDeals({ ...base, netBoxOffice: 3_000_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ dealType: 'flat', guarantee: 100, brackets: amount([0, 90]) }) }] })[0];
    expect(flat.payout).toBe(100);
  });
  it('ticket brackets read paid tickets sold', () => {
    const [r] = computeDeals({ ...base, dealExpenses: 0, paidSold: 1_500, netBoxOffice: 1_000_001, slots: [{ slotId: 'a', name: 'A', terms: terms({ dealType: 'door', brackets: tickets([1_000, 90]) }) }] });
    expect(r.payout).toBe(866_667);
  });
  it('no brackets: the deal is unchanged', () => {
    const a = computeDeals({ ...base, netBoxOffice: 4_000_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ guarantee: 500_000 }) }] })[0];
    const b = computeDeals({ ...base, netBoxOffice: 4_000_000, slots: [{ slotId: 'a', name: 'A', terms: terms({ guarantee: 500_000, brackets: { basis: 'amount', tiers: [] } }) }] })[0];
    expect(b).toEqual(a);
    expect(a.payout).toBe(2_550_000);
  });
});

const inputs = (extra: Partial<SettlementInputs>): SettlementInputs => ({
  version: 1, computed_at: '2026-11-02T00:00:00Z',
  event: { id: 'e', name: 'Show', status: 'published', starts_at: null, timezone: null, currency: 'USD', capacity: 100, venue: null, venue_name: null, hold_id: null },
  box_office: { tiers: [], paid_sold: 100, comps: 0, sold_last_24h: 0, first_sale_at: null, gross_cents: 4_000_000, tax_cents: 0, passed_on_fees_cents: 0, absorbed_fees_cents: 0, platform_fees_cents: 0 },
  sold_elsewhere: { available: false, lines: [] }, items: [],
  offers: [{ id: 'o1', budget_id: 'b', artist_name: 'A', status: 'accepted', currency: 'USD', terms: { deal_type: 'door', percentage: 85 }, pool_share_percent: null }],
  pools: [], budget: null, rental: null, promoter_mode: false,
  settlement: { adjustments: [], deposits_paid: {}, venue_share_percent: 0, venue_deposit_paid_cents: 0 },
  ...extra,
});

describe('settlement inputs with brackets and imported entries', () => {
  it('settles an offer with brackets from deal_brackets', () => {
    expect(settle(inputs({})).result.artistsTotal).toBe(3_400_000);
    const v = settle(inputs({ deal_brackets: { o1: { basis: 'amount', tiers: [{ threshold: 2_000_000, percentage: 90 }] } } }));
    expect(v.result.artistsTotal).toBe(1_700_000 + 1_800_000);
  });
  it('imported entries count in the settlement and are flagged in the P&L', () => {
    const inp = inputs({
      imported_entries: [
        { id: 'i1', source: 'bar', description: 'Bar night', amount_cents: 50_000, tax_amount_cents: 4_000, gl_code: '4100', posted_at: '2026-11-01T00:00:00Z', source_system: 'square' },
        { id: 'i2', source: 'bar', description: 'Bar comp', amount_cents: -5_000, tax_amount_cents: 0, gl_code: '4100', posted_at: '2026-11-01T00:00:00Z', source_system: 'square' },
        { id: 'i3', source: 'merchandise', description: 'Tees', amount_cents: 10_000, tax_amount_cents: 0, gl_code: null, posted_at: '2026-11-01T00:00:00Z', source_system: 'shopify' },
      ],
    });
    const v = settle(inp);
    expect(v.result.otherIncome).toBe(50_000);
    expect(v.result.merchIncome).toBe(10_000);
    expect(v.result.expensesTotal).toBe(5_000);
    const p = showPnl(inp, Date.parse('2026-11-02T00:00:00Z'));
    const rows = p.rows.filter((r) => r.imported);
    expect(rows.map((r) => [r.key, r.label, r.actual, r.forecast || 0])).toEqual([
      ['income:imported:bar', 'Imported · Bar / F&B', 50_000, 0],
      ['income:imported:merchandise', 'Imported · Merchandise', 10_000, 0],
      ['expense:imported:bar', 'Imported · Bar / F&B', -5_000, 0],
    ]);
    expect(p.rows.find((r) => r.key === 'gross')?.imported).toBeUndefined();
  });
});
