// Series editor (Opendate parity round 12): make an event recurring with a
// full recurrence rule (daily / weekly / monthly by date or nth weekday,
// every N, end date or count, exceptions), preview the dates in the event's
// timezone with the same code that generates them, then create the series
// (exos_series_create) and generate the next 90 days as drafts
// (exos_series_generate, idempotent per date). Lives at
// /dashboard/event/:eventId/recurring; the dates are then managed at
// /dashboard/series/:seriesId. Owner / manager; the RPCs re-check.

import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Repeat } from 'lucide-react';
import { getEventForEdit } from '../lib/events';
import { utcToZonedWallClock } from '../lib/datetime';
import { RuleError, addDays, describeRule, expandRule, parseRule, weekdayOf, type SeriesRule } from '../lib/recurrence';
import { generateBatches } from '../lib/slots';
import { createSeries, generateSeriesDates } from '../lib/seriesTimedApi';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';
const INPUT = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';

export default function SeriesEditor() {
  const { eventId } = useParams<{ eventId: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState('');
  const [freq, setFreq] = useState<'daily' | 'weekly' | 'monthly'>('weekly');
  const [interval, setIntervalN] = useState(1);
  const [weekdays, setWeekdays] = useState<number[]>([]);
  const [monthlyMode, setMonthlyMode] = useState<'date' | 'nth'>('date');
  const [nth, setNth] = useState(1);
  const [startDate, setStartDate] = useState('');
  const [time, setTime] = useState('20:00');
  const [stop, setStop] = useState<'count' | 'until'>('count');
  const [count, setCount] = useState(8);
  const [until, setUntil] = useState('');
  const [exceptions, setExceptions] = useState('');

  useEffect(() => {
    let live = true;
    (async () => {
      try {
        const ev = eventId ? await getEventForEdit(eventId) : null;
        if (!live) return;
        setEvent(ev);
        if (ev) {
          const wall = utcToZonedWallClock(ev.date.toDate(), ev.timezone || 'UTC');
          setName(ev.title);
          setStartDate(wall.slice(0, 10));
          setTime(wall.slice(11, 16) || '20:00');
          setWeekdays([weekdayOf(wall.slice(0, 10))]);
          setUntil(addDays(wall.slice(0, 10), 90));
        }
      } catch (err) {
        console.error('SeriesEditor load failed:', err);
      } finally {
        if (live) setLoading(false);
      }
    })();
    return () => { live = false; };
  }, [eventId]);

  const tz = event?.timezone || 'UTC';
  const parsed = useMemo((): { rule: SeriesRule | null; error: string | null } => {
    if (!startDate) return { rule: null, error: null };
    try {
      const rule = parseRule({
        freq, interval, weekdays, startDate, time,
        monthly: freq === 'monthly'
          ? (monthlyMode === 'date' ? { mode: 'date', day: Number(startDate.slice(8)) } : { mode: 'nth', nth, weekday: weekdayOf(startDate) })
          : null,
        endDate: stop === 'until' ? until : null,
        count: stop === 'count' ? count : null,
        exceptions: exceptions.split(',').map((s) => s.trim()).filter(Boolean),
      });
      return { rule, error: null };
    } catch (err) {
      return { rule: null, error: err instanceof RuleError ? err.message : String(err) };
    }
  }, [freq, interval, weekdays, startDate, time, monthlyMode, nth, stop, until, count, exceptions]);

  const preview = useMemo(() => (parsed.rule ? expandRule(parsed.rule, tz) : []), [parsed.rule, tz]);

  if (loading) return <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">Loading…</div>;
  if (!event) return <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">Event not found.</div>;
  if (event.seriesId) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">
        This event is already in a series. <Link className="text-[#026cdf] font-bold" to={`/dashboard/series/${event.seriesId}`}>Manage it</Link>.
      </div>
    );
  }

  const submit = async () => {
    if (!parsed.rule) return;
    setBusy(true);
    try {
      const seriesId = await createSeries(event.id, name.trim() || event.title, parsed.rule);
      const today = new Date().toISOString().slice(0, 10);
      // The template's own date is recorded by the create call.
      const batches = generateBatches(parsed.rule, tz, { from: today, to: addDays(today, 90) }, new Set([startDate]), Date.now());
      let made = 0;
      for (const b of batches) made += (await generateSeriesDates(seriesId, b)).created.length;
      toast({ kind: 'success', message: `Series created with ${made} draft date${made === 1 ? '' : 's'}. Publish them when ready.` });
      navigate(`/dashboard/series/${seriesId}`);
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not create the series.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <Link to={`/dashboard/event/${event.id}`} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} /> Back to report
        </Link>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Make it recurring</p>
        <h1 className="text-3xl font-bold tracking-tight text-slate-900 mb-1">{event.title}</h1>
        <p className="text-xs text-slate-400 mb-8">
          This event is the template: each date copies its details, ticket types (sales windows cleared), fees, tax and add-ons.
          Times are wall clock in {tz}. Timed-entry settings and seat maps aren't copied.
        </p>
        <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
          <div className="lg:col-span-3 bg-white rounded-2xl p-6 shadow-sm space-y-4">
            <label className="block"><span className={LBL}>Series name</span>
              <input className={`${INPUT} w-full`} value={name} onChange={(e) => setName(e.target.value)} /></label>
            <div className="flex flex-wrap gap-3 items-end">
              <label><span className={LBL}>Repeat</span>
                <select className={INPUT} value={freq} onChange={(e) => setFreq(e.target.value as typeof freq)}>
                  <option value="daily">Daily</option><option value="weekly">Weekly</option><option value="monthly">Monthly</option>
                </select></label>
              <label><span className={LBL}>Every</span>
                <input type="number" min={1} max={12} className={`${INPUT} w-16`} value={interval} onChange={(e) => setIntervalN(Math.max(1, Number(e.target.value) || 1))} /></label>
              <label><span className={LBL}>From</span>
                <input type="date" className={INPUT} value={startDate} onChange={(e) => setStartDate(e.target.value)} /></label>
              <label><span className={LBL}>At</span>
                <input type="time" className={INPUT} value={time} onChange={(e) => setTime(e.target.value)} /></label>
            </div>
            {freq === 'weekly' && (
              <div><span className={LBL}>On</span>
                <div className="flex flex-wrap gap-1">
                  {DAYS.map((d, i) => (
                    <button key={d} type="button" aria-pressed={weekdays.includes(i)}
                      onClick={() => setWeekdays((w) => (w.includes(i) ? w.filter((x) => x !== i) : [...w, i].sort()))}
                      className={`px-2.5 py-1 rounded text-[10px] font-black uppercase tracking-widest border ${weekdays.includes(i) ? 'bg-blue-600 text-white border-blue-600' : 'bg-white text-slate-600 border-slate-200'}`}>{d}</button>
                  ))}
                </div></div>
            )}
            {freq === 'monthly' && (
              <div className="flex flex-wrap gap-3 items-end">
                <label><span className={LBL}>Monthly on</span>
                  <select className={INPUT} value={monthlyMode} onChange={(e) => setMonthlyMode(e.target.value as 'date' | 'nth')}>
                    <option value="date">Day {Number(startDate.slice(8)) || 1} of the month</option>
                    <option value="nth">A weekday of the month</option>
                  </select></label>
                {monthlyMode === 'nth' && (
                  <label><span className={LBL}>Which {DAYS[weekdayOf(startDate || '2026-01-04')]}</span>
                    <select className={INPUT} value={nth} onChange={(e) => setNth(Number(e.target.value))}>
                      <option value={1}>First</option><option value={2}>Second</option><option value={3}>Third</option>
                      <option value={4}>Fourth</option><option value={5}>Fifth</option><option value={-1}>Last</option>
                    </select></label>
                )}
              </div>
            )}
            <div className="flex flex-wrap gap-3 items-end">
              <label><span className={LBL}>Ends</span>
                <select className={INPUT} value={stop} onChange={(e) => setStop(e.target.value as 'count' | 'until')}>
                  <option value="count">After a number of dates</option><option value="until">On a date</option>
                </select></label>
              {stop === 'count'
                ? <input aria-label="Number of dates" type="number" min={1} max={500} className={`${INPUT} w-20`} value={count} onChange={(e) => setCount(Number(e.target.value) || 1)} />
                : <input aria-label="Last date" type="date" className={INPUT} value={until} onChange={(e) => setUntil(e.target.value)} />}
            </div>
            <label className="block"><span className={LBL}>Skip dates (YYYY-MM-DD, comma separated)</span>
              <input className={`${INPUT} w-full`} value={exceptions} onChange={(e) => setExceptions(e.target.value)} /></label>
            {parsed.error && <p className="text-xs text-amber-600">{parsed.error}</p>}
            <button type="button" disabled={!parsed.rule || busy} onClick={submit}
              className="inline-flex items-center gap-2 px-4 py-2 bg-slate-900 text-white rounded-lg text-xs font-black uppercase tracking-widest disabled:opacity-40">
              <Repeat size={12} /> Create series
            </button>
            <p className="text-[11px] text-slate-400">The next 90 days are generated now as drafts; generate more from the series page.</p>
          </div>
          <div className="lg:col-span-2 bg-white rounded-2xl p-6 shadow-sm">
            <p className={LBL}>{parsed.rule ? describeRule(parsed.rule) : 'Preview'}</p>
            <p className="text-xs text-slate-500 mb-2">{preview.length} date{preview.length === 1 ? '' : 's'}</p>
            <ul className="text-sm text-slate-700 space-y-0.5 max-h-96 overflow-auto">
              {preview.slice(0, 60).map((o) => (
                <li key={o.date} className="font-mono text-xs">{o.date} {DAYS[weekdayOf(o.date)]} {o.time}{o.date === startDate ? ' · this event' : ''}</li>
              ))}
              {preview.length > 60 && <li className="text-xs text-slate-400">… and {preview.length - 60} more</li>}
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
}
