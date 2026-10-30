// Deal math, settlements, P&L and the PDF writer (docs/offers-settlements.md).
// The deal, settlement, budget and pace cases are the Firebase build's sims
// (Exos-Bridge sims/settlement.ts), ported case by case; pools, the box
// office from database inputs, the P&L columns and the documents are new.

import { describe, expect, it } from 'vitest';
import {
  boxOffice, computeDeals, computeDealsWithPools, computeSettlement, describeDeal, orgPnl, orgPnlCsv, paceEstimate,
  projectBudget, roundHalfUp, settle, showPnl, offerPdf, settlementPdf,
  type DealTerms, type SettlementInput, type SettlementInputs, type SlotInput,
} from './dealMath';
import { createPdf, wrap } from '../../supabase/functions/_shared/finance/pdf.ts';

const terms = (over: Partial<DealTerms>): DealTerms => ({
  dealType: 'flat', guarantee: 0, percentage: 0, expensesCap: null, promoterProfitPercent: 0, bonuses: [],
  merchArtistPercent: null, deposit: 0, depositPaid: false, ...over,
});
const slot = (over: Partial<DealTerms>, extra: Partial<SlotInput> = {}): SlotInput => ({ slotId: 's1', name: 'Headliner', terms: terms(over), ...extra });

interface DealCase {
  name: string;
  nbor: number;
  sold?: number;
  expenses?: number;
  merch?: number;
  slots: SlotInput[];
  expect: Record<string, unknown[]>;
}

const dealCases: DealCase[] = [
  { name: 'flat pays the guarantee whatever sells', nbor: 1_000, slots: [slot({ guarantee: 100_000 })],
    expect: { base: [100_000], payout: [100_000], splitPoint: [null] } },
  { name: 'versus: percentage of net after expenses beats the guarantee', nbor: 500_000, expenses: 200_000,
    slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85 })],
    // 85 % of 300,000 = 255,000; split point = 200,000 + ceil(100,000 / 0.85) = 317,648
    expect: { base: [255_000], splitPoint: [317_648], expensesApplied: [200_000] } },
  { name: 'versus: guarantee when the percentage is lower', nbor: 250_000, expenses: 200_000,
    slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85 })],
    expect: { base: [100_000], payout: [100_000] } },
  { name: 'versus: net below expenses pays the guarantee, never negative', nbor: 50_000, expenses: 200_000,
    slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85 })],
    expect: { base: [100_000] } },
  { name: 'plus: guarantee + percentage above the split point (with promoter profit)', nbor: 500_000, expenses: 200_000,
    slots: [slot({ dealType: 'plus', guarantee: 100_000, percentage: 85, promoterProfitPercent: 15 })],
    // profit 15 % of 300,000 = 45,000; split 345,000; 85 % of 155,000 = 131,750
    expect: { base: [231_750], splitPoint: [345_000] } },
  { name: 'plus: below the split point pays the guarantee only', nbor: 300_000, expenses: 200_000,
    slots: [slot({ dealType: 'plus', guarantee: 100_000, percentage: 85 })],
    expect: { base: [100_000], splitPoint: [300_000] } },
  { name: 'door: percentage of net box office, no expenses', nbor: 300_000, expenses: 200_000,
    slots: [slot({ dealType: 'door', percentage: 70 })],
    expect: { base: [210_000], splitPoint: [0] } },
  { name: 'door: the guarantee is a floor', nbor: 300_000, slots: [slot({ dealType: 'door', percentage: 70, guarantee: 250_000 })],
    expect: { base: [250_000], splitPoint: [357_143] } },
  { name: 'bonuses are cumulative: one threshold reached', nbor: 0, sold: 420,
    slots: [slot({ guarantee: 100_000, bonuses: [{ sold: 400, amount: 50_000 }, { sold: 450, amount: 50_000 }] })],
    expect: { bonus: [50_000], payout: [150_000] } },
  { name: 'bonuses are cumulative: both thresholds reached', nbor: 0, sold: 450,
    slots: [slot({ guarantee: 100_000, bonuses: [{ sold: 400, amount: 50_000 }, { sold: 450, amount: 50_000 }] })],
    expect: { bonus: [100_000], payout: [200_000] } },
  { name: 'expenses cap limits the expense base', nbor: 500_000, expenses: 200_000,
    slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85, expensesCap: 150_000 })],
    // 85 % of 350,000 = 297,500
    expect: { base: [297_500], expensesApplied: [150_000], capped: [true] } },
  { name: 'cap above the expenses changes nothing', nbor: 500_000, expenses: 200_000,
    slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85, expensesCap: 900_000 })],
    expect: { base: [255_000], capped: [false] } },
  { name: "support guarantees are the headliner's expenses", nbor: 500_000, expenses: 200_000,
    slots: [
      slot({ dealType: 'versus', guarantee: 100_000, percentage: 85 }),
      slot({ guarantee: 20_000 }, { slotId: 's2', name: 'Support' }),
    ],
    // headliner: 85 % of (500,000 − 220,000) = 238,000; support flat
    expect: { base: [238_000, 20_000], supportCosts: [20_000, 100_000] } },
  { name: 'merch share, adjustment and paid deposit', nbor: 0, merch: 80_000,
    slots: [slot({ guarantee: 100_000, merchArtistPercent: 80, deposit: 50_000, depositPaid: true }, { adjustments: -5_000 })],
    // 100,000 + 64,000 − 5,000 = 159,000; balance 109,000
    expect: { merch: [64_000], payout: [159_000], balanceDue: [109_000] } },
  { name: 'an unpaid deposit is not deducted', nbor: 0, slots: [slot({ guarantee: 100_000, deposit: 50_000, depositPaid: false })],
    expect: { balanceDue: [100_000] } },
  { name: 'half-up rounding once per line', nbor: 1_001, slots: [slot({ dealType: 'door', percentage: 50 })],
    expect: { base: [501] } },
  { name: 'a big adjustment never takes a payout below zero', nbor: 0, slots: [slot({ guarantee: 10_000 }, { adjustments: -50_000 })],
    expect: { payout: [0], balanceDue: [0] } },
];

