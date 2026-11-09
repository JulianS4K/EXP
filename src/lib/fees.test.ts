import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import * as client from './fees';
import * as server from '../../supabase/functions/_shared/fees.ts';
import { allInPrice, buyerTierPrice, includedFees, tierAllInPrice } from './pricing';
import { allInCents } from '../../supabase/functions/_shared/pricing.ts';
import type { FeeRule } from './fees';

// Organizer fee rules (mig 20261027100000, docs/fees.md). The storefront uses
// src/lib/fees.ts, exos-checkout and the feeds use _shared/fees.ts; they must
// be the same code, and the vectors below match tests/exos/test_fee_rules.sql
// (F5, F6), which checks the SQL mirror (exos_fee_unit_cents /
// exos_all_in_unit_cents).

describe('fees.ts parity (storefront vs exos-checkout)', () => {
  it('is the same file', () => {
    const a = readFileSync(new URL('./fees.ts', import.meta.url), 'utf8');
    const b = readFileSync(new URL('../../supabase/functions/_shared/fees.ts', import.meta.url), 'utf8');
    expect(a).toBe(b);
  });

  it('agrees on 3,000 generated units and rules', () => {
    let x = 20261027;
    const r = () => ((x = (x * 1664525 + 1013904223) >>> 0) / 2 ** 32);
    for (let i = 0; i < 3000; i++) {
      const unit = Math.round(r() * 50000);
      const fees = Array.from({ length: Math.floor(r() * 4) }, () => (r() < 0.5
        ? { calc: 'percent', percent: Math.round(r() * 30000) / 1000, cap_cents: r() < 0.2 ? Math.round(r() * 500) : null, taxable: r() < 0.7 }
        : { calc: 'fixed', amount_cents: Math.round(r() * 1000), taxable: r() < 0.7 }));
      expect(server.unitFeeTotals(unit, fees)).toEqual(client.unitFeeTotals(unit, fees));
    }
  });
});

describe('feeUnitCents', () => {
  const f = client.feeUnitCents;
  it('percent: half-up to a whole cent, per unit', () => {
    expect(f(1999, { calc: 'percent', percent: 3 })).toBe(60); // 59.97
    expect(f(100, { calc: 'percent', percent: 1.5 })).toBe(2); // 1.5 -> 2
    expect(f(1000, { calc: 'percent', percent: 12.345 })).toBe(123); // 123.45 -> 123
    expect(f(1, { calc: 'percent', percent: 2.5 })).toBe(0);
    expect(f(4000, { calc: 'percent', percent: '3' })).toBe(120); // numeric strings from PostgREST
  });
  it('percent cap; fixed amounts', () => {
    expect(f(100000, { calc: 'percent', percent: 10, cap_cents: 500 })).toBe(500);
    expect(f(1000, { calc: 'percent', percent: 10, cap_cents: 500 })).toBe(100);
    expect(f(4000, { calc: 'fixed', amount_cents: 200 })).toBe(200);
    expect(f(4000, { calc: 'fixed', amount_cents: '150' })).toBe(150);
  });
  it('guards: free units, bad input', () => {
    expect(f(0, { calc: 'fixed', amount_cents: 200 })).toBe(0);
    expect(f(-100, { calc: 'percent', percent: 5 })).toBe(0);
    expect(f(4000, { calc: 'bogus', amount_cents: 200 })).toBe(0);
    expect(f(4000, { calc: 'fixed', amount_cents: -5 })).toBe(0);
    expect(f(4000, { calc: 'percent', percent: 'abc' })).toBe(0);
    expect(f(4000, { calc: 'percent', percent: 150 })).toBe(4000); // clamped to 100%
    expect(f(4000, null)).toBe(0);
  });
});

