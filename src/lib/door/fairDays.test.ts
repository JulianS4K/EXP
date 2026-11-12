// Fair days at the door (mig 20261113110000): the device's offline rules,
// which mirror SQL _exos_checkin_day_refusal (tests/exos/test_fair_day.sql).
import { describe, expect, it } from 'vitest';
import { decideScan, parseDoorCode, type DoorCachedTicket, type ScanDecisionInput } from './decide';
import { dayListRefusal, dayListWrongDay, describeList, enteredOnDay, localDayKey, mapCheckinListRow, type DoorCheckinList } from './lists';
import { listsSignature } from './roster';

const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';
const T1 = '11111111-2222-3333-4444-555555555555';
const CODE = `T-${T1}:owner-1:12345:sig`;
const HOUR = 3600e3;
const NOW = Date.UTC(2027, 7, 21, 18, 0, 0); // day 2, 18:00 UTC
const day = (id: string, date: string, from: number, reentry = false, tierIds: string[] | null = null): DoorCheckinList => ({
  id, name: id, tierIds, allowReentry: reentry, validFrom: new Date(from).toISOString(),
  validUntil: new Date(from + 12 * HOUR).toISOString(), sortOrder: 0, admits: 'tickets', addonIds: null, entryDay: date,
});
const D1 = day('d1', '2027-08-20', NOW - 30 * HOUR);
const D2 = day('d2', '2027-08-21', NOW - 6 * HOUR);
const D2N = day('d2n', '2027-08-21', NOW - 6 * HOUR); // a second gate, day 2
const D3 = day('d3', '2027-08-22', NOW + 18 * HOUR);
const LISTS = [D1, D2, D2N, D3];
const R1 = day('r1', '2027-08-20', NOW - 30 * HOUR, true);
const R2 = day('r2', '2027-08-21', NOW - 6 * HOUR, true);
const RLISTS = [R1, R2];
const LOT: DoorCheckinList = { id: 'lot', name: 'Lot', tierIds: null, allowReentry: true, validFrom: null, validUntil: null,
  sortOrder: 9, admits: 'addons', addonIds: null, entryDay: null };

const offline = (entry: DoorCachedTicket, list: DoorCheckinList, over: Partial<ScanDecisionInput> = {}): ScanDecisionInput => ({
  code: parseDoorCode(CODE, 'camera'), source: 'camera', eventId: EVENT, entry, queued: false, verify: { ok: true },
  network: 'offline', gate: { opensAt: NOW - 40 * HOUR, testUntil: null }, now: NOW, canOverride: false, recent: null,
  list, lists: [...LISTS, ...RLISTS, LOT], dayLimits: { any: 1, flex: 2 }, ...over,
});
const admit = { action: 'admit', ticketId: T1, test: false, queue: true };
const reject = (reason: string) => ({ action: 'reject', ticketId: T1, reason });

describe('fair day lists: the rule', () => {
  it('maps entry_day from a row, and an ordinary list has none', () => {
    expect(mapCheckinListRow({ id: 'x', name: 'Fri', entry_day: '2027-08-20' }).entryDay).toBe('2027-08-20');
    expect(mapCheckinListRow({ id: 'x', name: 'Main' }).entryDay ?? null).toBeNull();
  });
  it('without re-entry: once that day, across the day\'s gates; another day is fine', () => {
    expect(dayListRefusal(D2, { d1: 'entry' }, LISTS, null)).toBeNull();
    expect(dayListRefusal(D2, { d2n: 'entry' }, LISTS, null)).toBe('used');
    expect(dayListRefusal(D2, { d2: 'entry' }, LISTS, null)).toBe('used');
    expect(enteredOnDay(D2, { d2n: 'entry' }, LISTS)).toBe(true);
    expect(enteredOnDay(D2, { d1: 'entry' }, LISTS)).toBe(false);
  });
  it('the day limit counts the other days entered', () => {
    expect(dayListRefusal(D2, { d1: 'entry' }, LISTS, 1)).toBe('day-limit');
    expect(dayListRefusal(D2, { d1: 'entry' }, LISTS, 2)).toBeNull();
    expect(dayListRefusal(D3, { d1: 'entry', d2: 'entry' }, LISTS, 2)).toBe('day-limit');
    // With re-entry: today's own entry doesn't count against the limit.
    expect(dayListRefusal(R1, { r1: 'exit' }, RLISTS, 1)).toBeNull();
    expect(dayListRefusal(R2, { r1: 'exit' }, RLISTS, 1)).toBe('day-limit');
  });
  it('an ordinary list has no day rule', () => {
    expect(dayListRefusal(LOT, { d1: 'entry' }, LISTS, 1)).toBeNull();
    expect(dayListRefusal(null, { d1: 'entry' }, LISTS, 1)).toBeNull();
  });
  it('a change of day makes the door pull the whole saved list again', () => {
    expect(listsSignature([D1])).not.toBe(listsSignature([{ ...D1, entryDay: '2027-08-21' }]));
  });
  it('describes a day list', () => {
    expect(describeList(D2, () => 'x')).toBe('All ticket types · once that day · fair day 2027-08-21');
    expect(describeList(R2, () => 'x')).toBe('All ticket types · re-entry the same day · fair day 2027-08-21');
  });
});

