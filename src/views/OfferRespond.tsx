// /offer/:offerId?t=<token> — the agent's page (no account): the show, the
// terms and the conditions, with Accept / Decline and the PDF
// (docs/offers-settlements.md). The 64-hex token is the credential; a sent
// offer can be answered once, after that the page shows the outcome.

import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Download } from 'lucide-react';
import { downloadBytes, getPublicOffer, respondToOffer, type PublicOffer } from '../lib/offersApi';
import { describeDeal, formatCents, offerPdf } from '../lib/dealMath';
import { BTN, BTN_PRIMARY, FLD, LABEL, Row, Section, StatusBadge } from '../components/finance/ui';

export default function OfferRespond() {
  const { offerId } = useParams();
  const [sp] = useSearchParams();
  const token = sp.get('t') ?? '';
  const [offer, setOffer] = useState<PublicOffer | null | undefined>(undefined);
  const [name, setName] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!offerId) return;
    getPublicOffer(offerId, token).then(setOffer).catch(() => setOffer(null));
  }, [offerId, token]);

  if (offer === undefined) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (offer === null) return <div className="max-w-xl mx-auto p-8 text-sm text-slate-600">This offer link isn't valid any more. Ask the promoter to send it again.</div>;

  const cur = offer.currency;
  const t = offer.terms ?? {};
  const answer = async (action: 'accept' | 'decline') => {
    if (!name.trim()) { setError('Please type your name.'); return; }
    if (!window.confirm(action === 'accept' ? 'Accept this offer?' : 'Decline this offer?')) return;
    setBusy(true); setError('');
    try {
      setOffer(await respondToOffer(offer.id, token, action, name.trim(), note.trim()));
    } catch (e) {
      setError((e as Error).message.replace(/^exos_[a-z_]+:\s*/, ''));
    } finally {
      setBusy(false);
    }
  };
  const pdf = () => downloadBytes(offerPdf({ ...offer, org: offer.org, venue: offer.venue, response: offer.response }), `offer-${offer.artist_name}.pdf`, 'application/pdf');

  return (
    <div className="max-w-2xl mx-auto px-4 py-10">
      <p className="text-xs text-slate-500 mb-1">{offer.org?.name}</p>
      <div className="flex items-center gap-3 mb-6">
        <h1 className="text-2xl font-black text-slate-900">Offer: {offer.artist_name}</h1>
        <StatusBadge status={offer.status} />
      </div>
      <Section title="Show" action={<button className={BTN} onClick={pdf}><Download size={12} className="inline mr-1" />PDF</button>}>
        <Row label="Show">{offer.title}</Row>
        <Row label="Dates">{offer.dates.length ? offer.dates.join(', ') : 'To be confirmed'}</Row>
        {offer.venue && <Row label="Venue">{offer.venue.name}{offer.venue.room ? ` — ${offer.venue.room}` : ''}</Row>}
        {offer.budget && offer.budget.capacity > 0 && <Row label="Capacity">{offer.budget.capacity}</Row>}
        {offer.budget && offer.budget.average_price_cents > 0 && <Row label="Average ticket price">{formatCents(offer.budget.average_price_cents, cur)}</Row>}
      </Section>
      <Section title="Terms">
        <Row label="Deal">{describeDeal(t, cur)}</Row>
        {t.expenses_cap_cents !== null && t.expenses_cap_cents !== undefined && <Row label="Expenses cap">{formatCents(t.expenses_cap_cents, cur)}</Row>}
        {(t.bonuses ?? []).map((b, i) => <Row key={i} label="Bonus">{formatCents(b.amount_cents, cur)} at {b.sold} tickets</Row>)}
        {t.merch_artist_percent !== null && t.merch_artist_percent !== undefined && <Row label="Merchandise">{t.merch_artist_percent}% to the artist</Row>}
        {!!t.deposit_cents && <Row label="Deposit">{formatCents(t.deposit_cents, cur)}{t.deposit_due_on ? `, due ${t.deposit_due_on}` : ''}</Row>}
        {t.hospitality && <Row label="Hospitality">{t.hospitality}</Row>}
        {t.rider && <Row label="Rider">{t.rider}</Row>}
      </Section>
      {offer.boilerplate && <Section title="Conditions"><p className="text-sm whitespace-pre-wrap text-slate-700">{offer.boilerplate}</p></Section>}

      {offer.status === 'sent' ? (
        <Section title="Your answer">
          <label className="block mb-3"><span className={LABEL}>Your name</span><input className={FLD} value={name} maxLength={100} onChange={(e) => setName(e.target.value)} /></label>
          <label className="block mb-3"><span className={LABEL}>Note (optional)</span><textarea className={FLD} rows={3} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} /></label>
          {error && <p className="text-sm text-red-600 mb-3" role="alert">{error}</p>}
          <div className="flex gap-2">
            <button className={BTN_PRIMARY} disabled={busy} onClick={() => answer('accept')}>Accept</button>
            <button className={BTN} disabled={busy} onClick={() => answer('decline')}>Decline</button>
          </div>
          {offer.expires_at && <p className="text-xs text-slate-400 mt-3">Open until {new Date(offer.expires_at).toLocaleString()}.</p>}
        </Section>
      ) : (
        <p className="text-sm text-slate-600">
          {offer.response ? `${offer.response.action === 'accept' ? 'Accepted' : 'Declined'}${offer.response.name ? ` by ${offer.response.name}` : ''} on ${new Date(offer.response.at).toLocaleString()}.` : `This offer is ${offer.status}.`}
        </p>
      )}
    </div>
  );
}
