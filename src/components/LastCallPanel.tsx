// Edit event → Last call (mig 20261029100000): at this many tickets left,
// only the primary ticketing system sells (Also sell on → Primary), so the
// last tickets go through one checkout and nothing oversells.

import { useCallback, useEffect, useState } from 'react';
import { Hourglass } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  fetchLastCallStatus, lastCallText, parseThresholdInput, setLastCallThreshold, thresholdLine, type LastCallStatus,
} from '../lib/marketplace/lastCall';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'w-28 bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function LastCallPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [st, setSt] = useState<LastCallStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);

  const show = useCallback((s: LastCallStatus | null) => {
    if (!s) { setHidden(true); return; }
    setSt(s);
    setText(s.eventThreshold === null ? '' : String(s.eventThreshold));
  }, []);
  useEffect(() => {
    fetchLastCallStatus(eventId).then(show).catch(() => setHidden(true));
  }, [eventId, show]);
  if (hidden || !st) return null;

  const parsed = parseThresholdInput(text);
  const save = async () => {
    if (parsed === undefined) return;
    setBusy(true);
    try {
      show(await setLastCallThreshold(eventId, parsed));
      toast({ kind: 'success', message: parsed === null ? 'Last call follows the default.' : parsed === 0 ? 'Last call is off for this event.' : `Last call at ${parsed} left.` });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not saved.' });
    } finally {
      setBusy(false);
    }
  };
  const fallback = st.orgThreshold ?? st.platformThreshold;

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-4">
      <div className="flex items-center space-x-3">
        <Hourglass className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Last call</h2>
      </div>
      <p className="type text-xs text-white/50">
        Near sell-out, only the primary ticketing system keeps selling: marketplaces and S4K hand their seats back,
        and Eventbrite or Luma (when they aren't the primary) show sold out. If the primary isn't Exos, the Exos page
        sends buyers there.
      </p>
      {st.active && <p role="status" className="type text-xs text-amber-400">{lastCallText(st)}.</p>}
      <p className="type text-xs text-white/70">{thresholdLine(st)}</p>
      {st.canManage && (
        <div className="flex flex-wrap items-end gap-3">
          <label className="block">
            <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">Tickets left (0 = off)</span>
            <input className={FLD} inputMode="numeric" value={text} placeholder={String(fallback)} aria-invalid={parsed === undefined}
              onChange={(e) => setText(e.target.value)} />
          </label>
          <button type="button" className={BTN} disabled={busy || parsed === undefined || parsed === st.eventThreshold} onClick={() => void save()}>
            Save
          </button>
          {st.eventThreshold !== null && (
            <button type="button" className={BTN} disabled={busy} onClick={() => { setText(''); void setLastCallThreshold(eventId, null).then(show, (e) => toast({ kind: 'error', message: (e as Error).message })); }}>
              Use the default ({fallback})
            </button>
          )}
        </div>
      )}
      {parsed === undefined && <p role="alert" className="type text-[11px] text-rose-400">A whole number from 0 to 10000, or empty for the default.</p>}
    </section>
  );
}
