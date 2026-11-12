// The attendance report, on the event report's Attendees tab (mig
// 20261113120000; docs/fans.md "Attendance report"). Read-only, owner /
// manager / finance. Two parts:
//   * where attendees are by billing postal code (aggregate only: an area
//     with fewer than 5 buyers is folded into "Other (fewer than 5)" in SQL,
//     before it reaches the browser; no buyer-level rows);
//   * daily sales pace, optionally against an earlier event of the org,
//     lined up by days before the event ($0 tickets apart from gross).
// "Download XLSX" builds a three-sheet workbook in the browser (the writer
// loads on the click) and logs export.run. Hidden when the report can't be
// read (role, or the migration not applied yet).

import { useEffect, useMemo, useRef, useState } from 'react';
import { Download, MapPin } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import {
  alignPacing, attendanceWorkbook, paceCheckpoints, paceSummary, postalLabel, postalTableRows,
  type AlignedDay, type AttendanceReport,
} from '../lib/attendanceReport';
import { getEventAttendance } from '../lib/attendanceReportApi';
import { saveXlsx } from '../lib/xlsxDownload';

const CHART_W = 640;
const CHART_H = 160;
const PAD = 28;

function PaceChart({ aligned, label }: { aligned: AlignedDay[]; label: string }) {
  if (aligned.length < 2) return null;
  const max = Math.max(1, ...aligned.map((a) => Math.max(a.current?.cumPaidTickets ?? 0, a.comparison?.cumPaidTickets ?? 0)));
  const first = aligned[0].daysBefore;
  const x = (d: number) => PAD + ((first - d) / Math.max(first, 1)) * (CHART_W - PAD * 2);
  const y = (n: number) => CHART_H - PAD - (n / max) * (CHART_H - PAD * 2);
  const line = (pick: (a: AlignedDay) => number | null) => aligned
    .map((a) => ({ d: a.daysBefore, v: pick(a) }))
    .filter((p): p is { d: number; v: number } => p.v !== null)
    .map((p, i) => `${i ? 'L' : 'M'}${x(p.d).toFixed(1)},${y(p.v).toFixed(1)}`).join(' ');
  const cur = line((a) => a.current?.cumPaidTickets ?? null);
  const cmp = line((a) => a.comparison?.cumPaidTickets ?? null);
  return (
    <svg viewBox={`0 0 ${CHART_W} ${CHART_H}`} className="w-full h-auto" role="img" aria-label={label}>
      <line x1={PAD} y1={CHART_H - PAD} x2={CHART_W - PAD} y2={CHART_H - PAD} stroke="#cbd5e1" />
      <text x={PAD} y={CHART_H - 8} fontSize="10" fill="#475569">{first} days out</text>
      <text x={CHART_W - PAD} y={CHART_H - 8} fontSize="10" fill="#475569" textAnchor="end">Event day</text>
      <text x={PAD} y={PAD - 10} fontSize="10" fill="#475569">{max} tickets</text>
      {cmp && <path d={cmp} fill="none" stroke="#94a3b8" strokeWidth="2" strokeDasharray="4 3" />}
      {cur && <path d={cur} fill="none" stroke="#026cdf" strokeWidth="2.5" />}
    </svg>
  );
}

