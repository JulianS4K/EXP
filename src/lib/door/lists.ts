// Check-in lists (gates / areas) for the door, mig 20260929140000.
//
// An event with no lists works as it always did: one implicit list that
// admits everyone once. An organizer can add lists (pretix CheckinList, kept
// simple): a name, the ticket types it admits (all, or some), an optional
// time window, and "Allow re-entry" (OFF unless turned on — operator decision
// 2026-09-29, "Keep reentry optional"). On a re-entry list a ticket is inside
// when its last scan on that list was an entry; an exit scan lets it back in.
//
// A list can be for one fair day (mig 20261113110000, entryDay): without
// re-entry a ticket enters once that DAY (every list with the same day, so
// several gates share it) instead of once per event, and a ticket type's
// max_entry_days caps how many different days it enters (an any-day pass is
// 1). See dayListRefusal.
//
// A list can also admit add-on entry codes (mig 20261107110000; DICE
// Extra.hasSeparateAccessBarcode): admits 'tickets' (the default), 'addons'
// (a VIP lounge, a merch pickup: add-on codes only) or 'both', and addonIds
// narrows the add-ons it takes (null = every add-on with its own code).
//
// Pure helpers (no network, storage passed in), unit-tested.

import type { StorageLike } from './kv';

export type DoorDirection = 'entry' | 'exit';

/** What a list scans: ticket codes, add-on entry codes, or both. */
export type ListAdmits = 'tickets' | 'addons' | 'both';
export const LIST_ADMITS: readonly ListAdmits[] = ['tickets', 'addons', 'both'];

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
  /** Absent on rows from before mig 20261107110000: tickets. */
  admits?: ListAdmits;
  /** The add-ons an add-on list takes; null = every add-on with its own code. */
  addonIds?: string[] | null;
  /** YYYY-MM-DD: a list for one fair day (mig 20261113110000); null / absent = ordinary. */
  entryDay?: string | null;
}