describe('fair day lists: the door offline', () => {
  it('a 3-day pass used yesterday enters today; twice today is used', () => {
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { d1: 'entry' } }, D2))).toEqual(admit);
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { d1: 'entry', d2n: 'entry' } }, D2))).toEqual(reject('used'));
  });
  it('a day pass is valid on its own day only, in that day\'s hours', () => {
    const d1Only = { ...D1, tierIds: ['day-1'] };
    expect(decideScan(offline({ used: false, tierId: 'day-1' }, { ...D2, tierIds: ['day-2'] }))).toEqual(reject('wrong-list'));
    expect(decideScan(offline({ used: false, tierId: 'day-1' }, d1Only))).toEqual(reject('invalid-time'));
  });
  it('the any-day pass gets one day; the flex pass two', () => {
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { d1: 'entry' } }, D2))).toEqual(reject('day-limit'));
    expect(decideScan(offline({ used: false, tierId: 'any' }, D2))).toEqual(admit);
    expect(decideScan(offline({ used: true, tierId: 'flex', lists: { d1: 'entry' } }, D2))).toEqual(admit);
  });
  it('same-day re-entry: in and out the same day, never a second day for an any-day pass', () => {
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { r2: 'exit' } }, R2))).toEqual(admit);
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { r2: 'entry' } }, R2))).toEqual(reject('already-inside'));
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { r1: 'exit' } }, R2))).toEqual(reject('day-limit'));
  });
  it('an ordinary list keeps "used" (a ticket used anywhere is refused)', () => {
    const main: DoorCheckinList = { ...D2, id: 'main', entryDay: null };
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { d1: 'entry' } }, main))).toEqual(reject('used'));
  });
  it('the lot scans only lot codes', () => {
    expect(decideScan(offline({ used: false, tierId: 'multi' }, LOT))).toEqual(reject('addon-only-list'));
    expect(decideScan(offline({ used: false, addon: true, addonId: 'parking' }, D2))).toEqual(reject('tickets-only-list'));
    expect(decideScan(offline({ used: false, addon: true, addonId: 'parking' }, LOT))).toEqual(admit);
  });
  it('a scan still queued on this device: a day list decides on the device marks, online too', () => {
    const e: DoorCachedTicket = { used: true, tierId: 'multi', lists: { d1: 'entry' } };
    expect(decideScan(offline(e, D2, { queued: true, network: 'online' }))).toEqual(admit);
    expect(decideScan(offline({ ...e, lists: { d1: 'entry', d2: 'entry' } }, D2, { queued: true, network: 'online' })))
      .toEqual(reject('used'));
    // Online with nothing queued: the server decides.
    expect(decideScan(offline(e, D2, { network: 'online' }))).toEqual({ action: 'ask-server', ticketId: T1 });
  });
  it('by name follows the same rule', () => {
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { d1: 'entry' } }, D2, { byName: true })))
      .toEqual(reject('day-limit'));
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { d1: 'entry' } }, D2, { byName: true })))
      .toEqual({ ...admit, byName: true });
  });
});

