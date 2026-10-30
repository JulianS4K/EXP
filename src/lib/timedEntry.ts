// ---------------------------------------------------------------------------
// Timed entry (docs/series-timed-entry.md): attractions and exhibitions
// that sell time slots instead of one start time. Pure: the settings
// editor validates and previews with it, the slot picker and the door use
// the slot and entry-window maths, and timedEntry.test.ts races buyers
// through planSlotSale. The database is the authority (mig 20261030150000:
// _exos_timed_entry_parse, _exos_slot_times, _exos_slot_of and the slot
// counters); this file follows the same rules.
//
// The config is exos_timed_entry (one row per event, written by
// exos_set_timed_entry). Slots are generated from it: for each date in
// [startDate, endDate] that is not closed, the weekday's opening ranges are
// cut into slots of `slotMinutes`; a slot must end by closing time. Slot
// ids are the wall-clock start in the event's zone, `YYYYMMDDTHHMM`, so the
// same slot always has the same id.
//
// Inventory is sparse: an exos_event_slots row exists only once a slot
// held, sold or was changed by staff; a missing row has the config's
// capacity and nothing sold.
// ---------------------------------------------------------------------------

import { DATE_RE, TIME_RE, addDays, daysBetween, isDate, weekdayOf, zonedToUtcMs } from './recurrence';

export interface OpeningRange { open: string; close: string }

export interface TimedEntryConfig {
  /** Tiers sold as time slots. */
  tierIds: string[];
  /** Slot length in minutes (5..480). */
  slotMinutes: number;
  /** Tickets per slot, all timed tiers together. */
  capacity: number;
  /** Optional per-tier cap per slot: { tierId: n }. */
  tierCapacity: Record<string, number>;
  /** Entry is valid this long after the slot starts; null = until the slot ends. */
  entryWindowMinutes: number | null;
  /** Entry is also valid this long before the slot starts. */
  earlyEntryMinutes: number;
  /** Opening hours per weekday ('0' = Sunday .. '6' = Saturday). */
  hours: Record<string, OpeningRange[]>;
  /** Dates slots are sold for (inclusive, wall-clock in the event zone). */
  startDate: string;
  endDate: string;
  /** Dates with no slots (holidays, private hire). */
  closedDates: string[];
  /** Changes on every save (ms). */
  version: number;
}

export interface Slot {
  id: string;
  date: string;
  time: string;
  /** UTC instants (ms). */
  startMs: number;
  endMs: number;
  entryFromMs: number;
  entryUntilMs: number;
}

export const SLOT_ID_RE = /^\d{8}T\d{4}$/;
export const MAX_RANGE_DAYS = 400;
export const MAX_SLOTS_PER_DAY = 96;
export const MAX_CLOSED_DATES = 200;

export class TimedEntryError extends Error {}

function minutes(t: string): number {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
}

