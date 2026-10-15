// Event report → Marketing → Promo links (mig 20261016110000): one URL per
// channel with a redemption limit, an optional deal and an expiry; visits and
// redemptions per link. Owner / manager create; finance sees.

import { useCallback, useEffect, useState } from 'react';
import { Copy, Link2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  CHANNELS, cleanCode, createPromoLink, dealText, listPromoLinks, promoUrl, redemptionText, type PromoLink,
} from '../lib/promoLinks';

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

export default function PromoLinksPanel({ eventId, currency, canCreate, canView }: {
  eventId: string; currency?: string; canCreate: boolean; canView: boolean;
}) {
  const { toast } = useToast();
  const [links, setLinks] = useState<PromoLink[] | null>(null);
  const [label, setLabel] = useState('');
  const [channel, setChannel] = useState('instagram');
  const [limit, setLimit] = useState('50');
  const [days, setDays] = useState('');
  const [deal, setDeal] = useState<'none' | 'percent' | 'amount'>('none');
  const [value, setValue] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    if (!canView) return;
    listPromoLinks(eventId).then(setLinks).catch(() => setLinks([]));
  }, [eventId, canView]);
  useEffect(load, [load]);
  if (!canView) return null;

  const n = Number(limit);
  const v = Number(value);
  const err = !label.trim() ? 'Name the link (e.g. "Instagram story").'
    : !Number.isInteger(n) || n < 1 || n > 100000 ? 'Limit: 1 to 100000 tickets.'
    : days && (!Number.isInteger(Number(days)) || Number(days) < 1 || Number(days) > 365) ? 'Expiry: 1 to 365 days.'
    : deal === 'percent' && (!(v > 0) || v >= 100) ? 'Percent off: more than 0, less than 100.'
    : deal === 'amount' && !(v > 0) ? 'Amount off: more than 0.'
    : code && cleanCode(code).length < 4 ? 'Code: at least 4 letters or digits.'
    : null;

  const copy = (text: string) =>
    navigator.clipboard.writeText(text).then(
      () => toast({ kind: 'success', message: 'Link copied.' }),
      () => toast({ kind: 'error', message: 'Copy failed. Select and copy manually.' }),
    );

  const create = async () => {
    if (err) return;
    setBusy(true);
    try {
      const c = await createPromoLink({
        eventId, label, channel, maxUses: n, validHours: days ? Number(days) * 24 : null, code: code || undefined,
        discountPercent: deal === 'percent' ? v : null, discountAmount: deal === 'amount' ? v : null,
      });
      toast({ kind: 'success', message: `Link ready (code ${c}).` });
      setLabel(''); setCode(''); setValue(''); setDeal('none');
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-8">
      <div className="flex items-center gap-2 mb-1">
        <Link2 className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 className="text-sm font-bold text-slate-700">Promo links</h3>
      </div>
      <p className="text-xs text-slate-500 mb-4">
        One link per place you post it. It opens the event with the code applied and stops working after the limit
        (tickets) or the expiry. Sales show up under Sales by source with the link's channel.
      </p>

      {canCreate && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-5">
          <label className="block sm:col-span-2"><span className={LBL}>Name</span>
            <input className={FLD} value={label} maxLength={80} onChange={(e) => setLabel(e.target.value)} placeholder="Instagram story, Oct 20" /></label>
          <label className="block"><span className={LBL}>Channel</span>
            <input className={FLD} list="promo-channels" value={channel} onChange={(e) => setChannel(e.target.value)} />
            <datalist id="promo-channels">{CHANNELS.map((c) => <option key={c} value={c} />)}</datalist></label>
          <label className="block"><span className={LBL}>Limit (tickets)</span>
            <input className={FLD} inputMode="numeric" value={limit} onChange={(e) => setLimit(e.target.value.replace(/[^0-9]/g, ''))} /></label>
          <label className="block"><span className={LBL}>Deal</span>
            <select className={FLD} value={deal} onChange={(e) => setDeal(e.target.value as typeof deal)}>
              <option value="none">No discount (tracking only)</option>
              <option value="percent">Percent off</option>
              <option value="amount">Amount off per ticket</option>
            </select></label>
          {deal !== 'none' && (
            <label className="block"><span className={LBL}>{deal === 'percent' ? 'Percent' : `Amount (${currency || 'USD'})`}</span>
              <input className={FLD} inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value.replace(/[^0-9.]/g, ''))} /></label>
          )}
          <label className="block"><span className={LBL}>Expires after (days, optional)</span>
            <input className={FLD} inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value.replace(/[^0-9]/g, ''))} /></label>
          <label className="block"><span className={LBL}>Code (optional)</span>
            <input className={FLD} value={code} onChange={(e) => setCode(cleanCode(e.target.value))} placeholder="random" /></label>
          <div className="sm:col-span-2 flex items-center gap-3">
            <button type="button" onClick={() => void create()} disabled={busy || !!err}
              className="px-4 py-2 bg-tm-blue text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
              {busy ? 'Creating…' : 'Create link'}
            </button>
            {err && label && <span className="text-[11px] text-rose-600">{err}</span>}
          </div>
        </div>
      )}

      {links && links.length === 0 && <p className="text-xs text-slate-400">No promo links yet.</p>}
      <ul className="space-y-3">
        {(links ?? []).map((l) => {
          const url = promoUrl(eventId, l);
          const expired = l.validUntil && l.validUntil.getTime() < Date.now();
          return (
            <li key={l.voucherId} className="border border-slate-200 rounded-xl p-4">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="text-sm font-bold text-slate-900">{l.label}</span>
                <span className="text-[11px] text-slate-500">{l.channel ?? 'promo'} · code {l.code}</span>
              </div>
              <p className="text-[11px] text-slate-500 mt-1">
                {dealText(l, currency)} · {l.clicks} visits · {redemptionText(l)}
                {l.validUntil ? ` · ${expired ? 'expired' : 'until'} ${l.validUntil.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}` : ''}
              </p>
              <div className="flex gap-2 mt-2">
                <input readOnly value={url} aria-label={`${l.label} link`} onClick={(e) => (e.target as HTMLInputElement).select()}
                  className="flex-1 min-w-0 bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-[11px] text-slate-700 font-mono" />
                <button type="button" onClick={() => void copy(url)}
                  className="px-3 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 inline-flex items-center gap-1">
                  <Copy className="w-3 h-3" aria-hidden="true" /> Copy
                </button>
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
