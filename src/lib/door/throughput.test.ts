import { describe, expect, it } from 'vitest';
import { bucketLabel, gateKey, parseThroughput, peakPerMinute, throughputGrid, throughputRefusalText, todayWindow } from './throughput';

const RAW = {
  event_id: 'e', timezone: 'America/Phoenix', from: '2027-08-20T07:00:00Z', until: '2027-08-20T20:00:00Z', bucket_minutes: 15,
  buckets: [
    { at: '2027-08-20T16:00:00+00:00', kind: 'ticket', list_id: 'l1', gate: 'Fri, Aug 20', entries: 40, exits: 2, forced: 1 },
    { at: '2027-08-20T16:15:00+00:00', kind: 'ticket', list_id: 'l1', gate: 'Fri, Aug 20', entries: 25, exits: 0, forced: 0 },
    { at: '2027-08-20T16:00:00+00:00', kind: 'ticket', list_id: 'l2', gate: 'North gate', entries: 10, exits: 0, forced: 0 },
    { at: '2027-08-20T16:15:00+00:00', kind: 'addon', list_id: 'lot', gate: 'Parking lot', entries: 7, exits: 1, forced: 0 },
  ],
  gates: [
    { kind: 'addon', list_id: 'lot', gate: 'Parking lot', entries: 7, exits: 1, forced: 0, devices: 1, peak_entries: 7 },
    { kind: 'ticket', list_id: 'l2', gate: 'North gate', entries: 10, exits: 0, forced: 0, devices: 1, peak_entries: 10 },
    { kind: 'ticket', list_id: 'l1', gate: 'Fri, Aug 20', entries: 65, exits: 2, forced: 1, devices: 3, peak_entries: 40,
      first_at: '2027-08-20T16:01:00Z', last_at: '2027-08-20T16:29:00Z' },
  ],
  inside: [{ list_id: 'l1', name: 'Fri, Aug 20', admits: 'tickets', entry_day: '2027-08-20', open_now: true, tickets_inside: 63, addons_inside: 0 }],
  in_park_now: 63, lot_now: 6, tracks_direction: true,
  refusals: [{ reason: 'day-limit', count: 3 }, { reason: 'invalid-barcode', count: 1 }],
};

describe('door throughput', () => {
  it('parses the server answer', () => {
    const t = parseThroughput(RAW)!;
    expect(t.bucketMinutes).toBe(15);
    expect(t.gates).toHaveLength(3);
    expect(t.gates[2]).toMatchObject({ kind: 'ticket', listId: 'l1', devices: 3, peakEntries: 40, firstAt: '2027-08-20T16:01:00Z' });
    expect(t.inside[0]).toMatchObject({ entryDay: '2027-08-20', openNow: true, ticketsInside: 63 });
    expect(t.inParkNow).toBe(63);
    expect(t.lotNow).toBe(6);
    expect(parseThroughput(null)).toBeNull();
    expect(parseThroughput({}).gates).toEqual([]);
  });

  it('lays out a column per gate (busiest first, the lot last) and a row per bucket', () => {
    const g = throughputGrid(parseThroughput(RAW)!);
    expect(g.columns.map((c) => c.label)).toEqual(['Fri, Aug 20', 'North gate', 'Parking lot']);
    expect(g.rows).toEqual([
      { at: '2027-08-20T16:00:00.000Z', cells: [40, 10, 0], total: 50 },
      { at: '2027-08-20T16:15:00.000Z', cells: [25, 0, 7], total: 32 },
    ]);
  });

  it('keeps two gates with one name apart by list', () => {
    expect(gateKey({ kind: 'ticket', listId: 'a', gate: 'Main' })).not.toBe(gateKey({ kind: 'ticket', listId: 'b', gate: 'Main' }));
    expect(gateKey({ kind: 'ticket', listId: 'a', gate: 'Main' })).not.toBe(gateKey({ kind: 'addon', listId: 'a', gate: 'Main' }));
  });

  it('labels buckets and rates in the event zone', () => {
    expect(bucketLabel('2027-08-20T16:00:00Z', 15, 'America/Phoenix')).toBe('9:00 AM – 9:15 AM');
    expect(peakPerMinute(parseThroughput(RAW)!.gates[2], 15)).toBeCloseTo(40 / 15);
    expect(throughputRefusalText('day-limit')).toBe("pass's days used up (fair days)");
    expect(throughputRefusalText('invalid-barcode')).toBe('unreadable or forged code');
  });

  it('starts "today" at midnight in the event zone', () => {
    const now = Date.parse('2027-08-20T16:30:00Z'); // 9:30 AM in Phoenix
    expect(todayWindow(now, 'America/Phoenix')).toEqual({ from: '2027-08-20T07:00:00.000Z', until: '2027-08-20T16:30:00.000Z' });
  });
});
