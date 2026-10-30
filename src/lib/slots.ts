// Pure helpers for the series / collections / timed-entry screens
// (docs/series-timed-entry.md): the slot picker's month calendar and day
// list, the slot report's grouping, the door's entry-window answer and the
// series editor's generate batches. Tested in slots.test.ts.

import { addDays, daysInMonth, expandRule, weekdayOf, type Occurrence, type SeriesRule } from './recurrence';

/** A row of exos_public_event_slots. */
export interface PublicSlot {
  slotId: string;
  date: string;
  time: string;
  startsAt: string;
  endsAt: string;
  entryUntil: string;
  capacity: number;
  remaining: number;
  tierRemaining: Record<string, number>;
  closed: boolean;
  ended: boolean;
}

/** Places left in a slot for one ticket type (the slot's own count when the type has none). */
export function slotLeftFor(slot: PublicSlot, tierId: string | null | undefined): number {
  if (slot.closed || slot.ended) return 0;
  if (tierId && typeof slot.tierRemaining?.[tierId] === 'number') return slot.tierRemaining[tierId];
  return slot.remaining;
}

export interface DaySummary {
  date: string;
  slots: number;
  /** Bookable slots (open, not ended, room for the tier). */
  open: number;
  left: number;
}

/** One summary per date, in order. */
export function summarizeDays(slots: readonly PublicSlot[], tierId?: string | null, qty = 1): DaySummary[] {
  const byDate = new Map<string, DaySummary>();
  for (const s of slots) {
    const d = byDate.get(s.date) ?? { date: s.date, slots: 0, open: 0, left: 0 };
    const left = slotLeftFor(s, tierId);
    d.slots += 1;
    if (left >= qty) d.open += 1;
    d.left += left;
    byDate.set(s.date, d);
  }
  return [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date));
}

