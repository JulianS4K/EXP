// POS drawer recount (mig 20261104200000): when the report offers it, and the
// numbers it shows.
import { describe, expect, it } from 'vitest';
import { parseCash, recountBlock, recountsFor, recountVariance, validReason, type RecountRow } from './drawerRecount';

const NOW = Date.parse('2026-11-04T12:00:00Z');
const closed = { status: 'closed' as const, closed_at: '2026-11-03T23:00:00Z' };

describe('recountBlock', () => {
  it('offers it to owners / managers on a closed drawer within 7 days, under 3 recounts', () => {
    expect(recountBlock(closed, 0, { canAct: true, settled: false, now: NOW })).toBeNull();
    expect(recountBlock(closed, 2, { canAct: true, settled: false, now: NOW })).toBeNull();
  });
  it('says why not', () => {
    expect(recountBlock(closed, 0, { canAct: false, settled: false, now: NOW })).toBe('role');
    expect(recountBlock({ status: 'open', closed_at: null }, 0, { canAct: true, settled: false, now: NOW })).toBe('open');
    expect(recountBlock(closed, 3, { canAct: true, settled: false, now: NOW })).toBe('limit');
    expect(recountBlock(closed, 0, { canAct: true, settled: true, now: NOW })).toBe('settled');
    expect(recountBlock({ status: 'closed', closed_at: '2026-10-27T11:00:00Z' }, 0, { canAct: true, settled: false, now: NOW }))
      .toBe('window');
  });
});

describe('numbers', () => {
  it('parseCash', () => {
    expect(parseCash('100')).toBe(10000);
    expect(parseCash('$1,234.5')).toBe(123450);
    expect(parseCash('0.07')).toBe(7);
    expect(parseCash('-5')).toBeNull();
    expect(parseCash('1.234')).toBeNull();
    expect(parseCash('')).toBeNull();
  });
  it('variance against the expected cash stored at close', () => {
    expect(recountVariance(10000, 10000)).toBe(0);
    expect(recountVariance(10000, 9500)).toBe(-500);
    expect(recountVariance(null, 9500)).toBeNull();
  });
  it('reasons and ordering', () => {
    expect(validReason('  ok ')).toBe(false);
    expect(validReason('found $10 under the tray')).toBe(true);
    expect(validReason('x'.repeat(501))).toBe(false);
    const rows = [{ session_id: 'a', recount_no: 2 }, { session_id: 'b', recount_no: 1 }, { session_id: 'a', recount_no: 1 }] as RecountRow[];
    expect(recountsFor(rows, 'a').map((r) => r.recount_no)).toEqual([1, 2]);
  });
});
