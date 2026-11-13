// The buyer's ticket page: event tokens on their tickets for this event (mig
// 20261114110000): drink tickets, ride credits, tasting tickets bought with
// the order or added at the door. Staff take them off the ticket's own QR, so
// there is no separate code to show. The rule (no cash value, this event
// only, when they expire, refundable or not) is shown with the balance.
// Hidden when there are none or before the migration.

import { useEffect, useState } from 'react';
import { myEventTokens, type MyTicketTokens } from '../lib/eventTokensApi';
import { NO_CASH_VALUE } from '../lib/eventTokens';

export default function EventTokensCard({ eventId }: { eventId: string }) {
  const [rows, setRows] = useState<MyTicketTokens[]>([]);
  useEffect(() => {
    let live = true;
    myEventTokens(eventId).then((r) => { if (live) setRows(r); }).catch(() => { if (live) setRows([]); });
    return () => { live = false; };
  }, [eventId]);
  if (rows.length === 0) return null;
  const many = rows.length > 1;
  return (
    <section className="mt-6 border border-white/10 p-5 space-y-3" aria-labelledby="event-tokens-card-title" data-testid="event-tokens-card">
      <h3 id="event-tokens-card-title" className="type text-[11px] text-white/70 uppercase tracking-widest">Event tokens</h3>
      <p className="type text-[11px] text-white/60">Staff scan this ticket&apos;s code to take them. {NO_CASH_VALUE}, this event only.</p>
      {rows.map((t, i) => (
        <div key={t.ticket_id} className="space-y-2">
          {many && <p className="type text-[11px] text-white/60">Ticket {i + 1}</p>}
          <ul className="space-y-1">
            {t.balances.map((b) => (
              <li key={b.product_id} className="type text-sm text-white">
                <span className="disp text-2xl mr-2">{b.credits}</span>{b.name}{b.credits === 1 ? '' : 's'} left
                <span className="block text-[11px] text-white/60">{t.rules[b.product_id]}</span>
              </li>
            ))}
            {t.balances.length === 0 && <li className="type text-[11px] text-white/60">All used, expired or refunded.</li>}
          </ul>
        </div>
      ))}
    </section>
  );
}
