// Door P1 fixes (mig 20261021090000 and the scanner page): clock persistence,
// sync health, uploader-aware queues, keyset roster pages, refusal titles,
// scanner scope, guest arrivals offline, the guest summary.
import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../supabase', () => ({ supabase: {} }));

import {
  CLOCK_SAVE_KEY,
  SAVED_OFFSET_MAX_AGE_MS,
  getOffsetInfo,
  loadSavedOffset,
  resetClockOffset,
  restoreSavedOffset,
  saveClockOffset,
  serverNow,
  setClockOffset,
} from '../serverClock';
import { syncHealth, type SyncHealthInput } from './health';
import { parseQueue, pendingScanCount, splitByUploader } from '../offlineCheckins';
import { fetchKeysetPages } from './roster';
import { refusalView } from './refusal';
import { assignedDoorEvents, doorAccessProblem } from './scope';
import { guestGate, type PendingArrival } from '../guestLists';
import { replayPendingArrivals, savePendingArrivals, loadPendingArrivals } from '../guestListsApi';
import { parseDoorSummary, summaryCsvRows, summaryText } from './summary';

const NOW = Date.UTC(2026, 9, 21, 22, 0, 0);
const MIN = 60_000;
const U1 = '11111111-1111-4111-8111-111111111111';
const U2 = '22222222-2222-4222-8222-222222222222';
const T1 = '33333333-3333-4333-8333-333333333333';
const R1 = '44444444-4444-4444-8444-444444444444';