export function mapCheckinListRow(r: Record<string, unknown>): DoorCheckinList {
  const s = (v: unknown) => (typeof v === 'string' && v ? v : null);
  const tiers = Array.isArray(r.tier_ids) ? (r.tier_ids as unknown[]).filter((x): x is string => typeof x === 'string') : null;
  const addons = Array.isArray(r.addon_ids) ? (r.addon_ids as unknown[]).filter((x): x is string => typeof x === 'string') : null;
  const admits = LIST_ADMITS.includes(r.admits as ListAdmits) ? (r.admits as ListAdmits) : 'tickets';
  return {
    id: String(r.id),
    name: String(r.name ?? ''),
    tierIds: tiers && tiers.length > 0 ? tiers : null,
    allowReentry: r.allow_reentry === true,
    validFrom: s(r.valid_from),
    validUntil: s(r.valid_until),
    sortOrder: Number(r.sort_order ?? 0) || 0,
    admits,
    addonIds: admits !== 'tickets' && addons && addons.length > 0 ? addons : null,
    ...(typeof r.entry_day === 'string' && /^\d{4}-\d{2}-\d{2}/.test(r.entry_day) ? { entryDay: r.entry_day.slice(0, 10) } : {}),
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
  if (list.admits === 'addons') return false;
  if (!list.tierIds) return true;
  if (!tierId) return true;
  return list.tierIds.includes(tierId);
}

/** Why a list refuses an add-on code, or null when it takes it (SQL
 *  _exos_check_in_addon_pass). No list at all is a ticket door. */
export function addonListRefusal(list: DoorCheckinList | null, addonId: string | null | undefined): 'tickets-only-list' | 'wrong-list' | null {
  if (!list || (list.admits ?? 'tickets') === 'tickets') return 'tickets-only-list';
  if (list.addonIds && (!addonId || !list.addonIds.includes(addonId))) return 'wrong-list';
  return null;
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

/** Fair days: a ticket's list state also has a 'day:YYYY-MM-DD' key for each
 *  local date (the event's zone) it entered on no list, an ordinary list or a
 *  deleted list (the roster sends them; the device adds its own). */
export const DAY_KEY_PREFIX = 'day:';

/** The day key for an entry at `ms` in the event's zone (UTC when unset or
 *  unknown, as the server's _exos_event_tz). */
export function localDayKey(ms: number, timezone: string | null | undefined): string {
  const fmt = (tz: string) => new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(new Date(ms));
  let d: string;
  try {
    d = fmt(timezone || 'UTC');
  } catch {
    d = fmt('UTC');
  }
  return `${DAY_KEY_PREFIX}${d}`;
}

/** The fair day of each state key: a day list's entryDay, or a day key's date. */
function stateDays(state: ListState | undefined, dayOf: Map<string, string>): Set<string> {
  const days = new Set<string>();
  for (const k of Object.keys(state ?? {})) {
    const d = k.startsWith(DAY_KEY_PREFIX) ? k.slice(DAY_KEY_PREFIX.length) : dayOf.get(k);
    if (d) days.add(d);
  }
  return days;
}

/** Fair days (mig 20261113110000): why a day list refuses a ticket's ENTRY,
 *  or null. `state` is the ticket's per-list last direction (roster
 *  list_state, which covers day lists and has day keys for every other
 *  entry, plus this device's marks); a list with a state was entered, and
 *  an entry anywhere else counts as its local date. Without re-entry: once that day, whichever of
 *  the day's lists ('used'). The ticket type's day limit counts the other
 *  days entered ('day-limit'). On a re-entry list the inside / outside rule
 *  is the caller's (as before). Mirrors SQL _exos_checkin_day_refusal. */
export function dayListRefusal(
  list: DoorCheckinList | null,
  state: ListState | undefined,
  allLists: DoorCheckinList[] | null | undefined,
  dayLimit: number | null | undefined,
): 'used' | 'day-limit' | null {
  if (!list?.entryDay) return null;
  const dayOf = new Map((allLists ?? []).filter((l) => l.entryDay).map((l) => [l.id, l.entryDay as string]));
  dayOf.set(list.id, list.entryDay);
  const days = stateDays(state, dayOf);
  if (!list.allowReentry && days.has(list.entryDay)) return 'used';
  days.delete(list.entryDay);
  if (dayLimit != null && dayLimit > 0 && days.size >= dayLimit) return 'day-limit';
  return null;
}

/** Has this ticket entered on the list's fair day (any of the day's lists)? */
export function enteredOnDay(list: DoorCheckinList, state: ListState | undefined, allLists: DoorCheckinList[] | null | undefined): boolean {
  if (!list.entryDay) return false;
  const ids = new Set((allLists ?? []).filter((l) => l.entryDay === list.entryDay).map((l) => l.id));
  ids.add(list.id);
  ids.add(`${DAY_KEY_PREFIX}${list.entryDay}`);
  return Object.keys(state ?? {}).some((id) => ids.has(id));
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
  /** Default 'tickets'. */
  admits?: ListAdmits;
  /** null = every add-on with its own entry code (add-on lists only). */
  addonIds?: string[] | null;
  /** YYYY-MM-DD fair day; undefined = leave it as it is. */
  entryDay?: string | null;
}

/** Problems with a list before it's saved, or null. */
export function checkinListInputError(l: CheckinListInput): string | null {
  if (!l.name.trim()) return 'Give the list a name, e.g. Main door or VIP deck.';
  if (l.name.trim().length > 60) return 'Keep the name under 60 characters.';
  if (l.tierIds && l.tierIds.length === 0) return 'Pick at least one ticket type, or all of them.';
  if (l.admits && !LIST_ADMITS.includes(l.admits)) return 'Pick what the list scans.';
  if (l.addonIds && l.addonIds.length === 0) return 'Pick at least one add-on, or all of them.';
  const from = l.validFrom ? Date.parse(l.validFrom) : NaN;
  const until = l.validUntil ? Date.parse(l.validUntil) : NaN;
  if (l.validFrom && !Number.isFinite(from)) return 'The start time is not a valid date.';
  if (l.validUntil && !Number.isFinite(until)) return 'The end time is not a valid date.';
  if (Number.isFinite(from) && Number.isFinite(until) && until <= from) return 'The window has to end after it starts.';
  return null;
}

/** One line describing a list, for the editor and the door picker. */
export function describeList(l: DoorCheckinList, tierName: (id: string) => string, addonName?: (id: string) => string): string {
  const tiers = l.tierIds ? l.tierIds.map(tierName).join(', ') : 'All ticket types';
  const addons = l.addonIds && addonName ? l.addonIds.map(addonName).join(', ') : 'all add-on codes';
  const what = l.admits === 'addons' ? `Add-on codes only (${addons})`
    : l.admits === 'both' ? `${tiers} + ${addons}` : tiers;
  const day = l.entryDay ? ` · fair day ${l.entryDay}` : '';
  return `${what} · ${l.allowReentry ? (l.entryDay ? 're-entry the same day' : 're-entry allowed') : (l.entryDay ? 'once that day' : 'no re-entry')}${day}`;
}
