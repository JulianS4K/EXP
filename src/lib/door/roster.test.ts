import { describe, it, expect, vi } from 'vitest';
import { REGISTRY_TTL_MS } from '../offlineCheckins';
import { localStorageKV, type StorageLike } from './kv';
import {
  addMark,
  applyMarks,
  buildRoster,
  doorGate,
  fetchAllPages,
  loadDoorEvent,
  loadMarks,
  loadRoster,
  mapDoorEventRow,
  marksSince,
  pruneLocalDoorCaches,
  pruneRosters,
  rosterKey,
  saveDoorEvent,
  saveMarks,
  saveRoster,
  wipeDoorRosters,
  listsSignature,
  mergeRosterDelta,
  planRosterRefresh,
  ROSTER_DELTA_OVERLAP_MS,
  ROSTER_FULL_EVERY_MS,
  type RosterRow,
  type RosterSync,
} from './roster';
import type { DoorCheckinList } from './lists';

const NOW = Date.UTC(2026, 8, 29, 22, 0, 0);
const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';

class MemStorage implements StorageLike {
  m = new Map<string, string>();
  failWrites = false;
  get length() {
    return this.m.size;
  }
  key(i: number) {
    return [...this.m.keys()][i] ?? null;
  }
  getItem(k: string) {
    return this.m.has(k) ? (this.m.get(k) as string) : null;
  }
  setItem(k: string, v: string) {
    if (this.failWrites) throw new Error('QuotaExceededError');
    this.m.set(k, v);
  }
  removeItem(k: string) {
    this.m.delete(k);
  }
}

const row = (i: number, over: Partial<RosterRow> = {}): RosterRow => ({
  id: `t-${String(i).padStart(6, '0')}`,
  status: 'active',
  ownerId: 'o',
  name: `Guest ${i}`,
  tier: 'GA',
  barcodeSecret: 's',
  promoterId: '',
  pendingTransferId: null,
  ...over,
});

/** A server holding `total` rows that caps every response at `cap`. */
function pagedServer(total: number, cap = Infinity) {
  const all = Array.from({ length: total }, (_, i) => row(i));
  const calls: [number, number][] = [];
  const fetchPage = vi.fn(async (from: number, to: number) => {
    calls.push([from, to]);
    return all.slice(from, Math.min(to + 1, from + cap));
  });
  return { all, calls, fetchPage };
}

describe('fetchAllPages', () => {
  it('pulls every page of an event bigger than one page', async () => {
    const s = pagedServer(2_500);
    const rows = await fetchAllPages(s.fetchPage, (r) => r.id, 1000);
    expect(rows).toHaveLength(2_500);
    expect(s.calls).toEqual([[0, 999], [1000, 1999], [2000, 2999], [2500, 3499]]);
  });

  it('is not truncated by a server row cap smaller than the page size', async () => {
    const s = pagedServer(2_300, 500);
    const rows = await fetchAllPages(s.fetchPage, (r) => r.id, 1000);
    expect(rows).toHaveLength(2_300);
    expect(new Set(rows.map((r) => r.id)).size).toBe(2_300);
  });

  it('exactly one full page still ends with an empty page', async () => {
    const s = pagedServer(1_000);
    expect(await fetchAllPages(s.fetchPage, (r) => r.id, 1000)).toHaveLength(1_000);
    expect(s.fetchPage).toHaveBeenCalledTimes(2);
  });

  it('an empty event is one call', async () => {
    const s = pagedServer(0);
    expect(await fetchAllPages(s.fetchPage, (r) => r.id, 1000)).toEqual([]);
    expect(s.fetchPage).toHaveBeenCalledTimes(1);
  });

  it('stops when the server ignores the range and sends everything', async () => {
    const all = Array.from({ length: 1_500 }, (_, i) => row(i));
    const fetchPage = vi.fn(async () => all);
    expect(await fetchAllPages(fetchPage, (r) => r.id, 1000)).toHaveLength(1_500);
    expect(fetchPage).toHaveBeenCalledTimes(1);
  });

  it('de-duplicates a row that shifted between pages', async () => {
    const pages = [[row(0), row(1)], [row(1), row(2)], []];
    const rows = await fetchAllPages(async () => pages.shift() ?? [], (r) => r.id, 2);
    expect(rows.map((r) => r.id)).toEqual(['t-000000', 't-000001', 't-000002']);
  });

  it('a failed page fails the whole download (the old copy stays in use)', async () => {
    const fetchPage = vi.fn(async (from: number) => {
      if (from > 0) throw new Error('network');
      return [row(0), row(1)];
    });
    await expect(fetchAllPages(fetchPage, (r) => r.id, 2)).rejects.toThrow('network');
  });
});

