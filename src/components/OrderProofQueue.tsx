// OrderProofQueue: guest orders whose tickets wait for the buyer to confirm
// their email or phone (mig 20261105100000). Shown on the Orders page for one
// event (owner / manager). A buyer who mistyped their email can't confirm it:
// "Send to another email" mails fresh claim links to the corrected address and
// kills the old ones (exos_order_proof_resend; the original email is kept).

import { useCallback, useEffect, useState } from 'react';
import { Mail } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { listOrderProofs, resendOrderProof, type OrderProofRow } from '../lib/orderProof';
import { normalizeGuestEmail } from '../../supabase/functions/_shared/guest.ts';

const STATUS: Record<string, string> = {
  pending: 'Waiting for the buyer', proven: 'Confirmed', cancelled: 'Refunded', expired: 'Not confirmed (event over)',
};
const VIA: Record<string, string> = { email_code: 'email code', sms: 'text code', organizer: 'sent by you' };

export default function OrderProofQueue({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<OrderProofRow[] | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    listOrderProofs(eventId).then(setRows).catch(() => setRows([]));
  }, [eventId]);
  useEffect(() => { load(); }, [load]);

  if (!rows || rows.length === 0) return null;
  const waiting = rows.filter((r) => r.status === 'pending').length;

  const resend = async (r: OrderProofRow) => {
    const to = normalizeGuestEmail(email);
    if (!to) { toast({ kind: 'error', message: 'Enter a valid email.' }); return; }
    if (!window.confirm(`Send this order's ${r.tickets} ticket${r.tickets === 1 ? '' : 's'} to ${to}? The links sent to ${r.email} stop working.`)) return;
    setBusy(true);
    try {
      await resendOrderProof(r.sessionId, to);
      toast({ kind: 'success', message: `Claim links sent to ${to}.` });
      setEditing(null); setEmail('');
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white border border-slate-200 rounded-2xl p-4">
      <h3 className="text-sm font-bold text-slate-700 mb-1">Guest orders waiting for email confirmation{waiting ? ` (${waiting})` : ''}</h3>
      <p className="text-xs text-slate-500 mb-3">
        Paid and seats kept; the tickets are released once the buyer enters the code we emailed (or texts a phone).
        If they typed the wrong email, send the order to the right one.
      </p>
      <ul className="divide-y divide-slate-100 text-sm">
        {rows.map((r) => (
          <li key={r.sessionId} className="py-2">
            <div className="flex flex-wrap items-center gap-2 justify-between">
              <span>
                <strong>{r.email}</strong>
                {r.originalEmail !== r.email && <span className="text-slate-400"> (typed: {r.originalEmail})</span>}
                <span className="text-slate-500"> · {r.tickets} ticket{r.tickets === 1 ? '' : 's'} · {STATUS[r.status] ?? r.status}
                  {r.provenVia ? ` (${VIA[r.provenVia] ?? r.provenVia})` : ''}</span>
              </span>
              {r.status === 'pending' && editing !== r.sessionId && (
                <button type="button" className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded border border-slate-200 text-xs font-bold"
                  onClick={() => { setEditing(r.sessionId); setEmail(''); }}>
                  <Mail className="w-3.5 h-3.5" /> Send to another email
                </button>
              )}
            </div>
            {editing === r.sessionId && (
              <form className="flex gap-2 mt-2" onSubmit={(e) => { e.preventDefault(); void resend(r); }}>
                <input type="email" aria-label="Corrected email" value={email} onChange={(e) => setEmail(e.target.value)}
                  placeholder="right@email.com" className="flex-1 bg-slate-50 border border-slate-200 rounded px-3 py-1.5" />
                <button disabled={busy} className="px-3 py-1.5 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50">Send</button>
                <button type="button" className="text-xs underline" onClick={() => setEditing(null)}>Cancel</button>
              </form>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
