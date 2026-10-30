// /settlement/:eventId?t=<token> — the show's settlement for its settlement
// contacts (tour accountant, the venue): frozen at finalize, without the
// promoter's net, with a PDF (docs/offers-settlements.md). No account; the
// 64-hex token is the credential and stops working on reopen.

import { useEffect, useMemo, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Download } from 'lucide-react';
import { downloadBytes, getPublicSettlement } from '../lib/offersApi';
import { settle, settlementPdf, type SettlementInputs } from '../lib/dealMath';
import { BTN, Money, Row, Section } from '../components/finance/ui';

export default function SettlementPublic() {
  const { eventId } = useParams();
  const [sp] = useSearchParams();
  const token = sp.get('t') ?? '';
  const [data, setData] = useState<{ org: { name: string } | null; finalized_at: string; inputs: SettlementInputs } | null | undefined>(undefined);
  useEffect(() => {
    if (!eventId) return;
    getPublicSettlement(eventId, token).then(setData).catch(() => setData(null));
  }, [eventId, token]);
  const view = useMemo(() => (data ? settle(data.inputs) : null), [data]);
  if (data === undefined) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!data || !view) return <div className="max-w-xl mx-auto p-8 text-sm text-slate-600">This settlement link isn't valid any more. Ask the promoter for a new one.</div>;
  const r = view.result;
  const cur = view.currency;
  const pdf = () => downloadBytes(settlementPdf(data.inputs, { orgName: data.org?.name, includePromoterNet: false, finalizedAt: data.finalized_at }),
    `settlement-${data.inputs.event.name}.pdf`, 'application/pdf');
  return (
    <div className="max-w-2xl mx-auto px-4 py-10">
      <p className="text-xs text-slate-500 mb-1">{data.org?.name}</p>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Settlement: {data.inputs.event.name}</h1>
      <p className="text-sm text-slate-500 mb-6">{data.inputs.event.starts_at ? new Date(data.inputs.event.starts_at).toLocaleString() : ''} · finalized {new Date(data.finalized_at).toLocaleString()}</p>
      <Section title="Box office" action={<button className={BTN} onClick={pdf}><Download size={12} className="inline mr-1" />PDF</button>}>
        {view.boxOffice.byTier.map((t) => <Row key={t.tierId} label={`${t.tierName}: ${t.sold} sold${t.comps ? `, ${t.comps} comps` : ''}`}><Money cents={t.gross} currency={cur} /></Row>)}
        {view.boxOffice.elsewhere.filter((e) => e.included).map((e) => <Row key={e.currency} label={`Sold elsewhere: ${e.sold}`}><Money cents={e.gross} currency={cur} /></Row>)}
        <Row label="Gross" strong><Money cents={r.grossBoxOffice} currency={cur} strong /></Row>
        <Row label="Taxes and fees"><Money cents={-r.deductions} currency={cur} /></Row>
        <Row label="Net box office" strong><Money cents={r.netBoxOffice} currency={cur} strong /></Row>
        <Row label="Expenses"><Money cents={-r.expensesTotal} currency={cur} /></Row>
      </Section>
      <Section title="Artists">
        {r.slots.map((a) => (
          <div key={a.slotId} className="mb-3">
            <p className="font-bold text-sm">{a.name}</p>
            <Row label="Deal pays"><Money cents={a.base} currency={cur} /></Row>
            {a.bonus > 0 && <Row label="Bonuses"><Money cents={a.bonus} currency={cur} /></Row>}
            {a.merch > 0 && <Row label="Merch"><Money cents={a.merch} currency={cur} /></Row>}
            {a.adjustments !== 0 && <Row label="Adjustments"><Money cents={a.adjustments} currency={cur} /></Row>}
            <Row label="Payout" strong><Money cents={a.payout} currency={cur} strong /></Row>
            {a.depositPaid > 0 && <Row label="Deposit paid"><Money cents={-a.depositPaid} currency={cur} /></Row>}
            <Row label="Balance due" strong><Money cents={a.balanceDue} currency={cur} strong /></Row>
          </div>
        ))}
      </Section>
      {r.venue && (
        <Section title="Venue">
          <Row label="Rental"><Money cents={r.venue.rentalFee} currency={cur} /></Row>
          {r.venue.sharePercent > 0 && <Row label={`${r.venue.sharePercent}% of net box office`}><Money cents={r.venue.share} currency={cur} /></Row>}
          {r.venue.depositPaid > 0 && <Row label="Rental deposit paid"><Money cents={-r.venue.depositPaid} currency={cur} /></Row>}
          <Row label="Balance due to the venue" strong><Money cents={r.venue.balanceDue} currency={cur} strong /></Row>
        </Section>
      )}
    </div>
  );
}
