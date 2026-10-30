// A series' dates (/dashboard/series/:seriesId): status and sales per date,
// Generate (next 90 days, idempotent), Publish all, Cancel one date, Edit
// future dates (propagate: title, description, image, prices; skips dates
// edited since, dates with sales, past and cancelled ones and says so),
// Archive, Cancel the series (by scope) and Delete (only when nothing sold).
// mig 20261030150000, docs/series-timed-entry.md.

import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import {
  cancelSeries, cancelSeriesDate, deleteSeries, generateSeriesDates, getSeries, listOccurrences, propagateSeries,
  publishSeries, updateSeries, type OccurrenceRow, type SeriesRow, type SeriesSkip,
} from '../lib/seriesTimedApi';
import { addDays, describeRule, parseRule } from '../lib/recurrence';
import { generateBatches } from '../lib/slots';
import { refundEventBatch } from '../lib/refundsApi';
import { useToast } from '../context/ToastContext';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';
const INPUT = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';
const BTN = 'px-3 py-1.5 border border-slate-200 rounded-lg text-[10px] font-black uppercase tracking-widest disabled:opacity-40';

const SKIP_TEXT: Record<string, string> = {
  edited: 'edited on that date', has_sales: 'has sales', past: 'already happened', cancelled: 'cancelled',
  exists: 'already in the series', exception: 'a skipped date', invalid: 'not a valid date',
};