describe('all-in with fees (allInCents / allInPrice)', () => {
  const fixed200 = [{ calc: 'fixed', amount_cents: 200 }];
  it('matches the SQL vectors (test_fee_rules.sql F5)', () => {
    expect(allInCents(4000, 0, [])).toBe(4000);
    expect(allInCents(4000, 8.875)).toBe(4355); // unchanged without fees
    expect(allInCents(4000, 0, fixed200)).toBe(4200);
    expect(allInCents(4000, 8.875, fixed200)).toBe(4573); // tax on 4200
    expect(allInCents(4000, 8.875, [{ ...fixed200[0], taxable: false }])).toBe(4555); // tax on 4000
    expect(allInCents(10000, 8.875, [...fixed200, { calc: 'percent', percent: 5, taxable: false }])).toBe(11605);
  });
  it('storefront = checkout to the cent over 5,000 generated prices, rates and rules', () => {
    let x = 77;
    const r = () => ((x = (x * 1664525 + 1013904223) >>> 0) / 2 ** 32);
    for (let i = 0; i < 5000; i++) {
      const price = Math.round(r() * 50000) / 100;
      const rate = r() < 0.3 ? 0 : Math.round(r() * 2500) / 100;
      const fees = Array.from({ length: Math.floor(r() * 3) }, () => (r() < 0.5
        ? { calc: 'percent', percent: Math.round(r() * 20000) / 1000, taxable: r() < 0.6 }
        : { calc: 'fixed', amount_cents: Math.round(r() * 800), taxable: r() < 0.6 }));
      expect(Math.round(allInPrice(price, rate, fees) * 100), JSON.stringify({ price, rate, fees }))
        .toBe(allInCents(Math.round(price * 100), rate, fees));
    }
  });
  it('a free ticket stays free', () => {
    expect(allInPrice(0, 8.875, fixed200)).toBe(0);
  });
  it('tier helpers fold the fees in; includedFees names them', () => {
    const tier = { price: 40, exclusiveTaxPercent: 0, passedOnFees: [{ name: 'Facility fee', ...fixed200[0] }] };
    expect(buyerTierPrice(tier)).toBe(42);
    expect(tierAllInPrice(tier, 30)).toBe(32);
    expect(includedFees(40, tier.passedOnFees)).toEqual([{ name: 'Facility fee', amount: 2 }]);
    expect(includedFees(0, tier.passedOnFees)).toEqual([]);
  });
});

// The rules of test_fee_rules.sql's event e1.
const RULES: FeeRule[] = client.parseFeeRules([
  { rule_id: 'f001', name: 'Facility fee', kind: 'passed_on', recipient: 'venue', calc: 'fixed', amount_cents: 200, per: 'ticket', taxable: true, applies_to_addons: true, tier_ids: null },
  { rule_id: 'f002', name: 'Service charge', kind: 'absorbed', recipient: 'org', calc: 'percent', percent: '3.000', per: 'ticket', taxable: true, applies_to_addons: false, tier_ids: null },
  { rule_id: 'f003', name: 'Order fee', kind: 'absorbed', recipient: 'promoter', calc: 'fixed', amount_cents: 150, per: 'order', taxable: true, applies_to_addons: true, tier_ids: null },
  { rule_id: 'f101', name: 'Restoration', kind: 'passed_on', recipient: 'org', calc: 'percent', percent: 5, per: 'ticket', taxable: false, applies_to_addons: false, tier_ids: ['vip'] },
  { rule_id: 'bad', name: 'Bad', kind: 'surprise', calc: 'fixed', amount_cents: 1, per: 'ticket' },
]);

