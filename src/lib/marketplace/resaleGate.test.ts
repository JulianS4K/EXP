import { describe, expect, it } from 'vitest';
import { admissionsForTier, BLANK_TABLE_DRAFT } from '../tables';
import {
  eventCapacityBounded, eventIsFreeTier, eventMaxCapacity, FREE_TIER_MAX_CAPACITY, RESALE_MIN_CAPACITY, resaleLockedText,
  resaleUnlocked,
} from './resaleGate';

describe('resale gate (migs 20261014140000, 20261029090000)', () => {
  it('max capacity, as the server works it out', () => {
    expect(eventMaxCapacity(0, [100, 100])).toBe(200);
    expect(eventMaxCapacity(0, [200, 60])).toBe(260);
    expect(eventMaxCapacity(300, [120])).toBe(120);
    expect(eventMaxCapacity(300, [100, 0])).toBe(300);
    expect(eventMaxCapacity(0, [100, 0])).toBe(100);
    expect(eventMaxCapacity(undefined, [])).toBe(0);
    expect(eventMaxCapacity(180, [200, 200])).toBe(180);
  });
  it('a table counts as its party size', () => {
    const table = { ...BLANK_TABLE_DRAFT, isTable: true, partySize: '2' };
    expect(eventMaxCapacity(0, [admissionsForTier(100, null), admissionsForTier(100, table)])).toBe(300);
    expect(eventMaxCapacity(0, [admissionsForTier(75, table)])).toBe(150);
  });
  it('bounded: an overall cap, or every ticket type capped', () => {
    expect(eventCapacityBounded(0, [100, 50])).toBe(true);
    expect(eventCapacityBounded(0, [100, 0])).toBe(false);
    expect(eventCapacityBounded(120, [100, 0])).toBe(true);
    expect(eventCapacityBounded(0, [])).toBe(false);
  });
  it('the line is 150: free tier at or under, resale (with the opt-in) over', () => {
    expect(FREE_TIER_MAX_CAPACITY).toBe(150);
    expect(RESALE_MIN_CAPACITY).toBe(151);
    expect(resaleUnlocked(150)).toBe(false);
    expect(resaleUnlocked(151)).toBe(true);
    expect(eventIsFreeTier(150, true)).toBe(true);
    expect(eventIsFreeTier(151, true)).toBe(false);
    expect(eventIsFreeTier(100, false)).toBe(false); // no max: not the free tier
    expect(eventIsFreeTier(120, true, 99)).toBe(false);
    expect(resaleLockedText(100, 150, false)).toBe(
      "Resale marketplaces and S4K need a max capacity over 150. This event's capped ticket types add up to 100.",
    );
    expect(resaleLockedText(120)).toBe(
      "Free tier: events with a max capacity of 150 or less pay no Exos fee and are never listed on resale marketplaces or S4K. This event's is 120.",
    );
  });
});
