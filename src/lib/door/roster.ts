// The door's offline copy: the roster (every ticket + its barcode secret),
// a small overlay of what this device changed since the download, and the
// event header the scanner needs to start with no network.
//
// Storage layout (keys all start with `registry_`, so sign-out wipes them):
//   registry_{event}         roster, { _savedAt, sealed } DoorKV (IndexedDB),
//                            AES-GCM under the device key (lib/door/kv
//                            doorCipher); { _savedAt, data } in plain text
//                            only where the browser can't encrypt. Written
//                            only when a download finishes.
//   registry_marks_{event}   { _savedAt, data: {ticketId: {patch, at}} }
//                            localStorage, small, written per scan
//   registry_event_{event}   { _savedAt, event, role }    localStorage
// The upload queue stays in pending_updates_{event} (lib/offlineCheckins).
//
// Pure helpers plus storage calls that take the store as a parameter, so the
// whole thing is unit-tested without a browser.

import { isRegistryFresh } from '../offlineCheckins';
import { parseNameCheckinMode, type DoorGate, type NameCheckinMode } from './decide';
import { DEVICE_KEY, isSealed, storageKeys, type DoorCipher, type DoorKV, type SealedBlob, type StorageLike } from './kv';
import type { DoorCheckinList, ListState } from './lists';

export const ROSTER_PAGE_SIZE = 1000;
/** Safety stop: 1000 pages of 1000 = a million tickets. */
const MAX_PAGES = 1000;
/** While the page is open and online, the roster is refreshed this often:
 *  only what changed (exos_event_checkin_roster_since, mig 20261008090000),
 *  with a full pull every ROSTER_FULL_EVERY_MS as a backstop. */
export const ROSTER_REFRESH_MS = 60_000;
export const ROSTER_FULL_EVERY_MS = 10 * 60_000;
/** A delta asks from this long before the last cursor: a write committed
 *  after the cursor by a transaction that started before it carries the
 *  earlier time. */
export const ROSTER_DELTA_OVERLAP_MS = 2 * 60_000;
/** The server refuses older cursors (7 days); stay well inside. */
const ROSTER_DELTA_MAX_AGE_MS = 24 * 60 * 60_000;

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
  /** Unclaimed ticket held on the org for its buyer (mig 20260929130000);
   *  it can be checked in by name. `name` is then the buyer's, not the org's. */
  parked?: boolean;
  /** The name the ticket was issued to, when known. */
  claimName?: string | null;
  /** The buyer's email, masked (j***@gmail.com). Never the full address. */
  claimEmailMasked?: string | null;
  /** Ticket type id (mig 20260929140000), for check-in lists offline. */
  tierId?: string | null;
  /** Last direction per re-entry list (roster list_state + this device). */
  lists?: ListState;
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
  parked?: boolean;
  claimName?: string | null;
  claimEmailMasked?: string | null;
  tierId?: string | null;
  listState?: ListState;
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
      ...(e.parked
        ? { parked: true, claimName: e.claimName ?? null, claimEmailMasked: e.claimEmailMasked ?? null }
        : {}),
      ...(e.tierId ? { tierId: e.tierId } : {}),
      ...(e.listState ? { lists: e.listState } : {}),
    };
  }
  return out;
}

/** Where incremental refreshes stand for one event, kept in memory only. */
export interface RosterSync {
  /** The event the base belongs to (a pull can finish after the page moved on). */
  eventId: string;
  /** The server roster as last pulled (no local marks or queued scans). */
  base: DoorRoster;
  /** Server time (ms) read just before the last pull started. */
  cursor: number;
  /** Device time of the last full pull. */
  fullAt: number;
  /** Lists signature at the last full pull (see listsSignature). */
  lists: string;
}

/** The parts of the check-in lists the roster depends on: which lists
 *  allow re-entry. A change there (or a list removed) needs a full pull. */
export function listsSignature(lists: DoorCheckinList[] | null | undefined): string {
  if (!lists) return '';
  return lists
    .map((l) => `${l.id}:${l.allowReentry ? 1 : 0}`)
    .sort()
    .join(',');
}

export type RosterPlan = { kind: 'full' } | { kind: 'delta'; since: number };

/** Full or incremental? Full when there is nothing to build on, the delta RPC
 *  is missing, the last full pull is old, the cursor is too old, or the
 *  re-entry lists changed. Pure. */
export function planRosterRefresh(
  sync: RosterSync | null,
  opts: { eventId: string; now: number; deltaSupported: boolean; lists: string; force?: boolean },
): RosterPlan {
  if (opts.force || !opts.deltaSupported || !sync || sync.eventId !== opts.eventId) return { kind: 'full' };
  if (opts.now - sync.fullAt >= ROSTER_FULL_EVERY_MS) return { kind: 'full' };
  if (opts.now - sync.cursor >= ROSTER_DELTA_MAX_AGE_MS) return { kind: 'full' };
  if (sync.lists !== opts.lists) return { kind: 'full' };
  return { kind: 'delta', since: sync.cursor - ROSTER_DELTA_OVERLAP_MS };
}