function memStorage(init: Record<string, string> = {}) {
  const m = new Map(Object.entries(init));
  return {
    m,
    get length() { return m.size; },
    key: (i: number) => [...m.keys()][i] ?? null,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
}

afterEach(() => resetClockOffset());

describe('clock offset: saved on the device, live wins', () => {
  it('a saved measurement stands in until the server answers', () => {
    const s = memStorage();
    saveClockOffset(s, -240_000, NOW - 2 * 60 * MIN);
    expect(loadSavedOffset(s, NOW)).toEqual({ ms: -240_000, at: NOW - 2 * 60 * MIN });
    expect(restoreSavedOffset(s, NOW)).toBe(true);
    // A phone 4 minutes fast: scans are checked on the corrected clock.
    expect(serverNow(NOW)).toBe(NOW - 240_000);
    expect(getOffsetInfo()).toEqual({ ms: -240_000, at: NOW - 2 * 60 * MIN, live: false });
    setClockOffset(-239_000, NOW, true);
    // A live one is never replaced by the saved copy.
    expect(restoreSavedOffset(s, NOW)).toBe(false);
    expect(getOffsetInfo()?.live).toBe(true);
  });
  it('ignores a copy that is too old, from the future, or unreadable', () => {
    expect(loadSavedOffset(memStorage({ [CLOCK_SAVE_KEY]: JSON.stringify({ ms: 5, at: NOW - SAVED_OFFSET_MAX_AGE_MS - 1 }) }), NOW)).toBeNull();
    expect(loadSavedOffset(memStorage({ [CLOCK_SAVE_KEY]: JSON.stringify({ ms: 5, at: NOW + 5 * MIN }) }), NOW)).toBeNull();
    expect(loadSavedOffset(memStorage({ [CLOCK_SAVE_KEY]: 'nope' }), NOW)).toBeNull();
    expect(loadSavedOffset(null, NOW)).toBeNull();
    expect(restoreSavedOffset(memStorage(), NOW)).toBe(false);
  });
});

const base: SyncHealthInput = {
  now: NOW, online: true, rosterSavedAt: NOW - MIN, rosterCount: 10, ticketsSold: 10, pending: [],
  lastSyncAt: NOW - MIN, clockOffsetMs: 0, conflicts: 0, authBlocked: false,
};

describe('sync health', () => {
  it('warns when the clock has not been measured', () => {
    const line = syncHealth({ ...base, clockOffsetMs: null }).lines.find((l) => l.label === 'Clock vs server')!;
    expect(line.level).toBe('warn');
    expect(line.value).toMatch(/not measured/);
  });
  it('says when the offset is the saved copy', () => {
    const line = syncHealth({ ...base, clockOffsetMs: 2_000, clockSavedAgeMs: 90 * MIN }).lines[3];
    expect(line.value).toBe('+2.0 s · saved 1 h 30 min ago');
    expect(line.level).toBe('ok');
  });
  it('counts guest arrivals and another account\'s paused scans as waiting', () => {
    const line = syncHealth({ ...base, guestPending: 2, otherAccount: 1 }).lines[1];
    expect(line.value).toBe('2 guest arrivals · 1 from another account (paused)');
    expect(line.level).toBe('warn');
    expect(syncHealth({ ...base, pending: [{ scannedAt: NOW }], guestPending: 1 }).lines[1].value).toMatch(/^1 scan \+ 1 guest arrival/);
  });
});

describe('queued scans remember who scanned', () => {
  it('keeps the uid through a reload', () => {
    const raw = JSON.stringify([{ ref: R1, ticketId: T1, payload: null, scannedAt: NOW, source: 'manual', uid: U1 }]);
    expect(parseQueue(raw, NOW)[0].uid).toBe(U1);
    const bad = JSON.stringify([{ ref: R1, ticketId: T1, payload: null, scannedAt: NOW, source: 'manual', uid: 'x' }]);
    expect(parseQueue(bad, NOW)[0].uid).toBeUndefined();
  });
  it('only the scanning account uploads; older scans go with whoever is signed in', () => {
    const q = [{ uid: U1, n: 1 }, { uid: U2, n: 2 }, { n: 3 }];
    expect(splitByUploader(q, U1)).toEqual({ mine: [q[0], q[2]], others: [q[1]] });
    expect(splitByUploader(q, null)).toEqual({ mine: [], others: q });
  });
  it('the sign-out warning counts guest-list arrivals too', () => {
    const s = memStorage({
      pending_updates_e1: JSON.stringify([{ ref: R1, ticketId: T1, payload: null, scannedAt: NOW, source: 'manual' }]),
      guest_pending_e1: JSON.stringify([{ ref: R1, entryId: T1, count: 2, at: NOW }, { ref: U2, entryId: T1, count: 1, at: NOW }]),
      guest_pending_e2: 'garbage',
    });
    expect(pendingScanCount(s, NOW)).toBe(3);
  });
});

describe('fetchKeysetPages', () => {
  it('asks after the last key until a page is empty (a capped page doesn\'t stop it)', async () => {
    const ids = Array.from({ length: 23 }, (_, i) => `id-${String(i).padStart(3, '0')}`);
    const calls: Array<[string | null, number]> = [];
    // The server caps pages at 7 rows whatever the limit (PostgREST max_rows).
    const rows = await fetchKeysetPages(async (after, limit) => {
      calls.push([after, limit]);
      return ids.filter((x) => after === null || x > after).slice(0, Math.min(limit, 7)).map((id) => ({ id }));
    }, (r) => r.id, 10);
    expect(rows.map((r) => r.id)).toEqual(ids);
    expect(calls[0]).toEqual([null, 10]);
    expect(calls[1][0]).toBe('id-006');
    expect(calls.length).toBe(5);
  });
  it('stops when a page doesn\'t move forward', async () => {
    let n = 0;
    const rows = await fetchKeysetPages(async () => { n++; return [{ id: 'a' }]; }, (r) => r.id, 10);
    expect(rows).toEqual([{ id: 'a' }]);
    expect(n).toBe(2);
  });
});

describe('refusal titles', () => {
  it('says what is wrong, and asks for a rescan only for code problems', () => {
    expect(refusalView('voided')).toEqual({ title: 'Refunded', rescan: false });
    expect(refusalView('wrong-event').title).toBe('Wrong event');
    expect(refusalView('wrong-list').title).toBe('Wrong door');
    expect(refusalView('doors-not-open').title).toBe('Before doors');
    expect(refusalView('needs-manager').title).toBe('Needs a manager');
    expect(refusalView('name-needs-manager').title).toBe('Needs a manager');
    expect(refusalView('not-assigned').rescan).toBe(false);
    expect(refusalView('barcode-rejected')).toEqual({ title: 'Code rejected', rescan: true });
    expect(refusalView('bucket-expired')).toEqual({ title: 'Code expired', rescan: true });
    expect(refusalView('no-key').rescan).toBe(false);
    expect(refusalView('something-new')).toEqual({ title: 'Not admitted', rescan: false });
    expect(refusalView(null).rescan).toBe(false);
  });
});

describe('scanner scope at the door', () => {
  const events = [{ id: 'e1' }, { id: 'e2' }, { id: 'e3' }];
  it('a scoped scanner sees only the events assigned to them', () => {
    expect(assignedDoorEvents(events, 'scanner', ['e2'])).toEqual([{ id: 'e2' }]);
    expect(assignedDoorEvents(events, 'scanner', [])).toEqual(events);
    expect(assignedDoorEvents(events, 'scanner', null)).toEqual(events);
    expect(assignedDoorEvents(events, 'manager', ['e2'])).toEqual(events);
  });
  it('tells "not assigned" from "not door staff"', () => {
    expect(doorAccessProblem({ code: '42501', message: 'exos_event_door_roster: not assigned to this event' })).toBe('not-assigned');
    expect(doorAccessProblem({ code: '42501', message: 'exos_check_in_ticket: not authorized' })).toBe('not-staff');
    expect(doorAccessProblem({ ok: false, reason: 'not-assigned' })).toBe('not-assigned');
    expect(doorAccessProblem({ code: 'PGRST301' })).toBeNull();
    expect(doorAccessProblem(new TypeError('Failed to fetch'))).toBeNull();
  });
});

describe('guest arrivals offline', () => {
  const H = 60 * MIN;
  it('follow the door times: before doors refused, test window a test, cancelled refused', () => {
    expect(guestGate({ opensAt: NOW - H, testUntil: null }, NOW)).toBe('ok');
    expect(guestGate({ opensAt: NOW + H, testUntil: null }, NOW)).toBe('doors-not-open');
    expect(guestGate({ opensAt: NOW + H, testUntil: NOW + 30 * MIN }, NOW)).toBe('test');
    expect(guestGate({ opensAt: NOW + H, testUntil: NOW - MIN }, NOW)).toBe('doors-not-open');
    expect(guestGate({ opensAt: null, testUntil: null, cancelled: true }, NOW)).toBe('event-cancelled');
  });

  it('replay from the page: own arrivals only, with their scan time; not-assigned keeps them', async () => {
    const store = memStorage();
    vi.stubGlobal('localStorage', store);
    try {
      const q: PendingArrival[] = [
        { ref: 'r1', entryId: 'g1', count: 1, at: NOW - 5 * MIN, uid: U1 },
        { ref: 'r2', entryId: 'g2', count: 2, at: NOW - 4 * MIN, uid: U2 },
        { ref: 'r3', entryId: 'g3', count: 1, at: NOW - 3 * MIN },
      ];
      savePendingArrivals('e1', q);
      const seen: PendingArrival[] = [];
      const r = await replayPendingArrivals('e1', U1, async (p) => {
        seen.push(p);
        return p.ref === 'r3' ? { ok: false, reason: 'used' } : { ok: true, reason: 'checked-in' };
      });
      expect(seen.map((p) => [p.ref, p.at])).toEqual([['r1', NOW - 5 * MIN], ['r3', NOW - 3 * MIN]]);
      expect(r).toEqual({ done: 2, refused: ['used'], blocked: false });
      expect(loadPendingArrivals('e1').map((p) => p.ref)).toEqual(['r2']);

      // Signed in as U2 but not assigned to the event: kept, and blocked.
      const r2 = await replayPendingArrivals('e1', U2, async () => ({ ok: false, reason: 'not-assigned' }));
      expect(r2).toEqual({ done: 0, refused: [], blocked: true, problem: 'not-assigned' });
      expect(loadPendingArrivals('e1').map((p) => p.ref)).toEqual(['r2']);

      // Network down: kept, not blocked.
      const r3 = await replayPendingArrivals('e1', U2, async () => { throw new TypeError('Failed to fetch'); });
      expect(r3.blocked).toBe(false);
      expect(loadPendingArrivals('e1')).toHaveLength(1);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe('door summary: guests', () => {
  const raw = {
    event: { name: 'Night', timezone: 'UTC' },
    tickets: { sold: 10, checked_in: 4 },
    entries: {},
    guests: {
      entries: 4, expected: 5, arrived: 4, eventbrite_app: 1, offline: 2,
      by_source: [{ source: 'Guest list', expected: 2, arrived: 2 }, { source: 'DICE', expected: 2, arrived: 1 }, { source: 'Eventbrite', expected: 1, arrived: 1 }],
    },
  };
  it('parses guest-list, imported and Eventbrite arrivals', () => {
    const s = parseDoorSummary(raw)!;
    expect(s.guests).toEqual({
      entries: 4, expected: 5, arrived: 4, eventbriteApp: 1, offline: 2,
      bySource: [{ source: 'Guest list', expected: 2, arrived: 2 }, { source: 'DICE', expected: 2, arrived: 1 }, { source: 'Eventbrite', expected: 1, arrived: 1 }],
    });
    expect(summaryText(s)).toMatch(/Guests: 4 of 5 in \(2 offline\)\n {2}Guest list: 2 \/ 2\n {2}DICE: 1 \/ 2/);
    expect(summaryCsvRows(s)).toContainEqual(['guest_source', 'DICE', 1, 2]);
    expect(summaryCsvRows(s)).toContainEqual(['guests', 'arrived', 4, 5]);
  });
  it('no guest lists (or an older database): none', () => {
    expect(parseDoorSummary({ ...raw, guests: null })!.guests).toBeNull();
    const { guests: _g, ...older } = raw;
    expect(parseDoorSummary(older)!.guests).toBeNull();
  });
});
