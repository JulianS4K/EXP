// Org settings → Gift cards (docs/gift-cards.md, mig 20261030130000).
//
// Products (owner / manager edit; finance and door staff read), a box-office
// sale (cash / check; owner / manager may also comp or record a card taken
// elsewhere), and the recent cards with void / new code. The plain code is
// shown once, right after a sale, and emailed to the recipient; Exos keeps
// only its hash.

import { useCallback, useEffect, useState } from 'react';
import { Gift, Plus } from 'lucide-react';
import {
  formatGiftCardCode, issueGiftCard, listGiftCardProducts, listGiftCards, majorToCents, reissueGiftCardCode,
  saveGiftCardProduct, voidGiftCard, type GiftCardProduct, type GiftCardRow,
} from '../lib/commerce';
import { formatCurrency } from '../lib/utils';
import { useToast } from '../context/ToastContext';

const inputCls = 'bg-slate-50 border-2 border-transparent rounded-2xl py-2 px-4 text-slate-900 font-bold w-full focus:outline-none focus:border-brand-primary focus:bg-white';
const labelCls = 'text-[10px] font-black text-slate-400 uppercase tracking-widest';

interface Props {
  orgId: string;
  /** Owner / manager. */
  canEdit: boolean;
  /** Door staff may record cash / check sales. */
  canSell: boolean;
}

