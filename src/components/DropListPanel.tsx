// Event report → Marketing → Drop list (mig 20261118100000): how many asked
// to be told when tickets go on sale, how many confirmed, texts, and where
// they came from (promoter code / UTM), so the organizer can size the room
// before the on-sale. Counts only, never an address. Owner / manager /
// finance read (checked in SQL); owner / manager set the list presale (a
// hidden ticket type the list may buy N minutes early with a list-only code)
// and export the CSV (an export.run row in the org audit log).

import { useCallback, useEffect, useId, useState } from 'react';
import { Bell, Download } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import {
  DROP_CSV_HEADER, dropCsvRows, exportDropList, getDropSummary, setDropPresale, sourceLabel, type DropSummary,
} from '../lib/dropList';

const LBL = 'block text-[10px] font-black text-slate-600 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

interface HiddenTier { id: string; name: string; visibility?: string | null; capacity?: number | null }

function fmt(d: Date | null, tz?: string | null): string {
  if (!d) return '';
  try {
    return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short', timeZone: tz || undefined });
  } catch {
    return d.toLocaleString();
  }
}

export default function DropListPanel({ eventId, eventTitle, timezone, tiers, canView }: {
  eventId: string; eventTitle: string; timezone?: string | null; tiers?: HiddenTier[] | null; canView: boolean;
}) {
  const { toast } = useToast();
  const [s, setS] = useState<DropSummary | null>(null);
  const [minutes, setMinutes] = useState('60');
  const [tierId, setTierId] = useState('');
  const [busy, setBusy] = useState(false);
  const ids = { minutes: useId(), tier: useId(), title: useId() };

  const load = useCallback(() => {
    if (!canView) return;
    getDropSummary(eventId).then(setS).catch(() => setS(null));
  }, [eventId, canView]);
  useEffect(load, [load]);
  useEffect(() => {
    if (s?.presale.minutes) setMinutes(String(s.presale.minutes));
    if (s?.presale.tierId) setTierId(s.presale.tierId);
  }, [s?.presale.minutes, s?.presale.tierId]);
  if (!canView || !s) return null;
  // Nothing to show for an event that never took signups.
  if (!s.open && s.signups === 0) return null;

  const hidden = (tiers ?? []).filter((t) => t.visibility === 'hidden' && Number(t.capacity ?? 0) > 0);
  const n = Number(minutes);
  const err = !Number.isInteger(n) || n < 5 || n > 1440 ? 'Early access: 5 to 1440 minutes.'
    : !tierId ? 'Pick the hidden ticket type the list may buy.' : null;

  const savePresale = async (off: boolean) => {
    setBusy(true);
    try {
      await setDropPresale(eventId, off ? 0 : n, off ? null : tierId);
      toast({ kind: 'success', message: off ? 'List presale off.' : 'List presale set.' });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const exportCsv = async () => {
    setBusy(true);
    try {
      const r = await exportDropList(eventId);
      downloadCsv(csvFileName(['drop-list', eventTitle]), toCsv(DROP_CSV_HEADER, dropCsvRows(r.rows)));
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const tiles: [string, number][] = [
    ['Signed up', s.signups], ['Confirmed', s.confirmed], ['Texts opted in', s.sms], ['Waiting to confirm', s.pending],
  ];

  return (
    <section aria-labelledby={ids.title} data-drop-panel className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <h3 id={ids.title} className="text-sm font-bold text-slate-800 mb-1 flex items-center gap-2">
        <Bell className="w-4 h-4" aria-hidden="true" /> Drop list
      </h3>
      <p className="text-xs text-slate-600 mb-4">
        {s.open
          ? `Fans who asked to be told when tickets go on sale${s.onSaleAt ? ` (${fmt(s.onSaleAt, timezone)})` : ''}. Each confirmed one gets one email, and a text if they opted in, at the on-sale.`
          : `Notified at the on-sale: ${s.notified} email${s.notified === 1 ? '' : 's'}, ${s.textsQueued} text${s.textsQueued === 1 ? '' : 's'} queued.`}
      </p>
      <dl className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
        {tiles.map(([k, v]) => (
          <div key={k} className="rounded-xl bg-slate-50 p-3">
            <dt className="text-[10px] font-black uppercase tracking-widest text-slate-600">{k}</dt>
            <dd className="text-2xl font-black text-slate-900">{v}</dd>
          </div>
        ))}
      </dl>

      {s.sources.length > 0 && (
        <table className="w-full text-xs mb-4">
          <caption className="sr-only">Where signups came from</caption>
          <thead>
            <tr className="text-left text-[10px] font-black uppercase tracking-widest text-slate-600 border-b border-slate-200">
              <th scope="col" className="py-2">Source</th>
              <th scope="col" className="py-2 text-right">Signed up</th>
              <th scope="col" className="py-2 text-right">Confirmed</th>
            </tr>
          </thead>
          <tbody>
            {s.sources.map((src) => (
              <tr key={src.label + (src.utmMedium ?? '') + (src.utmCampaign ?? '')} className="border-b border-slate-100">
                <td className="py-2 text-slate-800">{sourceLabel(src)}</td>
                <td className="py-2 text-right text-slate-800">{src.signups}</td>
                <td className="py-2 text-right text-slate-800">{src.confirmed}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <div className="rounded-xl border border-slate-200 p-4 mb-4">
        <p className="text-xs font-bold text-slate-800 mb-1">List presale</p>
        {s.presale.status === 'off' ? (
          <p className="text-xs text-slate-600 mb-3">Off. The list hears at the public on-sale.</p>
        ) : s.presale.status === 'stale' ? (
          <p className="text-xs text-amber-800 mb-3" role="status">
            The public on-sale moved since this was set, so the list will hear at the on-sale. Set it again to keep early access.
          </p>
        ) : (
          <p className="text-xs text-slate-600 mb-3">
            {s.presale.tierName} opens to the list {s.presale.minutes} minutes early ({fmt(s.presale.opensAt, timezone)}) with
            code <span className="font-mono font-bold text-slate-900">{s.presale.code}</span>, which works only for confirmed list members.
          </p>
        )}
        {s.canManage && s.open && (
          hidden.length === 0 ? (
            <p className="text-xs text-slate-600">Add a hidden ticket type (Edit event → Tickets) for the list to buy early.</p>
          ) : (
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
              <div>
                <label htmlFor={ids.tier} className={LBL}>Hidden ticket type</label>
                <select id={ids.tier} value={tierId} onChange={(e) => setTierId(e.target.value)} className={FLD}>
                  <option value="">Choose…</option>
                  {hidden.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </div>
              <div>
                <label htmlFor={ids.minutes} className={LBL}>Minutes before the on-sale</label>
                <input id={ids.minutes} type="number" min={5} max={1440} value={minutes}
                  onChange={(e) => setMinutes(e.target.value)} className={FLD} />
              </div>
              <div className="flex gap-2">
                <button type="button" disabled={busy || !!err} onClick={() => void savePresale(false)}
                  className="px-4 py-2 rounded-lg bg-slate-900 text-white text-xs font-bold disabled:opacity-50">Save</button>
                {s.presale.status !== 'off' && (
                  <button type="button" disabled={busy} onClick={() => void savePresale(true)}
                    className="px-4 py-2 rounded-lg border border-slate-300 text-slate-800 text-xs font-bold disabled:opacity-50">Turn off</button>
                )}
              </div>
              {err && <p className="sm:col-span-3 text-[11px] text-slate-600">{err}</p>}
            </div>
          )
        )}
      </div>

      {s.canManage && (
        <button type="button" disabled={busy || s.confirmed === 0} onClick={() => void exportCsv()}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-slate-300 text-slate-800 text-xs font-bold disabled:opacity-50">
          <Download className="w-3 h-3" aria-hidden="true" /> Export CSV
        </button>
      )}
    </section>
  );
}