/** A month grid (weeks start on Sunday): null for padding cells. */
export function monthGrid(year: number, month1: number): (string | null)[][] {
  const first = `${year}-${String(month1).padStart(2, '0')}-01`;
  const lead = weekdayOf(first);
  const cells: (string | null)[] = Array.from({ length: lead }, () => null);
  for (let d = 0; d < daysInMonth(year, month1); d++) cells.push(addDays(first, d));
  while (cells.length % 7) cells.push(null);
  const weeks: (string | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

/** First and last date of a month, clipped to [min, max]. */
export function monthRange(year: number, month1: number, min: string, max: string): { from: string; to: string } | null {
  const first = `${year}-${String(month1).padStart(2, '0')}-01`;
  const last = addDays(first, daysInMonth(year, month1) - 1);
  const from = first < min ? min : first;
  const to = last > max ? max : last;
  return from <= to ? { from, to } : null;
}

export function shiftMonth(year: number, month1: number, by: number): { year: number; month: number } {
  const idx = year * 12 + (month1 - 1) + by;
  return { year: Math.floor(idx / 12), month: (idx % 12) + 1 };
}

/** '10:30 – 11:00' from a slot's wall-clock start and its length. */
export function slotLabel(time: string, slotMinutes: number): string {
  const [h, m] = time.split(':').map(Number);
  const end = h * 60 + m + slotMinutes;
  const eh = Math.floor(end / 60) % 24;
  return `${time} – ${String(eh).padStart(2, '0')}:${String(end % 60).padStart(2, '0')}`;
}

/** The slot id's wall clock, '2026-11-14 10:30'. */
export function slotIdLabel(slotId: string): string {
  if (!/^\d{8}T\d{4}$/.test(slotId)) return slotId;
  return `${slotId.slice(0, 4)}-${slotId.slice(4, 6)}-${slotId.slice(6, 8)} ${slotId.slice(9, 11)}:${slotId.slice(11, 13)}`;
}

// -- Slot report ----------------------------------------------------------------------

export interface SlotReportRow {
  slotId: string;
  date: string;
  time: string;
  capacity: number;
  custom: boolean;
  closed: boolean;
  sold: number;
  held: number;
  checkedIn: number;
  gross: number;
  tierSold: Record<string, number>;
}

export interface SlotReportDay {
  date: string;
  rows: SlotReportRow[];
  sold: number;
  capacity: number;
  checkedIn: number;
  gross: number;
}

export function groupReport(rows: readonly SlotReportRow[]): SlotReportDay[] {
  const days = new Map<string, SlotReportDay>();
  for (const r of rows) {
    const d = days.get(r.date) ?? { date: r.date, rows: [], sold: 0, capacity: 0, checkedIn: 0, gross: 0 };
    d.rows.push(r);
    d.sold += r.sold;
    d.capacity += r.closed ? 0 : r.capacity;
    d.checkedIn += r.checkedIn;
    d.gross = Math.round((d.gross + r.gross) * 100) / 100;
    days.set(r.date, d);
  }
  return [...days.values()].sort((a, b) => a.date.localeCompare(b.date))
    .map((d) => ({ ...d, rows: d.rows.sort((a, b) => a.time.localeCompare(b.time)) }));
}

/** Share of a slot sold, 0..1 (a closed or zero-capacity slot is 1 when it sold anything). */
export function fillRatio(r: Pick<SlotReportRow, 'sold' | 'capacity'>): number {
  if (r.capacity <= 0) return r.sold > 0 ? 1 : 0;
  return Math.min(1, r.sold / r.capacity);
}

// -- The door -------------------------------------------------------------------------

export type EntryWindowAnswer = { ok: true } | { ok: false; window: 'early' | 'late'; from: number; until: number };

/** The same decision the server makes on a live scan (_exos_slot_entry_refusal). */
export function entryWindowAnswer(
  ticket: { entryFrom: string | null; entryUntil: string | null; override?: boolean },
  nowMs: number,
): EntryWindowAnswer {
  if (!ticket.entryFrom || !ticket.entryUntil || ticket.override) return { ok: true };
  const from = Date.parse(ticket.entryFrom);
  const until = Date.parse(ticket.entryUntil);
  if (nowMs < from) return { ok: false, window: 'early', from, until };
  if (nowMs > until) return { ok: false, window: 'late', from, until };
  return { ok: true };
}

/** "Too early: entry opens in 25 min" / "Too late: entry closed 1 h 5 min ago". */
export function entryWindowMessage(a: Exclude<EntryWindowAnswer, { ok: true }>, nowMs: number): string {
  const mins = Math.max(1, Math.round(Math.abs((a.window === 'early' ? a.from : a.until) - nowMs) / 60_000));
  const span = mins >= 60 ? `${Math.floor(mins / 60)} h${mins % 60 ? ` ${mins % 60} min` : ''}` : `${mins} min`;
  return a.window === 'early' ? `Too early: entry opens in ${span}` : `Too late: entry closed ${span} ago`;
}

// -- Series editor -------------------------------------------------------------------

/** exos_series_generate takes at most this many dates per call. */
export const GENERATE_BATCH = 120;

/** The dates to send for [from, to], skipping recorded dates and past starts, in batches. */
export function generateBatches(
  rule: SeriesRule, tz: string, window: { from: string; to: string }, recorded: ReadonlySet<string>, nowMs: number,
): { date: string; time: string }[][] {
  const todo: Occurrence[] = expandRule(rule, tz, window).filter((o) => !recorded.has(o.date) && o.startMs > nowMs);
  const out: { date: string; time: string }[][] = [];
  for (let i = 0; i < todo.length; i += GENERATE_BATCH) {
    out.push(todo.slice(i, i + GENERATE_BATCH).map((o) => ({ date: o.date, time: o.time })));
  }
  return out;
}

/** '10:00-13:00, 14:00-18:00' → opening ranges (the settings form's text box). Throws on junk. */
export function parseHoursText(text: string): { open: string; close: string }[] {
  const out: { open: string; close: string }[] = [];
  for (const part of text.split(',').map((p) => p.trim()).filter(Boolean)) {
    const m = /^(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})$/.exec(part);
    if (!m) throw new Error(`"${part}" is not a range like 10:00-17:00`);
    const pad = (h: string, mi: string) => `${h.padStart(2, '0')}:${mi}`;
    out.push({ open: pad(m[1], m[2]), close: pad(m[3], m[4]) });
  }
  return out;
}

/** The opposite of parseHoursText. */
export function hoursText(ranges: readonly { open: string; close: string }[] | undefined): string {
  return (ranges ?? []).map((r) => `${r.open}-${r.close}`).join(', ');
}

/** A collection slug from a name: lowercase letters, digits and hyphens (1-80). */
export function slugify(name: string): string {
  return name.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80).replace(/-+$/g, '');
}
