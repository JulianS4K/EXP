// The attendance report (claude/exos-attendance-report, mig 20261113120000):
// where an event's attendees are by billing postal area, and how its sales
// pace against a prior event of the org. The numbers come from
// exos_event_attendance (owner / manager / finance; aggregated in SQL, a
// postal area with fewer than 5 buyers is folded into "Other (fewer than
// 5)" before it leaves the database). This module parses that answer, lines
// the two pacing series up by days before the event, and builds the XLSX
// workbook. Pure (vitest: attendanceReport.test.ts); the read is in
// attendanceReportApi.ts.

import type { XlsxSheet } from './xlsx';

export interface PostalRow {
  country: string | null;
  postalCode: string | null;
  label: string | null;
  buyers: number;
  orders: number;
  tickets: number;
  checkedIn: number;
}

export interface PacingDay {
  day: string;
  daysBefore: number | null;
  paidOrders: number;
  paidTickets: number;
  grossCents: number;
  freeOrders: number;
  freeTickets: number;
  cumPaidTickets: number;
  cumGrossCents: number;
  cumFreeTickets: number;
}

export interface PacingTotals {
  paidOrders: number;
  paidTickets: number;
  grossCents: number;
  freeOrders: number;
  freeTickets: number;
}

export interface PacingSeries {
  eventId: string;
  name: string;
  startsAt: string | null;
  timezone: string;
  currency: string;
  eventDay: string | null;
  onSaleDay: string | null;
  onSaleDaysBefore: number | null;
  daysOutNow: number | null;
  totals: PacingTotals;
  rows: PacingDay[];
}

export interface AttendanceReport {
  eventId: string;
  generatedAt: string | null;
  minBuyers: number;
  totals: { buyers: number; orders: number; tickets: number; checkedIn: number; locatedOrders: number };
  postal: PostalRow[];
  postalOther: PostalRow;
  postalUnknown: PostalRow;
  otherTickets: number;
  event: PacingSeries | null;
  comparison: PacingSeries | null;
  candidates: { eventId: string; name: string; startsAt: string | null }[];
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : {});
const num = (v: unknown): number => {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};
const intOrNull = (v: unknown): number | null => (v === null || v === undefined || v === '' ? null : Math.trunc(num(v)));
const str = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

function postalRow(v: unknown): PostalRow {
  const o = obj(v);
  return {
    country: str(o.country), postalCode: str(o.postal_code), label: str(o.label),
    buyers: num(o.buyers), orders: num(o.orders), tickets: num(o.tickets), checkedIn: num(o.checked_in),
  };
}

function pacingDay(v: unknown): PacingDay {
  const o = obj(v);
  return {
    day: str(o.day) ?? '', daysBefore: intOrNull(o.days_before),
    paidOrders: num(o.paid_orders), paidTickets: num(o.paid_tickets), grossCents: num(o.gross_cents),
    freeOrders: num(o.free_orders), freeTickets: num(o.free_tickets),
    cumPaidTickets: num(o.cum_paid_tickets), cumGrossCents: num(o.cum_gross_cents), cumFreeTickets: num(o.cum_free_tickets),
  };
}

export function parsePacing(v: unknown): PacingSeries | null {
  if (!v || typeof v !== 'object') return null;
  const o = obj(v);
  const t = obj(o.totals);
  return {
    eventId: str(o.event_id) ?? '', name: str(o.name) ?? '', startsAt: str(o.starts_at),
    timezone: str(o.timezone) ?? 'UTC', currency: (str(o.currency) ?? 'USD').toUpperCase(),
    eventDay: str(o.event_day), onSaleDay: str(o.on_sale_day), onSaleDaysBefore: intOrNull(o.on_sale_days_before),
    daysOutNow: intOrNull(o.days_out_now),
    totals: {
      paidOrders: num(t.paid_orders), paidTickets: num(t.paid_tickets), grossCents: num(t.gross_cents),
      freeOrders: num(t.free_orders), freeTickets: num(t.free_tickets),
    },
    rows: arr(o.rows).map(pacingDay),
  };
}

