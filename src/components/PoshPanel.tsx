// Edit event → Posh (mig 20261029150000): the capped Posh tier. The organizer
// says how many tickets of one ticket type Posh may sell (Exos holds them off
// its own sales) and sets the same number on Posh by hand: Exos can't change
// Posh. Posh sales arrive by webhook and count here; anything past the cap is
// flagged until acknowledged (the door sees it on the buyer's entry too).

import { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, Ticket } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import {
  ackPoshOversell, cancelPoshOrder, capLine, fetchEventTiers, fetchPoshEventStatus, setPoshCap, type PoshEventStatus,
} from '../lib/posh';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'w-full bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function PoshPanel({ eventId, orgId }: { eventId: string; orgId?: string }) {
  const { toast } = useToast();
  const [st, setSt] = useState<PoshEventStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [busy, setBusy] = useState(false);
  const [tiers, setTiers] = useState<{ id: string; name: string; capacity: number }[]>([]);
  const [tierId, setTierId] = useState('');
  const [cap, setCap] = useState('');

  const load = useCallback(() => {
    fetchPoshEventStatus(eventId).then((s) => {
      setSt(s);
      if (s.cap) { setTierId(s.cap.tierId); setCap(String(s.cap.cap)); }
    }).catch(() => setHidden(true));
  }, [eventId]);
  useEffect(load, [load]);
  useEffect(() => {
    fetchEventTiers(eventId).then(setTiers).catch(() => setTiers([]));
  }, [eventId]);
  if (hidden || !st) return null;
  // Nothing to show for an org that doesn't use Posh.
  if (!st.connected && !st.cap && st.orders.length === 0) return null;

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const capNum = Number(cap);
  const capOk = /^\d{1,6}$/.test(cap.trim()) && tierId !== '';

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-4">
      <div className="flex items-center space-x-3">
        <Ticket className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Posh</h2>
      </div>
      <p className="type text-xs text-white/50">
        Posh sells from its own capped tier: the seats you give it here are held off Exos, and Posh's sales come off
        them. Set the same number as the capacity on Posh: Exos can't change it there.
      </p>

      {st.links.length === 0 && (
        <p className="type text-xs text-amber-300">
          No Posh event is linked to this one yet: link it in {orgId ? <Link to={`/orgs/${orgId}/settings`} className="underline">Org settings → Posh</Link> : 'Org settings → Posh'}.
        </p>
      )}

      <p className="type text-xs text-white/70">{capLine(st.cap)}</p>
      <p className="type text-[11px] text-white/50">
        {st.sales.confirmedTickets} Posh ticket{st.sales.confirmedTickets === 1 ? '' : 's'} sold in {st.sales.confirmedOrders} order{st.sales.confirmedOrders === 1 ? '' : 's'}
        {st.sales.pendingOrders > 0 ? ` · ${st.sales.pendingTickets} waiting for your approval on Posh (not counted yet)` : ''}
        {st.sales.uncountedOrders > 0 ? ` · ${st.sales.uncountedOrders} order${st.sales.uncountedOrders === 1 ? '' : 's'} waiting for a cap` : ''}.
      </p>

      {st.cap && st.cap.oversoldUnacked > 0 && (
        <div className="border border-rose-500/50 bg-rose-500/10 p-3 space-y-2" role="alert">
          <p className="type text-xs text-rose-300 flex items-center gap-2">
            <AlertTriangle className="w-4 h-4" aria-hidden="true" />
            Oversold: Posh sold {st.cap.oversoldUnacked} ticket{st.cap.oversoldUnacked === 1 ? '' : 's'} past its cap
            {st.cap.uncovered > 0 ? `, and ${st.cap.uncovered} have no seat left in Exos` : ''}. Lower the capacity on Posh, or raise the cap here.
            The door sees it on those buyers' entries.
          </p>
          {st.canManage && (
            <button type="button" className={BTN} disabled={busy} onClick={() => void run(() => ackPoshOversell(eventId), 'Noted.')}>I've seen it</button>
          )}
        </div>
      )}

      {st.canManage && (
        <div className="grid gap-2 md:grid-cols-[1fr_8rem_auto] items-end">
          <label className="block">
            <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">Ticket type</span>
            <select className={FLD} value={tierId} onChange={(e) => setTierId(e.target.value)} disabled={!!st.cap && st.cap.soldInCap > 0}>
              <option value="">Pick one…</option>
              {tiers.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.capacity})</option>)}
            </select>
          </label>
          <label className="block">
            <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">Posh cap</span>
            <input className={FLD} inputMode="numeric" value={cap} onChange={(e) => setCap(e.target.value)} placeholder="e.g. 50" />
          </label>
          <button type="button" className={BTN} disabled={busy || !capOk}
            onClick={() => void run(() => setPoshCap(eventId, tierId, capNum), `Posh may sell ${capNum}. Set the same capacity on Posh.`)}>
            Save cap
          </button>
        </div>
      )}

      {st.orders.length > 0 && (
        <div className="border-t border-white/10 pt-4 space-y-2">
          <p className="type text-[11px] uppercase tracking-widest text-white/70">Posh orders</p>
          <ul className="space-y-1">
            {st.orders.slice(0, 25).map((o) => (
              <li key={o.id} className="flex flex-wrap items-center justify-between gap-2 type text-xs text-white/70">
                <span>
                  {o.buyerName ?? o.buyerEmail ?? 'Posh buyer'} · {o.quantity} ticket{o.quantity === 1 ? '' : 's'}
                  {o.ticketLabel ? ` · ${o.ticketLabel}` : ''} · {o.state === 'pending' ? 'pending approval' : o.state}
                  {o.attention ? <span className={o.overQty > 0 ? 'text-rose-300' : 'text-amber-300'}> · {o.attention}</span> : null}
                </span>
                {st.canManage && o.state !== 'cancelled' && (
                  <button type="button" className={BTN} disabled={busy}
                    onClick={() => { if (window.confirm('Cancel this Posh order in Exos? Do this after refunding it on Posh. Its door entries are voided.')) void run(() => cancelPoshOrder(o.id), 'Cancelled in Exos.'); }}>
                    Cancel
                  </button>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
