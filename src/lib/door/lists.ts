// Check-in lists (gates / areas) for the door, mig 20260929140000.
//
// An event with no lists works as it always did: one implicit list that
// admits everyone once. An organizer can add lists (pretix CheckinList, kept
// simple): a name, the ticket types it admits (all, or some), an optional
// time window, and "Allow re-entry" (OFF unless turned on — operator decision
// 2026-09-29, "Keep reentry optional"). On a re-entry list a ticket is inside
// when its last scan on that list was an entry; an exit scan lets it back in.
//
// Pure helpers (no network, storage passed in), unit-tested.

import type { StorageLike } from './kv';

export type DoorDirection = 'entry' | 'exit';

export interface DoorCheckinList {
  id: string;
  name: string;
  /** null = every ticket type of the event. */
  tierIds: string[] | null;
  allowReentry: boolean;
  /** ISO timestamps, null = open-ended. */
  validFrom: string | null;
  validUntil: string | null;
  sortOrder: number;
}

export function mapCheckinListRow(r: Record<string, unknown>): DoorCheckinList {
  const s = (v: unknown) => (typeof v === 'string' && v ? v : null);
  const tiers = Array.isArray(r.tier_ids) ? (r.tier_ids as unknown[]).filter((x): x is string => typeof x === 'string') : null;
  return {
    id: String(r.id),
    name: String(r.name ?? ''),
    tierIds: tiers && tiers.length > 0 ? tiers : null,
    allowReentry: r.allow_reentry === true,
    validFrom: s(r.valid_from),
    validUntil: s(r.valid_until),
    sortOrder: Number(r.sort_order ?? 0) || 0,
  };
}

export function sortLists(lists: DoorCheckinList[]): DoorCheckinList[] {
  return [...lists].sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
}

// --- The device's choice ------------------------------------------------------

/** The choice value for "no list" (the implicit everyone-once list). */
export const NO_LIST = '';

export const listChoiceKey = (eventId: string) => `exos:door-list:${eventId}`;
export const directionKey = (eventId: string) => `exos:door-direction:${eventId}`;

/** Which list this device scans for. A remembered choice that still exists
 *  wins; "no list" is remembered too. Otherwise the first list, or no list
 *  when the event has none. */
export function pickList(lists: DoorCheckinList[] | null, remembered: string | null | undefined): DoorCheckinList | null {
  if (!lists || lists.length === 0) return null;
  if (remembered === NO_LIST) return null;
  const hit = remembered ? lists.find((l) => l.id === remembered) : undefined;
  return hit ?? sortLists(lists)[0];
}

export function loadListChoice(storage: StorageLike | null, eventId: string): string | null {
  try {
    return storage?.getItem(listChoiceKey(eventId)) ?? null;
  } catch {
    return null;
  }
}

export function saveListChoice(storage: StorageLike | null, eventId: string, listId: string | null): void {
  try {
    storage?.setItem(listChoiceKey(eventId), listId ?? NO_LIST);
  } catch {
    /* storage blocked: the choice lasts this page */
  }
}

/** Exits only exist on a re-entry list; anywhere else the door scans entries. */
export function effectiveDirection(list: DoorCheckinList | null, wanted: DoorDirection): DoorDirection {
  return list?.allowReentry ? wanted : 'entry';
}

export function loadDirection(storage: StorageLike | null, eventId: string): DoorDirection {
  try {
    return storage?.getItem(directionKey(eventId)) === 'exit' ? 'exit' : 'entry';
  } catch {
    return 'entry';
  }
}

export function saveDirection(storage: StorageLike | null, eventId: string, d: DoorDirection): void {
  try {
    storage?.setItem(directionKey(eventId), d);
  } catch {
    /* ignore */
  }
}

// --- Rules the device applies offline (the server applies them online) -------

/** Does the list admit this ticket type? An unknown tier (a roster from before
 *  the migration) is left to the server. */
export function listAdmitsTier(list: DoorCheckinList, tierId: string | null | undefined): boolean {
  if (!list.tierIds) return true;
  if (!tierId) return true;
  return list.tierIds.includes(tierId);
}

export type ListWindowState = 'open' | 'not-yet' | 'closed';

export function listWindow(list: DoorCheckinList, now: number): ListWindowState {
  const from = list.validFrom ? Date.parse(list.validFrom) : NaN;
  const until = list.validUntil ? Date.parse(list.validUntil) : NaN;
  if (Number.isFinite(from) && now < from) return 'not-yet';
  if (Number.isFinite(until) && now > until) return 'closed';
  return 'open';
}

/** The last direction per re-entry list, as the roster carries it. */
export type ListState = Record<string, DoorDirection>;

export function parseListState(v: unknown): ListState | undefined {
  if (!v || typeof v !== 'object') return undefined;
  const out: ListState = {};
  for (const [k, d] of Object.entries(v as Record<string, unknown>)) {
    if (d === 'entry' || d === 'exit') out[k] = d;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/** A ticket's list state after a scan on `listId`. */
export function withDirection(state: ListState | undefined, listId: string, d: DoorDirection): ListState {
  return { ...(state ?? {}), [listId]: d };
}

// --- The organizer's editor ---------------------------------------------------

export interface CheckinListInput {
  name: string;
  /** null = all ticket types. */
  tierIds: string[] | null;
  allowReentry: boolean;
  validFrom: string | null;
  validUntil: string | null;
}

/** Problems with a list before it's saved, or null. */
export function checkinListInputError(l: CheckinListInput): string | null {
  if (!l.name.trim()) return 'Give the list a name, e.g. Main door or VIP deck.';
  if (l.name.trim().length > 60) return 'Keep the name under 60 characters.';
  if (l.tierIds && l.tierIds.length === 0) return 'Pick at least one ticket type, or all of them.';
  const from = l.validFrom ? Date.parse(l.validFrom) : NaN;
  const until = l.validUntil ? Date.parse(l.validUntil) : NaN;
  if (l.validFrom && !Number.isFinite(from)) return 'The start time is not a valid date.';
  if (l.validUntil && !Number.isFinite(until)) return 'The end time is not a valid date.';
  if (Number.isFinite(from) && Number.isFinite(until) && until <= from) return 'The window has to end after it starts.';
  return null;
}

/** One line describing a list, for the editor and the door picker. */
export function describeList(l: DoorCheckinList, tierName: (id: string) => string): string {
  const tiers = l.tierIds ? l.tierIds.map(tierName).join(', ') : 'All ticket types';
  return `${tiers} · ${l.allowReentry ? 're-entry allowed' : 'no re-entry'}`;
}
