// /ticket-counts/opt-out?t=<token> — stop one show's ticket-count emails
// (docs/offers-settlements.md). Loading the page only describes it; the
// button opts out (so a link scanner can't do it for you).

import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { ticketCountsOptOut } from '../lib/offersApi';
import { BTN_PRIMARY } from '../components/finance/ui';

export default function TicketCountsOptOut() {
  const [sp] = useSearchParams();
  const token = sp.get('t') ?? '';
  const [info, setInfo] = useState<Awaited<ReturnType<typeof ticketCountsOptOut>> | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  useEffect(() => { ticketCountsOptOut(token, false).then(setInfo).catch(() => setInfo(null)); }, [token]);
  if (info === undefined) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (info === null) return <div className="max-w-xl mx-auto p-8 text-sm text-slate-600">This link isn't valid.</div>;
  return (
    <div className="max-w-xl mx-auto px-4 py-12">
      <h1 className="text-xl font-black text-slate-900 mb-2">Ticket-count emails</h1>
      <p className="text-sm text-slate-600 mb-6">{info.event?.name} · from {info.org?.name} · to {info.email}</p>
      {info.opted_out
        ? <p className="text-sm text-slate-700">You won't get these emails for this show any more.</p>
        : <button className={BTN_PRIMARY} disabled={busy} onClick={async () => {
            setBusy(true);
            try { setInfo(await ticketCountsOptOut(token, true)); } finally { setBusy(false); }
          }}>Stop these emails</button>}
    </div>
  );
}
