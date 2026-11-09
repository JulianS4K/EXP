import { describe, it, expect, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { capToStep, currentPriceStep, fromSqlCurrentPrice, priceStepNudge, priceStepsError, priceStepsPayload } from './priceSteps';
import { currentPriceStep as serverStep } from '../../supabase/functions/_shared/priceSteps.ts';

// The same cases tests/exos/test_price_steps.sql (PS1) runs against
// exos_tier_current_price: the SQL function and this mirror can't drift.
const CASES = JSON.parse(readFileSync(path.resolve(__dirname, '../../tests/exos/fixtures/price_steps_cases.json'), 'utf8')).cases as any[];

describe('price steps: TS / SQL parity (shared cases)', () => {
  it('has the cases', () => expect(CASES.length).toBeGreaterThanOrEqual(10));
  for (const c of CASES) {
    it(c.name, () => {
      const cp = currentPriceStep({
        basePriceCents: c.base_price_cents,
        doorPriceCents: c.door_price_cents,
        steps: c.steps.map((s: any) => ({
          id: s.key, name: s.name, priceCents: s.price_cents, endsAfterCount: s.ends_after_count,
          endsAt: s.ends_at, soldOutAt: s.sold_out_at, used: s.used,
        })),
      }, new Date(c.at), c.channel);
      expect(cp.priceCents).toBe(c.expect.price_cents);
      expect(cp.source).toBe(c.expect.source);
      expect(cp.stepId).toBe(c.expect.step);
      expect(cp.stepIndex).toBe(c.expect.step_index);
      expect(cp.stepRemaining).toBe(c.expect.step_remaining);
      expect(cp.nextPriceCents).toBe(c.expect.next_price_cents);
      // The SPA and Deno load the very same module.
      expect(serverStep).toBe(currentPriceStep);
    });
  }
});

describe('price steps: the SQL answer', () => {
  it('maps exos_tier_current_price jsonb', () => {
    const cp = fromSqlCurrentPrice({
      price_cents: 2000, source: 'step', step_id: 's1', step_name: 'Early bird', step_index: 1, step_count: 3,
      step_remaining: 37, step_ends_at: '2026-12-01T00:00:00+00:00', next_price_cents: 2500, next_step_name: null, door_price_cents: 3500,
    });
    expect(cp).toMatchObject({ priceCents: 2000, source: 'step', stepRemaining: 37, nextPriceCents: 2500, doorPriceCents: 3500 });
    expect(fromSqlCurrentPrice(null)).toBeNull();
  });
});

describe('price steps: boundary rule (cap)', () => {
  const cp = currentPriceStep({ basePriceCents: 0, steps: [
    { id: 'eb', priceCents: 2000, endsAfterCount: 100, used: 98 }, { id: 'f', priceCents: 3000, used: 0 },
  ] });
  it('caps an order at what the step has left', () => {
    expect(capToStep(5, cp)).toBe(2);
    expect(capToStep(1, cp)).toBe(1);
  });
  it('counts places for table tiers', () => expect(capToStep(5, cp, 2)).toBe(1));
  it('no count end: no cap', () => {
    expect(capToStep(7, currentPriceStep({ basePriceCents: 0, steps: [{ id: 'f', priceCents: 3000, used: 0 }] }))).toBe(7);
  });
});

describe('price steps: the buyer line', () => {
  const money = (c: number) => `$${(c / 100).toFixed(0)}`;
  const date = () => 'Dec 1';
  it('says when the price goes up, by date and count', () => {
    const cp = currentPriceStep({ basePriceCents: 0, steps: [
      { id: 'eb', priceCents: 2000, endsAfterCount: 100, endsAt: '2026-12-01T00:00:00Z', used: 63 },
      { id: 'f', priceCents: 2500, used: 0 },
    ] }, new Date('2026-11-20T00:00:00Z'));
    expect(priceStepNudge(cp, money, date)).toBe('Price goes up to $25 on Dec 1 or after 37 more are sold');
    // All-in: the caller passes the next step's all-in amount; no fee line.
    expect(priceStepNudge(cp, money, date, 2690)).toBe('Price goes up to $27 on Dec 1 or after 37 more are sold');
  });
  it('nothing on the last step or without steps', () => {
    expect(priceStepNudge(currentPriceStep({ basePriceCents: 2000, steps: [] }), money, date)).toBeNull();
    expect(priceStepNudge(currentPriceStep({ basePriceCents: 0, steps: [{ id: 'f', priceCents: 1, used: 0 }] }), money, date)).toBeNull();
  });
});

describe('price steps: editor checks', () => {
  const s = (o: Partial<any>) => ({ name: '', priceCents: 2000, endsAfterCount: null, endsAt: null, ...o });
  it('accepts early bird → GA → final', () => {
    expect(priceStepsError([s({ endsAfterCount: 100, endsAt: '2026-12-01T00:00:00Z' }), s({ priceCents: 2500, endsAfterCount: 200 }), s({ priceCents: 3000 })])).toBeNull();
  });
  it('needs an end on every step but the last, and none on the last', () => {
    expect(priceStepsError([s({}), s({})])).toMatch(/Step 1: give it an end/);
    expect(priceStepsError([s({ endsAfterCount: 3 })])).toMatch(/last step/);
  });
  it('refuses times going backwards, bad counts and prices', () => {
    expect(priceStepsError([s({ endsAt: '2026-12-10T00:00:00Z' }), s({ endsAt: '2026-12-01T00:00:00Z' }), s({})])).toMatch(/Step 2/);
    expect(priceStepsError([s({ endsAfterCount: 0 }), s({})])).toMatch(/1 or more/);
    expect(priceStepsError([s({ priceCents: -1 })])).toMatch(/0 or more/);
  });
  it('builds the RPC body', () => {
    expect(priceStepsPayload([s({ id: 'x', name: ' EB ', endsAfterCount: 5 })])).toEqual([
      { id: 'x', name: 'EB', price_cents: 2000, ends_after_count: 5, ends_at: null },
    ]);
  });
});
