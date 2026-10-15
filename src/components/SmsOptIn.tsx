// "Text me about this organizer's events" on the ticket page (mig
// 20261016120000). Explicit opt-in: the fan types their number and ticks the
// consent line; the exact words are stored with the opt-in. Shown even before
// the org connects a sender: the list is theirs either way.

import { useEffect, useState } from 'react';
import { MessageSquare } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { consentText, myStatus, normalizePhone, optIn, optOut } from '../lib/sms';
import { getPublicOrg } from '../lib/orgs';

export default function SmsOptIn({ orgId, eventId }: { orgId: string; eventId?: string }) {
  const { toast } = useToast();
  const [status, setStatus] = useState<{ subscribed: boolean; phoneHint: string } | null | undefined>(undefined);
  const [phone, setPhone] = useState('');
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);

  const [orgName, setOrgName] = useState('');
  useEffect(() => {
    myStatus(orgId).then(setStatus).catch(() => setStatus(null));
    getPublicOrg(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
  }, [orgId]);
  if (status === undefined || !orgName) return null;

  const box = 'border border-white/10 bg-white/[0.03] p-4 mt-6';
  const btn = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

  if (status?.subscribed) {
    return (
      <div className={box}>
        <p className="type text-xs text-white/70">Texts from {orgName} go to {status.phoneHint}.</p>
        <button type="button" disabled={busy} className={`${btn} mt-2`} onClick={async () => {
          setBusy(true);
          try { await optOut(orgId); setStatus({ ...status, subscribed: false }); toast({ kind: 'success', message: 'No more texts.' }); }
          catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
          finally { setBusy(false); }
        }}>Stop texts</button>
      </div>
    );
  }

  const valid = normalizePhone(phone) !== null;
  return (
    <div className={box}>
      <p className="type text-xs text-white/80 flex items-center gap-2">
        <MessageSquare className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Get texts about {orgName}'s next events
      </p>
      <div className="mt-3 flex gap-2">
        <input type="tel" inputMode="tel" autoComplete="tel" value={phone} onChange={(e) => setPhone(e.target.value)}
          placeholder="+1 212 555 0100" aria-label="Mobile number"
          className="flex-1 min-w-0 bg-black border border-white/20 px-3 py-2 text-xs text-white" />
        <button type="button" disabled={busy || !valid || !agree} className={btn} onClick={async () => {
          setBusy(true);
          try {
            const r = await optIn(orgId, orgName, phone, eventId);
            setStatus({ subscribed: true, phoneHint: `…${r.phone.slice(-4)}` });
            toast({ kind: 'success', message: `You're on ${orgName}'s text list.` });
          } catch (e) {
            toast({ kind: 'error', message: (e as Error).message });
          } finally {
            setBusy(false);
          }
        }}>Sign up</button>
      </div>
      <label className="type mt-2 flex items-start gap-2 text-[11px] text-white/50 leading-relaxed">
        <input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} className="mt-0.5 accent-brand-primary" />
        <span>{consentText(orgName)}</span>
      </label>
    </div>
  );
}
