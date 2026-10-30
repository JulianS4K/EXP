// ---------------------------------------------------------------------------
// Recurring event series: the recurrence rule and its expansion
// (docs/series-timed-entry.md). Pure: the series editor expands the rule
// into dates (preview, then exos_series_generate, which records each date
// once, mig 20261030150000); recurrence.test.ts checks the edge cases (DST,
// month ends, nth weekdays, exceptions). The SQL side mirrors zonedToUtcMs
// in _exos_zoned_ts.
//
// Occurrences are wall-clock dates and times in the series' timezone (the
// venue's, like every event: Create / Edit Event store the UTC instant of
// the wall-clock time the organizer typed in the event's zone). Dates are
// handled as plain 'YYYY-MM-DD' strings with UTC date maths, so a DST
// change never moves a date; only the final conversion to an instant
// looks at the zone.
//
// Rule semantics (close to RFC 5545):
//   daily    every `interval` days from startDate.
//   weekly   every `interval` weeks (weeks start on Sunday, counted from
//            the week of startDate) on each of `weekdays`.
//   monthly  every `interval` months on day `day` (months without that day
//            are skipped, like RRULE BYMONTHDAY), or on the `nth` weekday
//            (1..5, or -1 for the last; months without a 5th are skipped).
//   The series ends at endDate (inclusive) or after `count` occurrences,
//   whichever comes first; at least one of the two is required.
//   `count` counts rule occurrences before exceptions are removed (RRULE
//   COUNT with EXDATE): excepting a date does not add one at the end.
//   `overrides` move one date's start time.
// ---------------------------------------------------------------------------

export type Freq = 'daily' | 'weekly' | 'monthly';

export type MonthlyRule = { mode: 'date'; day: number } | { mode: 'nth'; nth: number; weekday: number };

export interface SeriesRule {
  freq: Freq;
  /** Every N days / weeks / months (1..12). */
  interval: number;
  /** Weekly: 0 = Sunday .. 6 = Saturday (at least one). */
  weekdays: number[];
  /** Monthly: by date or by nth weekday. */
  monthly: MonthlyRule | null;
  /** First possible occurrence, 'YYYY-MM-DD' (wall-clock date in the series zone). */
  startDate: string;
  /** Last possible occurrence (inclusive), or null when `count` bounds it. */
  endDate: string | null;
  /** Number of rule occurrences, or null when `endDate` bounds it. */
  count: number | null;
  /** Start time of every occurrence, 'HH:MM' (24-hour) in the series zone. */
  time: string;
  /** Dates that are skipped. */
  exceptions: string[];
  /** Per-date start time: { 'YYYY-MM-DD': 'HH:MM' }. */
  overrides: Record<string, string>;
}

export interface Occurrence {
  /** Wall-clock date in the series zone. */
  date: string;
  /** Wall-clock start time in the series zone. */
  time: string;
  /** UTC instant of the start (ms). */
  startMs: number;
  /** The time came from `overrides`. */
  overridden: boolean;
}

export const MAX_COUNT = 500;
/** endDate at most this many days after startDate. */
export const MAX_SPAN_DAYS = 3 * 366;
export const MAX_EXCEPTIONS = 200;
export const MAX_OVERRIDES = 200;

export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

// -- Date maths ('YYYY-MM-DD', UTC based) --------------------------------------------

export function isDate(s: unknown): s is string {
  if (typeof s !== 'string' || !DATE_RE.test(s)) return false;
  const [y, m, d] = s.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
}

function dateMs(s: string): number {
  const [y, m, d] = s.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
}

