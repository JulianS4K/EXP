// The door's offline copy: the roster (every ticket + its barcode secret),
// a small overlay of what this device changed since the download, and the
// event header the scanner needs to start with no network.
//
// Storage layout (keys all start with `registry_`, so sign-out wipes them):
//   registry_{event}         roster, { _savedAt, data }   DoorKV (IndexedDB)
//                            written only when a download finishes
//   registry_marks_{event}   { _savedAt, data: {ticketId: {patch, at}} }
//                            localStorage, small, written per scan
//   registry_event_{event}   { _savedAt, event, role }    localStorage
// The upload queue stays in pending_updates_{event} (lib/offlineCheckins).
//
// Pure helpers plus storage calls that take the store as a parameter, so the
// whole thing is unit-tested without a browser.

import { isRegistryFresh } from '../offlineCheckins';
import type { DoorGate } from './decide';
import { storageKeys, type DoorKV, type StorageLike } from './kv';

export const ROSTER_PAGE_SIZE = 1000;
/** Safety stop: 1000 pages of 1000 = a million tickets. */
const MAX_PAGES = 1000;
/** While the page is open and online, the roster is re-pulled this often. */
export const ROSTER_REFRESH_MS = 60_000;

export const rosterKey = (eventId: string) => `registry_${eventId}`;
export const marksKey = (eventId: string) => `registry_marks_${eventId}`;
export const eventKey = (eventId: string) => `registry_event_${eventId}`;

/** Fetch every page of a range-paged read. Pages are requested until one
 *  comes back empty, so a server row cap smaller than `pageSize` (PostgREST
 *  max_rows) can't silently truncate the list. A page larger than asked means
 *  the server ignored the range and returned everything: that's the whole list.
 *  Rows are de-duplicated by `keyOf` (a sale between two pages can shift one). */
export async function fetchAllPages<T>(
  fetchPage: (from: number, to: number) => Promise<T[]>,
  keyOf: (row: T) => string,
  pageSize: number = ROSTER_PAGE_SIZE,
): Promise<T[]> {
  const seen = new Map<string, T>();
  let from = 0;
  for (let i = 0; i < MAX_PAGES; i++) {
    const page = await fetchPage(from, from + pageSize - 1);
    if (!page || page.length === 0) break;
    for (const row of page) seen.set(keyOf(row), row);
    if (page.length > pageSize) break;
    from += page.length;
  }
  return [...seen.values()];
}

export interface DoorRosterEntry {
  used: boolean;
  voided?: boolean;
  name: string;
  tier: string;
  ownerId?: string;
  barcodeSecret?: string;
  promoterId?: string;
  /** Pending-transfer lock: the offline path refuses while it's set. */
  pendingTransferId?: string | null;
}

export type DoorRoster = Record<string, DoorRosterEntry>;

export interface RosterRow {
  id: string;
  status: string;
  ownerId: string;
  name: string;
  tier: string;
  barcodeSecret: string;
  promoterId: string;
  pendingTransferId: string | null;
}

export function buildRoster(rows: RosterRow[]): DoorRoster {
  const out: DoorRoster = {};
  for (const e of rows) {
    out[e.id] = {
      used: e.status === 'used',
      voided: e.status === 'voided',
      name: e.name,
      tier: e.tier,
      ownerId: e.ownerId,
      barcodeSecret: e.barcodeSecret,
      promoterId: e.promoterId,
      pendingTransferId: e.pendingTransferId,
    };
  }
  return out;
}

export interface StoredRoster {
  _savedAt: number;
  data: DoorRoster;
}

/** A stored roster, or null when missing, malformed or past its TTL. Older
 *  builds stored a bare Record<id, entry> with no timestamp: stale by
 *  definition. */
export function parseStoredRoster(raw: unknown, now: number): StoredRoster | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Partial<StoredRoster>;
  if (!isRegistryFresh(r._savedAt, now) || !r.data || typeof r.data !== 'object') return null;
  return { _savedAt: r._savedAt as number, data: r.data };
}

/** Load this event's roster: the door store first, then a copy an older build
 *  left in localStorage (moved into the store). Stale copies are deleted. */
export async function loadRoster(
  kv: DoorKV,
  legacy: StorageLike | null,
  eventId: string,
  now: number,
): Promise<StoredRoster | null> {
  const key = rosterKey(eventId);
  const stored = parseStoredRoster(await kv.get(key), now);
  if (stored) return stored;
  await kv.del(key);
  let old: StoredRoster | null = null;
  try {
    const raw = legacy?.getItem(key);
    if (raw) {
      old = parseStoredRoster(JSON.parse(raw), now);
      legacy?.removeItem(key);
    }
  } catch {
    try {
      legacy?.removeItem(key);
    } catch {
      /* storage blocked */
    }
  }
  if (old) await kv.set(key, old);
  return old;
}

export async function saveRoster(kv: DoorKV, eventId: string, data: DoorRoster, now: number): Promise<boolean> {
  return kv.set(rosterKey(eventId), { _savedAt: now, data } satisfies StoredRoster);
}

/** Drop rosters (any event) past their TTL. */
export async function pruneRosters(kv: DoorKV, now: number): Promise<void> {
  for (const k of await kv.keys('registry_')) {
    if (k.startsWith('registry_marks_') || k.startsWith('registry_event_')) continue;
    if (!parseStoredRoster(await kv.get(k), now)) await kv.del(k);
  }
}

// --- Local marks: what this device learned since the download ---------------

export interface RosterMark {
  patch: Partial<DoorRosterEntry>;
  at: number;
}
export type RosterMarks = Record<string, RosterMark>;