describe('deal math (sims)', () => {
  for (const c of dealCases) {
    it(c.name, () => {
      const res = computeDeals({ netBoxOffice: c.nbor, paidSold: c.sold ?? 0, dealExpenses: c.expenses ?? 0, merchIncome: c.merch ?? 0, slots: c.slots });
      for (const [k, v] of Object.entries(c.expect)) {
        expect(res.map((r) => (r as unknown as Record<string, unknown>)[k]), k).toEqual(v);
      }
    });
  }

  it('rounds half up, symmetric for negatives', () => {
    expect([roundHalfUp(0.5), roundHalfUp(1.4999), roundHalfUp(-2.5), roundHalfUp(Number.NaN)]).toEqual([1, 1, -3, 0]);
  });

  it('the documented worked example: $1,000 vs 85 %, $5,000 net, $2,000 expenses', () => {
    const [r] = computeDeals({ netBoxOffice: 500_000, paidSold: 0, dealExpenses: 200_000, merchIncome: 0,
      slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85 })] });
    expect(r.base).toBe(255_000);
    const [capped] = computeDeals({ netBoxOffice: 500_000, paidSold: 0, dealExpenses: 200_000, merchIncome: 0,
      slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85, expensesCap: 150_000 })] });
    expect(capped.base).toBe(297_500);
  });
});

const settleIn = (over: Partial<SettlementInput>): SettlementInput => ({
  grossBoxOffice: 0, deductions: 0, paidSold: 0, expensesTotal: 0, talentExpenses: 0, otherIncome: 0, merchIncome: 0,
  slots: [], houseAdjustments: 0, venue: null, ...over,
});

