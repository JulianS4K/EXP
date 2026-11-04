// /give/:orgSlug/:campaignSlug — a giving campaign's public page
// (docs/giving.md). Hands off to Stripe-hosted Checkout (no card field here).

import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { HeartHandshake } from 'lucide-react';
import { campaignProgress, coverFeesCents, donate, majorToCents, publicCampaign, type GivingCampaign } from '../lib/commerce';
import { useAuth } from '../context/AuthContext';
import { formatCurrency, publicUrl } from '../lib/utils';

export default function Give() {
  const { orgSlug = '', campaignSlug = '' } = useParams();
  const { user } = useAuth();
  const [c, setC] = useState<GivingCampaign | null | undefined>(undefined);
  const [amount, setAmount] = useState<number | null>(null);
  const [custom, setCustom] = useState('');
  const [cover, setCover] = useState(true);
  const [anon, setAnon] = useState(false);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const thanks = new URLSearchParams(window.location.search).get('thanks') === '1';

  useEffect(() => { publicCampaign(orgSlug, campaignSlug).then(setC).catch(() => setC(null)); }, [orgSlug, campaignSlug]);

  if (c === undefined) return <div className="p-16 text-center">Loading…</div>;
  if (c === null) return <div className="p-16 text-center">This campaign isn't taking donations.</div>;

  const fee = cover && c.cover_fees && amount ? coverFeesCents(amount, c.cover_fees_bps) : 0;
  const go = async () => {
    if (!amount || amount < 100) { setErr('Pick an amount.'); return; }
    setBusy(true); setErr(null);
    try {
      window.location.href = await donate({
        campaignId: c.id, amountCents: amount, coverFees: cover && c.cover_fees, anonymous: anon, donorName: name,
        email: user ? undefined : email, successUrl: publicUrl(`give/${orgSlug}/${campaignSlug}?thanks=1`),
        cancelUrl: publicUrl(`give/${orgSlug}/${campaignSlug}`),
      });
    } catch (x: any) { setErr(x?.message || 'Could not start checkout.'); setBusy(false); }
  };

  return (
    <div className="max-w-xl mx-auto px-4 py-12">
      {c.image_url && <img src={c.image_url} alt="" className="w-full mb-6" />}
      <p className="text-sm text-slate-500">{c.org_name}</p>
      <h1 className="text-3xl font-black mb-3 flex items-center gap-2"><HeartHandshake className="w-7 h-7" /> {c.name}</h1>
      {c.description && <p className="mb-6 whitespace-pre-line">{c.description}</p>}
      {c.goal_cents > 0 && (
        <div className="mb-6">
          <div className="h-3 bg-slate-200"><div className="h-3 bg-brand-primary" style={{ width: `${campaignProgress(c.raised_cents ?? 0, c.goal_cents) * 100}%` }} /></div>
          <p className="text-sm mt-1">{formatCurrency((c.raised_cents ?? 0) / 100, c.currency)} of {formatCurrency(c.goal_cents / 100, c.currency)} · {c.donation_count} gifts</p>
        </div>
      )}
      {thanks && <p className="mb-6 font-bold" role="status">Thank you! Your receipt is on its way.</p>}
      {!c.open ? <p>Donations open {c.starts_at?.slice(0, 10)}.</p> : (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            {c.suggested_cents.map((s) => (
              <button key={s} type="button" onClick={() => { setAmount(s); setCustom(''); }}
                className={`px-4 py-2 border ${amount === s && !custom ? 'border-brand-primary font-bold' : ''}`}>{formatCurrency(s / 100, c.currency)}</button>
            ))}
            <input aria-label="Other amount" inputMode="decimal" placeholder="Other" value={custom}
              onChange={(e) => { setCustom(e.target.value); setAmount(majorToCents(e.target.value)); }} className="border px-3 py-2 w-28" />
          </div>
          {c.cover_fees && (
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={cover} onChange={(e) => setCover(e.target.checked)} />
              Cover the card fees{fee > 0 ? ` (${formatCurrency(fee / 100, c.currency)})` : ''}</label>
          )}
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={anon} onChange={(e) => setAnon(e.target.checked)} /> Give anonymously</label>
          <input className="border px-3 py-2 w-full" placeholder="Your name (for the receipt)" value={name} onChange={(e) => setName(e.target.value)} />
          {!user && <input className="border px-3 py-2 w-full" type="email" placeholder="Email (for the receipt)" value={email} onChange={(e) => setEmail(e.target.value)} />}
          {err && <p role="alert" className="text-red-600">{err}</p>}
          <button disabled={busy} onClick={go} className="bg-brand-primary text-black px-6 py-3 font-black disabled:opacity-40">
            Give {amount ? formatCurrency((amount + fee) / 100, c.currency) : ''}
          </button>
        </div>
      )}
    </div>
  );
}
