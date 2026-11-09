// My Tickets: every refund request this account made (mig 20261031120000),
// open first. Asking happens on the ticket page (RefundAskCard, within the
// event's refund policy); here the fan sees where each ask stands, the
// organizer's note on a declined one, and can take an open one back.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { listMyRefundAsks, type MyAsk } from '../lib/fans';
import { withdrawRefundAsk } from '../lib/refundAsks';

const STATUS: Record<MyAsk['status'], string> = {
  open: 'Waiting for the organizer',
  refunded: 'Refunded',
  declined: 'Declined',
  withdrawn: 'You took it back',
};

export default function MyRefundAsks({ className = '' }: { className?: string }) {
  const { toast } = useToast();
  const [asks, setAsks] = useState<MyAsk[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const load = useCallback(() => {
    listMyRefundAsks().then(setAsks).catch(() => setAsks([]));
  }, []);
  useEffect(load, [load]);
  if (!asks || asks.length === 0) return null;

  const withdraw = async (a: MyAsk) => {
    setBusy(a.askId);
    try {
      await withdrawRefundAsk(a.askId);
      toast({ kind: 'success', message: 'Request taken back. Your ticket still works.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'That didn\'t work.' });
    } finally {
      setBusy(null);
      load();
    }
  };

  return (
    <section className={className} aria-labelledby="refund-asks-title">
      <h2 id="refund-asks-title" className="type text-[12px] text-brand-primary uppercase tracking-widest mb-6">refund requests</h2>
      <ul className="space-y-3">
        {asks.map((a) => (
          <li key={a.askId} className="bg-[#111] border border-white/10 p-5 flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0">
              <Link to={`/ticket/${a.ticketId}`} className="disp text-lg text-white hover:text-brand-primary leading-tight">{a.eventName}</Link>
              <p className="type text-[11px] text-white/60 uppercase tracking-widest mt-1">
                {a.tierName || 'Ticket'} · {formatCents(a.amountCents, a.currency)} · {STATUS[a.status]}
              </p>
              {a.status === 'declined' && a.declineNote && <p className="text-sm text-white/70 mt-2">“{a.declineNote}”</p>}
            </div>
            {a.status === 'open' && (
              <button type="button" disabled={busy === a.askId} onClick={() => void withdraw(a)}
                className="type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary disabled:opacity-40">
                Take back
              </button>
            )}
          </li>
        ))}
      </ul>
      <p className="text-xs text-white/40 mt-3">To ask for a refund, open the ticket. The organizer decides within their refund policy.</p>
    </section>
  );
}
