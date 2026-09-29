// "Offer refunds to ticket holders?" + the refund deadline, shown when an
// organizer moves a sold event to another day or by more than 3 hours
// (mig 20260929150000). Used by the Edit event save prompt (dark) and the
// Reschedule panel on the event dashboard (light). The deadline is entered in
// the event's time zone; the server re-checks it (future, not after the new
// start) and records the choice with the reschedule.

import { useId } from 'react';

export default function RefundOfferFields({
  offer,
  onOffer,
  deadline,
  onDeadline,
  tz,
  dark = false,
  problem,
}: {
  offer: boolean;
  onOffer: (v: boolean) => void;
  /** datetime-local wall clock in `tz` */
  deadline: string;
  onDeadline: (v: string) => void;
  tz: string;
  dark?: boolean;
  /** Validation message to show under the deadline, if any. */
  problem?: string | null;
}) {
  const id = useId();
  const label = dark ? 'text-white' : 'text-slate-700';
  const hint = dark ? 'text-white/60' : 'text-slate-400';
  const input = dark
    ? 'bg-black border border-white/20 text-white focus:border-brand-primary'
    : 'border-2 border-slate-200 focus:border-slate-900';
  return (
    <div className="space-y-3">
      <label htmlFor={`${id}-offer`} className={`flex items-start gap-3 cursor-pointer ${label}`}>
        <input
          id={`${id}-offer`}
          type="checkbox"
          checked={offer}
          onChange={(e) => onOffer(e.target.checked)}
          className="mt-1 h-4 w-4 accent-current"
        />
        <span>
          <span className="block text-sm font-bold">Offer refunds to ticket holders</span>
          <span className={`block text-xs ${hint}`}>
            Anyone who bought before the change can get their money back (tax included) until the deadline, no
            approval needed. Free tickets can be given back. Marketplace buyers are refunded by the marketplace.
          </span>
        </span>
      </label>
      {offer && (
        <label htmlFor={`${id}-deadline`} className="block">
          <span className={`block text-[10px] font-black uppercase tracking-widest mb-1 ${hint}`}>
            Refund deadline ({tz})
          </span>
          <input
            id={`${id}-deadline`}
            type="datetime-local"
            value={deadline}
            onChange={(e) => onDeadline(e.target.value)}
            className={`w-full outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 px-2 py-1.5 text-xs rounded-lg ${input}`}
          />
          {problem ? (
            <span role="alert" className="block text-xs text-rose-500 mt-1">{problem}</span>
          ) : (
            <span className={`block text-xs mt-1 ${hint}`}>
              Default: two weeks from now, or a day before the new start if that comes first.
            </span>
          )}
        </label>
      )}
      {!offer && (
        <p className={`text-xs ${hint}`}>Holders are still emailed the new date; their tickets stay valid.</p>
      )}
    </div>
  );
}