describe('buildRoster', () => {
  it('maps statuses and the transfer lock', () => {
    const r = buildRoster([row(1, { status: 'used' }), row(2, { status: 'voided' }), row(3, { pendingTransferId: 'tr' })]);
    expect(r['t-000001']).toMatchObject({ used: true, voided: false });
    expect(r['t-000002']).toMatchObject({ used: false, voided: true });
    expect(r['t-000003'].pendingTransferId).toBe('tr');
  });

  it('carries the unclaimed-ticket fields for parked tickets only', () => {
    const r = buildRoster([
      row(1, { pendingTransferId: 'tr', parked: true, claimName: 'Jane Doe', claimEmailMasked: 'j***@gmail.com' }),
      row(2, { parked: false, claimName: 'ignored' }),
    ]);
    expect(r['t-000001']).toMatchObject({ parked: true, claimName: 'Jane Doe', claimEmailMasked: 'j***@gmail.com' });
    expect(r['t-000002'].parked).toBeUndefined();
    expect(r['t-000002'].claimName).toBeUndefined();
  });
});

describe('roster storage', () => {
  it('round-trips through the store', async () => {
    const kv = localStorageKV(new MemStorage());
    const data = buildRoster([row(1)]);
    expect(await saveRoster(kv, EVENT, data, NOW)).toBe(true);
    expect(await loadRoster(kv, null, EVENT, NOW + 1000)).toEqual({ _savedAt: NOW, data });
  });

  it('drops a copy past its TTL', async () => {
    const mem = new MemStorage();
    const kv = localStorageKV(mem);
    await saveRoster(kv, EVENT, buildRoster([row(1)]), NOW);
    expect(await loadRoster(kv, null, EVENT, NOW + REGISTRY_TTL_MS + 1)).toBeNull();
    expect(mem.getItem(rosterKey(EVENT))).toBeNull();
  });

  it('moves a copy an older build left in localStorage into the store', async () => {
    const legacy = new MemStorage();
    const data = buildRoster([row(1)]);
    legacy.setItem(rosterKey(EVENT), JSON.stringify({ _savedAt: NOW, data }));
    const store = new MemStorage();
    const kv = localStorageKV(store);
    expect(await loadRoster(kv, legacy, EVENT, NOW)).toEqual({ _savedAt: NOW, data });
    expect(legacy.getItem(rosterKey(EVENT))).toBeNull();
    expect(JSON.parse(store.getItem(rosterKey(EVENT)) as string).data).toEqual(data);
  });

  it('ignores corrupt or old-format copies', async () => {
    const legacy = new MemStorage();
    legacy.setItem(rosterKey(EVENT), '{not json');
    expect(await loadRoster(localStorageKV(new MemStorage()), legacy, EVENT, NOW)).toBeNull();
    legacy.setItem(rosterKey(EVENT), JSON.stringify({ 't-1': { used: false } }));
    expect(await loadRoster(localStorageKV(new MemStorage()), legacy, EVENT, NOW)).toBeNull();
  });

  it('a full or blocked store reports failure instead of throwing', async () => {
    const mem = new MemStorage();
    mem.failWrites = true;
    expect(await saveRoster(localStorageKV(mem), EVENT, buildRoster([row(1)]), NOW)).toBe(false);
    expect(await loadRoster(localStorageKV(null), null, EVENT, NOW)).toBeNull();
  });

  it('prunes stale rosters and wipes all on sign-out', async () => {
    const mem = new MemStorage();
    const kv = localStorageKV(mem);
    await saveRoster(kv, 'old', {}, NOW - REGISTRY_TTL_MS - 1);
    await saveRoster(kv, EVENT, {}, NOW);
    await pruneRosters(kv, NOW);
    expect(await kv.keys('registry_')).toEqual([rosterKey(EVENT)]);
    await wipeDoorRosters(kv);
    expect(await kv.keys('registry_')).toEqual([]);
  });
});

