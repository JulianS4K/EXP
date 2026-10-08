// End-of-night door summary (exos_event_door_summary, mig 20261008090000):
// one server-side read with the night's totals, the busiest stretch, entries
// per hour in the event's time zone, ticket types, lists, staff and what
// needs a look (overrides, offline conflicts, refused scans). Copy as text or
// download as CSV. Hidden when the database doesn't have the RPC yet or the
// caller's role can't read it.

import { useEffect, useState } from 'react';
import { ClipboardCopy, Download, Moon, RefreshCw } from 'lucide-react';
import { fetchDoorSummary } from '../lib/door/api';
import {
  SUMMARY_CSV_HEADER,
  hourLabel,
  refusalText,
  showRate,
  summaryCsvRows,
  summaryText,
  timeIn,
  verificationText,
  type DoorSummary,
} from '../lib/door/summary';
import { conflictText } from '../lib/door/health';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';

export default function DoorSummaryPanel({ eventId, eventTitle }: { eventId: string; eventTitle?: string }) {
  const [summary, setSummary] = useState<DoorSummary | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'hidden' | 'error'>('loading');
  const [copied, setCopied] = useState(false);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let alive = true;
    setState((s) => (s === 'ready' ? s : 'loading'));
    fetchDoorSummary(eventId)
      .then((s) => {
        if (!alive) return;
        setSummary(s);
        setState(s ? 'ready' : 'hidden');
      })
      .catch((err) => {
        console.warn('door summary unavailable', err);
        if (alive) setState('error');
      });
    return () => {
      alive = false;
    };
  }, [eventId, tick]);

  if (state === 'hidden') return null;
  if (state === 'loading' && !summary) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm h-[120px] flex items-center justify-center text-slate-300 text-xs font-bold uppercase tracking-widest animate-pulse">
        Loading door summary…
      </div>
    );
  }
  if (state === 'error' && !summary) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm text-sm text-slate-500 flex items-center justify-between gap-3">
        <span>The door summary didn't load.</span>
        <button type="button" onClick={() => setTick((t) => t + 1)} className="text-[#026cdf] font-bold text-xs uppercase tracking-widest">
          Try again
        </button>
      </div>
    );
  }
  if (!summary) return null;

  const s = summary;
  const rate = showRate(s);
  const tz = s.timezone;
  const maxHour = Math.max(1, ...s.byHour.map((h) => h.entries));
  const issues = s.overrides.length + s.conflicts.length + s.refused.length;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(summaryText(s));
      setCopied(true);
      setTimeout(() => setCopied(false), 2_000);
    } catch {
      setCopied(false);
    }
  };
  const csv = () =>
    downloadCsv(csvFileName(['door-summary', eventTitle ?? s.eventName]), toCsv(SUMMARY_CSV_HEADER, summaryCsvRows(s)));

  return (
    <section aria-labelledby="door-summary-title" className="bg-white rounded-2xl p-6 shadow-sm space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 id="door-summary-title" className="text-sm font-bold text-slate-700 flex items-center gap-2">
            <Moon size={14} /> End-of-night door summary
          </h3>
          <p className="text-xs text-slate-400 mt-1">
            Times in {tz.replace(/_/g, ' ')}
            {s.generatedAt ? ` · as of ${timeIn(s.generatedAt, tz)}` : ''}
          </p>
        </div>
        <div className="flex gap-2">
          <button type="button" onClick={() => setTick((t) => t + 1)} aria-label="Refresh the door summary"
            className="p-2 rounded-lg border border-slate-200 text-slate-500 hover:text-slate-800">
            <RefreshCw size={14} />
          </button>
          <button type="button" onClick={copy}
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg border border-slate-200 text-xs font-bold text-slate-600 hover:text-slate-900">
            <ClipboardCopy size={14} /> {copied ? 'Copied' : 'Copy'}
          </button>
          <button type="button" onClick={csv}
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg border border-slate-200 text-xs font-bold text-slate-600 hover:text-slate-900">
            <Download size={14} /> CSV
          </button>
        </div>
      </div>

      <dl className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Tile label="Checked in" value={`${s.checkedIn} / ${s.sold}`} sub={rate === null ? undefined : `${rate}% showed up`} />
        <Tile label="No-shows" value={`${s.noShows}`} />
        <Tile
          label="Doors"
          value={s.firstEntryAt ? `${timeIn(s.firstEntryAt, tz)}` : '—'}
          sub={s.lastEntryAt ? `last in ${timeIn(s.lastEntryAt, tz)}` : undefined}
        />
        <Tile
          label="Busiest 15 min"
          value={s.peak ? `${s.peak.entries}` : '—'}
          sub={s.peak ? `from ${timeIn(s.peak.start, tz)}` : undefined}
        />
      </dl>

      {(s.entries.reentries > 0 || s.entries.exits > 0 || s.entries.offline > 0 || s.insideNow !== null) && (
        <p className="text-xs text-slate-500">
          {[
            s.entries.reentries ? `${s.entries.reentries} re-entr${s.entries.reentries === 1 ? 'y' : 'ies'}` : null,
            s.entries.exits ? `${s.entries.exits} exit${s.entries.exits === 1 ? '' : 's'}` : null,
            s.entries.offline ? `${s.entries.offline} scanned offline` : null,
            s.insideNow !== null ? `${s.insideNow} inside now` : null,
          ].filter(Boolean).join(' · ')}
        </p>
      )}

      {s.byHour.length > 0 && (
        <div>
          <h4 className="text-xs font-bold text-slate-500 uppercase tracking-widest mb-2">Entries by hour</h4>
          <ul className="space-y-1.5">
            {s.byHour.map((h) => (
              <li key={h.hour} className="flex items-center gap-3 text-xs">
                <span className="w-12 shrink-0 text-slate-500">{hourLabel(h.hour)}</span>
                <span className="flex-1 h-3 bg-slate-100 rounded">
                  <span className="block h-3 bg-[#026cdf] rounded" style={{ width: `${(h.entries / maxHour) * 100}%` }} />
                </span>
                <span className="w-10 text-right text-slate-700 font-bold">{h.entries}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {s.byTier.length > 0 && (
          <SmallTable
            title="By ticket type"
            head={['Type', 'In / sold']}
            rows={s.byTier.map((t) => [t.tier, `${t.checkedIn} / ${t.sold}`])}
          />
        )}
        {s.byStaff.length > 0 && (
          <SmallTable
            title="By staff"
            head={['Staff', 'In · refused']}
            rows={s.byStaff.map((t) => [t.staff, `${t.entries} · ${t.refused}`])}
          />
        )}
        {s.byList.length > 1 && (
          <SmallTable
            title="By list"
            head={['List', 'In · out']}
            rows={s.byList.map((l) => [l.list, `${l.entries} · ${l.exits}`])}
          />
        )}
        {s.entries.byVerification.length > 0 && (
          <SmallTable
            title="How they got in"
            head={['Method', 'Entries']}
            rows={s.entries.byVerification.map((v) => [verificationText(v.key), `${v.count}`])}
          />
        )}
      </div>

      {issues > 0 && (
        <div>
          <h4 className="text-xs font-bold text-slate-500 uppercase tracking-widest mb-2">Needs a look</h4>
          <ul className="text-sm text-slate-700 space-y-1">
            {s.overrides.map((o) => (
              <li key={`o-${o.key}`}>Manual override, “{o.key}”: <b>{o.count}</b></li>
            ))}
            {s.conflicts.map((c) => (
              <li key={`c-${c.key}`}>Let in offline, then refused ({conflictText({ reason: c.key, forced: false })}): <b>{c.count}</b></li>
            ))}
            {s.refused.map((r) => (
              <li key={`r-${r.key}`}>Refused at the door ({refusalText(r.key)}): <b>{r.count}</b></li>
            ))}
          </ul>
          {s.voidedEntered > 0 && (
            <p className="text-xs text-slate-400 mt-2">
              {s.voidedEntered} refunded or voided ticket{s.voidedEntered === 1 ? '' : 's'} got in while a door was offline.
            </p>
          )}
        </div>
      )}
    </section>
  );
}

function Tile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="bg-slate-50 rounded-xl p-4">
      <dt className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">{label}</dt>
      <dd className="text-xl font-black text-slate-900 mt-1">{value}</dd>
      {sub && <dd className="text-xs text-slate-500 mt-0.5">{sub}</dd>}
    </div>
  );
}

function SmallTable({ title, head, rows }: { title: string; head: [string, string]; rows: string[][] }) {
  return (
    <div>
      <h4 className="text-xs font-bold text-slate-500 uppercase tracking-widest mb-2">{title}</h4>
      <table className="w-full text-sm">
        <thead className="sr-only">
          <tr><th>{head[0]}</th><th>{head[1]}</th></tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={`${i}-${r[0]}`} className="border-b border-slate-50 last:border-b-0">
              <td className="py-1.5 text-slate-700">{r[0]}</td>
              <td className="py-1.5 text-slate-500 text-right whitespace-nowrap">{r[1]}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