export default function SeriesManager() {
  const { seriesId } = useParams<{ seriesId: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [series, setSeries] = useState<SeriesRow | null>(null);
  const [dates, setDates] = useState<OccurrenceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [edit, setEdit] = useState({ name: '', description: '', image_url: '', prices: '' });
  const [skips, setSkips] = useState<SeriesSkip[]>([]);

  const load = useCallback(async () => {
    if (!seriesId) return;
    try {
      const [s, d] = await Promise.all([getSeries(seriesId), listOccurrences(seriesId)]);
      setSeries(s);
      setDates(d);
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not load the series.' });
    } finally {
      setLoading(false);
    }
  }, [seriesId, toast]);
  useEffect(() => { void load(); }, [load]);

  if (loading) return <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">Loading…</div>;
  if (!series) return <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">Series not found.</div>;

  const run = async (what: () => Promise<string | void>) => {
    setBusy(true);
    try {
      const msg = await what();
      if (msg) toast({ kind: 'success', message: msg });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'That didn\'t work.' });
    } finally {
      setBusy(false);
    }
  };

  let ruleText = '';
  let rule = null;
  try { rule = series.rule ? parseRule(series.rule) : null; ruleText = rule ? describeRule(rule) : ''; } catch { /* legacy rule */ }
  const active = series.status === 'active';

  const generate = () => run(async () => {
    if (!rule) throw new Error('This series has no recurrence rule to generate from.');
    const today = new Date().toISOString().slice(0, 10);
    const batches = generateBatches(rule, series.timezone, { from: today, to: addDays(today, 90) }, new Set(dates.map((d) => d.date)), Date.now());
    let made = 0;
    for (const b of batches) made += (await generateSeriesDates(series.id, b)).created.length;
    return made ? `${made} new draft date${made === 1 ? '' : 's'}.` : 'Nothing new to generate in the next 90 days.';
  });

  const cancelDate = (d: OccurrenceRow) => run(async () => {
    const sold = d.event?.ticketsSold ?? 0;
    const reason = window.prompt(`Cancel ${d.date}?${sold ? ` ${sold} ticket(s) sold: holders are emailed and refunded.` : ''} Reason:`);
    if (reason === null) return undefined;
    const r = await cancelSeriesDate(series.id, d.date, reason || undefined);
    if (r.event_id && sold > 0) {
      try {
        // The same batch run as cancelling from the event report (exos-refund cancel_event).
        const nonce = crypto.randomUUID();
        let after: string | null = null;
        for (let i = 0; i < 200; i++) {
          const b = await refundEventBatch({ eventId: r.event_id, nonce, reason: reason || 'date cancelled', after });
          if (b.done || !b.nextAfter) break;
          after = b.nextAfter;
        }
      } catch (err: any) {
        return `Date cancelled; refunds didn't start (${err?.message || 'error'}): run them from that event's report.`;
      }
    }
    return r.status === 'skipped' ? `${d.date} will not be generated.` : `${d.date} cancelled.`;
  });

  const propagate = () => run(async () => {
    const changes: Record<string, unknown> = {};
    if (edit.name.trim()) changes.name = edit.name.trim();
    if (edit.description.trim()) changes.description = edit.description;
    if (edit.image_url.trim()) changes.image_url = edit.image_url.trim();
    const prices: Record<string, number> = {};
    for (const part of edit.prices.split(',').map((p) => p.trim()).filter(Boolean)) {
      const m = /^(.+?)\s*[=:]\s*(\d+(?:\.\d{1,2})?)$/.exec(part);
      if (!m) throw new Error(`"${part}" isn't "Ticket type = price"`);
      prices[m[1]] = Number(m[2]);
    }
    if (Object.keys(prices).length) changes.prices = prices;
    if (Object.keys(changes).length === 0) throw new Error('Nothing to change.');
    const r = await propagateSeries(series.id, changes);
    setSkips(r.skipped);
    return `${r.changed.length} date${r.changed.length === 1 ? '' : 's'} updated${r.skipped.length ? `, ${r.skipped.length} left alone (below)` : ''}.`;
  });

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <Link to={series.templateEventId ? `/dashboard/event/${series.templateEventId}` : '/dashboard'} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} /> Back
        </Link>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Series · {series.status}</p>
        <h1 className="text-3xl font-bold tracking-tight text-slate-900">{series.name}</h1>
        <p className="text-xs text-slate-400 mt-1 mb-6">{ruleText}{ruleText ? ' · ' : ''}{series.timezone}</p>

        <div className="flex flex-wrap gap-2 mb-6">
          <button type="button" disabled={busy || !active} className={BTN} onClick={generate}>Generate next 90 days</button>
          <button type="button" disabled={busy || !active} className={BTN}
            onClick={() => run(async () => `${await publishSeries(series.id)} date(s) published.`)}>Publish all</button>
          {series.status !== 'cancelled' && (
            <button type="button" disabled={busy} className={BTN}
              onClick={() => run(async () => { await updateSeries(series.id, { status: active ? 'archived' : 'active' }); return active ? 'Archived: off the public pages, no more generation.' : 'Active again.'; })}>
              {active ? 'Archive' : 'Unarchive'}
            </button>
          )}
          {series.status !== 'cancelled' && (
            <button type="button" disabled={busy} className={BTN}
              onClick={() => run(async () => {
                const all = window.confirm('Cancel the series. OK = also cancel every future show (holders emailed); Cancel = choose again.');
                if (!all && !window.confirm('Cancel only the series and leave every show running?')) return undefined;
                const r = await cancelSeries(series.id, all ? 'all_shows' : 'series_only');
                return `Series cancelled${r.cancelled_event_ids.length ? `; ${r.cancelled_event_ids.length} show(s) cancelled. Refund them from each event's report.` : '.'}`;
              })}>Cancel series</button>
          )}
          <button type="button" disabled={busy} className={BTN}
            onClick={() => run(async () => {
              if (!window.confirm('Delete the series? Its unsold draft dates are deleted; published shows and the template stay as standalone events.')) return;
              await deleteSeries(series.id);
              navigate('/dashboard');
            })}>Delete</button>
        </div>

        <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
          <h3 className="text-sm font-bold text-slate-700 mb-3">Dates</h3>
          <table className="w-full text-sm">
            <tbody>
              {dates.map((d) => (
                <tr key={d.date} className="border-t border-slate-100">
                  <td className="py-1.5 font-mono text-xs">{d.date} {d.time}</td>
                  <td className="py-1.5 text-xs">{d.status === 'generated' ? (d.event?.status ?? 'generated') : d.status}</td>
                  <td className="py-1.5 text-xs">{d.event ? `${d.event.ticketsSold}${d.event.totalTickets ? ` / ${d.event.totalTickets}` : ''} sold` : ''}</td>
                  <td className="py-1.5 text-right whitespace-nowrap">
                    {d.eventId && <Link to={`/dashboard/event/${d.eventId}`} className="text-xs text-[#026cdf] mr-3">Report</Link>}
                    {(d.status === 'generated') && d.event?.status !== 'cancelled' && (
                      <button type="button" disabled={busy} className="text-xs text-red-600" onClick={() => cancelDate(d)}>Cancel date</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="bg-white rounded-2xl p-6 shadow-sm">
          <h3 className="text-sm font-bold text-slate-700 mb-1">Edit future dates</h3>
          <p className="text-xs text-slate-400 mb-3">Changes the template and every future, uncancelled date, except fields edited on a date since the series wrote them and prices on dates with sales.</p>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <label><span className={LBL}>Title</span><input className={`${INPUT} w-full`} value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label><span className={LBL}>Image URL</span><input className={`${INPUT} w-full`} value={edit.image_url} onChange={(e) => setEdit({ ...edit, image_url: e.target.value })} /></label>
            <label className="sm:col-span-2"><span className={LBL}>Description</span><textarea className={`${INPUT} w-full`} rows={3} value={edit.description} onChange={(e) => setEdit({ ...edit, description: e.target.value })} /></label>
            <label className="sm:col-span-2"><span className={LBL}>Prices (Ticket type = price, comma separated)</span><input className={`${INPUT} w-full`} placeholder="GA = 25, VIP = 60" value={edit.prices} onChange={(e) => setEdit({ ...edit, prices: e.target.value })} /></label>
          </div>
          <button type="button" disabled={busy || series.status === 'cancelled'} className={`${BTN} mt-3`} onClick={propagate}>Apply to future dates</button>
          {skips.length > 0 && (
            <ul className="mt-3 text-xs text-slate-500 space-y-0.5">
              {skips.map((s, i) => <li key={i}>{s.date ?? ''} {s.field && s.field !== '*' ? `${s.field}: ` : ''}{SKIP_TEXT[s.reason] ?? s.reason}</li>)}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