describe('local marks (per-scan writes)', () => {
  it('overlay the roster without rewriting it', () => {
    const roster = buildRoster([row(1), row(2)]);
    let marks = addMark({}, 't-000001', { used: true }, NOW);
    marks = addMark(marks, 't-000001', { pendingTransferId: null }, NOW + 1);
    marks = addMark(marks, 'not-on-list', { used: true }, NOW);
    const merged = applyMarks(roster, marks);
    expect(merged['t-000001']).toMatchObject({ used: true, pendingTransferId: null });
    expect(merged['t-000002'].used).toBe(false);
    expect(merged['not-on-list']).toBeUndefined();
    expect(roster['t-000001'].used).toBe(false);
  });

  it('marks older than a fresh download are dropped', () => {
    const marks = addMark(addMark({}, 'a', { used: true }, NOW - 5), 'b', { used: true }, NOW + 5);
    expect(Object.keys(marksSince(marks, NOW))).toEqual(['b']);
  });

  it('save and load, tolerating a broken store', () => {
    const mem = new MemStorage();
    const marks = addMark({}, 'a', { used: true }, NOW);
    expect(saveMarks(mem, EVENT, marks, NOW)).toBe(true);
    expect(loadMarks(mem, EVENT, NOW)).toEqual(marks);
    expect(loadMarks(mem, EVENT, NOW + REGISTRY_TTL_MS + 1)).toEqual({});
    mem.failWrites = true;
    expect(saveMarks(mem, EVENT, marks, NOW)).toBe(false);
    expect(loadMarks(null, EVENT, NOW)).toEqual({});
  });
});

describe('event header cache (offline cold start)', () => {
  const ev = mapDoorEventRow({
    id: EVENT, name: 'Night One', org_id: 'org-1', status: 'published', timezone: 'America/New_York',
    starts_at: '2026-09-30T01:00:00Z', doors_at: '2026-09-30T00:00:00Z', ends_at: null,
    total_tickets: 500, tickets_sold: 312, checkin_test_mode: true, checkin_test_until: '2026-09-29T23:00:00Z',
    door_name_checkin: 'managers',
  });

  it('maps the row, with tickets sold separate from capacity', () => {
    expect(ev).toMatchObject({ title: 'Night One', orgId: 'org-1', totalTickets: 500, ticketsSold: 312, checkinTestMode: true });
  });

  it('keeps the name check-in setting (null before the column exists)', () => {
    expect(ev.nameCheckin).toBe('managers');
    expect(mapDoorEventRow({ id: EVENT, name: 'x' }).nameCheckin).toBeNull();
    expect(mapDoorEventRow({ id: EVENT, name: 'x', door_name_checkin: 'bogus' }).nameCheckin).toBeNull();
  });

  it('saves and loads with the door role; expires with the roster', () => {
    const mem = new MemStorage();
    expect(saveDoorEvent(mem, ev, 'manager', NOW)).toBe(true);
    expect(loadDoorEvent(mem, EVENT, NOW + 1)).toEqual({ _savedAt: NOW, event: ev, role: 'manager' });
    expect(loadDoorEvent(mem, 'other', NOW)).toBeNull();
    expect(loadDoorEvent(mem, EVENT, NOW + REGISTRY_TTL_MS + 1)).toBeNull();
  });

  it('gives the doors gate as the server applies it', () => {
    expect(doorGate(ev)).toEqual({
      opensAt: Date.parse('2026-09-30T00:00:00Z'),
      testUntil: Date.parse('2026-09-29T23:00:00Z'),
      cancelled: false,
    });
    expect(doorGate({ ...ev, doorsAt: null }).opensAt).toBe(Date.parse('2026-09-30T01:00:00Z'));
    expect(doorGate({ ...ev, checkinTestMode: false }).testUntil).toBeNull();
    expect(doorGate({ ...ev, status: 'cancelled' }).cancelled).toBe(true);
    expect(doorGate(null)).toEqual({ opensAt: null, testUntil: null });
  });

  it('prunes stale localStorage door caches', () => {
    const mem = new MemStorage();
    saveDoorEvent(mem, ev, null, NOW - REGISTRY_TTL_MS - 1);
    saveMarks(mem, EVENT, addMark({}, 'a', { used: true }, NOW), NOW);
    mem.setItem('registry_junk', 'nope');
    mem.setItem('pending_updates_x', '[]');
    pruneLocalDoorCaches(mem, NOW);
    expect([...mem.m.keys()].sort()).toEqual(['pending_updates_x', `registry_marks_${EVENT}`]);
  });
});

