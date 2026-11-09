// /shop/:orgSlug — what an organizer sells besides tickets: gift cards (and,
// with mig 20261030130500, season passes, flex packs and memberships). Every
// purchase hands off to Stripe-hosted Checkout through exos-commerce; no card
// field or extra script on this page (docs/pci.md).

import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Gift } from 'lucide-react';
import { buyGiftCard, majorToCents, publicGiftCardProducts, type GiftCardProduct } from '../lib/commerce';
import { useAuth } from '../context/AuthContext';
import { formatCurrency, publicUrl } from '../lib/utils';
import ShopPassesMemberships from '../components/ShopPassesMemberships';

function GiftCardForm({ p, orgSlug, signedIn }: { p: GiftCardProduct; orgSlug: string; signedIn: boolean }) {
  const [amount, setAmount] = useState<number | null>(p.amount_type === 'fixed' ? p.amounts_cents[0] ?? null : null);
  const [toEmail, setToEmail] = useState('');
  const [toName, setToName] = useState('');
  const [message, setMessage] = useState('');
  const [email, setEmail] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const buy = async () => {
    if (!amount) { setErr('Pick an amount.'); return; }
    setBusy(true); setErr(null);
    try {
      window.location.href = await buyGiftCard({
        productId: p.id, amountCents: amount, recipientEmail: toEmail, recipientName: toName, message,
        email: signedIn ? undefined : email, successUrl: publicUrl(`shop/${orgSlug}?bought=gift_card`), cancelUrl: publicUrl(`shop/${orgSlug}`),
      });
    } catch (x: any) { setErr(x?.message || 'Could not start checkout.'); setBusy(false); }
  };
  return (
    <div className="border p-4 space-y-2">
      {p.image_url && <img src={p.image_url} alt="" className="w-full" />}
      <h3 className="font-black flex items-center gap-2"><Gift className="w-4 h-4" /> {p.name}</h3>
      {p.description && <p className="text-sm">{p.description}</p>}
      {p.amount_type === 'fixed' ? (
        <div className="flex flex-wrap gap-2">
          {p.amounts_cents.map((a) => (
            <button key={a} type="button" onClick={() => setAmount(a)} className={`px-3 py-1 border ${amount === a ? 'border-brand-primary font-bold' : ''}`}>
              {formatCurrency(a / 100, p.currency)}
            </button>
          ))}
        </div>
      ) : (
        <input className="border px-3 py-2 w-full" inputMode="decimal"
          placeholder={`${formatCurrency((p.min_cents ?? 0) / 100, p.currency)} – ${formatCurrency((p.max_cents ?? 0) / 100, p.currency)}`}
          onChange={(e) => setAmount(majorToCents(e.target.value))} />
      )}
      <input className="border px-3 py-2 w-full" placeholder="Send to (email, optional)" value={toEmail} onChange={(e) => setToEmail(e.target.value)} />
      <input className="border px-3 py-2 w-full" placeholder="Their name" value={toName} onChange={(e) => setToName(e.target.value)} />
      <input className="border px-3 py-2 w-full" placeholder="Message" value={message} onChange={(e) => setMessage(e.target.value)} />
      {!signedIn && <input className="border px-3 py-2 w-full" type="email" placeholder="Your email (receipt)" value={email} onChange={(e) => setEmail(e.target.value)} />}
      {p.expiry_months && <p className="text-xs text-slate-500">Expires {p.expiry_months} months after purchase.</p>}
      {err && <p role="alert" className="text-red-600 text-sm">{err}</p>}
      <button disabled={busy} onClick={buy} className="bg-brand-primary text-black px-4 py-2 font-black disabled:opacity-40">Buy</button>
    </div>
  );
}

export default function Shop() {
  const { orgSlug = '' } = useParams();
  const { user } = useAuth();
  const [cards, setCards] = useState<GiftCardProduct[]>([]);
  const bought = new URLSearchParams(window.location.search).get('bought');
  useEffect(() => { publicGiftCardProducts(orgSlug).then(setCards).catch(() => setCards([])); }, [orgSlug]);
  return (
    <div className="max-w-3xl mx-auto px-4 py-12">
      <h1 className="text-3xl font-black mb-2">{cards[0]?.org_name ?? 'Shop'}</h1>
      {bought && <p role="status" className="mb-6 font-bold">Thanks! Check your email.</p>}
      <ShopPassesMemberships orgSlug={orgSlug} signedIn={!!user} />
      {cards.length > 0 && <h2 className="text-xl font-black mt-8 mb-3">Gift cards</h2>}
      <div className="grid sm:grid-cols-2 gap-4">
        {cards.map((p) => <div key={p.id}><GiftCardForm p={p} orgSlug={orgSlug} signedIn={!!user} /></div>)}
      </div>
      <p className="mt-8 text-sm"><a className="underline" href={publicUrl('gift-cards/balance')}>Check a gift card balance</a></p>
    </div>
  );
}