/** exos_event_attendance's jsonb as a typed report; null when it isn't one. */
export function parseAttendanceReport(raw: unknown): AttendanceReport | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = obj(raw);
  const a = obj(o.attendance);
  const t = obj(a.totals);
  const p = obj(o.pacing);
  return {
    eventId: str(o.event_id) ?? '',
    generatedAt: str(o.generated_at),
    minBuyers: num(o.min_buyers) || 5,
    totals: {
      buyers: num(t.buyers), orders: num(t.orders), tickets: num(t.tickets), checkedIn: num(t.checked_in),
      locatedOrders: num(t.located_orders),
    },
    postal: arr(a.postal).map(postalRow),
    postalOther: postalRow(a.postal_other),
    postalUnknown: postalRow(a.postal_unknown),
    otherTickets: num(a.other_tickets),
    event: parsePacing(p.event),
    comparison: parsePacing(p.comparison),
    candidates: arr(o.comparison_candidates).map((c) => {
      const x = obj(c);
      return { eventId: str(x.event_id) ?? '', name: str(x.name) ?? '', startsAt: str(x.starts_at) };
    }).filter((c) => c.eventId),
  };
}

// ── Pacing alignment ────────────────────────────────────────────────────

export interface PacePoint {
  /** The sale day (in that event's zone), or null before its first sale day in range. */
  day: string | null;
  paidTickets: number;
  grossCents: number;
  freeTickets: number;
  cumPaidTickets: number;
  cumGrossCents: number;
  cumFreeTickets: number;
}

export interface AlignedDay {
  daysBefore: number;
  /** null for the current event's days still ahead. */
  current: PacePoint | null;
  comparison: PacePoint | null;
}