describe('settlement (sims)', () => {
  it('promoter mode: rental, venue share, deposit', () => {
    const r = computeSettlement(settleIn({
      grossBoxOffice: 600_000, deductions: 20_000, paidSold: 300, expensesTotal: 350_000,
      slots: [slot({ guarantee: 200_000 })],
      venue: { rentalFee: 150_000, sharePercent: 10, depositPaid: 50_000 },
    }));
    expect(r.netBoxOffice).toBe(580_000);
    expect(r.venue?.share).toBe(58_000);
    expect(r.venue?.total).toBe(208_000);
    expect(r.venue?.balanceDue).toBe(158_000);
    expect(r.promoterNet).toBe(-28_000); // 580,000 − 350,000 − 200,000 − 58,000
  });

  it('talent lines are costs but not in the expense base', () => {
    const r = computeSettlement(settleIn({
      grossBoxOffice: 500_000, expensesTotal: 230_000, talentExpenses: 30_000,
      otherIncome: 40_000, merchIncome: 10_000, houseAdjustments: -1_000,
      slots: [slot({ dealType: 'versus', guarantee: 100_000, percentage: 85, merchArtistPercent: 50 })],
    }));
    expect(r.dealExpenses).toBe(200_000);
    expect(r.slots[0].payout).toBe(260_000);
    expect(r.promoterNet).toBe(59_000); // 500,000 + 40,000 + 10,000 − 230,000 − 260,000 − 1,000
  });

  it('whole-unit math stays exact (a zero-decimal currency)', () => {
    const r = computeSettlement(settleIn({ grossBoxOffice: 6_000, slots: [slot({ dealType: 'door', percentage: 33.3 })] }));
    expect(r.slots[0].payout).toBe(1_998);
  });
});

describe('offer pools', () => {
  const pool = { poolId: 'b1', terms: { dealType: 'versus' as const, guarantee: 300_000, percentage: 80, expensesCap: null, promoterProfitPercent: 0, payoutCap: null, payoutFloor: null } };

  it('one pool payout split by explicit shares and the rest equally', () => {
    const { slots, pools } = computeDealsWithPools({
      netBoxOffice: 1_000_000, paidSold: 0, dealExpenses: 200_000, merchIncome: 0, pools: [pool],
      slots: [
        slot({ guarantee: 999_999 }, { slotId: 'a', name: 'A', poolId: 'b1', poolShare: 50 }),
        slot({}, { slotId: 'b', name: 'B', poolId: 'b1', poolShare: null }),
        slot({}, { slotId: 'c', name: 'C', poolId: 'b1', poolShare: null }),
      ],
    });
    // 80 % of (1,000,000 − 200,000) = 640,000 > 300,000
    expect(pools[0].payout).toBe(640_000);
    expect(slots.map((s) => s.base)).toEqual([320_000, 160_000, 160_000]);
    expect(slots.map((s) => s.poolSharePercent)).toEqual([50, 25, 25]);
    expect(pools[0].distributed).toBe(640_000);
    // A member's own guarantee is not paid (the pool replaces it).
    expect(slots[0].guarantee).toBe(0);
  });

  it('odd cents go to the first remainder member; nothing is lost', () => {
    const { slots, pools } = computeDealsWithPools({
      netBoxOffice: 0, paidSold: 0, dealExpenses: 0, merchIncome: 0,
      pools: [{ poolId: 'p', terms: { ...pool.terms, dealType: 'flat', guarantee: 100_001 } }],
      slots: ['x', 'y', 'z'].map((id) => slot({}, { slotId: id, name: id, poolId: 'p' })),
    });
    expect(slots.map((s) => s.base)).toEqual([33_334, 33_334, 33_333]);
    expect(pools[0].distributed).toBe(100_001);
  });

  it('floor and cap clamp the pool; shares over 100 % are scaled down', () => {
    const capped = computeDealsWithPools({
      netBoxOffice: 2_000_000, paidSold: 0, dealExpenses: 0, merchIncome: 0,
      pools: [{ poolId: 'p', terms: { ...pool.terms, payoutCap: 500_000 } }],
      slots: [slot({}, { slotId: 'a', name: 'A', poolId: 'p', poolShare: 80 }), slot({}, { slotId: 'b', name: 'B', poolId: 'p', poolShare: 80 })],
    });
    expect(capped.pools[0].payout).toBe(500_000);
    expect(capped.slots.map((s) => s.base)).toEqual([250_000, 250_000]);
    const floored = computeDealsWithPools({
      netBoxOffice: 0, paidSold: 0, dealExpenses: 0, merchIncome: 0,
      pools: [{ poolId: 'p', terms: { ...pool.terms, guarantee: 0, payoutFloor: 70_000 } }],
      slots: [slot({}, { slotId: 'a', name: 'A', poolId: 'p' })],
    });
    expect(floored.pools[0].payout).toBe(70_000);
  });

  it("acts outside the pool count the pool's guarantee as support, and the pool theirs", () => {
    const { slots, pools } = computeDealsWithPools({
      netBoxOffice: 1_000_000, paidSold: 0, dealExpenses: 0, merchIncome: 0, pools: [pool],
      slots: [
        slot({ dealType: 'versus', guarantee: 100_000, percentage: 50 }, { slotId: 'solo', name: 'Solo' }),
        slot({}, { slotId: 'm', name: 'Member', poolId: 'b1' }),
      ],
    });
    expect(slots[0].supportCosts).toBe(300_000);
    expect(slots[0].base).toBe(350_000); // 50 % of 700,000
    expect(pools[0].supportCosts).toBe(100_000);
    expect(pools[0].payout).toBe(720_000); // 80 % of 900,000
  });

  it('bonuses, merch and deposits stay per member; an unknown pool id means its own deal', () => {
    const { slots } = computeDealsWithPools({
      netBoxOffice: 0, paidSold: 500, dealExpenses: 0, merchIncome: 10_000,
      pools: [{ poolId: 'p', terms: { ...pool.terms, dealType: 'flat', guarantee: 50_000 } }],
      slots: [
        slot({ bonuses: [{ sold: 400, amount: 5_000 }], merchArtistPercent: 10, deposit: 1_000, depositPaid: true }, { slotId: 'a', name: 'A', poolId: 'p' }),
        slot({ guarantee: 7_000 }, { slotId: 'b', name: 'B', poolId: 'nope' }),
      ],
    });
    expect(slots[0].payout).toBe(56_000);
    expect(slots[0].balanceDue).toBe(55_000);
    expect(slots[1].poolId).toBeNull();
    expect(slots[1].payout).toBe(7_000);
  });
});