function hhmm(min: number): string {
  return `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;
}

export function slotIdFor(date: string, time: string): string {
  return `${date.replace(/-/g, '')}T${time.replace(':', '')}`;
}

/** 'YYYYMMDDTHHMM' → { date, time }, or null. */
export function parseSlotId(id: unknown): { date: string; time: string } | null {
  if (typeof id !== 'string' || !SLOT_ID_RE.test(id)) return null;
  const date = `${id.slice(0, 4)}-${id.slice(4, 6)}-${id.slice(6, 8)}`;
  const time = `${id.slice(9, 11)}:${id.slice(11, 13)}`;
  return isDate(date) && TIME_RE.test(time) ? { date, time } : null;
}

function intIn(v: unknown, field: string, min: number, max: number, fallback?: number): number {
  if ((v === undefined || v === null || v === '') && fallback !== undefined) return fallback;
  const n = typeof v === 'string' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < min || n > max) throw new TimedEntryError(`${field} must be a whole number between ${min} and ${max}.`);
  return n;
}

/**
 * Validates a submitted config against the event's tier ids. Throws
 * TimedEntryError with a message for the organizer.
 */
export function parseTimedEntryConfig(raw: unknown, eventTierIds: string[]): Omit<TimedEntryConfig, 'version'> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new TimedEntryError('The timed entry settings must be an object.');
  const r = raw as Record<string, unknown>;
  const tierIds = Array.isArray(r.tierIds) ? [...new Set(r.tierIds.filter((x): x is string => typeof x === 'string'))] : [];
  if (tierIds.length === 0) throw new TimedEntryError('Pick at least one ticket type to sell as time slots.');
  for (const id of tierIds) if (!eventTierIds.includes(id)) throw new TimedEntryError('A timed ticket type is not part of this event.');
  const slotMinutes = intIn(r.slotMinutes, 'slotMinutes', 5, 480);
  const capacity = intIn(r.capacity, 'capacity', 1, 100_000);
  const tierCapacity: Record<string, number> = {};
  if (r.tierCapacity && typeof r.tierCapacity === 'object' && !Array.isArray(r.tierCapacity)) {
    for (const [k, v] of Object.entries(r.tierCapacity as Record<string, unknown>)) {
      if (v === null || v === undefined || v === '') continue;
      if (!tierIds.includes(k)) throw new TimedEntryError('A per-slot ticket type limit names a ticket type that is not timed.');
      tierCapacity[k] = intIn(v, `tierCapacity.${k}`, 0, 100_000);
    }
  }
  const entryWindowMinutes = r.entryWindowMinutes === null || r.entryWindowMinutes === undefined || r.entryWindowMinutes === ''
    ? null
    : intIn(r.entryWindowMinutes, 'entryWindowMinutes', 1, 24 * 60);
  const earlyEntryMinutes = intIn(r.earlyEntryMinutes, 'earlyEntryMinutes', 0, 240, 0);
  if (!isDate(r.startDate) || !isDate(r.endDate)) throw new TimedEntryError('startDate and endDate must be dates (YYYY-MM-DD).');
  const startDate = r.startDate as string;
  const endDate = r.endDate as string;
  if (endDate < startDate) throw new TimedEntryError('endDate must not be before startDate.');
  if (daysBetween(startDate, endDate) > MAX_RANGE_DAYS) throw new TimedEntryError(`Slots can be sold for at most ${MAX_RANGE_DAYS} days.`);
  const hoursRaw = r.hours && typeof r.hours === 'object' && !Array.isArray(r.hours) ? (r.hours as Record<string, unknown>) : {};
  const hours: Record<string, OpeningRange[]> = {};
  let anyOpen = false;
  for (let wd = 0; wd < 7; wd++) {
    const list = hoursRaw[String(wd)];
    if (list === undefined || list === null) continue;
    if (!Array.isArray(list) || list.length > 4) throw new TimedEntryError('Each weekday takes at most 4 opening ranges.');
    const ranges: OpeningRange[] = [];
    for (const item of list) {
      const o = (item ?? {}) as Record<string, unknown>;
      const open = typeof o.open === 'string' ? o.open : '';
      const close = typeof o.close === 'string' ? o.close : '';
      if (!TIME_RE.test(open) || !(TIME_RE.test(close) || close === '24:00')) throw new TimedEntryError('Opening hours must be HH:MM.');
      if (minutes(close === '24:00' ? '23:59' : close) + (close === '24:00' ? 1 : 0) <= minutes(open)) throw new TimedEntryError('Closing time must be after opening time.');
      ranges.push({ open, close });
    }
    ranges.sort((a, b) => a.open.localeCompare(b.open));
    for (let i = 1; i < ranges.length; i++) {
      if (closeMinutes(ranges[i - 1].close) > minutes(ranges[i].open)) throw new TimedEntryError('Opening ranges on one day must not overlap.');
    }
    if (ranges.length) {
      hours[String(wd)] = ranges;
      anyOpen = true;
    }
  }
  if (!anyOpen) throw new TimedEntryError('Add opening hours for at least one weekday.');
  for (const [wd, ranges] of Object.entries(hours)) {
    const perDay = ranges.reduce((n, rg) => n + Math.floor((closeMinutes(rg.close) - minutes(rg.open)) / slotMinutes), 0);
    if (perDay > MAX_SLOTS_PER_DAY) throw new TimedEntryError(`At most ${MAX_SLOTS_PER_DAY} slots a day (weekday ${wd} has ${perDay}); use longer slots.`);
  }
  const closedRaw = Array.isArray(r.closedDates) ? r.closedDates : [];
  if (closedRaw.length > MAX_CLOSED_DATES) throw new TimedEntryError(`At most ${MAX_CLOSED_DATES} closed dates.`);
  for (const d of closedRaw) if (!isDate(d)) throw new TimedEntryError('Every closed date must be a date (YYYY-MM-DD).');
  return {
    tierIds, slotMinutes, capacity, tierCapacity, entryWindowMinutes, earlyEntryMinutes, hours, startDate, endDate,
    closedDates: [...new Set(closedRaw as string[])].sort(),
  };
}

function closeMinutes(close: string): number {
  return close === '24:00' ? 24 * 60 : minutes(close);
}

/** Wall-clock start times of a date's slots (no zone needed). */
export function slotTimesFor(config: Pick<TimedEntryConfig, 'hours' | 'slotMinutes' | 'startDate' | 'endDate' | 'closedDates'>, date: string): string[] {
  if (!DATE_RE.test(date) || date < config.startDate || date > config.endDate || config.closedDates.includes(date)) return [];
  const ranges = config.hours[String(weekdayOf(date))] ?? [];
  const out: string[] = [];
  for (const rg of ranges) {
    for (let m = minutes(rg.open); m + config.slotMinutes <= closeMinutes(rg.close); m += config.slotMinutes) out.push(hhmm(m));
  }
  return out.slice(0, MAX_SLOTS_PER_DAY);
}

function slotOf(config: TimedEntryConfig, date: string, time: string, tz: string): Slot {
  const startMs = zonedToUtcMs(date, time, tz);
  const endMs = startMs + config.slotMinutes * 60_000;
  return {
    id: slotIdFor(date, time),
    date,
    time,
    startMs,
    endMs,
    entryFromMs: startMs - config.earlyEntryMinutes * 60_000,
    entryUntilMs: config.entryWindowMinutes === null ? endMs : startMs + config.entryWindowMinutes * 60_000,
  };
}

/** The slots of one date, in time order. */
export function slotsForDate(config: TimedEntryConfig, date: string, tz: string): Slot[] {
  return slotTimesFor(config, date).map((time) => slotOf(config, date, time, tz));
}

/** A slot id resolved against the config, or null when the config has no such slot. */
export function slotFromId(config: TimedEntryConfig, id: unknown, tz: string): Slot | null {
  const p = parseSlotId(id);
  if (!p) return null;
  return slotTimesFor(config, p.date).includes(p.time) ? slotOf(config, p.date, p.time, tz) : null;
}

/** Every open date of the config, in order. */
export function openDates(config: TimedEntryConfig): string[] {
  const out: string[] = [];
  for (let d = config.startDate; d <= config.endDate; d = addDays(d, 1)) {
    if (slotTimesFor(config, d).length > 0) out.push(d);
  }
  return out;
}

// -- Capacity (the decision the fulfillment transaction runs) -------------------------

export interface SlotState {
  capacity: number;
  sold: number;
  held: number;
  closed?: boolean;
  tierCapacity?: Record<string, number>;
  tierSold?: Record<string, number>;
}

/** A slot nobody has sold or changed yet. */
export function freshSlotState(config: Pick<TimedEntryConfig, 'capacity' | 'tierCapacity'>): SlotState {
  return { capacity: config.capacity, sold: 0, held: 0, closed: false, tierCapacity: { ...config.tierCapacity }, tierSold: {} };
}

/** How many of `tierId` this slot can still sell (all tiers' cap and the tier's own). */
export function slotRemaining(state: SlotState, tierId?: string): number {
  if (state.closed) return 0;
  let left = state.capacity - state.sold - state.held;
  if (tierId) {
    const cap = state.tierCapacity?.[tierId];
    if (typeof cap === 'number') left = Math.min(left, cap - (state.tierSold?.[tierId] ?? 0));
  }
  return Math.max(0, left);
}

export type SlotPlan = { ok: true; next: SlotState } | { ok: false; remaining: number; reason: 'slot_full' | 'slot_closed' };

/** Sell `qty` of `tierId` in the slot, or refuse. Pure: the caller writes `next`. */
export function planSlotSale(state: SlotState, tierId: string, qty: number): SlotPlan {
  if (state.closed) return { ok: false, remaining: 0, reason: 'slot_closed' };
  const remaining = slotRemaining(state, tierId);
  if (qty > remaining) return { ok: false, remaining, reason: 'slot_full' };
  return {
    ok: true,
    next: {
      ...state,
      sold: state.sold + qty,
      tierSold: { ...(state.tierSold ?? {}), [tierId]: (state.tierSold?.[tierId] ?? 0) + qty },
    },
  };
}

/** Give `qty` of `tierId` back (refund, void). Never below zero. */
export function planSlotRelease(state: SlotState, tierId: string, qty: number): SlotState {
  return {
    ...state,
    sold: Math.max(0, state.sold - qty),
    tierSold: { ...(state.tierSold ?? {}), [tierId]: Math.max(0, (state.tierSold?.[tierId] ?? 0) - qty) },
  };
}

// -- The door -------------------------------------------------------------------------

export type EntryWindowStatus = 'early' | 'ok' | 'late';

/** Where `nowMs` falls against a ticket slot's entry window. */
export function entryWindowStatus(slot: { entryFromMs: number; entryUntilMs: number }, nowMs: number): EntryWindowStatus {
  if (nowMs < slot.entryFromMs) return 'early';
  if (nowMs > slot.entryUntilMs) return 'late';
  return 'ok';
}
