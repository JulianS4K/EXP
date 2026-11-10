// Per-gate throughput on the door report (exos_door_throughput, mig
// 20261113110000): entries per 15 minutes (or 5 / 30 / 60) per gate and
// list, the lot's add-on codes in their own column, gate totals (devices,
// the busiest stretch), how many are in the park now where gates scan people
// out (re-entry lists), and refusals by reason. Today in the event's time
// zone by default; refreshes every minute while open. Hidden when the
// database doesn't have it yet or the caller's role can't read it.

import { useEffect, useState } from 'react';
import { Gauge, RefreshCw } from 'lucide-react';
import { fetchDoorThroughput } from '../lib/door/api';
import {
  BUCKET_MINUTES, bucketLabel, peakPerMinute, throughputGrid, throughputRefusalText, todayWindow, type DoorThroughput,
} from '../lib/door/throughput';
import { timeIn } from '../lib/door/summary';

type Range = 'today' | '24h' | '3d';
const REFRESH_MS = 60_000;

function windowFor(range: Range, timezone: string): { from: string; until: string } {
  const now = Date.now();
  if (range === 'today') return todayWindow(now, timezone);
  const hours = range === '24h' ? 24 : 72;
  return { from: new Date(now - hours * 3600e3).toISOString(), until: new Date(now).toISOString() };
}

