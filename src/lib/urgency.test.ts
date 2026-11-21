import { describe, expect, it } from 'vitest';
import { lowStockThreshold, SALES_END_SOON_MS, tierUrgency } from './urgency';

const now = Date.UTC(2026, 10, 21, 12);
const H = 60 * 60 * 1000;

describe('lowStockThreshold', () => {
  it('is 15% of capacity, rounded up, at least 1 and at most 20', () => {
    expect(lowStockThreshold(10)).toBe(2);
    expect(lowStockThreshold(20)).toBe(3);
    expect(lowStockThreshold(100)).toBe(15);
    expect(lowStockThreshold(134)).toBe(20);
    expect(lowStockThreshold(10_000)).toBe(20);
    expect(lowStockThreshold(1)).toBe(1);
  });
  it('is 0 for a closed or missing capacity', () => {
    expect(lowStockThreshold(0)).toBe(0);
    expect(lowStockThreshold(null)).toBe(0);
    expect(lowStockThreshold(undefined)).toBe(0);
  });
});

describe('tierUrgency', () => {
  it('shows N left only when low by both measures', () => {
    expect(tierUrgency({ capacity: 100, sold: 85, nowMs: now }).lowStockLeft).toBe(15);
    expect(tierUrgency({ capacity: 100, sold: 84, nowMs: now }).lowStockLeft).toBeNull();
    expect(tierUrgency({ capacity: 10_000, sold: 8_500, nowMs: now }).lowStockLeft).toBeNull();
    expect(tierUrgency({ capacity: 10_000, sold: 9_980, nowMs: now }).lowStockLeft).toBe(20);
    expect(tierUrgency({ capacity: 20, sold: 2, nowMs: now }).lowStockLeft).toBeNull();
    expect(tierUrgency({ capacity: 20, sold: 19, nowMs: now }).lowStockLeft).toBe(1);
  });

  it('sold out (and closed capacity 0) is struck through, with no N left', () => {
    const s = tierUrgency({ capacity: 50, sold: 50, nowMs: now });
    expect(s).toMatchObject({ left: 0, soldOut: true, struck: true, lowStockLeft: null, salesEndSoon: false });
    expect(tierUrgency({ capacity: 0, sold: 0, nowMs: now })).toMatchObject({ soldOut: true, struck: true });
    expect(tierUrgency({ capacity: 50, sold: 70, nowMs: now }).left).toBe(0);
  });

  it('sales end soon only in the final 24h of an open window', () => {
    expect(tierUrgency({ capacity: 100, sold: 0, salesEndMs: now + 23 * H, nowMs: now }).salesEndSoon).toBe(true);
    expect(tierUrgency({ capacity: 100, sold: 0, salesEndMs: now + SALES_END_SOON_MS, nowMs: now }).salesEndSoon).toBe(true);
    expect(tierUrgency({ capacity: 100, sold: 0, salesEndMs: now + 25 * H, nowMs: now }).salesEndSoon).toBe(false);
    expect(tierUrgency({ capacity: 100, sold: 0, salesEndMs: null, nowMs: now }).salesEndSoon).toBe(false);
    // ended: no "ends soon", struck through instead
    const ended = tierUrgency({ capacity: 100, sold: 0, salesEndMs: now - 1, nowMs: now });
    expect(ended).toMatchObject({ salesEnded: true, salesEndSoon: false, struck: true, lowStockLeft: null });
    // sold out inside the last day: no "ends soon"
    expect(tierUrgency({ capacity: 10, sold: 10, salesEndMs: now + H, nowMs: now }).salesEndSoon).toBe(false);
  });

  it('a type not yet on sale shows no urgency', () => {
    const u = tierUrgency({ capacity: 10, sold: 9, salesStartMs: now + H, salesEndMs: now + 2 * H, nowMs: now });
    expect(u).toMatchObject({ notYetOnSale: true, lowStockLeft: null, salesEndSoon: false, struck: false });
  });
});