describe('incremental refresh (roster delta)', () => {
  const rowOf = (id: string, status = 'active'): RosterRow => ({
    id, status, ownerId: 'o', name: id.toUpperCase(), tier: 'GA', barcodeSecret: `s-${id}`, promoterId: '', pendingTransferId: null,
  });
  const T0 = 1_800_000_000_000;
  const sync = (over: Partial<RosterSync> = {}): RosterSync => ({
    base: buildRoster([rowOf('a'), rowOf('b')]), cursor: T0, fullAt: T0, lists: '', ...over,
  });

  it('plans a delta from the cursor minus the overlap', () => {
    expect(planRosterRefresh(sync(), { now: T0 + 60_000, deltaSupported: true, lists: '' })).toEqual({
      kind: 'delta', since: T0 - ROSTER_DELTA_OVERLAP_MS,
    });
  });

  it('plans a full pull when it must', () => {
    const now = T0 + 60_000;
    expect(planRosterRefresh(null, { now, deltaSupported: true, lists: '' }).kind).toBe('full');
    expect(planRosterRefresh(sync(), { now, deltaSupported: false, lists: '' }).kind).toBe('full');
    expect(planRosterRefresh(sync(), { now, deltaSupported: true, lists: '', force: true }).kind).toBe('full');
    expect(planRosterRefresh(sync(), { now: T0 + ROSTER_FULL_EVERY_MS, deltaSupported: true, lists: '' }).kind).toBe('full');
    expect(planRosterRefresh(sync(), { now, deltaSupported: true, lists: 'l1:1' }).kind).toBe('full');
    // A delta keeps the full-pull clock: ten minutes after the last FULL pull.
    expect(
      planRosterRefresh(sync({ cursor: T0 + 9 * 60_000 }), { now: T0 + ROSTER_FULL_EVERY_MS + 1, deltaSupported: true, lists: '' }).kind,
    ).toBe('full');
    expect(planRosterRefresh(sync({ fullAt: T0 + 1e10 }), { now: T0 + 25 * 3600_000, deltaSupported: true, lists: '' }).kind).toBe('full');
  });

  it('lists signature tracks re-entry switches, not names or order', () => {
    const l = (id: string, allowReentry: boolean) => ({ id, allowReentry }) as unknown as DoorCheckinList;
    expect(listsSignature(null)).toBe('');
    expect(listsSignature([l('b', false), l('a', true)])).toBe(listsSignature([l('a', true), l('b', false)]));
    expect(listsSignature([l('a', true)])).not.toBe(listsSignature([l('a', false)]));
    expect(listsSignature([l('a', true), l('b', false)])).not.toBe(listsSignature([l('a', true)]));
  });

  it('merges changed rows over the base', () => {
    const base = sync().base;
    expect(mergeRosterDelta(base, [])).toBe(base);
    const next = mergeRosterDelta(base, [rowOf('b', 'used'), rowOf('c')]);
    expect(Object.keys(next).sort()).toEqual(['a', 'b', 'c']);
    expect(next.a).toBe(base.a);
    expect(next.b.used).toBe(true);
    expect(next.c.barcodeSecret).toBe('s-c');
    expect(base.b.used).toBe(false);
  });
});