function addDays(isoDay: string, n: number): string {
  const d = new Date(`${isoDay}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Days before the event a series spans: from its on-sale (or first sale) down to 0. */
export function seriesStart(s: PacingSeries): number {
  const fromRows = s.rows.reduce((m, r) => (r.daysBefore !== null && r.daysBefore > m ? r.daysBefore : m), 0);
  return Math.max(fromRows, s.onSaleDaysBefore ?? 0, 0);
}

function pointsByDay(s: PacingSeries, from: number): Map<number, PacePoint> {
  const byDay = new Map<number, PacingDay>();
  for (const r of s.rows) if (r.daysBefore !== null) byDay.set(r.daysBefore, r);
  const out = new Map<number, PacePoint>();
  let cumP = 0;
  let cumG = 0;
  let cumF = 0;
  for (let d = from; d >= 0; d--) {
    const r = byDay.get(d);
    if (r) {
      cumP = r.cumPaidTickets;
      cumG = r.cumGrossCents;
      cumF = r.cumFreeTickets;
    }
    out.set(d, {
      day: s.eventDay ? addDays(s.eventDay, -d) : null,
      paidTickets: r?.paidTickets ?? 0, grossCents: r?.grossCents ?? 0, freeTickets: r?.freeTickets ?? 0,
      cumPaidTickets: cumP, cumGrossCents: cumG, cumFreeTickets: cumF,
    });
  }
  return out;
}

/**
 * One row per day before the event, from the earlier on-sale of the two
 * series down to the event day (0). Running totals carry over days with no
 * sale; the current event's days still ahead (fewer days out than today)
 * are null. A series without an event day can't be aligned: [].
 */
export function alignPacing(event: PacingSeries | null, comparison: PacingSeries | null = null): AlignedDay[] {
  if (!event || !event.eventDay) return [];
  const cmp = comparison && comparison.eventDay ? comparison : null;
  const from = Math.max(seriesStart(event), cmp ? seriesStart(cmp) : 0);
  const cur = pointsByDay(event, from);
  const prev = cmp ? pointsByDay(cmp, from) : null;
  const today = event.daysOutNow;
  const out: AlignedDay[] = [];
  for (let d = from; d >= 0; d--) {
    out.push({
      daysBefore: d,
      current: today !== null && d < today ? null : cur.get(d) ?? null,
      comparison: prev ? prev.get(d) ?? null : null,
    });
  }
  return out;
}

export interface PaceSummary {
  daysBefore: number;
  currentTickets: number;
  comparisonTickets: number;
  currentGrossCents: number;
  comparisonGrossCents: number;
  /** Paid tickets ahead (+) or behind (−) the comparison at the same days out. */
  ticketDelta: number;
  /** That as a whole percent of the comparison; null when it had sold none. */
  ticketPct: number | null;
}

/** Where the current event stands against the comparison at the same days out (today, or the event day once past). */
export function paceSummary(aligned: AlignedDay[], daysOutNow: number | null): PaceSummary | null {
  if (!aligned.length) return null;
  const want = Math.max(daysOutNow ?? 0, 0);
  const row = aligned.find((a) => a.daysBefore === want)
    ?? [...aligned].reverse().find((a) => a.current !== null)
    ?? null;
  if (!row || !row.current || !row.comparison) return null;
  const cur = row.current.cumPaidTickets;
  const prev = row.comparison.cumPaidTickets;
  return {
    daysBefore: row.daysBefore,
    currentTickets: cur,
    comparisonTickets: prev,
    currentGrossCents: row.current.cumGrossCents,
    comparisonGrossCents: row.comparison.cumGrossCents,
    ticketDelta: cur - prev,
    ticketPct: prev > 0 ? Math.round(((cur - prev) / prev) * 100) : null,
  };
}

/** Checkpoints for the on-page table: these days out, when the series reaches them. */
export const PACE_CHECKPOINTS = [90, 60, 30, 21, 14, 7, 3, 1, 0] as const;

export function paceCheckpoints(aligned: AlignedDay[]): AlignedDay[] {
  const have = new Map(aligned.map((a) => [a.daysBefore, a]));
  return PACE_CHECKPOINTS.filter((d) => have.has(d)).map((d) => have.get(d)!);
}

// ── Display + XLSX ─────────────────────────────────────────────────────

/** A postal row's label: the code, else the row's own label (Other / No postal code). */
export function postalLabel(r: PostalRow): string {
  return r.postalCode ?? r.label ?? 'Unknown';
}

/** Every postal row of the table: the named areas, then Other, then No postal code (empty ones left out). */
export function postalTableRows(r: AttendanceReport): PostalRow[] {
  return [...r.postal, r.postalOther, r.postalUnknown].filter((x) => x.orders > 0);
}

const cents = (c: number) => Math.round(c) / 100;

/** The workbook: Summary, Postal codes, Pacing (aligned with the comparison when there is one). */
export function attendanceWorkbook(r: AttendanceReport, eventTitle: string): XlsxSheet[] {
  const ev = r.event;
  const cmp = r.comparison;
  const currency = ev?.currency ?? 'USD';
  const summary: XlsxSheet = {
    name: 'Summary',
    header: ['Item', 'Value'],
    rows: [
      ['Event', eventTitle],
      ['Generated', r.generatedAt ?? ''],
      ['Buyers', r.totals.buyers],
      ['Orders with live tickets', r.totals.orders],
      ['Live tickets', r.totals.tickets],
      ['Checked in', r.totals.checkedIn],
      ['Orders with a postal code', r.totals.locatedOrders],
      ['Tickets with no order (door sales, imports)', r.otherTickets],
      ['Paid tickets sold', ev?.totals.paidTickets ?? 0],
      [`Gross (${currency}, before refunds)`, cents(ev?.totals.grossCents ?? 0)],
      ['$0 orders (free claims, comps, RSVPs)', ev?.totals.freeOrders ?? 0],
      ['$0 tickets', ev?.totals.freeTickets ?? 0],
      ['On sale', ev?.onSaleDay ?? ''],
      ['Event day', ev?.eventDay ?? ''],
      ['Time zone', ev?.timezone ?? ''],
      ['Compared with', cmp ? `${cmp.name} (${cmp.eventDay ?? ''})` : 'None'],
      ['Privacy', `Postal areas with fewer than ${r.minBuyers} buyers are grouped as "Other (fewer than ${r.minBuyers})". No buyer-level data.`],
    ],
  };
  const postal: XlsxSheet = {
    name: 'Postal codes',
    header: ['country', 'postal_code', 'buyers', 'orders', 'tickets', 'checked_in'],
    rows: postalTableRows(r).map((p) => [p.country ?? '', postalLabel(p), p.buyers, p.orders, p.tickets, p.checkedIn]),
  };
  const aligned = alignPacing(ev, cmp);
  const header = ['days_before', 'date', 'paid_tickets', 'gross', 'free_tickets', 'cum_paid_tickets', 'cum_gross', 'cum_free_tickets'];
  if (cmp) header.push('comparison_date', 'comparison_cum_paid_tickets', 'comparison_cum_gross', 'comparison_cum_free_tickets');
  const pacing: XlsxSheet = {
    name: 'Pacing',
    header,
    moneyColumns: cmp ? [3, 6, 10] : [3, 6],
    rows: aligned.map((a) => {
      const c = a.current;
      const row: (string | number)[] = c
        ? [a.daysBefore, c.day ?? '', c.paidTickets, cents(c.grossCents), c.freeTickets, c.cumPaidTickets, cents(c.cumGrossCents), c.cumFreeTickets]
        : [a.daysBefore, '', '', '', '', '', '', ''];
      if (cmp) {
        const p = a.comparison;
        row.push(p?.day ?? '', p ? p.cumPaidTickets : '', p ? cents(p.cumGrossCents) : '', p ? p.cumFreeTickets : '');
      }
      return row;
    }),
  };
  return [summary, postal, pacing];
}
