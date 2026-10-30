// Season passes, flex packs and memberships on /shop/:orgSlug (mig
// 20261030130500, docs/memberships.md). Buying hands off to Stripe-hosted
// Checkout through exos-commerce (no card field here, docs/pci.md).

import { useEffect, useState } from 'react';
import { BadgeCheck, Ticket } from 'lucide-react';
import {
  buyMembership, buyPass, publicMembershipProducts, publicPassProducts, type MembershipProduct, type PassProduct,
} from '../lib/commerce';
import { formatCurrency, publicUrl } from '../lib/utils';

const per = { month: '/ month', year: '/ year', once: '' } as const;

export default function ShopPassesMemberships({ orgSlug, signedIn }: { orgSlug: string; signedIn: boolean }) {
  const [passes, setPasses] = useState<PassProduct[]>([]);
  const [members, setMembers] = useState<MembershipProduct[]>([]);
  const [email, setEmail] = useState('');
  const [giftTo, setGiftTo] = useState<Record<string, string>>({});
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    publicPassProducts(orgSlug).then(setPasses).catch(() => setPasses([]));
    publicMembershipProducts(orgSlug).then(setMembers).catch(() => setMembers([]));
  }, [orgSlug]);

  const back = publicUrl(`shop/${orgSlug}`);
  const go = async (fn: () => Promise<string>) => {
    setErr(null);
    try { window.location.href = await fn(); } catch (x: any) { setErr(x?.message || 'Could not start checkout.'); }
  };

  if (passes.length === 0 && members.length === 0) return null;
  return (
    <div className="space-y-8">
      {err && <p role="alert" className="text-red-600">{err}</p>}
      {members.length > 0 && (
        <section>
          <h2 className="text-xl font-black mb-3 flex items-center gap-2"><BadgeCheck className="w-5 h-5" /> Memberships</h2>
          <div className="grid sm:grid-cols-2 gap-4">
            {members.map((m) => (
              <div key={m.id} className="border p-4 space-y-2">
                <h3 className="font-black">{m.name}</h3>
                <p className="text-2xl font-black">{formatCurrency(m.price_cents / 100, m.currency)} <span className="text-sm">{per[m.billing]}</span></p>
                {m.billing === 'once' && <p className="text-xs">{m.duration_days} days</p>}
                <ul className="text-sm list-disc pl-5">
                  {m.discount_percent > 0 && <li>{Number(m.discount_percent)}% off tickets</li>}
                  {m.presale && <li>Member presales</li>}
                  {m.free_tickets_per_period > 0 && <li>{m.free_tickets_per_period} free ticket{m.free_tickets_per_period > 1 ? 's' : ''} each period</li>}
                  {m.guest_allowance > 0 && <li>Bring {m.guest_allowance} guest{m.guest_allowance > 1 ? 's' : ''} at the member price</li>}
                  {m.household_seats > 0 && <li>Share with {m.household_seats} household member{m.household_seats > 1 ? 's' : ''}</li>}
                </ul>
                {m.description && <p className="text-sm">{m.description}</p>}
                {signedIn ? (
                  <>
                    <button className="bg-brand-primary text-black px-4 py-2 font-black" onClick={() => go(() => buyMembership({
                      productId: m.id, successUrl: publicUrl('me/memberships?bought=1'), cancelUrl: back }))}>Join</button>
                    {m.giftable && (
                      <div className="flex gap-2">
                        <input className="border px-2 py-1 flex-1" placeholder="Gift to (email)" value={giftTo[m.id] ?? ''}
                          onChange={(e) => setGiftTo({ ...giftTo, [m.id]: e.target.value })} />
                        <button className="border px-3" disabled={!giftTo[m.id]} onClick={() => go(() => buyMembership({
                          productId: m.id, giftToEmail: giftTo[m.id], successUrl: publicUrl(`shop/${orgSlug}?bought=gift`), cancelUrl: back }))}>Give</button>
                      </div>
                    )}
                  </>
                ) : <p className="text-sm">Sign in to join.</p>}
              </div>
            ))}
          </div>
        </section>
      )}
      {passes.length > 0 && (
        <section>
          <h2 className="text-xl font-black mb-3 flex items-center gap-2"><Ticket className="w-5 h-5" /> Passes</h2>
          {!signedIn && <input className="border px-3 py-2 mb-3 w-full" type="email" placeholder="Your email" value={email} onChange={(e) => setEmail(e.target.value)} />}
          <div className="grid sm:grid-cols-2 gap-4">
            {passes.map((p) => (
              <div key={p.id} className="border p-4 space-y-2">
                <h3 className="font-black">{p.kind === 'flex' ? 'Flex pack' : 'Season pass'}: {p.name}</h3>
                <p className="text-2xl font-black">{formatCurrency(p.price_cents / 100, p.currency)}</p>
                <p className="text-sm">
                  {p.kind === 'flex' ? `${p.credits} admissions to use on any eligible show`
                    : p.event_ids.length > 0 ? `One admission to each of ${p.event_ids.length} shows`
                      : 'One admission to every show in the season'}
                  {p.valid_until ? `, until ${p.valid_until.slice(0, 10)}` : ''}
                </p>
                {p.description && <p className="text-sm">{p.description}</p>}
                <button disabled={p.sold_out} className="bg-brand-primary text-black px-4 py-2 font-black disabled:opacity-40"
                  onClick={() => go(() => buyPass({ productId: p.id, email: signedIn ? undefined : email,
                    successUrl: publicUrl('me/memberships?bought=pass'), cancelUrl: back }))}>
                  {p.sold_out ? 'Sold out' : 'Buy'}
                </button>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
