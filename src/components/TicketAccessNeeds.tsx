// Holder-side "tell the organizer what you need" on the pass (mig
// 20260926090000). Needs go only to the event's staff and the door; they
// clear when the ticket changes hands. Hides itself when the server doesn't
// have the feature yet (RPC missing).
import { useEffect, useState } from 'react';
import { Accessibility as AccessIcon } from 'lucide-react';
import { AccessNeedsPicker } from './Accessibility';
import { getMyTicketAccessNeeds, setMyTicketAccessNeeds } from '../lib/accessibilityApi';
import type { AccessNeed } from '../lib/accessibility';
import { useToast } from '../context/ToastContext';

export default function TicketAccessNeeds({ ticketId, disabled }: { ticketId: string; disabled?: boolean }) {
  const { toast } = useToast();
  const [saved, setSaved] = useState<AccessNeed[] | null>(null);
  const [draft, setDraft] = useState<AccessNeed[]>([]);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    setSaved(null);
    setOpen(false);
    getMyTicketAccessNeeds(ticketId)
      .then((n) => { if (alive) { setSaved(n); setDraft(n); } })
      .catch(() => { if (alive) setSaved(null); });
    return () => { alive = false; };
  }, [ticketId]);

  if (saved === null) return null;

  const dirty = draft.join() !== saved.join();
  const save = async () => {
    setBusy(true);
    try {
      const n = await setMyTicketAccessNeeds(ticketId, draft);
      setSaved(n); setDraft(n);
      toast({ kind: 'success', message: n.length ? 'Sent to the organizer and the door team.' : 'Access needs cleared.' });
      setOpen(false);
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save. Please try again.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="border border-white/10 bg-white/[0.03] p-5 mb-10" aria-labelledby={`access-${ticketId}`}>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 id={`access-${ticketId}`} className="type text-[11px] uppercase tracking-widest text-white/70 flex items-center gap-2">
            <AccessIcon className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Access needs
          </h3>
          <p className="type text-xs text-white/50 mt-1">
            {saved.length
              ? `Shared with the organizer: ${saved.length} need${saved.length === 1 ? '' : 's'}.`
              : 'Need a wheelchair space, a seat or an interpreter? Let the organizer know.'}
          </p>
        </div>
        {!open && (
          <button
            type="button"
            onClick={() => setOpen(true)}
            disabled={disabled}
            className="type shrink-0 border border-white/20 px-4 py-2.5 text-[11px] uppercase tracking-widest text-white hover:border-brand-primary disabled:opacity-40"
          >
            {saved.length ? 'Edit' : 'Add'}
          </button>
        )}
      </div>
      {open && (
        <div className="mt-4 space-y-4">
          <AccessNeedsPicker idPrefix={`tan-${ticketId}`} value={draft} onChange={setDraft} disabled={busy} />
          <p className="type text-[11px] text-white/40">Only this event's organizer and door staff see this. It's cleared if you transfer the ticket.</p>
          <div className="flex gap-3">
            <button
              type="button"
              onClick={save}
              disabled={busy || !dirty}
              className="disp bg-brand-primary text-black px-6 py-2.5 text-base tracking-wide disabled:opacity-40"
            >
              {busy ? 'Saving…' : 'Save'}
            </button>
            <button
              type="button"
              onClick={() => { setDraft(saved); setOpen(false); }}
              className="type px-4 py-2.5 text-[11px] uppercase tracking-widest text-white/60 hover:text-white"
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