export default function OrgGiftCardsPanel({ orgId, canEdit, canSell }: Props) {
  const { toast } = useToast();
  const [products, setProducts] = useState<GiftCardProduct[]>([]);
  const [cards, setCards] = useState<GiftCardRow[]>([]);
  const [draft, setDraft] = useState({ name: '', amounts: '25, 50, 100', open: false, min: '10', max: '500', expiry: '' });
  const [sale, setSale] = useState({ productId: '', amount: '', method: 'cash' as 'cash' | 'check' | 'comp' | 'card', email: '', name: '', message: '' });
  const [lastCode, setLastCode] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setProducts(await listGiftCardProducts(orgId));
      if (canEdit) setCards(await listGiftCards(orgId));
    } catch { /* RLS: nothing to show */ }
  }, [orgId, canEdit]);
  useEffect(() => { load(); }, [load]);

  const addProduct = async () => {
    const amounts = draft.amounts.split(',').map((a) => majorToCents(a)).filter((a): a is number => a !== null);
    try {
      await saveGiftCardProduct({
        org_id: orgId, name: draft.name.trim(),
        amount_type: draft.open ? 'open' : 'fixed', amounts_cents: draft.open ? [] : amounts,
        min_cents: draft.open ? majorToCents(draft.min) : null, max_cents: draft.open ? majorToCents(draft.max) : null,
        expiry_months: draft.expiry ? Number(draft.expiry) : null,
      });
      setDraft({ ...draft, name: '' });
      toast({ kind: 'success', message: 'Gift card product saved.' });
      load();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the product.' });
    }
  };

  const sell = async () => {
    const cents = majorToCents(sale.amount);
    if (!cents) { toast({ kind: 'error', message: 'Enter an amount.' }); return; }
    setBusy(true);
    try {
      const r = await issueGiftCard({
        orgId, amountCents: cents, paymentMethod: sale.method, productId: sale.productId || null,
        currency: products.find((p) => p.id === sale.productId)?.currency ?? 'usd',
        recipientEmail: sale.email, recipientName: sale.name, message: sale.message,
        externalId: `pos-${Date.now().toString(36)}`, source: 'box_office',
      });
      setLastCode(r.code);
      setSale({ ...sale, amount: '', email: '', name: '', message: '' });
      load();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not issue the gift card.' });
    } finally {
      setBusy(false);
    }
  };

  const doVoid = async (c: GiftCardRow) => {
    if (!window.confirm(`Void the card ending ${c.last4}? Its ${formatCurrency(c.balance_cents / 100, c.currency)} balance is gone.`)) return;
    try { await voidGiftCard(c.id); load(); } catch (e: any) { toast({ kind: 'error', message: e?.message || 'Could not void.' }); }
  };
  const doReissue = async (c: GiftCardRow) => {
    try { const r = await reissueGiftCardCode(c.id); setLastCode(r.code); load(); }
    catch (e: any) { toast({ kind: 'error', message: e?.message || 'Could not make a new code.' }); }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2 flex items-center gap-2"><Gift className="w-4 h-4" /> Gift cards</h2>
      <p className="text-xs text-slate-400 mb-4">
        Sold on your shop page and at the box office, spent at checkout. A gift card is a way to pay: fees and tax are
        on the full price. Leave expiry empty unless you've checked the law where you sell (many places limit it).
      </p>

      <div className="space-y-2 mb-4">
        {products.map((p) => (
          <div key={p.id} className="flex items-center justify-between text-sm">
            <span className="font-bold text-slate-800">{p.name}{p.active === false ? ' (off)' : ''}</span>
            <span className="text-slate-500">
              {p.amount_type === 'fixed'
                ? p.amounts_cents.map((a) => formatCurrency(a / 100, p.currency)).join(' · ')
                : `${formatCurrency((p.min_cents ?? 0) / 100, p.currency)} – ${formatCurrency((p.max_cents ?? 0) / 100, p.currency)}`}
              {canEdit && (
                <button className="ml-3 underline" onClick={async () => { await saveGiftCardProduct({ ...p, active: !p.active }); load(); }}>
                  {p.active ? 'Turn off' : 'Turn on'}
                </button>
              )}
            </span>
          </div>
        ))}
        {products.length === 0 && <p className="text-xs text-slate-400">No gift card products yet.</p>}
      </div>

      {canEdit && (
        <div className="grid grid-cols-2 gap-2 mb-6">
          <label className="col-span-2"><span className={labelCls}>Product name</span>
            <input className={inputCls} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} placeholder="Holiday gift card" /></label>
          <label className="col-span-2 flex items-center gap-2 text-xs text-slate-600">
            <input type="checkbox" checked={draft.open} onChange={(e) => setDraft({ ...draft, open: e.target.checked })} /> Buyer picks the amount
          </label>
          {draft.open ? (<>
            <label><span className={labelCls}>Min</span><input className={inputCls} value={draft.min} onChange={(e) => setDraft({ ...draft, min: e.target.value })} /></label>
            <label><span className={labelCls}>Max</span><input className={inputCls} value={draft.max} onChange={(e) => setDraft({ ...draft, max: e.target.value })} /></label>
          </>) : (
            <label className="col-span-2"><span className={labelCls}>Amounts (comma separated)</span>
              <input className={inputCls} value={draft.amounts} onChange={(e) => setDraft({ ...draft, amounts: e.target.value })} /></label>
          )}
          <label><span className={labelCls}>Expires after (months, optional)</span>
            <input className={inputCls} inputMode="numeric" value={draft.expiry} onChange={(e) => setDraft({ ...draft, expiry: e.target.value.replace(/\D/g, '') })} /></label>
          <button disabled={!draft.name.trim()} onClick={addProduct}
            className="self-end bg-slate-900 text-white rounded-2xl py-2 px-4 text-xs font-black uppercase flex items-center justify-center gap-2 disabled:opacity-40">
            <Plus className="w-4 h-4" /> Add product
          </button>
        </div>
      )}

      {(canSell || canEdit) && (
        <div className="border-t border-slate-100 pt-4">
          <h3 className={`${labelCls} mb-2`}>Box office sale</h3>
          <div className="grid grid-cols-2 gap-2">
            <select className={inputCls} value={sale.productId} onChange={(e) => setSale({ ...sale, productId: e.target.value })}>
              {canEdit ? <option value="">Any amount (no product)</option> : <option value="">Pick a product…</option>}
              {/* Door staff sell fixed-amount products only, under the per-card / per-day caps. */}
              {products.filter((p) => p.active !== false && (canEdit || p.amount_type === 'fixed'))
                .map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            <input className={inputCls} placeholder="Amount" inputMode="decimal" value={sale.amount} onChange={(e) => setSale({ ...sale, amount: e.target.value })} />
            <select className={inputCls} value={sale.method} onChange={(e) => setSale({ ...sale, method: e.target.value as typeof sale.method })}>
              <option value="cash">Cash</option>
              <option value="check">Check</option>
              {canEdit && <option value="comp">Comp (free)</option>}
              {canEdit && <option value="card">Card (taken on your own terminal)</option>}
            </select>
            <input className={inputCls} placeholder="Recipient email (optional)" value={sale.email} onChange={(e) => setSale({ ...sale, email: e.target.value })} />
            <input className={inputCls} placeholder="Recipient name" value={sale.name} onChange={(e) => setSale({ ...sale, name: e.target.value })} />
            <input className={inputCls} placeholder="Message" value={sale.message} onChange={(e) => setSale({ ...sale, message: e.target.value })} />
          </div>
          <button disabled={busy} onClick={sell} className="mt-2 bg-brand-primary text-black rounded-2xl py-2 px-4 text-xs font-black uppercase disabled:opacity-40">
            Issue gift card
          </button>
          {lastCode && (
            <p className="mt-3 text-sm">
              Code (shown once, also emailed if you gave an email): <strong className="font-mono">{formatGiftCardCode(lastCode)}</strong>
            </p>
          )}
        </div>
      )}

      {canEdit && cards.length > 0 && (
        <div className="border-t border-slate-100 pt-4 mt-4">
          <h3 className={`${labelCls} mb-2`}>Recent cards</h3>
          <div className="space-y-1 text-xs">
            {cards.slice(0, 30).map((c) => (
              <div key={c.id} className="flex items-center justify-between">
                <span className="font-mono">…{c.last4}</span>
                <span>{formatCurrency(c.balance_cents / 100, c.currency)} / {formatCurrency(c.initial_cents / 100, c.currency)}</span>
                <span className="text-slate-400">{c.source} · {c.payment_method}{c.status === 'voided' ? ' · voided' : ''}</span>
                {c.status === 'active' && (
                  <span className="space-x-2">
                    <button className="underline" onClick={() => doReissue(c)}>New code</button>
                    <button className="underline text-red-600" onClick={() => doVoid(c)}>Void</button>
                  </span>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
