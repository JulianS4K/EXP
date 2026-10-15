// "Ask for a refund" on the ticket page (mig 20261015090000). Shown only to
// the person who paid; the organizer decides. Silent when there's nothing to
// say (comp, marketplace, someone else paid).

import { useCallback, useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { askRefund, cantAskText, fetchMyRefundAsks, policyLine, withdrawRefundAsk, type MyRefundAsk } from '../lib/refundAsks';

export default function RefundAskCard({ eventId, ticketId }: { eventId: string; ticketId: string }) {
  const { toast } = useToast();
  const [row, setRow] = useState<MyRefundAsk | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    fetchMyRefundAsks(eventId)
      .then((rows) => setRow(rows.find((r) => r.ticketId === ticketId) ?? null))
      .catch(() => setRow(null));
  }, [eventId, ticketId]);
  useEffect(() => {
    setOpen(false);
    setReason('');
    load();
  }, [load]);

  if (!row) return null;

  const submit = async () => {
    setBusy(true);
    try {
      const [res] = await askRefund([ticketId], reason);
      if (res?.ok) {
        toast({ kind: 'success', message: 'Sent. The organizer will refund or reply here.' });
        setOpen(false);
      } else {
        toast({ kind: 'error', message: cantAskText(res?.reason ?? null, row.askUntil) || 'You can\'t ask for a refund on this ticket.' });
      }
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not sent.' });
    } finally {
      setBusy(false);
      load();
    }
  };

  const withdraw = async () => {
    if (!row.askId) return;
    setBusy(true);
    try {
      await withdrawRefundAsk(row.askId);
      toast({ kind: 'success', message: 'Request withdrawn. Your ticket stays valid.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not withdrawn.' });
    } finally {
      setBusy(false);
      load();
    }
  };

  const box = 'border border-white/10 bg-white/[0.03] p-4 mt-6';
  const btn = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

  if (row.askStatus === 'open') {
    return (
      <div className={box} role="status">
        <p className="type text-xs text-white/80">
          Refund requested ({formatCents(row.amountCents, row.currency)}). Waiting for the organizer. Your ticket still works until they refund it.
        </p>
        <button type="button" onClick={() => void withdraw()} disabled={busy} className={`${btn} mt-3`}>Withdraw request</button>
      </div>
    );
  }

  const declined = row.askStatus === 'declined' && (
    <p className="type text-xs text-white/70 mb-2">
      The organizer declined your last request{row.declineNote ? `: “${row.declineNote}”` : '.'}
    </p>
  );

  if (!row.canAsk) {
    const why = cantAskText(row.reason, row.askUntil);
    if (!why && !declined) return null;
    return (
      <div className={box}>
        {declined}
        {why && <p className="type text-[11px] text-white/50">{why}</p>}
      </div>
    );
  }

  return (
    <div className={box}>
      {declined}
      <p className="type text-[11px] text-white/50">{policyLine(row.refundPolicy, row.askUntil)}</p>
      {open ? (
        <div className="mt-3 space-y-2">
          <label htmlFor={`ra-${ticketId}`} className="type block text-[10px] uppercase tracking-widest text-white/50">
            Why? (optional, the organizer sees it)
          </label>
          <textarea id={`ra-${ticketId}`} value={reason} maxLength={500} rows={2} onChange={(e) => setReason(e.target.value)}
            className="w-full bg-black border border-white/20 px-3 py-2 text-xs text-white" />
          <div className="flex gap-2">
            <button type="button" onClick={() => void submit()} disabled={busy} className={btn}>
              {busy ? 'Sending…' : `Ask for ${formatCents(row.amountCents, row.currency)}`}
            </button>
            <button type="button" onClick={() => setOpen(false)} className={btn}>Cancel</button>
          </div>
        </div>
      ) : (
        <button type="button" onClick={() => setOpen(true)} className={`${btn} mt-3`}>Ask for a refund</button>
      )}
    </div>
  );
}