export default function AttendanceReportPanel({ eventId, orgId, eventTitle, canView }: {
  eventId: string; orgId?: string | null; eventTitle: string; canView: boolean;
}) {
  const [compareId, setCompareId] = useState<string>('');
  const [report, setReport] = useState<AttendanceReport | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'hidden' | 'rate_limited' | 'not_found'>('loading');
  const [busy, setBusy] = useState(false);
  // A failed refresh keeps the last answer on screen.
  const hadReport = useRef(false);

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    setState('loading');
    void getEventAttendance(eventId, compareId || null).then((r) => {
      if (cancelled) return;
      if ('report' in r) {
        hadReport.current = true;
        setReport(r.report);
        setState('ready');
      } else if (r.error === 'unavailable') {
        setState(hadReport.current ? 'ready' : 'hidden');
      } else {
        setState(r.error);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [eventId, compareId, canView]);

  const aligned = useMemo(() => alignPacing(report?.event ?? null, report?.comparison ?? null), [report]);
  const pace = useMemo(() => paceSummary(aligned, report?.event?.daysOutNow ?? null), [aligned, report]);

  if (!canView || state === 'hidden') return null;

  const ev = report?.event ?? null;
  const cmp = report?.comparison ?? null;
  const currency = ev?.currency ?? 'USD';
  const rows = report ? postalTableRows(report) : [];
  const checkpoints = paceCheckpoints(aligned);

  const download = async () => {
    if (!report) return;
    setBusy(true);
    try {
      await saveXlsx(['attendance', eventTitle], attendanceWorkbook(report, eventTitle), { orgId, eventId, kind: 'attendance' });
    } finally {
      setBusy(false);
    }
  };

  const stat = (label: string, value: string) => (
    <div className="bg-slate-50 rounded-xl px-4 py-3">
      <p className="text-[10px] font-black text-slate-500 uppercase tracking-widest">{label}</p>
      <p className="text-lg font-black text-slate-800">{value}</p>
    </div>
  );

  const paceText = pace && cmp
    ? `At ${pace.daysBefore} day${pace.daysBefore === 1 ? '' : 's'} out: ${pace.currentTickets} paid ticket${pace.currentTickets === 1 ? '' : 's'}, against ${pace.comparisonTickets} for ${cmp.name}${pace.ticketPct === null ? '' : ` (${pace.ticketPct > 0 ? '+' : ''}${pace.ticketPct}%)`}.`
    : null;
  const chartLabel = `Paid tickets sold so far by days before the event${cmp ? `, this event against ${cmp.name}` : ''}.${paceText ? ' ' + paceText : ''}`;

  return (
    <section id="attendance-report" className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="attendance-title">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
        <div className="flex items-center gap-2">
          <MapPin className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h3 id="attendance-title" className="text-sm font-bold text-slate-700">Attendance report</h3>
        </div>
        <button
          type="button"
          onClick={() => void download()}
          disabled={!report || busy}
          className="inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-700 hover:bg-slate-50 disabled:opacity-40"
        >
          <Download size={12} aria-hidden="true" /> {busy ? 'Preparing…' : 'Download XLSX'}
        </button>
      </div>
      <p className="text-xs text-slate-500 mb-4">
        Where attendees are, by the billing postal code on each payment, and how sales are pacing. Totals only: a postal
        area with fewer than {report?.minBuyers ?? 5} buyers is grouped as “Other (fewer than {report?.minBuyers ?? 5})”.
        Free orders and RSVPs have no postal code.
      </p>

      {state === 'rate_limited' && (
        <p role="alert" className="text-sm text-amber-800 mb-3">Too many reports in a minute. Try again shortly.</p>
      )}
      {state === 'not_found' && (
        <p role="alert" className="text-sm text-amber-800 mb-3">That event can’t be compared. Pick another one.</p>
      )}

      {!report ? (
        <p className="text-sm text-slate-500">Loading…</p>
      ) : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-5">
            {stat('Buyers', String(report.totals.buyers))}
            {stat('Live tickets', String(report.totals.tickets))}
            {stat('Checked in', String(report.totals.checkedIn))}
            {stat('With a postal code', `${report.totals.locatedOrders} of ${report.totals.orders}`)}
          </div>

          <h4 className="text-[10px] font-black uppercase tracking-widest text-slate-500 mb-2">By postal code</h4>
          {rows.length === 0 ? (
            <p className="text-sm text-slate-500 mb-5">No orders yet.</p>
          ) : (
            <div className="mb-5">
              <table className="w-full text-xs sm:text-sm" aria-label="Attendees by postal code">
                <thead>
                  <tr className="text-left text-[10px] font-black text-slate-500 uppercase tracking-widest border-b border-slate-100">
                    <th scope="col" className="py-2 pr-2 font-black">Postal code</th>
                    <th scope="col" className="py-2 pr-2 text-right font-black break-words">Buyers</th>
                    <th scope="col" className="py-2 pr-2 text-right font-black break-words">Orders</th>
                    <th scope="col" className="py-2 pr-2 text-right font-black break-words">Tickets</th>
                    <th scope="col" className="py-2 text-right font-black break-words">Checked in</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={`${r.country}-${postalLabel(r)}`} className="border-b border-slate-50 last:border-0">
                      <td className={`py-2 pr-2 break-words ${r.postalCode ? 'text-slate-800' : 'text-slate-600 italic'}`}>
                        {postalLabel(r)}{r.country && <span className="ml-1 text-slate-500">{r.country}</span>}
                      </td>
                      <td className="py-2 pr-2 text-right tabular-nums">{r.buyers}</td>
                      <td className="py-2 pr-2 text-right tabular-nums">{r.orders}</td>
                      <td className="py-2 pr-2 text-right tabular-nums">{r.tickets}</td>
                      <td className="py-2 text-right tabular-nums">{r.checkedIn}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {report.otherTickets > 0 && (
            <p className="text-xs text-slate-500 -mt-3 mb-5">
              {report.otherTickets} more ticket{report.otherTickets === 1 ? '' : 's'} came from door sales or imports, with no order.
            </p>
          )}

          <div className="flex flex-wrap items-end justify-between gap-3 mb-2">
            <h4 className="text-[10px] font-black uppercase tracking-widest text-slate-500">Sales pace</h4>
            <label className="text-[10px] font-black uppercase tracking-widest text-slate-500">
              Compare with
              <select
                value={compareId}
                onChange={(e) => setCompareId(e.target.value)}
                className="block mt-1 bg-white border border-slate-200 rounded px-2 py-1.5 text-sm text-slate-900 normal-case tracking-normal font-normal"
              >
                <option value="">No comparison</option>
                {report.candidates.map((c) => (
                  <option key={c.eventId} value={c.eventId}>
                    {c.name}{c.startsAt ? ` (${c.startsAt.slice(0, 10)})` : ''}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {ev && (
            <p className="text-xs text-slate-500 mb-3">
              {ev.totals.paidTickets} paid ticket{ev.totals.paidTickets === 1 ? '' : 's'} sold, {formatCents(ev.totals.grossCents, currency)} gross
              (before refunds); {ev.totals.freeTickets} $0 ticket{ev.totals.freeTickets === 1 ? '' : 's'} (free claims, comps, RSVPs) counted
              apart. Days are in the event’s time zone ({ev.timezone}).
            </p>
          )}
          {paceText && <p className="text-sm font-semibold text-slate-800 mb-3">{paceText}</p>}
          {aligned.length === 0 ? (
            <p className="text-sm text-slate-500">No sales to pace yet.</p>
          ) : (
            <>
              <PaceChart aligned={aligned} label={chartLabel} />
              {checkpoints.length > 0 && (
                <div className="mt-3">
                  <table className="w-full text-xs sm:text-sm" aria-label="Paid tickets by days before the event">
                    <thead>
                      <tr className="text-left text-[10px] font-black text-slate-500 uppercase tracking-widest border-b border-slate-100">
                        <th scope="col" className="py-2 pr-3 font-black">Days out</th>
                        <th scope="col" className="py-2 pr-2 text-right font-black break-words">Paid tickets</th>
                        <th scope="col" className="py-2 pr-2 text-right font-black break-words">Gross</th>
                        {cmp && <th scope="col" className="py-2 pr-2 text-right font-black break-words">{cmp.name}: tickets</th>}
                        {cmp && <th scope="col" className="py-2 text-right font-black break-words">{cmp.name}: gross</th>}
                      </tr>
                    </thead>
                    <tbody>
                      {checkpoints.map((a) => (
                        <tr key={a.daysBefore} className="border-b border-slate-50 last:border-0">
                          <th scope="row" className="py-2 pr-2 text-left font-normal text-slate-700">{a.daysBefore === 0 ? 'Event day' : a.daysBefore}</th>
                          <td className="py-2 pr-2 text-right tabular-nums">{a.current ? a.current.cumPaidTickets : '—'}</td>
                          <td className="py-2 pr-2 text-right tabular-nums">{a.current ? formatCents(a.current.cumGrossCents, currency) : '—'}</td>
                          {cmp && <td className="py-2 pr-2 text-right tabular-nums">{a.comparison ? a.comparison.cumPaidTickets : '—'}</td>}
                          {cmp && <td className="py-2 text-right tabular-nums">{a.comparison ? formatCents(a.comparison.cumGrossCents, cmp.currency) : '—'}</td>}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </>
      )}
    </section>
  );
}
