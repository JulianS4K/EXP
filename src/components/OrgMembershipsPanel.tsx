// Org settings → Memberships & passes (docs/memberships.md, mig 20261030130500).
// Owner / manager edit products and comp a membership as a gift; finance reads.
// Editing a product never changes existing members (they keep their snapshot).

import { useCallback, useEffect, useState } from 'react';
import { BadgeCheck, Ticket } from 'lucide-react';
import {
  giftMembership, listMembershipProducts, listPassProducts, majorToCents, saveMembershipProduct, savePassProduct,
  scanMembershipCard, type MembershipProduct, type PassProduct,
} from '../lib/commerce';
import { formatCurrency } from '../lib/utils';
import { useToast } from '../context/ToastContext';

const inputCls = 'bg-slate-50 border-2 border-transparent rounded-2xl py-2 px-4 text-slate-900 font-bold w-full focus:outline-none focus:border-brand-primary focus:bg-white';
const labelCls = 'text-[10px] font-black text-slate-400 uppercase tracking-widest';

export default function OrgMembershipsPanel({ orgId, canEdit, canScan }: { orgId: string; canEdit: boolean; canScan: boolean }) {
  const { toast } = useToast();
  const [members, setMembers] = useState<MembershipProduct[]>([]);
  const [passes, setPasses] = useState<PassProduct[]>([]);
  const [m, setM] = useState({ name: '', price: '', billing: 'month' as 'month' | 'year' | 'once', discount: '10', presale: true, free: '0', guests: '0', seats: '0' });
  const [p, setP] = useState({ name: '', price: '', kind: 'flex' as 'season' | 'flex', credits: '5', from: '', to: '' });
  const [gift, setGift] = useState({ productId: '', email: '' });
  const [card, setCard] = useState('');
  const [scan, setScan] = useState<Record<string, unknown> | null>(null);

  const load = useCallback(async () => {
    try { setMembers(await listMembershipProducts(orgId)); setPasses(await listPassProducts(orgId)); } catch { /* RLS */ }
  }, [orgId]);
  useEffect(() => { load(); }, [load]);

  const fail = (e: any, msg: string) => toast({ kind: 'error', message: e?.message || msg });

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 space-y-6">
      <div>
        <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2 flex items-center gap-2"><BadgeCheck className="w-4 h-4" /> Memberships</h2>
        <p className="text-xs text-slate-400 mb-3">Monthly / yearly (a Stripe subscription) or a one-time term. Member price, presales, free tickets each period, guests and household seats.</p>
        {members.map((x) => (
          <div key={x.id} className="flex justify-between text-sm">
            <span className="font-bold">{x.name}{x.active === false ? ' (off)' : ''}</span>
            <span className="text-slate-500">{formatCurrency(x.price_cents / 100, x.currency)} / {x.billing} · {Number(x.discount_percent)}% off
              {canEdit && <button className="ml-2 underline" onClick={async () => { await saveMembershipProduct({ ...x, active: !x.active }); load(); }}>{x.active ? 'Turn off' : 'Turn on'}</button>}
            </span>
          </div>
        ))}
        {canEdit && (
          <div className="grid grid-cols-3 gap-2 mt-3">
            <label className="col-span-3"><span className={labelCls}>Name</span><input className={inputCls} value={m.name} onChange={(e) => setM({ ...m, name: e.target.value })} /></label>
            <label><span className={labelCls}>Price</span><input className={inputCls} inputMode="decimal" value={m.price} onChange={(e) => setM({ ...m, price: e.target.value })} /></label>
            <label><span className={labelCls}>Billing</span>
              <select className={inputCls} value={m.billing} onChange={(e) => setM({ ...m, billing: e.target.value as typeof m.billing })}>
                <option value="month">Monthly</option><option value="year">Yearly</option><option value="once">One-time (365 days)</option>
              </select></label>
            <label><span className={labelCls}>% off tickets</span><input className={inputCls} inputMode="decimal" value={m.discount} onChange={(e) => setM({ ...m, discount: e.target.value })} /></label>
            <label><span className={labelCls}>Free tickets / period</span><input className={inputCls} inputMode="numeric" value={m.free} onChange={(e) => setM({ ...m, free: e.target.value })} /></label>
            <label><span className={labelCls}>Guests</span><input className={inputCls} inputMode="numeric" value={m.guests} onChange={(e) => setM({ ...m, guests: e.target.value })} /></label>
            <label><span className={labelCls}>Household seats</span><input className={inputCls} inputMode="numeric" value={m.seats} onChange={(e) => setM({ ...m, seats: e.target.value })} /></label>
            <label className="flex items-center gap-2 text-xs col-span-2"><input type="checkbox" checked={m.presale} onChange={(e) => setM({ ...m, presale: e.target.checked })} /> Member presales</label>
            <button className="bg-slate-900 text-white rounded-2xl text-xs font-black uppercase" disabled={!m.name || !majorToCents(m.price)} onClick={async () => {
              try {
                await saveMembershipProduct({ org_id: orgId, name: m.name, price_cents: majorToCents(m.price) ?? 0, billing: m.billing,
                  discount_percent: Number(m.discount) || 0, presale: m.presale, free_tickets_per_period: Number(m.free) || 0,
                  guest_allowance: Number(m.guests) || 0, household_seats: Number(m.seats) || 0 });
                setM({ ...m, name: '' }); load();
              } catch (e) { fail(e, 'Could not save.'); }
            }}>Add</button>
          </div>
        )}
        {canEdit && members.length > 0 && (
          <div className="flex gap-2 mt-3">
            <select className={inputCls} value={gift.productId} onChange={(e) => setGift({ ...gift, productId: e.target.value })}>
              <option value="">Comp a membership…</option>
              {members.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select>
            <input className={inputCls} placeholder="Their email" value={gift.email} onChange={(e) => setGift({ ...gift, email: e.target.value })} />
            <button className="bg-brand-primary text-black rounded-2xl px-4 text-xs font-black" disabled={!gift.productId || !gift.email} onClick={async () => {
              try { await giftMembership(gift.productId, gift.email); toast({ kind: 'success', message: 'Gift sent.' }); setGift({ productId: '', email: '' }); }
              catch (e) { fail(e, 'Could not send the gift.'); }
            }}>Send</button>
          </div>
        )}
      </div>

      <div>
        <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2 flex items-center gap-2"><Ticket className="w-4 h-4" /> Season passes &amp; flex packs</h2>
        {passes.map((x) => (
          <div key={x.id} className="flex justify-between text-sm">
            <span className="font-bold">{x.name}{x.active === false ? ' (off)' : ''}</span>
            <span className="text-slate-500">{x.kind} · {formatCurrency(x.price_cents / 100, x.currency)} · sold {x.sold ?? 0}{x.max_sold ? ` / ${x.max_sold}` : ''}
              {canEdit && <button className="ml-2 underline" onClick={async () => { await savePassProduct({ ...x, active: !x.active }); load(); }}>{x.active ? 'Turn off' : 'Turn on'}</button>}
            </span>
          </div>
        ))}
        {canEdit && (
          <div className="grid grid-cols-3 gap-2 mt-3">
            <label className="col-span-3"><span className={labelCls}>Name</span><input className={inputCls} value={p.name} onChange={(e) => setP({ ...p, name: e.target.value })} /></label>
            <label><span className={labelCls}>Price</span><input className={inputCls} inputMode="decimal" value={p.price} onChange={(e) => setP({ ...p, price: e.target.value })} /></label>
            <label><span className={labelCls}>Kind</span>
              <select className={inputCls} value={p.kind} onChange={(e) => setP({ ...p, kind: e.target.value as typeof p.kind })}>
                <option value="flex">Flex pack</option><option value="season">Season (date range)</option>
              </select></label>
            {p.kind === 'flex'
              ? <label><span className={labelCls}>Admissions</span><input className={inputCls} inputMode="numeric" value={p.credits} onChange={(e) => setP({ ...p, credits: e.target.value })} /></label>
              : <><label><span className={labelCls}>From</span><input type="date" className={inputCls} value={p.from} onChange={(e) => setP({ ...p, from: e.target.value })} /></label>
                  <label><span className={labelCls}>To</span><input type="date" className={inputCls} value={p.to} onChange={(e) => setP({ ...p, to: e.target.value })} /></label></>}
            <button className="bg-slate-900 text-white rounded-2xl text-xs font-black uppercase" disabled={!p.name || !majorToCents(p.price)} onClick={async () => {
              try {
                await savePassProduct({ org_id: orgId, name: p.name, kind: p.kind, price_cents: majorToCents(p.price) ?? 0,
                  credits: Number(p.credits) || 1, date_from: p.from ? new Date(p.from).toISOString() : null,
                  date_to: p.to ? new Date(p.to).toISOString() : null, per_event_limit: p.kind === 'season' ? 1 : null });
                setP({ ...p, name: '' }); load();
              } catch (e) { fail(e, 'Could not save.'); }
            }}>Add</button>
          </div>
        )}
      </div>

      {canScan && (
        <div>
          <h3 className={`${labelCls} mb-2`}>Look up a membership card</h3>
          <div className="flex gap-2">
            <input className={inputCls} placeholder="Scanned code" value={card} onChange={(e) => setCard(e.target.value)} />
            <button className="border rounded-2xl px-4 text-xs font-black" onClick={async () => {
              const id = card.trim().replace(/^exos-member:/, '');
              try { setScan(await scanMembershipCard(orgId, id)); } catch (e) { fail(e, 'Lookup failed.'); }
            }}>Look up</button>
          </div>
          {scan && <p className="text-sm mt-2">{scan.valid ? '✓ Member' : '✗ Not valid'} · {String(scan.product_name ?? scan.reason ?? '')}
            {scan.member_first_name ? ` · ${String(scan.member_first_name)}` : ''} · {String(scan.status ?? '')}</p>}
        </div>
      )}
    </div>
  );
}
