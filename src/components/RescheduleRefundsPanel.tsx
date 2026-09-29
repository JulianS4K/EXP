// Date-change refunds (seller side), next to the refund panel on the event
// dashboard (mig 20260929150000). Shows every date change and, for the latest
// one, what buyers did with the refund offer: refunds asked for, money
// returned (and still on its way), free tickets given back, and how many
// tickets could still ask before the deadline. Read-only; buyers act on their
// own from the email or My Tickets. Owner / manager / finance; renders nothing
// before the first date change (or before the migration is applied).

import { useEffect, useState } from 'react';
import { CalendarClock, ArrowRight } from 'lucide-react';
import { Event } from '../types';
import { getRescheduleSummary, type RescheduleSummary } from '../lib/rescheduleRefunds';
import { formatInTz, getBrowserTimezone } from '../lib/datetime';
import { formatCents } from '../lib/refunds';

export default function RescheduleRefundsPanel({ event, canView }: { event: Event; canView: boolean }) {
  const [summary, setSummary] = useState<RescheduleSummary | null>(null);
  const tz = event.timezone || getBrowserTimezone();

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    void getRescheduleSummary(event.id).then((s) => {
      if (!cancelled) setSummary(s);
    });
    return () => {
      cancelled = true;
    };
  }, [event.id, canView]);

  if (!canView || !summary || summary.reschedules.length === 0) return null;
  const l = summary.latest;
  const when = (d: Date | null) => (d ? formatInTz(d, tz, { dateStyle: 'medium', timeStyle: 'short' }) : 'TBA');

  const stat = (label: string, value: string) => (
    <div className="bg-slate-50 rounded-xl px-4 py-3">
      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{label}</p>
      <p className="text-lg font-black text-slate-800">{value}</p>
    </div>
  );

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-6" aria-labelledby="resched-refunds-title">
      <div className="flex items-center gap-2 mb-1">
        <CalendarClock className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 id="resched-refunds-title" className="text-sm font-bold text-slate-700">Date changes and refunds</h3>
      </div>

      {l && l.refundsOffered ? (
        <>
          <p className="text-xs text-slate-400 mb-4">
            {l.open
              ? `Ticket holders can ask for a refund until ${when(l.refundDeadline)}.`
              : `The refund offer closed ${when(l.refundDeadline)}.`}{' '}
            Refunds are automatic and come out of this event's payouts.
          </p>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            {stat('Refunds asked for', String(l.refundsRequested))}
            {stat('Returned', formatCents(l.refundedCents, l.currency))}
            {stat('Free tickets given back', String(l.released))}
            {stat('Could still ask', l.open ? String(l.remainingEligible) : '0')}
          </div>
          {l.inFlightCents > 0 && (
            <p className="text-xs text-slate-500 mb-4">{formatCents(l.inFlightCents, l.currency)} is still on its way back to buyers.</p>
          )}
        </>
      ) : (
        <p className="text-xs text-slate-400 mb-4">No refunds were offered for the latest date change.</p>
      )}

      <ul className="space-y-2 border-t border-slate-100 pt-4">
        {summary.reschedules.map((r) => (
          <li key={r.id} className="text-xs text-slate-500 flex flex-wrap items-center gap-2">
            <span className="text-slate-400 line-through">{when(r.oldStartsAt)}</span>
            <ArrowRight size={12} className="text-slate-300" aria-hidden="true" />
            <span className="font-bold text-slate-700">{when(r.newStartsAt)}</span>
            <span className="text-[10px] font-black text-slate-300 uppercase tracking-widest">
              · {r.recipientCount} emailed · {r.refundsOffered ? `refunds until ${when(r.refundDeadline)}` : 'no refunds offered'}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}
