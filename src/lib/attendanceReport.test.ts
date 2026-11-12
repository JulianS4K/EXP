import { describe, expect, it } from 'vitest';
import {
  alignPacing, attendanceWorkbook, paceCheckpoints, paceSummary, parseAttendanceReport, parsePacing, postalTableRows,
} from './attendanceReport';
import { buildXlsx } from './xlsx';

const day = (d: string, before: number, paid: number, gross: number, free: number, cum: [number, number, number]) => ({
  day: d, days_before: before, paid_orders: paid ? 1 : 0, paid_tickets: paid, gross_cents: gross, free_orders: free ? 1 : 0,
  free_tickets: free, cum_paid_tickets: cum[0], cum_gross_cents: cum[1], cum_free_tickets: cum[2],
});

// As exos_event_attendance answers (mig 20261113120000; the SQL test's e2 / e0).
const RAW = {
  org_id: 'o1', event_id: 'e2', generated_at: '2026-12-12T10:00:00Z', min_buyers: 5,
  attendance: {
    totals: { buyers: 17, orders: 18, tickets: 24, checked_in: 2, located_orders: 16 },
    postal: [
      { country: 'CA', postal_code: 'K1A', buyers: 5, orders: 5, tickets: 5, checked_in: 0 },
      { country: 'US', postal_code: '10001', buyers: 5, orders: 5, tickets: 5, checked_in: 1 },
    ],
    postal_other: { label: 'Other (fewer than 5)', buyers: 5, orders: 6, tickets: 11, checked_in: 0 },
    postal_unknown: { label: 'No postal code', buyers: 0, orders: 0, tickets: 0, checked_in: 0 },
    other_tickets: 1,
  },
  pacing: {
    event: {
      event_id: 'e2', name: 'Pacing', starts_at: '2026-12-21T01:00:00Z', timezone: 'America/New_York', currency: 'usd',
      event_day: '2026-12-20', on_sale_day: '2026-12-08', on_sale_days_before: 12, days_out_now: 8,
      totals: { paid_orders: 3, paid_tickets: 5, gross_cents: 11000, free_orders: 1, free_tickets: 3 },
      rows: [day('2026-12-10', 10, 3, 5500, 0, [3, 5500, 0])],
    },
    comparison: {
      event_id: 'e0', name: 'Last Year', starts_at: '2025-12-20T01:00:00Z', timezone: 'America/New_York', currency: 'USD',
      event_day: '2025-12-19', on_sale_day: '2025-11-21', on_sale_days_before: 28, days_out_now: -357,
      totals: { paid_orders: 2, paid_tickets: 5, gross_cents: 10000, free_orders: 0, free_tickets: 0 },
      rows: [day('2025-12-09', 10, 4, 8000, 0, [4, 8000, 0]), day('2025-12-18', 1, 1, 2000, 0, [5, 10000, 0])],
    },
  },
  comparison_candidates: [{ event_id: 'e0', name: 'Last Year', starts_at: '2025-12-20T01:00:00Z' }, { name: 'no id' }],
};

describe('attendance report: parsing', () => {
  it('reads the RPC answer', () => {
    const r = parseAttendanceReport(RAW)!;
    expect(r.totals).toEqual({ buyers: 17, orders: 18, tickets: 24, checkedIn: 2, locatedOrders: 16 });
    expect(r.postal.map((p) => p.postalCode)).toEqual(['K1A', '10001']);
    expect(r.postalOther.label).toBe('Other (fewer than 5)');
    expect(r.event!.currency).toBe('USD');
    expect(r.event!.rows[0]).toMatchObject({ daysBefore: 10, paidTickets: 3, grossCents: 5500, cumPaidTickets: 3 });
    expect(r.candidates).toEqual([{ eventId: 'e0', name: 'Last Year', startsAt: '2025-12-20T01:00:00Z' }]);
    // Empty rows (no unknown orders) are left out of the table.
    expect(postalTableRows(r).map((p) => p.postalCode ?? p.label)).toEqual(['K1A', '10001', 'Other (fewer than 5)']);
  });

  it('tolerates a missing or partial answer', () => {
    expect(parseAttendanceReport(null)).toBeNull();
    expect(parseAttendanceReport('x')).toBeNull();
    const r = parseAttendanceReport({ attendance: {}, pacing: { event: null, comparison: null } })!;
    expect(r.postal).toEqual([]);
    expect(r.minBuyers).toBe(5);
    expect(r.event).toBeNull();
    expect(alignPacing(r.event, r.comparison)).toEqual([]);
  });
});