/** The base roster with the changed rows replaced or added. */
export function mergeRosterDelta(base: DoorRoster, changed: RosterRow[]): DoorRoster {
  if (changed.length === 0) return base;
  return { ...base, ...buildRoster(changed) };
}

export interface StoredRoster {
  _savedAt: number;
  data: DoorRoster;
}

/** What is written to the store when the device can encrypt. */
interface SealedRoster {
  _savedAt: number;
  sealed: SealedBlob;
}

/** How the saved list is kept on this device (the scanner warns on plain). */
export type RosterProtection = 'encrypted' | 'plaintext';

/** A stored roster, or null when missing, malformed or past its TTL. Older
 *  builds stored a bare Record<id, entry> with no timestamp: stale by
 *  definition. (A sealed roster is opened by loadRoster.) */
export function parseStoredRoster(raw: unknown, now: number): StoredRoster | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Partial<StoredRoster>;
  if (!isRegistryFresh(r._savedAt, now) || !r.data || typeof r.data !== 'object') return null;
  return { _savedAt: r._savedAt as number, data: r.data };
}

function parseSealedRoster(raw: unknown, now: number): SealedRoster | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Partial<SealedRoster>;
  if (!isRegistryFresh(r._savedAt, now) || !isSealed(r.sealed)) return null;
  return { _savedAt: r._savedAt as number, sealed: r.sealed };
}

/** Load this event's roster: the door store first, then a copy an older build
 *  left in localStorage (moved into the store). Stale copies are deleted.
 *  With a cipher, a sealed copy is opened and a plain-text one (saved before
 *  encryption, or where it wasn't available) is sealed in place. A copy this
 *  device can't open (another key) is dropped: the next download replaces it. */
export async function loadRoster(
  kv: DoorKV,
  legacy: StorageLike | null,
  eventId: string,
  now: number,
  cipher: DoorCipher | null = null,
): Promise<StoredRoster | null> {
  const key = rosterKey(eventId);
  const raw = await kv.get(key);
  const sealed = parseSealedRoster(raw, now);
  if (sealed) {
    if (cipher) {
      try {
        const data = await cipher.open<DoorRoster>(sealed.sealed);
        if (data && typeof data === 'object') return { _savedAt: sealed._savedAt, data };
      } catch (err) {
        console.warn('door cache: the saved list could not be decrypted on this device', err);
      }
    }
    await kv.del(key);
    return null;
  }
  const stored = parseStoredRoster(raw, now);
  if (stored) {
    if (cipher) await saveRoster(kv, eventId, stored.data, stored._savedAt, cipher);
    return stored;
  }
  await kv.del(key);
  let old: StoredRoster | null = null;
  try {
    const rawOld = legacy?.getItem(key);
    if (rawOld) {
      old = parseStoredRoster(JSON.parse(rawOld), now);
      legacy?.removeItem(key);
    }
  } catch {
    try {
      legacy?.removeItem(key);
    } catch {
      /* storage blocked */
    }
  }
  if (old) await saveRoster(kv, eventId, old.data, old._savedAt, cipher);
  return old;
}

export async function saveRoster(
  kv: DoorKV,
  eventId: string,
  data: DoorRoster,
  now: number,
  cipher: DoorCipher | null = null,
): Promise<boolean> {
  if (cipher) {
    try {
      return await kv.set(rosterKey(eventId), { _savedAt: now, sealed: await cipher.seal(data) } satisfies SealedRoster);
    } catch (err) {
      console.warn('door cache: sealing the list failed; it is not saved', err);
      return false;
    }
  }
  return kv.set(rosterKey(eventId), { _savedAt: now, data } satisfies StoredRoster);
}

/** Drop rosters (any event) past their TTL. */
export async function pruneRosters(kv: DoorKV, now: number): Promise<void> {
  for (const k of await kv.keys('registry_')) {
    if (k.startsWith('registry_marks_') || k.startsWith('registry_event_')) continue;
    const raw = await kv.get(k);
    if (!parseStoredRoster(raw, now) && !parseSealedRoster(raw, now)) await kv.del(k);
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
  /** door_name_checkin (mig 20260929130000), saved with the header so the
   *  door knows offline whether name check-in is allowed. null = the
   *  database doesn't have the column yet. */
  nameCheckin: NameCheckinMode | null;
  /** The event's check-in lists (mig 20260929140000), saved with the header
   *  so the picker works offline. [] = none (the implicit everyone-once
   *  list); null = the database doesn't have lists yet (old RPCs only). */
  checkinLists?: DoorCheckinList[] | null;
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
    nameCheckin: parseNameCheckinMode(row.door_name_checkin),
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

/** Sign-out: the roster holds every ticket's barcode secret. The device key
 *  goes too (a new one is made on the next download). */
export async function wipeDoorRosters(kv: DoorKV): Promise<void> {
  for (const k of await kv.keys('registry_')) await kv.del(k);
  await kv.del(DEVICE_KEY);
}
