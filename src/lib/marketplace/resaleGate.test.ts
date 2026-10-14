import { describe, expect, it } from 'vitest';
import { admissionsForTier, BLANK_TABLE_DRAFT } from '../tables';
import { eventMaxCapacity, RESALE_MIN_CAPACITY, resaleLockedText, resaleUnlocked } from './resaleGate';

describe('resale gate (mig 20261014140000)', () => {
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
  });
  it('the line is 250', () => {
    expect(RESALE_MIN_CAPACITY).toBe(250);
    expect(resaleUnlocked(249)).toBe(false);
    expect(resaleUnlocked(250)).toBe(true);
    expect(resaleLockedText(200)).toBe("Resale marketplaces and S4K unlock at a max capacity of 250. This event's is 200.");
  });
});