describe('attendance report: pacing math', () => {
  const r = parseAttendanceReport(RAW)!;
  const aligned = alignPacing(r.event, r.comparison);

  it('spans the earlier on-sale down to the event day, by days before', () => {
    // The comparison went on sale 28 days out, this one 12.
    expect(aligned[0].daysBefore).toBe(28);
    expect(aligned[aligned.length - 1].daysBefore).toBe(0);
    expect(aligned).toHaveLength(29);
  });

  it('lines the two events up by days before, carrying running totals', () => {
    const d10 = aligned.find((a) => a.daysBefore === 10)!;
    expect(d10.current).toMatchObject({ day: '2026-12-10', paidTickets: 3, cumPaidTickets: 3, cumGrossCents: 5500 });
    expect(d10.comparison).toMatchObject({ day: '2025-12-09', paidTickets: 4, cumPaidTickets: 4, cumGrossCents: 8000 });
    // A day with no sale keeps yesterday's running total and sells nothing.
    const d9 = aligned.find((a) => a.daysBefore === 9)!;
    expect(d9.current).toMatchObject({ day: '2026-12-11', paidTickets: 0, cumPaidTickets: 3 });
    expect(d9.comparison).toMatchObject({ paidTickets: 0, cumPaidTickets: 4 });
    // Before anything sold: zero.
    expect(aligned[0].current).toMatchObject({ cumPaidTickets: 0, cumGrossCents: 0 });
    expect(aligned.find((a) => a.daysBefore === 1)!.comparison!.cumPaidTickets).toBe(5);
  });

  it('leaves the current event\'s days still ahead empty', () => {
    // 8 days out today: day 8 is filled, 7..0 are null; the comparison is complete.
    expect(aligned.find((a) => a.daysBefore === 8)!.current).not.toBeNull();
    expect(aligned.filter((a) => a.current === null).map((a) => a.daysBefore)).toEqual([7, 6, 5, 4, 3, 2, 1, 0]);
    expect(aligned.every((a) => a.comparison !== null)).toBe(true);
  });

  it('summarizes the pace at today\'s days out', () => {
    expect(paceSummary(aligned, 8)).toEqual({
      daysBefore: 8, currentTickets: 3, comparisonTickets: 4, currentGrossCents: 5500, comparisonGrossCents: 8000,
      ticketDelta: -1, ticketPct: -25,
    });
    // A past event: compared on the event day.
    const past = alignPacing({ ...r.event!, daysOutNow: -3 }, r.comparison);
    expect(past.every((a) => a.current !== null)).toBe(true);
    expect(paceSummary(past, -3)).toMatchObject({ daysBefore: 0, currentTickets: 3, comparisonTickets: 5, ticketPct: -40 });
    // No comparison: no summary; a comparison that had sold nothing: no percent.
    expect(paceSummary(alignPacing(r.event, null), 8)).toBeNull();
    const none = alignPacing(r.event, { ...r.comparison!, rows: [] });
    expect(paceSummary(none, 8)).toMatchObject({ comparisonTickets: 0, ticketDelta: 3, ticketPct: null });
  });

  it('works without a comparison and without a start date', () => {
    const solo = alignPacing(r.event, null);
    expect(solo[0].daysBefore).toBe(12);
    expect(solo.every((a) => a.comparison === null)).toBe(true);
    expect(alignPacing({ ...r.event!, eventDay: null }, r.comparison)).toEqual([]);
    // A comparison that can't be aligned is dropped, not misaligned.
    expect(alignPacing(r.event, { ...r.comparison!, eventDay: null })[0].daysBefore).toBe(12);
  });

  it('picks the checkpoints the series reaches', () => {
    expect(paceCheckpoints(aligned).map((a) => a.daysBefore)).toEqual([21, 14, 7, 3, 1, 0]);
  });

  it('reads a series with no rows', () => {
    const s = parsePacing({ event_id: 'x', event_day: '2026-01-10', on_sale_days_before: null, days_out_now: 2, rows: [] })!;
    expect(alignPacing(s)).toHaveLength(1);
    expect(alignPacing(s)[0]).toMatchObject({ daysBefore: 0, current: null });
  });
});

describe('attendance report: workbook', () => {
  const r = parseAttendanceReport(RAW)!;

  it('has Summary, Postal codes and Pacing sheets with the aggregate rows only', () => {
    const wb = attendanceWorkbook(r, 'Pacing Night');
    expect(wb.map((s) => s.name)).toEqual(['Summary', 'Postal codes', 'Pacing']);
    expect(wb[0].rows).toContainEqual(['Event', 'Pacing Night']);
    expect(wb[0].rows).toContainEqual(['Gross (USD, before refunds)', 110]);
    expect(wb[0].rows).toContainEqual(['Compared with', 'Last Year (2025-12-19)']);
    expect(wb[1].rows).toEqual([
      ['CA', 'K1A', 5, 5, 5, 0],
      ['US', '10001', 5, 5, 5, 1],
      ['', 'Other (fewer than 5)', 5, 6, 11, 0],
    ]);
    const pace = wb[2];
    expect(pace.header).toContain('comparison_cum_paid_tickets');
    const d10 = pace.rows.find((row) => row[0] === 10)!;
    expect(d10).toEqual([10, '2026-12-10', 3, 55, 0, 3, 55, 0, '2025-12-09', 4, 80, 0]);
    // Days still ahead: the current columns are blank, the comparison's filled.
    expect(pace.rows.find((row) => row[0] === 0)!.slice(1, 8)).toEqual(['', '', '', '', '', '', '']);
    expect(pace.rows.find((row) => row[0] === 0)![9]).toBe(5);
    // It builds.
    expect(buildXlsx(wb).length).toBeGreaterThan(1000);
  });

  it('drops the comparison columns when there is none', () => {
    const wb = attendanceWorkbook({ ...r, comparison: null }, 'X');
    expect(wb[2].header).toHaveLength(8);
    expect(wb[0].rows).toContainEqual(['Compared with', 'None']);
  });
});
