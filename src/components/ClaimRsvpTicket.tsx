// ClaimRsvpTicket — on a ticket link page (/t/:id#k=…), a signed-in guest
// moves a phone-RSVP ticket into their Exos account (mig 20261102150000,
// exos_phone_rsvp_claim). The link key proves they hold it; the barcode
// secret rotates, so the old link stops working and the ticket lives in My
// tickets (transfer, wallet and door as usual). Other links answer
// "not_claimable" and the button says so.

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { claimRsvpTicket } from '../lib/phoneRsvp';

export default function ClaimRsvpTicket({ ticketId, linkKey }: { ticketId: string; linkKey: string }) {
  const { user } = useAuth();
  const [state, setState] = useState<'idle' | 'busy' | 'done' | 'no'>('idle');
  const [msg, setMsg] = useState<string | null>(null);
  if (!user) return null;
  if (state === 'done') {
    return <p className="text-[11px] text-white/70">Saved to your account. <Link to={`/ticket/${ticketId}`} className="text-brand-primary">Open it in My tickets</Link>.</p>;
  }
  if (state === 'no') return msg ? <p className="text-[11px] text-white/50">{msg}</p> : null;
  return (
    <div className="space-y-1">
      <button type="button" disabled={state === 'busy'}
        className="w-full border border-brand-primary text-brand-primary px-3 py-2 text-[11px] uppercase tracking-widest disabled:opacity-50"
        onClick={async () => {
          setState('busy');
          try {
            const r = await claimRsvpTicket(ticketId, linkKey);
            if (r.ok) { setState('done'); return; }
            setState('no');
            setMsg(r.error === 'not_claimable' ? 'This ticket stays on its link (it isn\'t a phone RSVP, or it was already saved).' : 'This link no longer works.');
          } catch (e: any) {
            setState('idle');
            setMsg(e?.message || 'Could not save it. Try again.');
          }
        }}>
        Save to my Exos account
      </button>
      {msg && state === 'idle' && <p className="text-[11px] text-rose-300">{msg}</p>}
    </div>
  );
}
