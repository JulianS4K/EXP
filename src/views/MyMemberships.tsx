// /me/memberships — my memberships (held or shared), passes and gift cards
// (docs/memberships.md, docs/gift-cards.md). Billing (renew, cancel, change
// card) happens in Stripe's customer portal; the household is managed here.
// The membership card's QR is the membership id: door staff look it up with
// exos_membership_scan (it is not an entry code).

import { useCallback, useEffect, useState } from 'react';
import { BadgeCheck, Gift, Ticket } from 'lucide-react';
import { QRCodeSVG } from 'qrcode.react';
import {
  myGiftCards, myMemberships, myPasses, openBillingPortal, passLeftLabel, setHousehold, type MyMembership, type MyPass,
} from '../lib/commerce';
import { useAuth } from '../context/AuthContext';
import { formatCurrency, publicUrl } from '../lib/utils';

export default function MyMemberships() {
  const { user } = useAuth();
  const [members, setMembers] = useState<MyMembership[]>([]);
  const [passes, setPasses] = useState<MyPass[]>([]);
  const [cards, setCards] = useState<Awaited<ReturnType<typeof myGiftCards>>>([]);
  const [email, setEmail] = useState<Record<string, string>>({});
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user) return;
    try {
      const [m, p, c] = await Promise.all([myMemberships(), myPasses(), myGiftCards()]);
      setMembers(m); setPasses(p); setCards(c);
    } catch (x: any) { setErr(x?.message || 'Could not load.'); }
  }, [user]);
  useEffect(() => { load(); }, [load]);

  if (!user) return <div className="p-16 text-center">Sign in to see your memberships and passes.</div>;

  const household = async (m: MyMembership, add: boolean, addr: string) => {
    setErr(null);
    try { await setHousehold(m.id, addr, add); setEmail({ ...email, [m.id]: '' }); load(); }
    catch (x: any) { setErr(x?.message || 'Could not update the household.'); }
  };

  return (
    <div className="max-w-3xl mx-auto px-4 py-12 space-y-10">
      {err && <p role="alert" className="text-red-600">{err}</p>}
      <section>
        <h1 className="text-2xl font-black mb-4 flex items-center gap-2"><BadgeCheck className="w-6 h-6" /> Memberships</h1>
        {members.length === 0 && <p className="text-sm">No memberships yet.</p>}
        <div className="space-y-4">
          {members.map((m) => (
            <div key={m.id} className="border p-4 flex gap-4">
              <QRCodeSVG value={`exos-member:${m.id}`} size={96} aria-label="Membership card code" />
              <div className="flex-1 space-y-1 text-sm">
                <p className="font-black text-base">{m.org_name} · {m.product_name}{m.shared ? ' (shared with you)' : ''}</p>
                <p>Status: {m.status}{m.current_period_end ? ` · ${m.cancel_at_period_end || m.billing === 'once' ? 'ends' : 'renews'} ${m.current_period_end.slice(0, 10)}` : ''}</p>
                {Number(m.benefits.discount_percent) > 0 && <p>{Number(m.benefits.discount_percent)}% off tickets</p>}
                {Number(m.benefits.free_tickets_per_period) > 0 && (
                  <p>Free tickets this period: {Math.max(0, Number(m.benefits.free_tickets_per_period) - m.free_used_this_period)} left (use them on the event page)</p>
                )}
                {m.can_manage_billing && (
                  <button className="underline" onClick={async () => {
                    try { window.location.href = await openBillingPortal(m.id, publicUrl('me/memberships')); }
                    catch (x: any) { setErr(x?.message || 'Could not open billing.'); }
                  }}>Manage billing</button>
                )}
                {!m.shared && Number(m.benefits.household_seats) > 0 && (
                  <div className="pt-2">
                    <p className="font-bold">Household ({(m.household ?? []).length} / {Number(m.benefits.household_seats)})</p>
                    {(m.household ?? []).map((h) => (
                      <p key={h}>{h} <button className="underline text-red-600" onClick={() => household(m, false, h)}>Remove</button></p>
                    ))}
                    {(m.household ?? []).length < Number(m.benefits.household_seats) && (
                      <div className="flex gap-2 mt-1">
                        <input className="border px-2 py-1 flex-1" type="email" placeholder="Their email" value={email[m.id] ?? ''}
                          onChange={(e) => setEmail({ ...email, [m.id]: e.target.value })} />
                        <button className="border px-3" onClick={() => household(m, true, email[m.id] ?? '')}>Add</button>
                      </div>
                    )}
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      </section>
      <section>
        <h2 className="text-xl font-black mb-3 flex items-center gap-2"><Ticket className="w-5 h-5" /> Passes</h2>
        {passes.length === 0 && <p className="text-sm">No passes yet.</p>}
        {passes.map((p) => (
          <div key={p.id} className="border p-3 mb-2 text-sm">
            <p className="font-black">{p.org_name} · {p.name}</p>
            <p>{p.status === 'active' ? passLeftLabel(p) : 'voided'}{p.valid_until ? ` · valid until ${p.valid_until.slice(0, 10)}` : ''}</p>
            <p className="text-xs text-slate-500">Use it from an event page: "Use my pass".</p>
          </div>
        ))}
      </section>
      <section>
        <h2 className="text-xl font-black mb-3 flex items-center gap-2"><Gift className="w-5 h-5" /> Gift cards</h2>
        {cards.length === 0 && <p className="text-sm">No gift cards.</p>}
        {cards.map((c) => (
          <p key={c.id} className="text-sm">{c.org_name} · ending {c.last4} · {formatCurrency(c.balance_cents / 100, c.currency)}
            {c.status === 'voided' ? ' (voided)' : ''}{c.sent_to_me ? '' : ' (bought by you)'}</p>
        ))}
      </section>
    </div>
  );
}