export function addMark(marks: RosterMarks, ticketId: string, patch: Partial<DoorRosterEntry>, at: number): RosterMarks {
  const prev = marks[ticketId];
  return { ...marks, [ticketId]: { patch: { ...(prev?.patch ?? {}), ...patch }, at } };
}

/** Marks made at or after `since` (older ones are in the fresh download). */
export function marksSince(marks: RosterMarks, since: number): RosterMarks {
  const out: RosterMarks = {};
  for (const [id, m] of Object.entries(marks)) if (m.at >= since) out[id] = m;
  return out;
}

export function applyMarks(roster: DoorRoster, marks: RosterMarks): DoorRoster {
  const ids = Object.keys(marks).filter((id) => roster[id]);
  if (ids.length === 0) return roster;
  const out = { ...roster };
  for (const id of ids) out[id] = { ...out[id], ...marks[id].patch };
  return out;
}

export function loadMarks(storage: StorageLike | null, eventId: string, now: number): RosterMarks {
  try {
    const raw = storage?.getItem(marksKey(eventId));
    if (!raw) return {};
    const p = JSON.parse(raw);
    if (!p || !isRegistryFresh(p._savedAt, now) || !p.data || typeof p.data !== 'object') return {};
    return p.data as RosterMarks;
  } catch {
    return {};
  }
}

export function saveMarks(storage: StorageLike | null, eventId: string, marks: RosterMarks, now: number): boolean {
  if (!storage) return false;
  try {
    if (Object.keys(marks).length === 0) storage.removeItem(marksKey(eventId));
    else storage.setItem(marksKey(eventId), JSON.stringify({ _savedAt: now, data: marks }));
    return true;
  } catch {
    return false;
  }
}

// --- Event header ------------------------------------------------------------

/** What the scanner needs about the event, cached so it starts offline. */
export interface DoorEvent {
  id: string;
  title: string;
  orgId: string;
  status: string;
  timezone?: string;
  currency?: string;
  startsAt: string | null;
  doorsAt: string | null;
  endsAt: string | null;
  totalTickets: number;
  ticketsSold: number;
  checkinTestMode: boolean;
  checkinTestUntil: string | null;
}

export function mapDoorEventRow(row: Record<string, unknown>): DoorEvent {
  const s = (v: unknown) => (typeof v === 'string' && v ? v : null);
  return {
    id: String(row.id),
    title: String(row.name ?? ''),
    orgId: String(row.org_id ?? ''),
    status: s(row.status) ?? 'published',
    timezone: s(row.timezone) ?? undefined,
    currency: s(row.currency) ?? undefined,
    startsAt: s(row.starts_at),
    doorsAt: s(row.doors_at),
    endsAt: s(row.ends_at),
    totalTickets: Number(row.total_tickets ?? 0) || 0,
    ticketsSold: Number(row.tickets_sold ?? 0) || 0,
    checkinTestMode: row.checkin_test_mode === true,
    checkinTestUntil: s(row.checkin_test_until),
  };
}

const ms = (iso: string | null) => {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
};

/** The doors gate as the server applies it: coalesce(doors_at, starts_at),
 *  lifted before doors only while test mode is on and not expired. */
export function doorGate(ev: DoorEvent | null): DoorGate {
  if (!ev) return { opensAt: null, testUntil: null };
  return {
    opensAt: ms(ev.doorsAt) ?? ms(ev.startsAt),
    testUntil: ev.checkinTestMode ? ms(ev.checkinTestUntil) : null,
    cancelled: ev.status === 'cancelled',
  };
}

export interface CachedDoorEvent {
  _savedAt: number;
  event: DoorEvent;
  /** The caller's door role in the event's org (a UI hint; the server re-checks). */
  role: string | null;
}

/** The header is kept as long as the roster. */
export function saveDoorEvent(storage: StorageLike | null, event: DoorEvent, role: string | null, now: number): boolean {
  if (!storage) return false;
  try {
    storage.setItem(eventKey(event.id), JSON.stringify({ _savedAt: now, event, role } satisfies CachedDoorEvent));
    return true;
  } catch {
    return false;
  }
}

export function loadDoorEvent(storage: StorageLike | null, eventId: string, now: number): CachedDoorEvent | null {
  try {
    const raw = storage?.getItem(eventKey(eventId));
    if (!raw) return null;
    const p = JSON.parse(raw) as CachedDoorEvent;
    if (!p || !isRegistryFresh(p._savedAt, now) || !p.event || p.event.id !== eventId) return null;
    return { _savedAt: p._savedAt, event: p.event, role: typeof p.role === 'string' ? p.role : null };
  } catch {
    return null;
  }
}

/** Drop stale marks / headers (and old-format rosters) left in localStorage. */
export function pruneLocalDoorCaches(storage: StorageLike | null, now: number): void {
  const stale: string[] = [];
  for (const k of storageKeys(storage, 'registry_')) {
    try {
      const p = JSON.parse(storage?.getItem(k) ?? 'null');
      if (!p || typeof p !== 'object' || !isRegistryFresh(p._savedAt, now)) stale.push(k);
    } catch {
      stale.push(k);
    }
  }
  for (const k of stale) {
    try {
      storage?.removeItem(k);
    } catch {
      /* storage blocked */
    }
  }
}

/** Sign-out: the roster holds every ticket's barcode secret. */
export async function wipeDoorRosters(kv: DoorKV): Promise<void> {
  for (const k of await kv.keys('registry_')) await kv.del(k);
}