describe('budget and pace (sims)', () => {
  it('projects a budget and finds break-even', () => {
    const b = projectBudget({
      capacity: 500, averagePrice: 2_500, sellThroughPercent: 80,
      expenses: [{ amount: 300_000 }, { amount: 50_000, talent: true }],
      slots: [slot({ dealType: 'versus', guarantee: 200_000, percentage: 85 })],
    });
    expect(b.projectedSold).toBe(400);
    expect(b.projectedGross).toBe(1_000_000);
    expect(b.artistsTotal).toBe(595_000);
    expect(b.promoterNet).toBe(1_000_000 - 350_000 - 595_000);
    expect(b.breakEvenTickets).toBe(254);
    expect(b.breakEvenGross).toBe(635_000);
    expect(projectBudget({ capacity: 10, averagePrice: 1_000, expenses: [{ amount: 50_000 }], slots: [] }).breakEvenTickets).toBeNull();
  });

  it('estimates sales at the current pace, capped at capacity', () => {
    const DAY = 86_400_000;
    const NOW = Date.UTC(2026, 9, 23, 12);
    const p = paceEstimate({ sold: 100, gross: 250_000, capacity: 500, startedAt: NOW - 10 * DAY, eventAt: NOW + 20 * DAY, now: NOW });
    expect([p.perDay, p.estimatedSold, p.estimatedGross]).toEqual([10, 300, 750_000]);
    expect(paceEstimate({ sold: 100, gross: 250_000, capacity: 150, startedAt: NOW - 10 * DAY, eventAt: NOW + 20 * DAY, now: NOW }).estimatedSold).toBe(150);
    expect(paceEstimate({ sold: 100, gross: 250_000, capacity: 500, startedAt: NOW - 10 * DAY, eventAt: NOW - DAY, now: NOW }).estimatedSold).toBe(100);
  });
});