function fmtDate(ms: number): string {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

export function addDays(s: string, n: number): string {
  return fmtDate(dateMs(s) + n * 86_400_000);
}

export function daysBetween(a: string, b: string): number {
  return Math.round((dateMs(b) - dateMs(a)) / 86_400_000);
}

/** 0 = Sunday .. 6 = Saturday. */
export function weekdayOf(s: string): number {
  return new Date(dateMs(s)).getUTCDay();
}

export function daysInMonth(year: number, month1: number): number {
  return new Date(Date.UTC(year, month1, 0)).getUTCDate();
}

/** The nth (1..5, or -1 = last) `weekday` of a month, or null when it doesn't exist. */
export function nthWeekdayOfMonth(year: number, month1: number, nth: number, weekday: number): string | null {
  const dim = daysInMonth(year, month1);
  if (nth === -1) {
    const lastWd = new Date(Date.UTC(year, month1 - 1, dim)).getUTCDay();
    const day = dim - ((lastWd - weekday + 7) % 7);
    return fmtDate(Date.UTC(year, month1 - 1, day));
  }
  const firstWd = new Date(Date.UTC(year, month1 - 1, 1)).getUTCDay();
  const day = 1 + ((weekday - firstWd + 7) % 7) + (nth - 1) * 7;
  return day <= dim ? fmtDate(Date.UTC(year, month1 - 1, day)) : null;
}

// -- Time zones ----------------------------------------------------------------------

// One formatter per zone: building an Intl.DateTimeFormat is the slow part,
// and a slot calendar converts thousands of times.
const formatters = new Map<string, Intl.DateTimeFormat>();

function formatterFor(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    });
    formatters.set(tz, f);
  }
  return f;
}

