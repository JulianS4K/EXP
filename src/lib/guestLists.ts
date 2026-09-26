// Guest lists (mig 20260926050000) — PURE model: counts, cap math, door
// search, partial arrivals and the offline pending-arrival queue. No Supabase
// import (RPC wrappers + local cache: ./guestListsApi).
//
// A party is the guest plus their plus-ones. Caps count heads (party sizes).
// The door checks in any number of a party at a time; the total never goes
// past 1 + plus-ones.

export interface GuestEntry {
  id: string;
  listId: string;
  guestName: string;
  plusOnes: number;
  arrived: number;
  arrivedAt: string | null;
  note: string | null;
  email?: string | null;
  phone?: string | null;
}

export interface GuestListMeta {
  id: string;
  name: string;
  cap: number | null;
  status: 'open' | 'closed';
  promoter: string | null;
}

export const MAX_GUEST_NAME = 80;

export function mapGuestEntry(r: any): GuestEntry {
  return {
    id: String(r.id),
    listId: String(r.list_id),
    guestName: String(r.guest_name ?? ''),
    plusOnes: Number(r.plus_ones) || 0,
    arrived: Number(r.arrived) || 0,
    arrivedAt: r.arrived_at ?? null,
    note: r.note ?? null,
    email: r.email ?? null,
    phone: r.phone ?? null,
  };
}

export function mapGuestListMeta(r: any): GuestListMeta {
  return {
    id: String(r.id),
    name: String(r.name ?? ''),
    cap: r.cap != null ? Number(r.cap) : null,
    status: r.status === 'closed' ? 'closed' : 'open',
    promoter: r.promoter ?? null,
  };
}

export const partySize = (e: Pick<GuestEntry, 'plusOnes'>): number => 1 + Math.max(0, e.plusOnes);
export const remainingFor = (e: Pick<GuestEntry, 'plusOnes' | 'arrived'>): number =>
  Math.max(0, partySize(e) - e.arrived);

export interface ListCounts {
  entries: number;
  heads: number;
  arrived: number;
}

export function listCounts(entries: GuestEntry[]): ListCounts {
  let heads = 0;
  let arrived = 0;
  for (const e of entries) {
    heads += partySize(e);
    arrived += e.arrived;
  }
  return { entries: entries.length, heads, arrived };
}

/** Counts per list id (lists with no entries included when given). */
export function countsByList(entries: GuestEntry[], listIds: string[] = []): Record<string, ListCounts> {
  const out: Record<string, ListCounts> = {};
  for (const id of listIds) out[id] = { entries: 0, heads: 0, arrived: 0 };
  for (const e of entries) {
    const c = (out[e.listId] ??= { entries: 0, heads: 0, arrived: 0 });
    c.entries += 1;
    c.heads += partySize(e);
    c.arrived += e.arrived;
  }
  return out;
}

/** Spots left under a cap (null = no cap). */
export function capLeft(cap: number | null, entries: GuestEntry[]): number | null {
  if (cap == null) return null;
  return Math.max(0, cap - listCounts(entries).heads);
}

export function validateGuestInput(
  input: { guestName: string; plusOnes: number; email?: string; phone?: string },
  opts: { maxPlusOnes: number; capLeft?: number | null; currentHeads?: number },
): string | null {
  const name = (input.guestName ?? '').trim();
  if (!name) return 'Add the guest’s name.';
  if (name.length > MAX_GUEST_NAME) return `Keep the name under ${MAX_GUEST_NAME} characters.`;
  const p = input.plusOnes;
  if (!Number.isInteger(p) || p < 0) return 'Plus-ones must be 0 or more.';
  if (p > opts.maxPlusOnes) return `This list allows up to ${opts.maxPlusOnes} plus-one${opts.maxPlusOnes === 1 ? '' : 's'}.`;
  const email = (input.email ?? '').trim();
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return 'That email doesn’t look right.';
  const phone = (input.phone ?? '').trim();
  if (phone && !/^[0-9+() .-]{3,32}$/.test(phone)) return 'That phone number doesn’t look right.';
  if (opts.capLeft != null && 1 + p - (opts.currentHeads ?? 0) > opts.capLeft) {
    return opts.capLeft === 0 ? 'The list is full.' : `Only ${opts.capLeft} spot${opts.capLeft === 1 ? '' : 's'} left.`;
  }
  return null;
}