describe('box office from the database', () => {
  const sales = {
    tiers: [
      { tier_id: 'ga', name: 'GA', paid: 2, comps: 0, gross_cents: 5_000 },
      { tier_id: 'vip', name: 'VIP', paid: 1, comps: 0, gross_cents: 5_000 },
      { tier_id: 'comp', name: 'Guest list', paid: 0, comps: 2, gross_cents: 0 },
    ],
    paid_sold: 3, comps: 2, sold_last_24h: 1, first_sale_at: '2026-10-18T12:00:00Z', gross_cents: 10_000,
    tax_cents: 417, passed_on_fees_cents: 0, absorbed_fees_cents: 150, platform_fees_cents: 300,
  };
  it('adds sold elsewhere in the show currency only', () => {
    const b = boxOffice(sales, [{ currency: 'usd', sold: 10, gross_cents: 30_000 }, { currency: 'JPY', sold: 5, gross_cents: 9_000 }], 'USD');
    expect(b.gross).toBe(40_000);
    expect(b.deductions).toBe(867);
    expect(b.paidSold).toBe(13);
    expect(b.attendance).toBe(15);
    expect(b.elsewhere.map((e) => [e.currency, e.included])).toEqual([['USD', true], ['JPY', false]]);
    expect(b.byTier.map((t) => t.tierId)).toEqual(['ga', 'vip', 'comp']);
    expect(b.firstSaleAt).toBe(Date.parse('2026-10-18T12:00:00Z'));
    expect(boxOffice(null, null, 'USD').gross).toBe(0);
  });
});

// A whole show as the database returns it.
function inputs(over: Partial<SettlementInputs> = {}): SettlementInputs {
  return {
    version: 1,
    computed_at: '2026-10-30T00:00:00Z',
    event: { id: 'e1', name: 'Night One', status: 'published', starts_at: '2026-11-20T02:00:00Z', timezone: 'America/Chicago',
      currency: 'USD', capacity: 500, venue: { id: 'v1', name: 'Metro', relationship: 'rented' }, venue_name: 'Metro', hold_id: 'h1' },
    box_office: { tiers: [{ tier_id: 't', name: 'GA', paid: 300, comps: 10, gross_cents: 600_000 }], paid_sold: 300, comps: 10,
      sold_last_24h: 5, first_sale_at: '2026-10-20T00:00:00Z', gross_cents: 600_000, tax_cents: 20_000,
      passed_on_fees_cents: 0, absorbed_fees_cents: 0, platform_fees_cents: 0 },
    sold_elsewhere: { available: true, lines: [] },
    items: [
      { kind: 'expense', label: 'Venue rental', category_key: 'venue-rental', category_name: 'Venue rental', amount_cents: 150_000, forecast_cents: null, estimate_cents: null, actual_cents: null },
      { kind: 'expense', label: 'Sound', category_key: 'production', category_name: 'Production', amount_cents: 200_000, forecast_cents: 180_000, estimate_cents: null, actual_cents: null },
    ],
    offers: [{ id: 'o1', budget_id: 'b1', artist_name: 'Headliner', status: 'accepted', currency: 'USD',
      terms: { deal_type: 'flat', guarantee_cents: 200_000, bonuses: [] }, pool_share_percent: null }],
    pools: [],
    budget: { id: 'b1', name: 'Night One', currency: 'USD', capacity: 500, average_price_cents: 2_000, sell_through_percent: 80,
      lines: [{ kind: 'expense', label: 'Production', category_key: 'production', amount_cents: 150_000 },
              { kind: 'expense', label: 'Marketing', category_key: 'marketing', amount_cents: 50_000 }],
      offers: [], pool: null },
    rental: { status: 'confirmed', fee_cents: 150_000, deposit_cents: 50_000, currency: 'USD' },
    promoter_mode: true,
    settlement: { adjustments: [], deposits_paid: {}, venue_share_percent: 10, venue_deposit_paid_cents: 50_000 },
    ...over,
  };
}

