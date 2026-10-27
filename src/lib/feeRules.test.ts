import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { effectiveFeeRules, feeRuleProblems, withAddonFees, withTierFees, type FeeRuleRow } from './feeRules';
import { parseFeeRules } from './fees';

const row = (o: Partial<FeeRuleRow>): FeeRuleRow => ({
  id: 'r', orgId: 'o', eventId: null, name: 'Fee', recipient: 'org', kind: 'passed_on', calc: 'fixed',
  percent: null, amountCents: 100, capCents: null, per: 'ticket', taxable: true, appliesToAddons: false,
  tierIds: null, active: true, sortOrder: 0, createdAt: '2026-10-01T00:00:00Z', ...o,
});

describe('effectiveFeeRules (mirrors exos_effective_fee_rules)', () => {
  const org = [
    row({ id: 'b', name: 'Service', sortOrder: 2 }),
    row({ id: 'a', name: 'Facility', sortOrder: 1 }),
    row({ id: 'z', name: 'Old', active: false }),
  ];
  const own = [row({ id: 'e', eventId: 'ev', name: 'Restoration' })];

  it('org rules in order, then the event\'s own; inactive ones never', () => {
    expect(effectiveFeeRules(org, own, { inheritOrgRules: true, skippedOrgRuleIds: [] }).map((r) => r.name))
      .toEqual(['Facility', 'Service', 'Restoration']);
  });
  it('opt out of every org rule, or skip some', () => {
    expect(effectiveFeeRules(org, own, { inheritOrgRules: false, skippedOrgRuleIds: [] }).map((r) => r.name)).toEqual(['Restoration']);
    expect(effectiveFeeRules(org, own, { inheritOrgRules: true, skippedOrgRuleIds: ['a'] }).map((r) => r.name))
      .toEqual(['Service', 'Restoration']);
  });
  it('at most 10 take effect', () => {
    const many = Array.from({ length: 12 }, (_, i) => row({ id: `r${i}`, sortOrder: i }));
    expect(effectiveFeeRules(many, [], { inheritOrgRules: true, skippedOrgRuleIds: [] })).toHaveLength(10);
  });
});

describe('feeRuleProblems', () => {
  const ok = { name: 'Facility fee', recipient: 'venue', kind: 'passed_on' as const, calc: 'fixed' as const,
    percent: null, amountCents: 200, capCents: null, per: 'ticket' as const };
  it('accepts a sound rule', () => expect(feeRuleProblems(ok)).toEqual([]));
  it('refuses a passed-on per-order fee (all-in prices are per ticket)', () => {
    expect(feeRuleProblems({ ...ok, per: 'order' })[0]).toMatch(/can't be passed on/);
    expect(feeRuleProblems({ ...ok, per: 'order', kind: 'absorbed' })).toEqual([]);
  });
  it('checks amounts', () => {
    expect(feeRuleProblems({ ...ok, amountCents: 0 })).toHaveLength(1);
    expect(feeRuleProblems({ ...ok, calc: 'percent', percent: 120 })).toHaveLength(1);
    expect(feeRuleProblems({ ...ok, calc: 'percent', percent: 3, amountCents: null })).toEqual([]);
    expect(feeRuleProblems({ ...ok, capCents: 100 })).toHaveLength(1);
    expect(feeRuleProblems({ ...ok, name: ' ' })).toHaveLength(1);
  });
});

describe('attaching fees to public rows', () => {
  const rules = parseFeeRules([
    { event_id: 'e1', id: 'f', name: 'Facility fee', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 200, applies_to_addons: true },
    { event_id: 'e1', id: 'v', name: 'VIP only', kind: 'passed_on', per: 'ticket', calc: 'fixed', amount_cents: 500, tier_ids: ['vip'] },
  ]);
  it('per tier and per add-on', () => {
    const tiers = withTierFees([{ id: 'ga', event_id: 'e1' }, { id: 'vip', event_id: 'e1' }], new Map([['e1', rules]]));
    expect(tiers.map((t) => t.passed_on_fees.length)).toEqual([1, 2]);
    expect(withAddonFees([{ event_id: 'e1' }], rules)[0].passed_on_fees.map((f) => f.name)).toEqual(['Facility fee']);
    expect(withTierFees([{ id: 'ga', event_id: 'e2' }], new Map([['e1', rules]]))[0].passed_on_fees).toEqual([]);
  });
});
