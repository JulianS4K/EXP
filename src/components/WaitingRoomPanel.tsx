// Event report → Overview → Waiting room (mig 20261118120000): an on-sale
// queue for big drops, off by default. Owner / manager turn it on and set its
// numbers (audited as event.waiting_room); owner / manager / finance see the
// live counts (waiting, admitted, checked out, expired). Counts only, never a
// buyer. Checked in SQL.

import { useCallback, useEffect, useId, useState } from 'react';
import { Users } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  TURNSTILE_SITE_KEY, configureRoom, getRoomSummary, settingsProblem, type RoomSettingsInput, type RoomSummary,
} from '../lib/waitingRoom';

const LBL = 'block text-[10px] font-black text-slate-600 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

function fmt(d: Date | null, tz?: string | null): string {
  if (!d) return '';
  try {
    return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short', timeZone: tz || undefined });
  } catch {
    return d.toLocaleString();
  }
}

const PHASE: Record<RoomSummary['phase'], string> = {
  off: 'Off', before: 'Armed: opens before the on-sale', lobby: 'Open: people are gathering', live: 'Live: letting people in',
};

export default function WaitingRoomPanel({ eventId, timezone, canView, siteKey = TURNSTILE_SITE_KEY }: {
  eventId: string; timezone?: string | null; canView: boolean; siteKey?: string;
}) {
  const { toast } = useToast();
  const [s, setS] = useState<RoomSummary | null>(null);
  const [turnstile, setTurnstile] = useState(false);
  const [form, setForm] = useState<Record<Exclude<keyof RoomSettingsInput, 'turnstile'>, string>>({
    windowMinutes: '15', admitPerMinute: '200', admissionMinutes: '10', idleCloseMinutes: '10', maxEntries: '',
  });
  const [busy, setBusy] = useState(false);
  const ids = { title: useId(), win: useId(), rate: useId(), adm: useId(), idle: useId(), cap: useId(), ts: useId(), tsHelp: useId() };

  const load = useCallback(() => {
    if (!canView) return;
    getRoomSummary(eventId).then(setS).catch(() => setS(null));
  }, [eventId, canView]);
  useEffect(load, [load]);
  // Live counts while the room is open: every 10 seconds.
  useEffect(() => {
    if (!s || s.phase === 'off') return undefined;
    const t = setInterval(load, 10000);
    return () => clearInterval(t);
  }, [s?.phase, load]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!s) return;
    setForm({
      windowMinutes: String(s.windowMinutes), admitPerMinute: String(s.admitPerMinute),
      admissionMinutes: String(s.admissionMinutes), idleCloseMinutes: String(s.idleCloseMinutes),
      maxEntries: s.maxEntries == null ? '' : String(s.maxEntries),
    });
    setTurnstile(s.turnstile);
  }, [s?.windowMinutes, s?.admitPerMinute, s?.admissionMinutes, s?.idleCloseMinutes, s?.maxEntries, s?.turnstile]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!canView || !s) return null;

  const input: RoomSettingsInput = {
    windowMinutes: Number(form.windowMinutes), admitPerMinute: Number(form.admitPerMinute),
    admissionMinutes: Number(form.admissionMinutes), idleCloseMinutes: Number(form.idleCloseMinutes),
    maxEntries: form.maxEntries.trim() === '' ? 0 : Number(form.maxEntries),
    // Without the platform's keys it can only be turned off, never on.
    turnstile: siteKey ? turnstile : (s.turnstile ? false : undefined),
  };
  const err = settingsProblem(input);
  const on = s.enabled && !s.closedAt;

  const save = async (enabled: boolean) => {
    setBusy(true);
    try {
      setS(await configureRoom(eventId, enabled, input));
      toast({ kind: 'success', message: enabled ? (on ? 'Waiting room updated.' : 'Waiting room on.') : 'Waiting room off.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const tiles: [string, number][] = [
    ['Waiting', s.counts.waiting], ['Admitted', s.counts.admitted],
    ['Checked out', s.counts.checkedOut], ['Expired', s.counts.expired],
  ];
  const field = (k: Exclude<keyof RoomSettingsInput, 'turnstile'>, id: string, label: string, min: number, max: number, placeholder?: string) => (
    <div>
      <label htmlFor={id} className={LBL}>{label}</label>
      <input id={id} type="number" min={min} max={max} value={form[k]} disabled={!s.canManage} placeholder={placeholder}
        onChange={(e) => setForm((f) => ({ ...f, [k]: e.target.value }))} className={FLD} />
    </div>
  );

  return (
    <section aria-labelledby={ids.title} data-wroom-panel className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <h3 id={ids.title} className="text-sm font-bold text-slate-800 mb-1 flex items-center gap-2">
        <Users className="w-4 h-4" aria-hidden="true" /> Waiting room
      </h3>
      <p className="text-xs text-slate-600 mb-4">
        For big on-sales. Buyers who arrive in the window before the on-sale get a random place in line at the
        on-sale; later ones join at the back. Exos lets people in at the rate you set, and only they can check out.
        It closes itself when nobody has been waiting for a while.
      </p>
      <p className="text-xs text-slate-800 mb-4" role="status">
        <span className="font-bold">{PHASE[s.phase]}</span>
        {s.phase !== 'off' && s.onSaleAt ? ` · on-sale ${fmt(s.onSaleAt, timezone)}` : ''}
        {s.phase === 'before' && s.opensAt ? ` · opens ${fmt(s.opensAt, timezone)}` : ''}
        {s.phase === 'off' && s.closedReason === 'idle' && s.closedAt ? ` · closed itself ${fmt(s.closedAt, timezone)} (nobody waiting)` : ''}
        {s.phase === 'live' && s.counts.waiting > 0 ? ` · the back of the line waits about ${s.waitMinutes} min` : ''}
      </p>
      {s.counts.total > 0 && (
        <dl className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
          {tiles.map(([k, v]) => (
            <div key={k} className="rounded-xl bg-slate-50 p-3">
              <dt className="text-[10px] font-black uppercase tracking-widest text-slate-600">{k}</dt>
              <dd className="text-2xl font-black text-slate-900">{v.toLocaleString()}</dd>
            </div>
          ))}
        </dl>
      )}
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-3 items-end mb-3">
        {field('windowMinutes', ids.win, 'Opens before on-sale (min)', 0, 240)}
        {field('admitPerMinute', ids.rate, 'Let in per minute', 1, 20000)}
        {field('admissionMinutes', ids.adm, 'Time to check out (min)', 2, 60)}
        {field('idleCloseMinutes', ids.idle, 'Close when idle for (min)', 1, 240)}
        {field('maxEntries', ids.cap, 'Most people in line', 100, 1000000, s.cap ? `Automatic (${s.cap.toLocaleString()})` : 'Automatic')}
      </div>
      <div className="mb-3">
        <label htmlFor={ids.ts} className="flex items-center gap-2 text-xs text-slate-800">
          <input id={ids.ts} type="checkbox" checked={turnstile && !!siteKey} disabled={!s.canManage || !siteKey}
            aria-describedby={ids.tsHelp} onChange={(e) => setTurnstile(e.target.checked)} />
          Human check before joining (Cloudflare Turnstile)
        </label>
        <p id={ids.tsHelp} className="text-[11px] text-slate-600 mt-1">
          {siteKey
            ? 'Stops bots filling the line, and lets more people per network in (carriers share addresses).'
            : "Not available: the platform's Cloudflare Turnstile keys aren't set up (docs/self-hosting.md)."}
        </p>
      </div>
      {s.canManage ? (
        <div className="flex flex-wrap gap-2 items-center">
          <button type="button" disabled={busy || !!err} onClick={() => void save(true)}
            className="px-4 py-2 rounded-lg bg-slate-900 text-white text-xs font-bold disabled:opacity-50">
            {on ? 'Save' : 'Turn on'}
          </button>
          {on && (
            <button type="button" disabled={busy} onClick={() => void save(false)}
              className="px-4 py-2 rounded-lg border border-slate-300 text-slate-800 text-xs font-bold disabled:opacity-50">
              Turn off
            </button>
          )}
          {err && <p className="text-[11px] text-slate-600">{err}</p>}
        </div>
      ) : (
        <p className="text-[11px] text-slate-600">Owners and managers can change these.</p>
      )}
    </section>
  );
}
