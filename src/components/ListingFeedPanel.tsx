// Org settings → Listing feed (mig 20261030110000, docs/listing-feed.md). An
// owner mints one shared key per listing partner (Bandsintown, JamBase,
// Songkick, their own website…); the key and its feed URL are shown once.
// Revoking stops the key at once.

import { useEffect, useState } from 'react';
import { Copy } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  createListingKey, listingFeedUrl, listListingKeys, PARTNER_TYPES, revokeListingKey,
  type ListingKey, type PartnerType,
} from '../lib/artists';

const PARTNER_LABELS: Record<PartnerType, string> = {
  bandsintown: 'Bandsintown', jambase: 'JamBase', songkick: 'Songkick', website: 'Our website', other: 'Other',
};
const BTN = 'px-4 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue transition-colors disabled:opacity-40';
const FLD = 'bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

export default function ListingFeedPanel({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [keys, setKeys] = useState<ListingKey[] | null>(null);
  const [partner, setPartner] = useState<PartnerType>('bandsintown');
  const [label, setLabel] = useState('');
  const [fresh, setFresh] = useState<{ key: string; url: string } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    listListingKeys(orgId).then((k) => alive && setKeys(k)).catch(() => alive && setKeys(null));
    return () => { alive = false; };
  }, [orgId]);

  // Before the migration (or without the owner role) there is nothing to show.
  if (!keys) return null;

  const create = async () => {
    setBusy(true);
    try {
      const k = await createListingKey(orgId, partner, label.trim());
      setKeys([...keys, k]);
      setFresh({ key: k.key, url: listingFeedUrl(k.key) });
      setLabel('');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (k: ListingKey) => {
    if (!window.confirm(`Revoke the ${k.label} key? The partner's feed stops working at once.`)) return;
    try {
      await revokeListingKey(k.id);
      setKeys(keys.map((x) => (x.id === k.id ? { ...x, revoked_at: new Date().toISOString() } : x)));
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  };

  const copy = (text: string) => {
    navigator.clipboard.writeText(text)
      .then(() => toast({ kind: 'success', message: 'Copied.' }))
      .catch(() => toast({ kind: 'error', message: 'Copy failed — select and copy manually.' }));
  };

  return (
    <div data-testid="listing-feed-panel" className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2">Listing feed</h2>
      <p className="text-xs text-slate-400 mb-4">
        Your published, listed upcoming events and their lineups as a feed for listing sites (Bandsintown, JamBase,
        Songkick) or your own website. It follows Opendate's public listing format, so a partner that reads Opendate
        only needs the new URL. Make one key per partner: each can be revoked on its own, and its ticket links are
        tagged with the partner. Secret venues show only their area.
      </p>
      <div className="flex flex-wrap gap-2 items-end mb-4">
        <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
          Partner
          <select className={`${FLD} block mt-1`} value={partner} onChange={(e) => setPartner(e.target.value as PartnerType)}>
            {PARTNER_TYPES.map((p) => <option key={p} value={p}>{PARTNER_LABELS[p]}</option>)}
          </select>
        </label>
        <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
          Label (optional)
          <input className={`${FLD} block mt-1`} value={label} maxLength={80} onChange={(e) => setLabel(e.target.value)} />
        </label>
        <button type="button" className={BTN} disabled={busy} onClick={create}>Create shared key</button>
      </div>

      {fresh && (
        <div role="status" className="bg-emerald-50 border border-emerald-200 rounded-lg p-3 mb-4 space-y-2">
          <p className="text-xs text-emerald-800 font-bold">Copy the feed URL now — the key isn't shown again.</p>
          <div className="flex gap-2">
            <input readOnly aria-label="Feed URL" value={fresh.url || fresh.key} onClick={(e) => (e.target as HTMLInputElement).select()}
              className="flex-1 min-w-0 bg-white border border-emerald-200 rounded px-2 py-1 text-[11px] font-mono" />
            <button type="button" className={`${BTN} inline-flex items-center gap-1`} onClick={() => copy(fresh.url || fresh.key)}>
              <Copy className="w-3 h-3" aria-hidden="true" /> Copy
            </button>
          </div>
        </div>
      )}

      {keys.length > 0 && (
        <ul className="divide-y divide-slate-100">
          {keys.map((k) => (
            <li key={k.id} className="flex items-center gap-3 py-2 text-sm">
              <span className="flex-1 min-w-0">
                <span className="font-bold">{k.label}</span>{' '}
                <span className="text-[11px] text-slate-400">{PARTNER_LABELS[k.partner_type] ?? k.partner_type} · {k.key_prefix}…
                  {k.last_used_at ? ` · last read ${new Date(k.last_used_at).toLocaleString()}` : ' · not read yet'}</span>
              </span>
              {k.revoked_at
                ? <span className="text-[10px] font-black uppercase text-slate-400">Revoked</span>
                : <button type="button" className={BTN} onClick={() => revoke(k)}>Revoke</button>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