describe('settlement from database inputs', () => {
  it('matches the promoter-mode sim through the model', () => {
    const v = settle(inputs());
    expect(v.result.netBoxOffice).toBe(580_000);
    expect(v.result.venue?.rentalFee).toBe(150_000);
    expect(v.result.venue?.balanceDue).toBe(158_000);
    expect(v.result.promoterNet).toBe(-28_000);
  });

  it('adjustments: on an act, on the house; deposits; another currency is listed not settled', () => {
    const v = settle(inputs({
      offers: [
        { id: 'o1', budget_id: 'b1', artist_name: 'Headliner', status: 'accepted', currency: 'USD',
          terms: { deal_type: 'flat', guarantee_cents: 200_000, deposit_cents: 50_000 }, pool_share_percent: null },
        { id: 'o2', budget_id: 'b2', artist_name: 'Euro act', status: 'accepted', currency: 'EUR',
          terms: { deal_type: 'flat', guarantee_cents: 100_000 }, pool_share_percent: null },
      ],
      settlement: {
        adjustments: [
          { id: 'a1', offer_id: 'o1', label: 'Late', amount_cents: -10_000, reason: 'Started late' },
          { id: 'a2', offer_id: null, label: 'Damage', amount_cents: -5_000, reason: 'Broken mic' },
        ],
        deposits_paid: { o1: true }, venue_share_percent: 0, venue_deposit_paid_cents: 0,
      },
    }));
    expect(v.excludedOffers).toEqual(['o2']);
    expect(v.result.slots[0].payout).toBe(190_000);
    expect(v.result.slots[0].balanceDue).toBe(140_000);
    expect(v.result.houseAdjustments).toBe(-5_000);
  });

  it('pools in pool mode pay the lineup from the shared deal', () => {
    const v = settle(inputs({
      promoter_mode: false,
      offers: [
        { id: 'o1', budget_id: 'b1', artist_name: 'A', status: 'accepted', currency: 'USD', terms: { guarantee_cents: 1 }, pool_share_percent: 60 },
        { id: 'o2', budget_id: 'b1', artist_name: 'B', status: 'accepted', currency: 'USD', terms: {}, pool_share_percent: null },
      ],
      pools: [{ budget_id: 'b1', mode: 'pool', terms: { deal_type: 'door', percentage: 50 } }],
    }));
    // door 50 % of 580,000 = 290,000 → 174,000 / 116,000
    expect(v.result.slots.map((s) => s.payout)).toEqual([174_000, 116_000]);
    const independent = settle(inputs({ promoter_mode: false, offers: v.result.slots.map((s, i) => ({
      id: s.slotId, budget_id: 'b1', artist_name: s.name, status: 'accepted', currency: 'USD',
      terms: { guarantee_cents: 1 + i }, pool_share_percent: null })),
      pools: [{ budget_id: 'b1', mode: 'independent', terms: { deal_type: 'door', percentage: 50 } }] }));
    expect(independent.result.slots.map((s) => s.payout)).toEqual([1, 2]);
  });
});