/** Lowercase, strip accents, collapse spaces: "  José  Núñez" → "jose nunez". */
export function normalizeForSearch(s: string): string {
  return (s ?? '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Door search. Every word typed must start a word of the name ("ana r" finds
 * "Ana Ruiz"; "ruiz" finds it too). Names starting with the query rank first,
 * then alphabetical. Empty query → everyone, alphabetical.
 */
export function searchGuests(entries: GuestEntry[], query: string, limit = 50): GuestEntry[] {
  const q = normalizeForSearch(query);
  const byName = (a: GuestEntry, b: GuestEntry) => a.guestName.localeCompare(b.guestName);
  if (!q) return [...entries].sort(byName).slice(0, limit);
  const qTokens = q.split(' ');
  const scored: { e: GuestEntry; rank: number }[] = [];
  for (const e of entries) {
    const n = normalizeForSearch(e.guestName);
    const words = n.split(' ');
    const hit = qTokens.every((t) => words.some((w) => w.startsWith(t)));
    if (!hit) continue;
    scored.push({ e, rank: n.startsWith(q) ? 0 : 1 });
  }
  scored.sort((a, b) => a.rank - b.rank || byName(a.e, b.e));
  return scored.slice(0, limit).map((s) => s.e);
}

export type ArrivalRefusal = 'over' | 'used' | 'bad-count';

export interface ArrivalResult {
  ok: boolean;
  /** Set when ok. */
  entry?: GuestEntry;
  /** Set when refused. */
  reason?: ArrivalRefusal;
  remaining: number;
}

/** Local (offline-first) arrival: same rule the server applies. */
export function applyArrival(e: GuestEntry, count: number, nowIso = new Date().toISOString()): ArrivalResult {
  const left = remainingFor(e);
  if (!Number.isInteger(count) || count < 1) return { ok: false, reason: 'bad-count', remaining: left };
  if (left === 0) return { ok: false, reason: 'used', remaining: 0 };
  if (count > left) return { ok: false, reason: 'over', remaining: left };
  const next = { ...e, arrived: e.arrived + count, arrivedAt: e.arrivedAt ?? nowIso };
  return { ok: true, entry: next, remaining: left - count };
}

/** An arrival recorded at the door but not yet confirmed by the server. */
export interface PendingArrival {
  ref: string; // client_ref (uuid) — makes the replay idempotent server-side
  entryId: string;
  count: number;
  at: number;
}

export function enqueueArrival(queue: PendingArrival[], p: PendingArrival): PendingArrival[] {
  if (queue.some((q) => q.ref === p.ref)) return queue;
  return [...queue, p];
}

export function dropFromQueue(queue: PendingArrival[], refs: string[]): PendingArrival[] {
  const done = new Set(refs);
  return queue.filter((q) => !done.has(q.ref));
}

/** Re-apply still-pending arrivals on top of a fresh server download. */
export function overlayPending(entries: GuestEntry[], queue: PendingArrival[]): GuestEntry[] {
  if (queue.length === 0) return entries;
  const add: Record<string, number> = {};
  for (const q of queue) add[q.entryId] = (add[q.entryId] ?? 0) + q.count;
  return entries.map((e) =>
    add[e.id] ? { ...e, arrived: Math.min(partySize(e), e.arrived + add[e.id]), arrivedAt: e.arrivedAt ?? new Date().toISOString() } : e,
  );
}

export function arrivalReasonText(reason: string, remaining?: number): string {
  switch (reason) {
    case 'over':
      return `Only ${remaining ?? 0} of this party still to arrive.`;
    case 'used':
      return 'Everyone in this party is already in.';
    case 'wrong-event':
      return 'This guest is on another event’s list.';
    case 'event-cancelled':
      return 'This event was cancelled. Nobody can be checked in.';
    case 'doors-not-open':
      return 'Doors are not open yet.';
    case 'not-found':
      return 'Guest not found. Sync and try again.';
    default:
      return 'Could not check this guest in.';
  }
}
