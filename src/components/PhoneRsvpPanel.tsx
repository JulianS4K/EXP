// PhoneRsvpPanel — the organizer's phone-number RSVP switch for a free event
// (mig 20261102150000, docs/organizer-guide.md "Phone RSVP"), with the guests
// who RSVP'd. Owner / manager change it (the RPC re-checks); the list of
// guests (names, masked numbers) is owner / manager only by RLS. Hidden when
// the event has no free ticket type or the database doesn't have it yet.

import { useEffect, useState } from 'react';
import { Smartphone } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { publicUrl } from '../lib/utils';
import {
  getPhoneRsvpSettings, listPhoneRsvps, maskPhone, rsvpHeads, setPhoneRsvpSettings,
  type PhoneRsvpRow, type PhoneRsvpSettings,
} from '../lib/phoneRsvp';

export default function PhoneRsvpPanel({ eventId, freeTiers, canManage }: {
  eventId: string;
  freeTiers: { id: string; name: string }[];
  canManage: boolean;
}) {
  const { toast } = useToast();
  const [s, setS] = useState<PhoneRsvpSettings | null>(null);
  const [rows, setRows] = useState<PhoneRsvpRow[] | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (freeTiers.length === 0) return;
    getPhoneRsvpSettings(eventId).then(setS);
    listPhoneRsvps(eventId).then(setRows);
  }, [eventId, freeTiers.length]);

  if (freeTiers.length === 0 || !s) return null;

  const save = async (next: PhoneRsvpSettings) => {
    setBusy(true);
    try {
      await setPhoneRsvpSettings(eventId, next);
      setS(next);
      toast({ kind: 'success', message: next.enabled ? 'Phone RSVP is on.' : 'Phone RSVP is off.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save.' });
    } finally {
      setBusy(false);
    }
  };
  const link = publicUrl(`rsvp/${eventId}`);
  const confirmed = (rows ?? []).filter((r) => r.status === 'confirmed');

  return (
    <section className="bg-white rounded-2xl border border-slate-200 p-6 mb-8">
      <h2 className="text-lg font-bold flex items-center gap-2 mb-1"><Smartphone size={18} aria-hidden="true" /> RSVP by phone</h2>
      <p className="text-sm text-slate-600 mb-4 max-w-prose">
        Guests RSVP with just a name and a mobile number: no app, no account. They get a code by text from your
        Twilio or Telnyx number (Integrations), or by email when texts aren't set up, then their ticket link with the
        live QR code. One RSVP per number; capacity and the waitlist work as usual.
      </p>
      <div className="grid gap-3 md:grid-cols-4 items-end">
        <label className="flex items-center gap-2 text-sm font-bold text-slate-700">
          <input type="checkbox" checked={s.enabled} disabled={!canManage || busy} onChange={(e) => void save({ ...s, enabled: e.target.checked })} />
          On for this event
        </label>
        <label className="text-xs font-bold text-slate-600">Ticket type
          <select className="mt-1 w-full border border-slate-200 rounded-lg px-2 py-2 text-sm" value={s.tierId ?? ''} disabled={!canManage || busy}
            onChange={(e) => void save({ ...s, tierId: e.target.value || null })}>
            <option value="">First free type</option>
            {freeTiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="text-xs font-bold text-slate-600">Plus-ones per guest
          <select className="mt-1 w-full border border-slate-200 rounded-lg px-2 py-2 text-sm" value={s.maxPlusOnes} disabled={!canManage || busy}
            onChange={(e) => void save({ ...s, maxPlusOnes: Number(e.target.value) })}>
            {Array.from({ length: 10 }, (_, i) => <option key={i} value={i}>{i === 0 ? 'None' : `Up to ${i}`}</option>)}
          </select>
        </label>
        {s.enabled && (
          <button type="button" onClick={() => navigator.clipboard?.writeText(link).then(() => toast({ kind: 'success', message: 'RSVP link copied.' })).catch(() => {})}
            className="justify-self-start px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-700">
            Copy RSVP link
          </button>
        )}
      </div>
      {rows && (
        <div className="mt-6">
          <p className="text-xs font-bold text-slate-600 mb-2">
            {confirmed.length} RSVP{confirmed.length === 1 ? '' : 's'} · {rsvpHeads(rows)} people
          </p>
          {confirmed.length > 0 && (
            <ul className="divide-y divide-slate-100 text-sm max-h-72 overflow-auto">
              {confirmed.map((r) => (
                <li key={r.id} className="flex items-center gap-3 py-2">
                  <span className="flex-1 truncate">{r.guestName}{r.plusOnes ? ` +${r.plusOnes}` : ''}</span>
                  <span className="text-xs text-slate-500">{maskPhone(r.phone)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