describe('profit and loss', () => {
  const NOW = Date.parse('2026-10-30T00:00:00Z');
  it('three columns: forecast from the budget, estimate at pace, actual = settlement', () => {
    const p = showPnl(inputs(), NOW);
    const row = (k: string) => p.rows.find((r) => r.key === k)!;
    // Forecast: 500 × 80 % = 400 × $20 = $8,000.
    expect(row('gross').forecast).toBe(800_000);
    expect(p.sold.forecast).toBe(400);
    // The production item's explicit forecast replaces the budget line of its category.
    expect(row('expense:production').forecast).toBe(-180_000);
    expect(row('expense:marketing').forecast).toBe(-50_000);
    // Actual is the settlement.
    expect(p.net.actual).toBe(settle(inputs()).result.promoterNet);
    expect(row('gross').actual).toBe(600_000);
    // Estimate: 300 sold in 10 days, 21 days to go → capped at 500.
    expect(p.sold.estimate).toBe(500);
    expect(row('gross').estimate).toBe(1_000_000);
    // Marketing has no item: the estimate falls back to the budget line.
    expect(row('expense:marketing').estimate).toBe(-50_000);
    expect(row('venue_share').actual).toBe(-58_000);
  });

  it('org-wide: per show, totals per currency, CSV safe against formulas', () => {
    const a = inputs();
    const b = inputs({ event: { ...inputs().event, id: 'e2', name: '=HYPERLINK("x")', currency: 'EUR' }, offers: [] });
    const org = orgPnl([{ event_id: 'e1', finalized: true, inputs: a }, { event_id: 'e2', finalized: false, inputs: b }, { event_id: 'e3', finalized: false, inputs: null }], NOW);
    expect(org.shows.map((s) => s.currency)).toEqual(['USD', 'EUR']);
    expect(org.totals.map((t) => t.currency)).toEqual(['EUR', 'USD']);
    const csv = orgPnlCsv(org);
    expect(csv.split('\r\n')[0]).toBe('event_id,show,starts_at,currency,finalized,gross,expenses,payouts,net_forecast,net_estimate,net_actual');
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv).toContain(',-280.00\r\n');
    expect(csv).toContain('Total (1 show)');
  });

  it('describes a deal in words', () => {
    expect(describeDeal({ deal_type: 'versus', guarantee_cents: 100_000, percentage: 85 }, 'USD')).toBe('$1,000.00 versus 85% of net after expenses');
    expect(describeDeal({ deal_type: 'door', percentage: 70 }, 'USD')).toBe('70% of net box office');
  });
});

describe('PDF documents', () => {
  const text = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join('');

  it('writes a valid PDF 1.4 file with a correct cross-reference table', () => {
    const pdf = createPdf({ title: 'Test' });
    pdf.heading('Hello (world) \\ €');
    for (let i = 0; i < 120; i++) pdf.row([[`Line ${i}`], ['$1.00', { align: 'right' }]]);
    const s = text(pdf.toBytes());
    expect(s.startsWith('%PDF-1.4')).toBe(true);
    expect(s.trimEnd().endsWith('%%EOF')).toBe(true);
    expect(s).toContain('(Hello \\(world\\) \\\\ \\200)');
    expect(Number(/\/Count (\d+)/.exec(s)![1])).toBeGreaterThan(1);
    const xref = Number(/startxref\n(\d+)/.exec(s)![1]);
    expect(s.slice(xref, xref + 4)).toBe('xref');
    const offsets = [...s.slice(xref).matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    offsets.forEach((o, i) => expect(s.slice(o, o + `${i + 1} 0 obj`.length)).toBe(`${i + 1} 0 obj`));
  });

  it('wraps long words hard', () => {
    expect(wrap('x'.repeat(400), 100, 10).length).toBeGreaterThan(1);
  });

  it('offer and settlement documents (the contacts\' copy has no promoter net)', () => {
    const offer = text(offerPdf({
      title: 'Night One', status: 'sent', org: { name: 'Org' }, artist_name: 'Headliner', dates: ['2026-11-19'], currency: 'USD',
      venue: { name: 'Metro', room: 'Main' }, terms: { deal_type: 'versus', guarantee_cents: 100_000, percentage: 85, bonuses: [{ sold: 400, amount_cents: 5_000 }] },
      boilerplate: 'Subject to contract.', expires_at: '2026-11-01T00:00:00Z',
    }));
    expect(offer).toContain('versus 85% of net after expenses');
    expect(offer).toContain('Subject to contract.');
    const full = text(settlementPdf(inputs(), { orgName: 'Org', includePromoterNet: true }));
    const contacts = text(settlementPdf(inputs(), { orgName: 'Org', includePromoterNet: false, finalizedAt: '2026-11-21T00:00:00Z' }));
    expect(full).toContain('Promoter net');
    expect(contacts).not.toContain('Promoter net');
    expect(contacts).toContain('Balance due to the venue');
  });
});