function wallParts(ms: number, tz: string): { date: string; time: string } {
  const parts = formatterFor(tz).formatToParts(new Date(ms)).reduce<Record<string, string>>((acc, p) => {
    if (p.type !== 'literal') acc[p.type] = p.value;
    return acc;
  }, {});
  return { date: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}` };
}

/** UTC offset of `tz` at instant `ms`, in minutes (positive = ahead of UTC). */
function offsetMinutes(ms: number, tz: string): number {
  const w = wallParts(ms, tz);
  const [h, mi] = w.time.split(':').map(Number);
  const asUtc = dateMs(w.date) + (h * 60 + mi) * 60_000;
  return Math.round((asUtc - Math.floor(ms / 60_000) * 60_000) / 60_000);
}

/** Whether `tz` is an IANA zone this runtime knows. */
export function validZone(tz: unknown): tz is string {
  if (typeof tz !== 'string' || !tz || tz.length > 64) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Wall-clock `date` + `time` in `tz` → the UTC instant (ms).
 *   * Ambiguous times (the repeated hour when clocks go back) take the
 *     first, earlier instant.
 *   * Times that don't exist (the skipped hour when clocks go forward)
 *     move forward by the gap: 02:30 on a spring-forward night is 03:30.
 */
export function zonedToUtcMs(date: string, time: string, tz: string): number {
  const [h, mi] = time.split(':').map(Number);
  const naive = dateMs(date) + (h * 60 + mi) * 60_000;
  const before = offsetMinutes(naive - 12 * 3_600_000, tz);
  const after = offsetMinutes(naive + 12 * 3_600_000, tz);
  const candidates = [...new Set([naive - before * 60_000, naive - after * 60_000])]
    .filter((c) => {
      const w = wallParts(c, tz);
      return w.date === date && w.time === time;
    })
    .sort((a, b) => a - b);
  if (candidates.length > 0) return candidates[0];
  // In the gap: the offset in force before the change pushes it forward.
  return naive - before * 60_000;
}

/** The wall-clock date and time of instant `ms` in `tz`. */
export function utcToZoned(ms: number, tz: string): { date: string; time: string } {
  return wallParts(ms, tz);
}

// -- Validation ----------------------------------------------------------------------

export class RuleError extends Error {}

function intIn(v: unknown, field: string, min: number, max: number, fallback?: number): number {
  if ((v === undefined || v === null || v === '') && fallback !== undefined) return fallback;
  const n = typeof v === 'string' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < min || n > max) throw new RuleError(`${field} must be a whole number between ${min} and ${max}.`);
  return n;
}

/** Validates a submitted rule. Throws RuleError with a message for the user. */
export function parseRule(raw: unknown): SeriesRule {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new RuleError('rule must be an object.');
  const r = raw as Record<string, unknown>;
  const freq = r.freq;
  if (freq !== 'daily' && freq !== 'weekly' && freq !== 'monthly') throw new RuleError('rule.freq must be daily, weekly or monthly.');
  const interval = intIn(r.interval, 'rule.interval', 1, 12, 1);
  if (!isDate(r.startDate)) throw new RuleError('rule.startDate must be a date (YYYY-MM-DD).');
  const startDate = r.startDate;
  let endDate: string | null = null;
  if (r.endDate !== undefined && r.endDate !== null && r.endDate !== '') {
    if (!isDate(r.endDate)) throw new RuleError('rule.endDate must be a date (YYYY-MM-DD).');
    endDate = r.endDate;
    if (endDate < startDate) throw new RuleError('rule.endDate must not be before rule.startDate.');
    if (daysBetween(startDate, endDate) > MAX_SPAN_DAYS) throw new RuleError('A series can span at most three years.');
  }
  const count = r.count === undefined || r.count === null || r.count === '' ? null : intIn(r.count, 'rule.count', 1, MAX_COUNT);
  if (endDate === null && count === null) throw new RuleError('Give the series an end date or a number of dates.');
  const time = typeof r.time === 'string' ? r.time : '';
  if (!TIME_RE.test(time)) throw new RuleError('rule.time must be HH:MM (24-hour).');

  let weekdays: number[] = [];
  if (freq === 'weekly') {
    if (!Array.isArray(r.weekdays) || r.weekdays.length === 0) throw new RuleError('Pick at least one weekday.');
    weekdays = [...new Set(r.weekdays.map((w, i) => intIn(w, `rule.weekdays[${i}]`, 0, 6)))].sort((a, b) => a - b);
  }
  let monthly: MonthlyRule | null = null;
  if (freq === 'monthly') {
    const m = (r.monthly ?? {}) as Record<string, unknown>;
    if (m.mode === 'nth') {
      const nth = intIn(m.nth, 'rule.monthly.nth', -1, 5);
      if (nth === 0) throw new RuleError('rule.monthly.nth must be 1 to 5, or -1 for the last.');
      monthly = { mode: 'nth', nth, weekday: intIn(m.weekday, 'rule.monthly.weekday', 0, 6) };
    } else if (m.mode === 'date' || m.mode === undefined) {
      monthly = { mode: 'date', day: intIn(m.day, 'rule.monthly.day', 1, 31, Number(startDate.slice(8))) };
    } else {
      throw new RuleError('rule.monthly.mode must be date or nth.');
    }
  }

  const exceptions = Array.isArray(r.exceptions) ? r.exceptions : [];
  if (exceptions.length > MAX_EXCEPTIONS) throw new RuleError(`At most ${MAX_EXCEPTIONS} exceptions.`);
  for (const e of exceptions) if (!isDate(e)) throw new RuleError('Every exception must be a date (YYYY-MM-DD).');
  const overridesRaw = r.overrides && typeof r.overrides === 'object' && !Array.isArray(r.overrides) ? (r.overrides as Record<string, unknown>) : {};
  const keys = Object.keys(overridesRaw);
  if (keys.length > MAX_OVERRIDES) throw new RuleError(`At most ${MAX_OVERRIDES} time overrides.`);
  const overrides: Record<string, string> = {};
  for (const k of keys.sort()) {
    const v = overridesRaw[k];
    if (!isDate(k) || typeof v !== 'string' || !TIME_RE.test(v)) throw new RuleError('Every time override must map a date (YYYY-MM-DD) to a time (HH:MM).');
    overrides[k] = v;
  }
  return {
    freq, interval, weekdays, monthly, startDate, endDate, count, time,
    exceptions: [...new Set(exceptions as string[])].sort(),
    overrides,
  };
}

// -- Expansion -----------------------------------------------------------------------

/** Rule dates in order, before exceptions; stops at endDate, count or `max`. */
export function ruleDates(rule: SeriesRule, max = MAX_COUNT): string[] {
  const out: string[] = [];
  const limit = Math.min(max, rule.count ?? MAX_COUNT);
  const end = rule.endDate ?? addDays(rule.startDate, MAX_SPAN_DAYS);
  const push = (d: string): boolean => {
    if (d < rule.startDate) return true;
    if (d > end) return false;
    out.push(d);
    return out.length < limit;
  };
  // A guard against loops on odd rules (e.g. monthly on the 31st with a
  // 12-month interval landing on a month without one forever).
  const MAX_STEPS = 5000;
  if (rule.freq === 'daily') {
    for (let k = 0; k < MAX_STEPS; k++) {
      if (!push(addDays(rule.startDate, k * rule.interval))) break;
    }
  } else if (rule.freq === 'weekly') {
    const weekStart = addDays(rule.startDate, -weekdayOf(rule.startDate));
    outer: for (let k = 0; k < MAX_STEPS; k++) {
      const ws = addDays(weekStart, k * 7 * rule.interval);
      if (ws > end) break;
      for (const wd of rule.weekdays) {
        if (!push(addDays(ws, wd))) break outer;
      }
    }
  } else {
    const [y0, m0] = rule.startDate.split('-').map(Number);
    for (let k = 0; k < MAX_STEPS; k++) {
      const idx = (m0 - 1) + k * rule.interval;
      const y = y0 + Math.floor(idx / 12);
      const m = (idx % 12) + 1;
      if (`${y}-${String(m).padStart(2, '0')}-01` > end) break;
      const mr = rule.monthly ?? { mode: 'date', day: Number(rule.startDate.slice(8)) };
      let d: string | null;
      if (mr.mode === 'date') d = mr.day <= daysInMonth(y, m) ? `${y}-${String(m).padStart(2, '0')}-${String(mr.day).padStart(2, '0')}` : null;
      else d = nthWeekdayOfMonth(y, m, mr.nth, mr.weekday);
      if (d && !push(d)) break;
    }
  }
  return out;
}

/**
 * The series' occurrences (exceptions removed, overrides applied),
 * optionally only those whose date falls in [from, to].
 */
export function expandRule(rule: SeriesRule, tz: string, window: { from?: string; to?: string } = {}): Occurrence[] {
  const skip = new Set(rule.exceptions);
  return ruleDates(rule)
    .filter((d) => !skip.has(d) && (!window.from || d >= window.from) && (!window.to || d <= window.to))
    .map((date) => {
      const time = rule.overrides[date] ?? rule.time;
      return { date, time, startMs: zonedToUtcMs(date, time, tz), overridden: date in rule.overrides };
    });
}

/**
 * Generation plan: which occurrences in the window still need an event.
 * `existing` holds the dates that already have an occurrence record
 * (generated, cancelled or skipped); those are never touched again, so
 * running the plan twice creates nothing the second time. Past starts
 * (before `nowMs`) are left out.
 */
export function planGeneration(
  rule: SeriesRule, tz: string, window: { from: string; to: string }, existing: Set<string>, nowMs: number,
): Occurrence[] {
  return expandRule(rule, tz, window).filter((o) => !existing.has(o.date) && o.startMs > nowMs);
}

/** "Every Friday and Saturday at 20:00", for lists. English; the UI has its own. */
export function describeRule(rule: SeriesRule): string {
  const names = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const every = (unit: string) => (rule.interval === 1 ? `Every ${unit}` : `Every ${rule.interval} ${unit}s`);
  let base: string;
  if (rule.freq === 'daily') base = every('day');
  else if (rule.freq === 'weekly') base = `${every('week')} on ${rule.weekdays.map((w) => names[w]).join(', ')}`;
  else if (rule.monthly?.mode === 'nth') {
    const ord = rule.monthly.nth === -1 ? 'last' : ['first', 'second', 'third', 'fourth', 'fifth'][rule.monthly.nth - 1];
    base = `${every('month')} on the ${ord} ${names[rule.monthly.weekday]}`;
  } else base = `${every('month')} on day ${rule.monthly?.day ?? Number(rule.startDate.slice(8))}`;
  return `${base} at ${rule.time}`;
}