// Security review of 3610a22: every entry counts, whatever its list. The
// device keeps a 'day:YYYY-MM-DD' key (the event's zone) for an entry off the
// fair-day lists (no list, an ordinary list, a deleted list), as the roster does.
describe('fair day lists: entries off the day lists count', () => {
  it('a day key is the local date in the event zone, UTC when unknown', () => {
    const t = Date.parse('2027-08-21T05:30:00Z');
    expect(localDayKey(t, 'America/Phoenix')).toBe('day:2027-08-20');
    expect(localDayKey(t, 'Europe/Berlin')).toBe('day:2027-08-21');
    expect(localDayKey(t, null)).toBe('day:2027-08-21');
    expect(localDayKey(t, 'Mars/Olympus')).toBe('day:2027-08-21');
  });
  it('a no-list entry today, then today\'s day list: used', () => {
    expect(dayListRefusal(D2, { 'day:2027-08-21': 'entry' }, LISTS, null)).toBe('used');
    expect(enteredOnDay(D2, { 'day:2027-08-21': 'entry' }, LISTS)).toBe(true);
    expect(dayListRefusal(D2, { 'day:2027-08-20': 'entry' }, LISTS, null)).toBeNull();
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { 'day:2027-08-21': 'entry' } }, D2))).toEqual(reject('used'));
  });
  it('an ordinary-list (or deleted-list) entry on day 1 uses an any-day pass\'s day', () => {
    expect(dayListRefusal(D2, { main: 'entry', 'day:2027-08-20': 'entry' }, LISTS, 1)).toBe('day-limit');
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { 'day:2027-08-20': 'entry' } }, D2))).toEqual(reject('day-limit'));
    // A day key and a day list for the same day are one day.
    expect(dayListRefusal(D3, { d1: 'entry', 'day:2027-08-20': 'entry' }, LISTS, 2)).toBeNull();
    // Re-entry day list: today's own day key doesn't count against the limit.
    expect(dayListRefusal(R2, { 'day:2027-08-21': 'entry' }, RLISTS, 1)).toBeNull();
  });
  it('an ordinary list\'s key alone is not a day (its day key is)', () => {
    expect(dayListRefusal(D2, { main: 'entry' }, [...LISTS, { ...D2, id: 'main', entryDay: null }], 1)).toBeNull();
  });
});

// The Applier's review of wave 13: a fair day's re-entry gates share in / out
// ('dayin:' key), the day limit on re-entry lists, and a scan's local date
// must be the list's day ('wrong-day').
describe('fair day lists: re-entry across gates, and the scan\'s day', () => {
  const R2N = day('r2n', '2027-08-21', NOW - 6 * HOUR, true);
  const RL = [R1, R2, R2N];
  it('in at gate A, refused at gate B until an exit (at either gate)', () => {
    expect(dayListRefusal(R2N, { r2: 'entry', 'dayin:2027-08-21': 'entry' }, RL, null)).toBe('already-inside');
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { r2: 'entry', 'dayin:2027-08-21': 'entry' } }, R2N, { lists: RL })))
      .toEqual(reject('already-inside'));
    // Out at B: back in at A even though A's own last scan was an entry.
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { r2: 'entry', r2n: 'exit', 'dayin:2027-08-21': 'exit' } }, R2, { lists: RL })))
      .toEqual(admit);
    // A saved list from before the day key: the list's own state.
    expect(decideScan(offline({ used: true, tierId: 'multi', lists: { r2: 'entry' } }, R2, { lists: RL }))).toEqual(reject('already-inside'));
  });
  it('the day limit holds on re-entry lists; the day used is not a new day', () => {
    expect(decideScan(offline({ used: true, tierId: 'any', lists: { r1: 'exit', 'dayin:2027-08-20': 'exit' } }, R2, { lists: RL })))
      .toEqual(reject('day-limit'));
    expect(dayListRefusal(R2, { r2: 'exit', 'dayin:2027-08-21': 'exit' }, RL, 1)).toBeNull();
  });
  it('a scan on another day than the list\'s is wrong-day, live and offline', () => {
    const noHours: DoorCheckinList = { ...D1, validFrom: null, validUntil: null }; // day 1 = 2027-08-20
    expect(dayListWrongDay(noHours, NOW, 'UTC')).toBe(true); // NOW is Aug 21
    expect(dayListWrongDay({ ...noHours, entryDay: '2027-08-21' }, NOW, 'UTC')).toBe(false);
    expect(decideScan(offline({ used: false, tierId: 'multi' }, noHours))).toEqual(reject('wrong-day'));
    // In the event's zone: 01:00 UTC on Aug 22 is still Aug 21 in Phoenix.
    expect(dayListWrongDay({ ...noHours, entryDay: '2027-08-21' }, Date.UTC(2027, 7, 22, 1), 'America/Phoenix')).toBe(false);
  });
  it('after midnight inside a window that opens on the list\'s day is that day', () => {
    const late: DoorCheckinList = { ...D2, validFrom: '2027-08-21T18:00:00Z', validUntil: '2027-08-22T02:00:00Z' };
    expect(dayListWrongDay(late, Date.UTC(2027, 7, 22, 0, 30), 'UTC')).toBe(false);
    expect(dayListWrongDay(late, Date.UTC(2027, 7, 22, 3, 0), 'UTC')).toBe(true);
  });
});
