// Event report → Timed entry settings (owners, managers): which ticket types
// sell a date + time slot, slot length, places per slot (and per type), entry
// window, opening hours per weekday, the dates sold and closed dates, with a
// live preview of the first open day. Saved by exos_set_timed_entry, which
// re-validates everything and refuses a change that would strand a sale
// (mig 20261030150000, docs/series-timed-entry.md).

import { useEffect, useMemo, useState } from 'react';
import { Clock } from 'lucide-react';
import { clearTimedEntry, getTimedEntry, setTimedEntry } from '../lib/seriesTimedApi';
import { TimedEntryError, openDates, parseTimedEntryConfig, slotsForDate } from '../lib/timedEntry';
import { addDays } from '../lib/recurrence';
import { hoursText, parseHoursText } from '../lib/slots';
import { useToast } from '../context/ToastContext';

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';
const INPUT = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';

interface Form {
  tierIds: string[];
  slotMinutes: number;
  capacity: number;
  tierCapacity: Record<string, string>;
  entryWindowMinutes: string;
  earlyEntryMinutes: number;
  hours: string[];
  startDate: string;
  endDate: string;
  closedDates: string;
}

export default function TimedEntryPanel({
  eventId, tiers, timezone, canManage,
}: {
  eventId: string;
  tiers: { id: string; name: string; kind?: string }[];
  timezone?: string;
  canManage: boolean;
}) {
  const { toast } = useToast();
  const today = new Date().toISOString().slice(0, 10);
  const [saved, setSaved] = useState<boolean | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [f, setF] = useState<Form>({
    tierIds: [], slotMinutes: 30, capacity: 20, tierCapacity: {}, entryWindowMinutes: '15', earlyEntryMinutes: 0,
    hours: ['', '10:00-17:00', '10:00-17:00', '10:00-17:00', '10:00-17:00', '10:00-17:00', '10:00-17:00'],
    startDate: today, endDate: addDays(today, 90), closedDates: '',
  });

  useEffect(() => {
    let live = true;
    getTimedEntry(eventId).then((c) => {
      if (!live) return;
      setSaved(!!c);
      if (c) {
        setF({
          tierIds: c.tierIds, slotMinutes: c.slotMinutes, capacity: c.capacity,
          tierCapacity: Object.fromEntries(Object.entries(c.tierCapacity).map(([k, v]) => [k, String(v)])),
          entryWindowMinutes: c.entryWindowMinutes == null ? '' : String(c.entryWindowMinutes),
          earlyEntryMinutes: c.earlyEntryMinutes,
          hours: DAYS.map((_, i) => hoursText(c.hours[String(i)])),
          startDate: c.startDate, endDate: c.endDate, closedDates: c.closedDates.join(', '),
        });
      }
    }).catch((err) => { console.warn('timed entry read failed:', err); if (live) setSaved(null); });
    return () => { live = false; };
  }, [eventId]);

  const built = useMemo(() => {
    try {
      const hours: Record<string, { open: string; close: string }[]> = {};
      f.hours.forEach((h, i) => { const r = parseHoursText(h); if (r.length) hours[String(i)] = r; });
      const cfg = parseTimedEntryConfig({
        tierIds: f.tierIds, slotMinutes: f.slotMinutes, capacity: f.capacity,
        tierCapacity: Object.fromEntries(Object.entries(f.tierCapacity).filter(([k, v]) => v !== '' && f.tierIds.includes(k)).map(([k, v]) => [k, Number(v)])),
        entryWindowMinutes: f.entryWindowMinutes === '' ? null : Number(f.entryWindowMinutes),
        earlyEntryMinutes: f.earlyEntryMinutes, hours, startDate: f.startDate, endDate: f.endDate,
        closedDates: f.closedDates.split(',').map((d) => d.trim()).filter(Boolean),
      }, tiers.map((t) => t.id));
      return { cfg, error: null as string | null };
    } catch (err) {
      return { cfg: null, error: err instanceof TimedEntryError || err instanceof Error ? err.message : String(err) };
    }
  }, [f, tiers]);

  const preview = useMemo(() => {
    if (!built.cfg) return null;
    const cfg = { ...built.cfg, version: 0 };
    const day = openDates(cfg).find((d) => d >= today) ?? openDates(cfg)[0];
    return day ? { day, slots: slotsForDate(cfg, day, timezone || 'UTC') } : null;
  }, [built, today, timezone]);

  if (saved === null && !open) return null;
  const standard = tiers.filter((t) => (t.kind ?? 'standard') === 'standard');

  const save = async () => {
    if (!built.cfg) return;
    setBusy(true);
    try {
      await setTimedEntry(eventId, built.cfg);
      setSaved(true);
      toast({ kind: 'success', message: 'Timed entry saved.' });
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not save timed entry.' });
    } finally { setBusy(false); }
  };
  const turnOff = async () => {
    if (!window.confirm('Turn timed entry off? Only possible while no slot has sales.')) return;
    setBusy(true);
    try {
      await clearTimedEntry(eventId);
      setSaved(false);
      toast({ kind: 'success', message: 'Timed entry is off.' });
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not turn timed entry off.' });
    } finally { setBusy(false); }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center justify-between gap-2 mb-2">
        <div className="flex items-center gap-2">
          <Clock className="w-4 h-4 text-slate-500" />
          <h3 className="text-sm font-bold text-slate-700">Timed entry</h3>
          <span className="text-[10px] uppercase tracking-widest text-slate-400">{saved ? 'on' : 'off'}</span>
        </div>
        {canManage && (
          <button type="button" onClick={() => setOpen((o) => !o)} className="text-xs font-bold text-[#026cdf]">
            {open ? 'Close' : saved ? 'Edit settings' : 'Sell by time slot'}
          </button>
        )}
      </div>
      <p className="text-xs text-slate-400">
        Chosen ticket types sell a date and time slot instead of one start time, with a capacity per slot that is never oversold.
        Keep the ticket types' own capacity and the event's end time covering the whole run.
      </p>
      {open && canManage && (
        <div className="mt-4 space-y-4">
          <div>
            <span className={LBL}>Ticket types sold by slot</span>
            <div className="flex flex-wrap gap-3">
              {standard.map((t) => (
                <label key={t.id} className="text-sm flex items-center gap-1.5">
                  <input type="checkbox" checked={f.tierIds.includes(t.id)}
                    onChange={(e) => setF((s) => ({ ...s, tierIds: e.target.checked ? [...s.tierIds, t.id] : s.tierIds.filter((x) => x !== t.id) }))} />
                  {t.name}
                  {f.tierIds.includes(t.id) && (
                    <input aria-label={`${t.name} per slot`} placeholder="per slot" className={`${INPUT} w-20`} inputMode="numeric"
                      value={f.tierCapacity[t.id] ?? ''} onChange={(e) => setF((s) => ({ ...s, tierCapacity: { ...s.tierCapacity, [t.id]: e.target.value.replace(/\D/g, '') } }))} />
                  )}
                </label>
              ))}
            </div>
          </div>
          <div className="flex flex-wrap gap-3">
            <label><span className={LBL}>Slot length (min)</span>
              <input type="number" min={5} max={480} className={`${INPUT} w-24`} value={f.slotMinutes} onChange={(e) => setF((s) => ({ ...s, slotMinutes: Number(e.target.value) }))} /></label>
            <label><span className={LBL}>Places per slot</span>
              <input type="number" min={1} className={`${INPUT} w-24`} value={f.capacity} onChange={(e) => setF((s) => ({ ...s, capacity: Number(e.target.value) }))} /></label>
            <label><span className={LBL}>Entry window (min, blank = slot)</span>
              <input className={`${INPUT} w-24`} inputMode="numeric" value={f.entryWindowMinutes} onChange={(e) => setF((s) => ({ ...s, entryWindowMinutes: e.target.value.replace(/\D/g, '') }))} /></label>
            <label><span className={LBL}>Early entry (min)</span>
              <input type="number" min={0} max={240} className={`${INPUT} w-24`} value={f.earlyEntryMinutes} onChange={(e) => setF((s) => ({ ...s, earlyEntryMinutes: Number(e.target.value) }))} /></label>
          </div>
          <div>
            <span className={LBL}>Opening hours (e.g. 10:00-13:00, 14:00-18:00; blank = closed)</span>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              {DAYS.map((d, i) => (
                <label key={d} className="flex items-center gap-2 text-sm"><span className="w-10 text-slate-500">{d}</span>
                  <input className={`${INPUT} flex-1`} value={f.hours[i]} onChange={(e) => setF((s) => ({ ...s, hours: s.hours.map((h, j) => (j === i ? e.target.value : h)) }))} />
                </label>
              ))}
            </div>
          </div>
          <div className="flex flex-wrap gap-3">
            <label><span className={LBL}>First date</span>
              <input type="date" className={INPUT} value={f.startDate} onChange={(e) => setF((s) => ({ ...s, startDate: e.target.value }))} /></label>
            <label><span className={LBL}>Last date</span>
              <input type="date" className={INPUT} value={f.endDate} onChange={(e) => setF((s) => ({ ...s, endDate: e.target.value }))} /></label>
            <label className="flex-1 min-w-[12rem]"><span className={LBL}>Closed dates (YYYY-MM-DD, comma separated)</span>
              <input className={`${INPUT} w-full`} value={f.closedDates} onChange={(e) => setF((s) => ({ ...s, closedDates: e.target.value }))} /></label>
          </div>
          {built.error ? (
            <p className="text-xs text-amber-600">{built.error}</p>
          ) : preview && (
            <p className="text-xs text-slate-500">
              {preview.day}: {preview.slots.length} slot{preview.slots.length === 1 ? '' : 's'} ({preview.slots.slice(0, 8).map((s) => s.time).join(', ')}{preview.slots.length > 8 ? ', …' : ''})
            </p>
          )}
          <div className="flex gap-2">
            <button type="button" disabled={busy || !built.cfg} onClick={save}
              className="px-4 py-2 bg-slate-900 text-white rounded-lg text-xs font-black uppercase tracking-widest disabled:opacity-40">Save</button>
            {saved && (
              <button type="button" disabled={busy} onClick={turnOff}
                className="px-4 py-2 border border-slate-200 rounded-lg text-xs font-black uppercase tracking-widest">Turn off</button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