export default function DoorThroughputPanel({ eventId, timezone }: { eventId: string; timezone?: string }) {
  const [data, setData] = useState<DoorThroughput | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'hidden' | 'error'>('loading');
  const [range, setRange] = useState<Range>('today');
  const [minutes, setMinutes] = useState<number>(15);
  const [tick, setTick] = useState(0);
  const tz = data?.timezone || timezone || 'UTC';

  useEffect(() => { setData(null); setState('loading'); }, [eventId]);

  useEffect(() => {
    let alive = true;
    const w = windowFor(range, timezone || 'UTC');
    fetchDoorThroughput(eventId, w.from, w.until, minutes)
      .then((t) => {
        if (!alive) return;
        setData(t);
        setState(t ? 'ready' : 'hidden');
      })
      .catch((err) => {
        console.warn('door throughput unavailable', err);
        if (alive) setState('error');
      });
    return () => { alive = false; };
  }, [eventId, range, minutes, timezone, tick]);

  useEffect(() => {
    if (state === 'hidden') return undefined;
    const id = setInterval(() => {
      if (typeof document === 'undefined' || document.visibilityState === 'visible') setTick((t) => t + 1);
    }, REFRESH_MS);
    return () => clearInterval(id);
  }, [state]);

  if (state === 'hidden') return null;
  if (!data) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm text-sm text-slate-600 flex items-center justify-between gap-3">
        <span>{state === 'error' ? "Gate throughput didn't load." : 'Loading gate throughput…'}</span>
        {state === 'error' && (
          <button type="button" onClick={() => setTick((t) => t + 1)} className="text-[#026cdf] font-bold text-xs uppercase tracking-widest">
            Try again
          </button>
        )}
      </div>
    );
  }

  const grid = throughputGrid(data);
  const ticketGates = data.gates.filter((g) => g.kind === 'ticket');
  const totalIn = ticketGates.reduce((s, g) => s + g.entries, 0);
  const busiest = [...ticketGates].sort((a, b) => b.peakEntries - a.peakEntries)[0];
  const hasLot = data.gates.some((g) => g.kind === 'addon') || data.inside.some((i) => i.admits === 'addons');

  return (
    <section aria-labelledby="door-throughput-title" className="bg-white rounded-2xl p-6 shadow-sm space-y-6" data-testid="door-throughput">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 id="door-throughput-title" className="text-sm font-bold text-slate-700 flex items-center gap-2">
            <Gauge size={14} aria-hidden="true" /> Gate throughput
          </h3>
          <p className="text-xs text-slate-600 mt-1">Times in {tz.replace(/_/g, ' ')} · refreshes every minute</p>
          {state === 'error' && <p role="status" className="text-xs text-red-700 mt-1">Refresh failed; showing the last numbers.</p>}
        </div>
        <div className="flex flex-wrap gap-2 items-center">
          <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5">
            Window
            <select value={range} onChange={(e) => setRange(e.target.value as Range)}
              className="border border-slate-300 rounded-lg px-2 py-1.5 text-xs text-slate-800 bg-white">
              <option value="today">Today</option>
              <option value="24h">Last 24 hours</option>
              <option value="3d">Last 3 days</option>
            </select>
          </label>
          <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5">
            Per
            <select value={minutes} onChange={(e) => setMinutes(Number(e.target.value))}
              className="border border-slate-300 rounded-lg px-2 py-1.5 text-xs text-slate-800 bg-white">
              {BUCKET_MINUTES.map((m) => <option key={m} value={m}>{m} minutes</option>)}
            </select>
          </label>
          <button type="button" onClick={() => setTick((t) => t + 1)} aria-label="Refresh gate throughput"
            className="p-2 rounded-lg border border-slate-300 text-slate-600 hover:text-slate-900">
            <RefreshCw size={14} aria-hidden="true" />
          </button>
        </div>
      </div>

      <dl className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {data.tracksDirection && (
          <div className="bg-slate-50 rounded-xl p-4">
            <dt className="text-[11px] font-bold uppercase tracking-widest text-slate-600">In the park now</dt>
            <dd className="text-2xl font-black text-slate-900" data-testid="in-park-now">{data.inParkNow.toLocaleString('en-US')}</dd>
          </div>
        )}
        {hasLot && (
          <div className="bg-slate-50 rounded-xl p-4">
            <dt className="text-[11px] font-bold uppercase tracking-widest text-slate-600">In the lot now</dt>
            <dd className="text-2xl font-black text-slate-900">{data.lotNow.toLocaleString('en-US')}</dd>
          </div>
        )}
        <div className="bg-slate-50 rounded-xl p-4">
          <dt className="text-[11px] font-bold uppercase tracking-widest text-slate-600">Entries</dt>
          <dd className="text-2xl font-black text-slate-900">{totalIn.toLocaleString('en-US')}</dd>
        </div>
        <div className="bg-slate-50 rounded-xl p-4">
          <dt className="text-[11px] font-bold uppercase tracking-widest text-slate-600">Busiest gate</dt>
          <dd className="text-lg font-black text-slate-900">{busiest ? busiest.gate : '—'}</dd>
          {busiest && <dd className="text-xs text-slate-600">{peakPerMinute(busiest, data.bucketMinutes).toFixed(1)} a minute at peak</dd>}
        </div>
      </dl>

      {grid.rows.length === 0 ? (
        <p className="text-sm text-slate-600">No scans in this window yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs text-left">
            <caption className="text-left text-xs font-bold text-slate-700 pb-2">Entries per {data.bucketMinutes} minutes, by gate</caption>
            <thead>
              <tr className="text-slate-600 border-b border-slate-200">
                <th scope="col" className="py-2 pr-3 font-bold">Time</th>
                {grid.columns.map((c) => (
                  <th key={c.key} scope="col" className="py-2 pr-3 font-bold text-right">{c.label}{c.kind === 'addon' ? ' (lot codes)' : ''}</th>
                ))}
                <th scope="col" className="py-2 font-bold text-right">All gates</th>
              </tr>
            </thead>
            <tbody>
              {grid.rows.map((r) => (
                <tr key={r.at} className="border-b border-slate-100 text-slate-800">
                  <th scope="row" className="py-1.5 pr-3 font-medium whitespace-nowrap">{bucketLabel(r.at, data.bucketMinutes, tz)}</th>
                  {r.cells.map((n, i) => <td key={grid.columns[i].key} className="py-1.5 pr-3 text-right tabular-nums">{n || ''}</td>)}
                  <td className="py-1.5 text-right font-bold tabular-nums">{r.total}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {data.gates.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-xs text-left">
            <caption className="text-left text-xs font-bold text-slate-700 pb-2">Gates and lists</caption>
            <thead>
              <tr className="text-slate-600 border-b border-slate-200">
                <th scope="col" className="py-2 pr-3 font-bold">Gate</th>
                <th scope="col" className="py-2 pr-3 font-bold text-right">In</th>
                <th scope="col" className="py-2 pr-3 font-bold text-right">Out</th>
                <th scope="col" className="py-2 pr-3 font-bold text-right">Offline admits</th>
                <th scope="col" className="py-2 pr-3 font-bold text-right">Devices</th>
                <th scope="col" className="py-2 pr-3 font-bold text-right">Peak a minute</th>
                <th scope="col" className="py-2 font-bold text-right">Last scan</th>
              </tr>
            </thead>
            <tbody>
              {data.gates.map((g) => (
                <tr key={`${g.kind}:${g.listId}:${g.gate}`} className="border-b border-slate-100 text-slate-800">
                  <th scope="row" className="py-1.5 pr-3 font-medium">{g.gate}{g.kind === 'addon' ? ' (lot codes)' : ''}</th>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{g.entries}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{g.exits}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{g.forced}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{g.devices}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{peakPerMinute(g, data.bucketMinutes).toFixed(1)}</td>
                  <td className="py-1.5 text-right">{timeIn(g.lastAt, tz)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {data.inside.length > 0 && (
        <div>
          <h4 className="text-xs font-bold text-slate-700 pb-2">Inside now, by list (lists that scan people out)</h4>
          <ul className="text-xs text-slate-800 space-y-1">
            {data.inside.map((i) => (
              <li key={i.listId}>
                {i.name}: {i.admits === 'addons' ? `${i.addonsInside} lot codes` : `${i.ticketsInside} people`}
                {i.openNow ? '' : ' (closed now)'}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div>
        <h4 className="text-xs font-bold text-slate-700 pb-2">Refused, by reason</h4>
        {data.refusals.length === 0 ? (
          <p className="text-xs text-slate-600">No refusals in this window.</p>
        ) : (
          <ul className="text-xs text-slate-800 space-y-1" data-testid="throughput-refusals">
            {data.refusals.map((r) => <li key={r.reason}>{throughputRefusalText(r.reason)}: {r.count}</li>)}
          </ul>
        )}
      </div>
    </section>
  );
}
