// A promoter's own handles and "tag me" switch, on their private kit page.
// Saved with the kit token (exos_promoter_set_socials, mig 20260925010000);
// fans' shares @-tag them only while the switch is on (lib/socialTags.ts).

import { useState, type FormEvent } from 'react';
import { AtSign } from 'lucide-react';
import { setPromoterSocials } from '../lib/promoters';
import { cleanHandle, type SocialHandles, type SocialPlatform } from '../lib/socialTags';
import { useToast } from '../context/ToastContext';

const FIELDS: { key: SocialPlatform; label: string }[] = [
  { key: 'instagram', label: 'Instagram' },
  { key: 'tiktok', label: 'TikTok' },
  { key: 'x', label: 'X' },
];

export default function PromoterSocialsForm({ token, socials, allowTagging }: {
  token: string;
  socials: SocialHandles;
  allowTagging: boolean;
}) {
  const { toast } = useToast();
  const [values, setValues] = useState<SocialHandles>(socials);
  const [allow, setAllow] = useState(allowTagging);
  const [busy, setBusy] = useState(false);

  const save = async (e: FormEvent) => {
    e.preventDefault();
    const out: SocialHandles = {};
    for (const { key, label } of FIELDS) {
      const raw = values[key]?.trim();
      if (!raw) continue;
      const h = cleanHandle(raw, key);
      if (!h) { toast({ kind: 'error', message: `That ${label} handle doesn't look right.` }); return; }
      out[key] = h;
    }
    setBusy(true);
    try {
      await setPromoterSocials(token, out, allow);
      setValues(out);
      toast({ kind: 'success', message: allow ? 'Saved. Fans who share will tag you.' : 'Saved. Shares won\'t tag you.' });
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not save.' });
    } finally {
      setBusy(false);
    }
  };

  const field = 'bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus:border-brand-primary';
  return (
    <form onSubmit={save} className="bg-[#111] border border-white/10 p-4 mb-8">
      <p className="type text-[10px] uppercase tracking-widest text-brand-primary mb-2 flex items-center gap-1">
        <AtSign className="w-3 h-3" /> Get tagged
      </p>
      <p className="text-xs text-white/60 mb-3">
        When fans who came through your links share the event, their posts mention you.
      </p>
      <div className="grid gap-2 sm:grid-cols-3 mb-3">
        {FIELDS.map(({ key, label }) => (
          <input
            key={key}
            className={field}
            placeholder={`${label} @handle`}
            aria-label={`${label} handle`}
            value={values[key] ?? ''}
            onChange={(e) => setValues((v) => ({ ...v, [key]: e.target.value }))}
          />
        ))}
      </div>
      <label className="flex items-center gap-2 text-xs text-white/70 mb-3">
        <input type="checkbox" checked={allow} onChange={(e) => setAllow(e.target.checked)} />
        Tag me in shares
      </label>
      <button disabled={busy} className="bg-brand-primary text-black px-4 py-2 text-xs font-black uppercase disabled:opacity-50">
        Save
      </button>
    </form>
  );
}
