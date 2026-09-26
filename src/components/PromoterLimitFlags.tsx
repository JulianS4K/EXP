// The promoter portal's "Limit flags" tab (mig 20260926194000): accounts that
// bought through this promoter's links and now hold more of an event's
// tickets than its max per account. Email masked; the promoter can leave a
// note for the organizer, who does the reviewing.
import { useState } from 'react';
import { notePromoterLimitFlag, type PromoterLimitFlag } from '../lib/marketplace/linksApi';
import { useToast } from '../context/ToastContext';

export default function PromoterLimitFlags({
  token, flags, onChanged,
}: { token: string; flags: PromoterLimitFlag[]; onChanged: () => void }) {
  const { toast } = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const note = async (f: PromoterLimitFlag) => {
    const text = window.prompt('A note for the organizer (e.g. who this is, why they bought extra)', f.promoter_note ?? '');
    if (text === null) return;
    setBusy(f.id);
    try {
      await notePromoterLimitFlag(token, f.id, text);
      onChanged();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(null);
    }
  };
  if (!flags.length) {
    return <p className="text-[11px] text-white/40 italic">No buyer from your links is over an event's per-account limit.</p>;
  }
  return (
    <div className="space-y-3">
      <p className="text-xs text-white/60">
        These buyers came through your links and now hold more tickets than the event allows per account. The organizer
        reviews them; add a note if you know who they are.
      </p>
      {flags.map((f) => (
        <section key={f.id} className={`bg-[#111] border p-4 ${f.reviewed ? 'border-white/10 opacity-70' : 'border-amber-400/60'}`}>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="text-xs text-white/70 space-y-1">
              <p className="text-white font-bold">{f.event_name ?? 'Event'}</p>
              <p>{f.buyer ?? 'A buyer'} holds {f.held} (limit {f.max_per_account}), {f.from_you} through your links</p>
              {f.promoter_note && <p className="text-white/80">Your note: “{f.promoter_note}”</p>}
              {f.reviewed && <p className="text-white/50">Reviewed by the organizer</p>}
            </div>
            <button type="button" disabled={busy === f.id} onClick={() => note(f)}
              className="px-3 py-2 border border-white/20 text-white/80 text-[10px] uppercase tracking-widest disabled:opacity-50">
              {f.promoter_note ? 'Edit note' : 'Add note'}
            </button>
          </div>
        </section>
      ))}
    </div>
  );
}
