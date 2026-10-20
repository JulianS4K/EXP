// Buyer refund requests on the event report (mig 20261015090000): refund
// (the usual Stripe refund, keyed to the ask) or decline with a note.
// Owner / manager / finance; the RPCs and exos-refund re-check the role.

import { useCallback, useEffect, useState } from 'react';
import { Undo2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { declineRefundAsk, fetchEventRefundAsks, refundAsk, type EventRefundAsk } from '../lib/refundAsks';

export default function RefundAsksPanel({ eventId, canAct, onRefunded }: { eventId: string; canAct: boolean; onRefunded?: () => void }) {
  const { toast } = useToast();
  const [asks, setAsks] = useState<EventRefundAsk[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [declining, setDeclining] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [showClosed, setShowClosed] = useState(false);

  const load = useCallback(() => {
    if (!canAct) return;
    fetchEventRefundAsks(eventId).then(setAsks).catch((e) => {
      console.warn('refund requests unavailable', e);
      setAsks([]);
    });
  }, [eventId, canAct]);
  useEffect(load, [load]);

  if (!canAct || asks === null) return null;
  const open = asks.filter((a) => a.status === 'open');
  const closed = asks.filter((a) => a.status !== 'open');

  const refund = async (shown: EventRefundAsk) => {
    // Re-read first: another refund on the order since this list loaded
    // (an order-level partial) lowers what refunding the ask would return.
    let a = shown;
    try {
      const fresh = await fetchEventRefundAsks(eventId);
      setAsks(fresh);
      const cur = fresh.find((x) => x.askId === shown.askId);
      if (!cur || cur.status !== 'open' || cur.amountCents <= 0) {
        toast({ kind: 'error', message: 'This request is no longer open, or nothing is left to refund on the order.' });
        return;
      }
      a = cur;
    } catch {
      // Keep the shown amount; exos-refund caps the refund at what's left.
    }
    if (!window.confirm(`Refund ${formatCents(a.amountCents, a.currency)} to ${a.buyerEmail || 'the buyer'}? The ticket stops working.`)) return;
    setBusy(a.askId);
    try {
      const out = await refundAsk(a);
      if (out.status === 'succeeded' || out.status === 'pending') {
        toast({ kind: 'success', message: `Refunded ${formatCents(out.amountCents ?? a.amountCents, a.currency)}.` });
        onRefunded?.();
      } else {
        toast({ kind: 'error', message: out.error || 'Stripe didn\'t confirm the refund. Try again; it won\'t refund twice.' });
      }
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Refund failed.' });
    } finally {
      setBusy(null);
      load();
    }
  };

  const decline = async (a: EventRefundAsk) => {
    setBusy(a.askId);
    try {
      await declineRefundAsk(a.askId, note);
      toast({ kind: 'success', message: 'Declined. The buyer sees your note on their ticket.' });
      setDeclining(null);
      setNote('');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not saved.' });
    } finally {
      setBusy(null);
      load();
    }
  };

  const STATUS: Record<string, string> = { refunded: 'Refunded', declined: 'Declined', withdrawn: 'Withdrawn by buyer' };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-8">
      <div className="flex items-center gap-2 mb-1">
        <Undo2 className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 className="text-sm font-bold text-slate-700">Refund requests</h3>
        {open.length > 0 && (
          <span className="text-[10px] font-black uppercase tracking-widest bg-amber-100 text-amber-800 rounded px-2 py-0.5">{open.length} open</span>
        )}
      </div>
      <p className="text-xs text-slate-500 mb-4">
        Buyers can ask from their ticket within your refund policy. Nothing is refunded until you say so.
      </p>
      {open.length === 0 && <p className="text-xs text-slate-400">No open requests.</p>}
      <ul className="space-y-3">
        {open.map((a) => (
          <li key={a.askId} className="border border-slate-200 rounded-xl p-4">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="text-sm font-bold text-slate-900">{a.buyerEmail || 'Buyer'} · {a.tierName}</span>
              <span className="text-sm font-bold text-slate-900">{formatCents(a.amountCents, a.currency)}</span>
            </div>
            <p className="text-[11px] text-slate-400 mt-0.5">
              Asked {a.createdAt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
              {a.checkedIn ? ' · already scanned in' : a.ticketStatus !== 'active' ? ` · ticket ${a.ticketStatus}` : ''}
            </p>
            {a.reason && <p className="text-xs text-slate-600 mt-2">“{a.reason}”</p>}
            {declining === a.askId ? (
              <div className="mt-3 space-y-2">
                <label className="block text-[10px] font-black uppercase tracking-widest text-slate-400" htmlFor={`dn-${a.askId}`}>
                  Note to the buyer (optional)
                </label>
                <textarea id={`dn-${a.askId}`} value={note} maxLength={500} rows={2} onChange={(e) => setNote(e.target.value)}
                  className="w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800" />
                <div className="flex gap-2">
                  <button type="button" disabled={busy === a.askId} onClick={() => void decline(a)}
                    className="px-3 py-1.5 rounded bg-slate-900 text-white text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
                    Decline
                  </button>
                  <button type="button" onClick={() => { setDeclining(null); setNote(''); }}
                    className="px-3 py-1.5 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600">
                    Back
                  </button>
                </div>
              </div>
            ) : (
              <div className="mt-3 flex gap-2">
                <button type="button" disabled={busy === a.askId || a.checkedIn || a.ticketStatus !== 'active'} onClick={() => void refund(a)}
                  className="px-3 py-1.5 rounded bg-tm-blue text-white text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
                  {busy === a.askId ? 'Refunding…' : 'Refund'}
                </button>
                <button type="button" disabled={busy === a.askId} onClick={() => setDeclining(a.askId)}
                  className="px-3 py-1.5 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600 disabled:opacity-50">
                  Decline
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
      {closed.length > 0 && (
        <div className="mt-4">
          <button type="button" onClick={() => setShowClosed((v) => !v)} className="text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-slate-800">
            {showClosed ? 'Hide' : 'Show'} {closed.length} closed
          </button>
          {showClosed && (
            <ul className="mt-2 divide-y divide-slate-100 text-xs text-slate-600">
              {closed.map((a) => (
                <li key={a.askId} className="py-2 flex flex-wrap justify-between gap-2">
                  <span>{a.buyerEmail || 'Buyer'} · {a.tierName} · {formatCents(a.amountCents, a.currency)}</span>
                  <span className="text-slate-400">{STATUS[a.status] ?? a.status}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
