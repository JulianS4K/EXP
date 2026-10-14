import { describe, expect, it } from 'vitest';
import { maxSplit, parsePoolStatus, poolsAfter, splitError, splitForPercent, type PoolTier } from './s4kPools';

const tier = (over: Partial<PoolTier> = {}): PoolTier => ({
  tierId: 't1', name: 'GA', capacity: 100, sold: 64, splittable: true,
  s4kSplit: 30, s4kSold: 4, s4kHeld: 26, sharedFree: 10, eventbriteMapped: false, ...over,
});

describe('S4K pools (mig 20261014130000)', () => {
  it('parses the status', () => {
    const s = parsePoolStatus({
      route: 's4k', on_feed: true,
      tiers: [{ tier_id: 't1', name: 'GA', capacity: 100, sold: 64, splittable: true, s4k_split: 30, s4k_sold: 4,
                s4k_held: 26, shared_free: 10, eventbrite_mapped: true }, { name: 'no id' },
              { tier_id: 't2', name: 'Open', capacity: 0, shared_free: null }],
    });
    expect(s.route).toBe('s4k');
    expect(s.tiers).toHaveLength(2);
    expect(s.tiers[0]).toEqual(tier({ eventbriteMapped: true }));
    expect(s.tiers[1]).toMatchObject({ splittable: false, sharedFree: null, s4kSplit: 0 });
    expect(parsePoolStatus(null)).toEqual({ route: 'direct', onFeed: false, tiers: [] });
  });
  it('the most S4K can have now', () => {
    expect(maxSplit(tier())).toBe(40);
  });
  it('percent fill: never below sold, never above the max', () => {
    expect(splitForPercent(tier(), 20)).toBe(20);
    expect(splitForPercent(tier(), 2)).toBe(4);
    expect(splitForPercent(tier(), 90)).toBe(40);
    expect(splitForPercent(tier(), -5)).toBe(4);
  });
  it('errors', () => {
    expect(splitError(tier(), 3)).toMatch(/already sold 4/);
    expect(splitError(tier(), 41)).toMatch(/Only 40/);
    expect(splitError(tier(), 2.5)).toMatch(/Whole seats/);
    expect(splitError(tier({ splittable: false }), 1)).toMatch(/can't go to S4K/);
    expect(splitError(tier({ splittable: false, s4kSold: 0 }), 0)).toBeNull();
    expect(splitError(tier(), 40)).toBeNull();
  });
  it('the pools after a split', () => {
    expect(poolsAfter(tier(), 30)).toEqual({ s4k: 26, shared: 10 });
    expect(poolsAfter(tier(), 10)).toEqual({ s4k: 6, shared: 30 });
    expect(poolsAfter(tier(), 40)).toEqual({ s4k: 36, shared: 0 });
    expect(poolsAfter(tier({ sharedFree: null }), 10)).toEqual({ s4k: 6, shared: null });
  });
});