describe('picking rules', () => {
  it('parseFeeRules drops unusable rows and keeps ids', () => {
    expect(RULES.map((r) => r.id)).toEqual(['f001', 'f002', 'f003', 'f101']);
    expect(client.parseFeeRules('nope')).toEqual([]);
    expect(client.parseFeeRules([{ id: 'x', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 1 }])[0].rule_id).toBe('x');
  });
  it('per tier: passed-on per-ticket rules for that tier only', () => {
    expect(client.tierPassedOnFees(RULES, 'ga').map((r) => r.name)).toEqual(['Facility fee']);
    expect(client.tierPassedOnFees(RULES, 'vip').map((r) => r.name)).toEqual(['Facility fee', 'Restoration']);
    expect(client.addonPassedOnFees(RULES).map((r) => r.name)).toEqual(['Facility fee']);
  });
  it('groups by event and attaches to tier rows', () => {
    const by = client.feeRulesByEvent([
      { event_id: 'e1', id: 'a', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 100 },
      { event_id: 'e2', id: 'b', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 200 },
      { id: 'no-event', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 1 },
    ]);
    expect([...by.keys()]).toEqual(['e1', 'e2']);
    const tiers = client.attachTierFees([{ id: 't1', event_id: 'e2', price: 10 }, { id: 't2', event_id: 'e3' }], by);
    expect(tiers[0].passed_on_fees.map((f) => f.amount_cents)).toEqual([200]);
    expect(tiers[1].passed_on_fees).toEqual([]);
  });
});

describe('orderFeeLines (the breakdown fulfillment records)', () => {
  it('the e1 order: 2 x GA at $40 + 1 parking at $10 (test_fee_rules.sql F6)', () => {
    const lines = client.orderFeeLines(RULES, {
      tierId: 'ga', ticketUnitCents: 4000, quantity: 2, addons: [{ id: 'parking', unitCents: 1000, quantity: 1 }],
    });
    expect(lines.map((l) => [l.name, l.kind, l.item_kind, l.unit_cents, l.quantity, l.amount_cents])).toEqual([
      ['Facility fee', 'passed_on', 'ticket', 200, 2, 400],
      ['Facility fee', 'passed_on', 'addon', 200, 1, 200],
      ['Service charge', 'absorbed', 'ticket', 120, 2, 240],
      ['Order fee', 'absorbed', 'order', 150, 1, 150],
    ]);
    expect(client.feeTotals(lines)).toEqual({ passedOn: 600, absorbed: 390 });
    expect(lines[0]).toMatchObject({ rule_id: 'f001', recipient: 'venue', taxable: true, per: 'ticket', item_id: 'ga' });
    expect(lines[2]).toMatchObject({ percent: 3, taxable: false });
    expect(lines[3]).toMatchObject({ per: 'order', item_id: null, recipient: 'promoter' });
  });
  it('passed-on lines equal the fees folded into the unit prices', () => {
    const lines = client.orderFeeLines(RULES, { tierId: 'vip', ticketUnitCents: 10000, quantity: 3, addons: [] });
    const folded = client.unitFeeTotals(10000, client.tierPassedOnFees(RULES, 'vip')).total * 3;
    expect(client.feeTotals(lines).passedOn).toBe(folded);
  });
  it('a free order has no fee lines', () => {
    expect(client.orderFeeLines(RULES, { tierId: 'ga', ticketUnitCents: 0, quantity: 2, addons: [] })).toEqual([]);
  });
  it('a per-order percent fee is on the tickets (+ add-ons when the rule covers them)', () => {
    const rules = client.parseFeeRules([
      { id: 'p', name: 'Promoter cut', kind: 'absorbed', calc: 'percent', percent: 10, per: 'order', applies_to_addons: false },
      { id: 'q', name: 'Venue cut', kind: 'absorbed', calc: 'percent', percent: 10, cap_cents: 700, per: 'order', applies_to_addons: true },
    ]);
    const lines = client.orderFeeLines(rules, { tierId: 't', ticketUnitCents: 2500, quantity: 2, addons: [{ id: 'a', unitCents: 1000, quantity: 3 }] });
    expect(lines.map((l) => l.amount_cents)).toEqual([500, 700]); // 10% of 50.00; 10% of 80.00 capped at 7.00
  });
  it('ignores a passed-on per-order rule (the database refuses one)', () => {
    const rules = client.parseFeeRules([{ id: 'x', name: 'X', kind: 'passed_on', calc: 'fixed', amount_cents: 150, per: 'order' }]);
    expect(client.orderFeeLines(rules, { tierId: 't', ticketUnitCents: 2500, quantity: 1, addons: [] })).toEqual([]);
  });
});
