// Sales by source, on the event report's Marketing tab. Read-only.
//
// Paid checkouts for this event (exos_checkout_sessions: fulfilled,
// partially_refunded, refunded), grouped by UTM source / medium / campaign,
// promoter code and the ad platform behind the click id; the rest is "Direct
// / unknown". RLS (exos_checkout_sel) lets org owner / manager / finance read
// the org's sessions, the same roles this report is open to. Aggregation is
// src/lib/sourceReport.ts.
//
// Older schemas degrade instead of failing: without ad_ids (mig 20260929131000)
// the platform comes from attribution.fbclid only; without attribution (mig
// 20260924223000) or when the read is refused, the panel hides.

import { useEffect, useMemo, useState } from 'react';
import { Download, Megaphone } from 'lucide-react';
import { Event } from '../types';
import { supabase } from '../lib/supabase';
import { fetchAllPages } from '../lib/door/roster';
import { formatCents } from '../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import {
  SOURCES_CSV_HEADER,
  sourcesCsvRows,
  summarizeSources,
  type SourceDimension,
  type SourceSessionRow,
} from '../lib/sourceReport';

const PAGE = 1000;
const BASE_COLS = 'session_id, status, quantity, amount_cents, currency, promoter_id, attribution';
const STATUSES = ['fulfilled', 'partially_refunded', 'refunded'];

async function readSessions(eventId: string, cols: string): Promise<SourceSessionRow[]> {
  return fetchAllPages<SourceSessionRow>(async (from, to) => {
    const { data, error } = await supabase
      .from('exos_checkout_sessions')
      .select(cols)
      .eq('event_id', eventId)
      .in('status', STATUSES)
      .order('session_id', { ascending: true })
      .range(from, to);
    if (error) throw error;
    return (data as unknown as SourceSessionRow[] | null) ?? [];
  }, (r) => r.session_id, PAGE);
}

/** The event's counted checkouts with their sources; null when unreadable. */
export async function getEventSourceSessions(eventId: string): Promise<{ rows: SourceSessionRow[]; hasAdIds: boolean } | null> {
  try {
    return { rows: await readSessions(eventId, `${BASE_COLS}, ad_ids`), hasAdIds: true };
  } catch {
    // ad_ids not on this database yet: try without it.
  }
  try {
    return { rows: await readSessions(eventId, BASE_COLS), hasAdIds: false };
  } catch (e) {
    console.warn('sources read unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
}

const DIMENSIONS: { key: SourceDimension; label: string }[] = [
  { key: 'all', label: 'Everything' },
  { key: 'source', label: 'Source / medium' },
  { key: 'campaign', label: 'Campaign' },
  { key: 'promoter', label: 'Promoter' },
  { key: 'platform', label: 'Ad platform' },
];

export default function SourcesPanel({ event, canView }: { event: Event; canView: boolean }) {
  const [data, setData] = useState<{ rows: SourceSessionRow[]; hasAdIds: boolean } | null>(null);
  const [dim, setDim] = useState<SourceDimension>('all');

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    void getEventSourceSessions(event.id).then((d) => {
      if (!cancelled) setData(d);
    });
    return () => {
      cancelled = true;
    };
  }, [event.id, canView]);

  const fallbackCurrency = event.currency || 'USD';
  const summary = useMemo(() => (data ? summarizeSources(data.rows, dim, fallbackCurrency) : null), [data, dim, fallbackCurrency]);

  if (!canView || !data || !summary) return null;
  const money = (cents: number) => formatCents(cents, summary.currency);

  const exportCsv = () => {
    // The CSV is always the full breakdown, whatever the table shows.
    const full = dim === 'all' ? summary : summarizeSources(data.rows, 'all', fallbackCurrency);
    downloadCsv(csvFileName(['sources', event.title]), toCsv(SOURCES_CSV_HEADER, sourcesCsvRows(full)));
  };

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="sources-title">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
        <div className="flex items-center gap-2">
          <Megaphone className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h3 id="sources-title" className="text-sm font-bold text-slate-700">Sources</h3>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <label className="text-[10px] font-black uppercase tracking-widest text-slate-400">
            <span className="sr-only">Group by</span>
            <select
              value={dim}
              onChange={(e) => setDim(e.target.value as SourceDimension)}
              className="px-2 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600 bg-white"
            >
              {DIMENSIONS.map((d) => <option key={d.key} value={d.key}>{d.label}</option>)}
            </select>
          </label>
          <button
            type="button"
            onClick={exportCsv}
            disabled={summary.orders === 0}
            className="inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600 hover:bg-slate-50 disabled:opacity-40"
          >
            <Download size={12} aria-hidden="true" /> Sources CSV
          </button>
        </div>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Paid orders by UTM tags, promoter code and the ad platform the buyer clicked through from.
        {summary.orders > 0 && ` ${summary.attributedOrders} of ${summary.orders} order${summary.orders === 1 ? '' : 's'} have a source.`}
        {' '}Gross is before refunds. Free claims aren’t included.
      </p>

      {summary.orders === 0 ? (
        <p className="text-sm text-slate-400">No paid orders yet.</p>
      ) : (
        <div className="overflow-x-auto -mx-6 px-6">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th scope="col" className="py-2 pr-4">Source</th>
                <th scope="col" className="py-2 pr-4 text-right">Orders</th>
                <th scope="col" className="py-2 pr-4 text-right">Tickets</th>
                <th scope="col" className="py-2 pr-4 text-right">Gross</th>
                <th scope="col" className="py-2 text-right">Refunded</th>
              </tr>
            </thead>
            <tbody>
              {summary.rows.map((r) => (
                <tr key={r.label} className="border-b border-slate-50 last:border-0">
                  <td className={`py-2 pr-4 ${r.direct ? 'text-slate-400 italic' : 'text-slate-700'} break-all`}>{r.label}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{r.orders}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{r.tickets}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{money(r.grossCents)}</td>
                  <td className="py-2 text-right tabular-nums text-slate-400">{r.refundedOrders || ''}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="font-bold text-slate-700 border-t border-slate-200">
                <td className="py-2 pr-4">Total</td>
                <td className="py-2 pr-4 text-right tabular-nums">{summary.orders}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{summary.tickets}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{money(summary.grossCents)}</td>
                <td className="py-2" />
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {(summary.mixedCurrencies || !data.hasAdIds) && (
        <ul className="text-xs text-amber-700 space-y-1 mt-3">
          {summary.mixedCurrencies && <li>These orders are in more than one currency; the totals add them as they are.</li>}
          {!data.hasAdIds && <li>Ad click ids aren’t recorded on this database yet, so only Meta clicks (fbclid) show a platform.</li>}
        </ul>
      )}
    </section>
  );
}
