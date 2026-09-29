import { describe, it, expect } from 'vitest';
import { doorTotals, type DoorScanRow } from './report';

const row = (ticketId: string, over: Partial<DoorScanRow> = {}): DoorScanRow => ({
  ticketId, direction: 'entry', forced: false, conflict: null, verification: 'verified', ...over,
});

describe('doorTotals', () => {
  it('one row per ticket: as before', () => {
    expect(doorTotals([row('a'), row('b'), row('c', { verification: 'name' })])).toEqual({
      checkedIn: 3, reentries: 0, exits: 0, forced: 0, byName: 1, conflicts: [],
    });
  });
  it('re-entry: entry, exit, entry is one ticket checked in, one re-entry, one exit', () => {
    const t = doorTotals([row('a'), row('a', { direction: 'exit' }), row('a'), row('b')]);
    expect(t).toMatchObject({ checkedIn: 2, reentries: 1, exits: 1 });
  });
  it('forced rows count as attendance and are grouped by reason', () => {
    const t = doorTotals([
      row('a', { forced: true, conflict: 'voided', verification: 'manual' }),
      row('b', { forced: true, conflict: 'voided' }),
      row('c', { forced: true, conflict: 'wrong-list' }),
      row('d'),
    ]);
    expect(t.checkedIn).toBe(4);
    expect(t.forced).toBe(3);
    expect(t.reentries).toBe(0);
    expect(t.conflicts).toEqual([{ reason: 'voided', count: 2 }, { reason: 'wrong-list', count: 1 }]);
  });
});
