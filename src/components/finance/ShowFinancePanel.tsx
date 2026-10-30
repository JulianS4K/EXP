// Event report → Settlement tab (docs/offers-settlements.md): the show's
// settlement (box office, each act's deal worked through, deposits,
// adjustments, the venue in promoter mode, finalize / reopen, PDFs), its
// finance items, its profit and loss in three columns (CSV), and the
// ticket-count emails. Owner / manager / finance; reopen and ticket counts
// owner / manager. Renders nothing for anyone else.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Download } from 'lucide-react';
import { useToast } from '../../context/ToastContext';
import {
  deleteFinanceItem, downloadBytes, finalizeSettlement, getSettlement, getTicketCounts, listCategories, reopenSettlement,
  saveFinanceItem, saveTicketCounts, sendTicketCountsNow, updateSettlement, type AdjustmentInput, type CategoryRow,
  type FinanceItemRow, type SettlementState, type TicketCountsState,
} from '../../lib/offersApi';
import { PNL_COLUMNS, settle, settlementPdf, showPnl, showPnlCsv } from '../../lib/dealMath';
import { downloadCsv } from '../../lib/csv';
import { BTN, BTN_PRIMARY, centsFromInput, FLD, inputFromCents, LABEL, Money, Row, Section, StatusBadge } from './ui';

interface Props {
  eventId: string;
  orgId: string;
  orgName: string;
  /** owner / manager / finance */
  canView: boolean;
  /** owner / manager */
  canManage: boolean;
}

export default function ShowFinancePanel({ eventId, orgId, orgName, canView, canManage }: Props) {
  const { toast } = useToast();
  const [s, setS] = useState<SettlementState | null>(null);
  const [cats, setCats] = useState<CategoryRow[]>([]);
  const [busy, setBusy] = useState(false);
  const [link, setLink] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!canView) return;
    try {
      const [st, c] = await Promise.all([getSettlement(eventId), listCategories(orgId)]);
      setS(st); setCats(c);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  }, [eventId, orgId, canView, toast]);
  useEffect(() => { load(); }, [load]);

  const view = useMemo(() => (s?.inputs ? settle(s.inputs) : null), [s]);
  const pnl = useMemo(() => (s?.inputs ? showPnl(s.inputs) : null), [s]);
  if (!canView || !s || !view || !pnl) return null;
  const finalized = s.status === 'finalized';
  const cur = view.currency;
  const r = view.result;
  const offers = s.inputs.offers ?? [];

  const run = async (fn: () => Promise<SettlementState | void>, ok?: string) => {
    setBusy(true);
    try {
      const out = await fn();
      if (out && 'inputs' in out) {
        setS(out);
        if (out.link_path) setLink(`${window.location.origin}${(import.meta as { env?: { BASE_URL?: string } }).env?.BASE_URL?.replace(/\/$/, '') ?? ''}${out.link_path}`);
      } else await load();
      if (ok) toast({ kind: 'success', message: ok });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const patch = (p: Record<string, unknown>) => run(() => updateSettlement(eventId, p, s.revision));
  const adjustments: AdjustmentInput[] = s.adjustments.map((a) => ({ id: a.id, offer_id: a.offer_id, label: a.label, amount_cents: a.amount_cents, reason: a.reason }));
  const items = (s.inputs.items ?? []) as unknown as (FinanceItemRow & { category_name: string | null; gl_code: string | null })[];
  const pdf = (contacts: boolean) => downloadBytes(settlementPdf(s.inputs, { orgName, includePromoterNet: !contacts, finalizedAt: s.finalized_at }),
    `settlement-${s.inputs.event.name}${contacts ? '-contacts' : ''}.pdf`, 'application/pdf');

  return (
    <>
      <Section title="Settlement" action={<div className="flex gap-2 items-center">
        <StatusBadge status={s.status} />
        <button className={BTN} onClick={() => pdf(false)}><Download size={12} className="inline mr-1" />PDF</button>
        <button className={BTN} onClick={() => pdf(true)}>Contacts' PDF</button>
      </div>}>
        {finalized
          ? <p className="text-xs text-slate-500 mb-3">Finalized {s.finalized_at ? new Date(s.finalized_at).toLocaleString() : ''}: these numbers are frozen{s.emailed_to.length ? `; sent to ${s.emailed_to.join(', ')}` : ''}. Reopen to go back to live numbers.</p>
          : <p className="text-xs text-slate-500 mb-3">Live: sales and items move it until you finalize. {offers.length ? '' : <>No accepted offers on this show yet — <Link className="text-tm-blue" to={`/orgs/${orgId}/offers`}>make an offer</Link>.</>}</p>}

        <p className={LABEL}>Box office</p>
        {view.boxOffice.byTier.map((t) => <Row key={t.tierId} label={`${t.tierName}: ${t.sold} sold${t.comps ? `, ${t.comps} comps` : ''}`}><Money cents={t.gross} currency={cur} /></Row>)}
        {view.boxOffice.elsewhere.map((e) => <Row key={e.currency} label={`Sold elsewhere (${e.currency}): ${e.sold}${e.included ? '' : ' — other currency, not counted'}`}><Money cents={e.gross} currency={e.currency} /></Row>)}
        {!s.inputs.sold_elsewhere?.available && <p className="text-xs text-slate-400">Sales from other platforms appear here once they're recorded.</p>}
        <Row label="Gross box office" strong><Money cents={r.grossBoxOffice} currency={cur} strong /></Row>
        {view.boxOffice.deductionLines.tax > 0 && <Row label="Tax"><Money cents={-view.boxOffice.deductionLines.tax} currency={cur} /></Row>}
        {view.boxOffice.deductionLines.passedOnFees > 0 && <Row label="Fees paid by buyers"><Money cents={-view.boxOffice.deductionLines.passedOnFees} currency={cur} /></Row>}
        {view.boxOffice.deductionLines.absorbedFees > 0 && <Row label="Fees absorbed"><Money cents={-view.boxOffice.deductionLines.absorbedFees} currency={cur} /></Row>}
        {view.boxOffice.deductionLines.platformFees > 0 && <Row label="Ticketing and card fees"><Money cents={-view.boxOffice.deductionLines.platformFees} currency={cur} /></Row>}
        <Row label="Net box office" strong><Money cents={r.netBoxOffice} currency={cur} strong /></Row>

        <p className={`${LABEL} mt-4`}>Artists</p>
        {r.slots.map((a) => (
          <div key={a.slotId} className="border border-slate-100 rounded p-3 mt-2">
            <p className="font-bold text-sm">{a.name} <span className="text-xs text-slate-400">{a.poolId ? `pool, ${a.poolSharePercent ?? 0}%` : a.dealType}</span></p>
            {!a.poolId && a.guarantee > 0 && <Row label="Guarantee"><Money cents={a.guarantee} currency={cur} /></Row>}
            {!a.poolId && a.dealType !== 'flat' && <Row label={`${a.percentage}%${a.capped ? ' (expenses capped)' : ''}; split point ${a.splitPoint === null ? '—' : (a.splitPoint / 100).toFixed(2)}`}><Money cents={a.percentageAmount} currency={cur} /></Row>}
            <Row label="Deal pays"><Money cents={a.base} currency={cur} /></Row>
            {a.bonus > 0 && <Row label="Bonuses"><Money cents={a.bonus} currency={cur} /></Row>}
            {a.merch > 0 && <Row label="Merch"><Money cents={a.merch} currency={cur} /></Row>}
            {a.adjustments !== 0 && <Row label="Adjustments"><Money cents={a.adjustments} currency={cur} /></Row>}
            <Row label="Payout" strong><Money cents={a.payout} currency={cur} strong /></Row>
            <Row label={<label className="flex items-center gap-2"><input type="checkbox" disabled={finalized || busy} checked={!!s.deposits_paid[a.slotId]}
              onChange={(e) => patch({ deposits_paid: { ...s.deposits_paid, [a.slotId]: e.target.checked } })} /> Deposit paid</label>}>
              <Money cents={-a.depositPaid} currency={cur} /></Row>
            <Row label="Balance due" strong><Money cents={a.balanceDue} currency={cur} strong /></Row>
          </div>
        ))}
        {view.excludedOffers.length > 0 && <p className="text-xs text-amber-700 mt-2">{view.excludedOffers.length} accepted offer(s) in another currency are not settled here.</p>}

        {r.venue && (<>
          <p className={`${LABEL} mt-4`}>Venue (promoter mode)</p>
          <Row label="Rental (the Venue rental items)"><Money cents={r.venue.rentalFee} currency={cur} /></Row>
          <Row label={<span className="flex items-center gap-2">Share of net box office %
            <input className={`${FLD} w-20`} disabled={finalized || busy} defaultValue={String(s.venue_share_percent)} key={`vs${s.revision}`}
              onBlur={(e) => { const v = Number(e.target.value); if (Number.isFinite(v) && v !== Number(s.venue_share_percent)) patch({ venue: { share_percent: Math.min(100, Math.max(0, v)) } }); }} /></span>}>
            <Money cents={r.venue.share} currency={cur} /></Row>
          <Row label={<span className="flex items-center gap-2">Rental deposit paid
            <input className={`${FLD} w-28`} disabled={finalized || busy} defaultValue={inputFromCents(r.venue.depositPaid)} key={`vd${s.revision}`}
              onBlur={(e) => { const c = centsFromInput(e.target.value); if (c !== null && !Number.isNaN(c) && c !== r.venue!.depositPaid) patch({ venue: { deposit_paid_cents: c } }); }} /></span>}>
            <Money cents={-r.venue.depositPaid} currency={cur} /></Row>
          <Row label="Balance due to the venue" strong><Money cents={r.venue.balanceDue} currency={cur} strong /></Row>
        </>)}

        <Adjustments adjustments={adjustments} offers={offers.map((o) => ({ id: o.id, name: o.artist_name }))} disabled={finalized || busy}
          onSave={(list) => patch({ adjustments: list })} />

        <p className={`${LABEL} mt-4`}>Result</p>
        <Row label="Expenses"><Money cents={-r.expensesTotal} currency={cur} /></Row>
        {r.otherIncome > 0 && <Row label="Other income"><Money cents={r.otherIncome} currency={cur} /></Row>}
        {r.merchIncome > 0 && <Row label="Merch income"><Money cents={r.merchIncome} currency={cur} /></Row>}
        <Row label="Artist payouts"><Money cents={-r.artistsTotal} currency={cur} /></Row>
        {r.venue && <Row label="Venue share"><Money cents={-r.venue.share} currency={cur} /></Row>}
        {r.houseAdjustments !== 0 && <Row label="House adjustments"><Money cents={r.houseAdjustments} currency={cur} /></Row>}
        <Row label="Promoter net" strong><Money cents={r.promoterNet} currency={cur} strong /></Row>

        <div className="flex gap-2 mt-4">
          {!finalized && <button className={BTN_PRIMARY} disabled={busy} onClick={() => {
            if (window.confirm('Finalize? The numbers freeze and the show\'s settlement contacts get a link.')) run(() => finalizeSettlement(eventId, s.revision), 'Finalized.');
          }}>Finalize</button>}
          {finalized && canManage && <button className={BTN} disabled={busy} onClick={() => {
            if (window.confirm('Reopen? The contacts\' link stops working.')) run(() => reopenSettlement(eventId), 'Reopened.');
          }}>Reopen</button>}
        </div>
        {link && <p className="text-xs text-slate-500 mt-2 break-all">The contacts' link: {link}</p>}
      </Section>

      <Items items={items} cats={cats} currency={cur} finalized={finalized}
        onSave={(it, id) => run(() => saveFinanceItem(orgId, eventId, it, id))}
        onDelete={(id) => run(() => deleteFinanceItem(id))} />

      <Section title="Profit and loss" action={<button className={BTN} onClick={() => downloadCsv(`profit-and-loss-${s.inputs.event.name}.csv`, showPnlCsv(pnl))}>CSV</button>}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="text-[10px] uppercase tracking-widest text-slate-400 text-right"><th className="text-left py-1" />
              {PNL_COLUMNS.map((c) => <th key={c} className="py-1">{c}</th>)}</tr></thead>
            <tbody>
              {pnl.rows.map((row) => (
                <tr key={row.key} className={`border-t border-slate-100 ${row.section === 'result' ? 'font-bold' : ''}`}>
                  <td className="py-1.5">{row.label}</td>
                  {PNL_COLUMNS.map((c) => <td key={c} className="py-1.5 text-right"><Money cents={row[c]} currency={cur} /></td>)}
                </tr>
              ))}
              <tr className="text-xs text-slate-400"><td className="py-1">Tickets</td>{PNL_COLUMNS.map((c) => <td key={c} className="text-right">{pnl.sold[c]}</td>)}</tr>
            </tbody>
          </table>
        </div>
        <p className="text-xs text-slate-400 mt-2">Forecast: the offer budget. Estimate: sales so far plus the current pace until the show. Actual: the settlement.</p>
      </Section>

      <TicketCounts eventId={eventId} canManage={canManage} />
    </>
  );
}

function Adjustments({ adjustments, offers, disabled, onSave }: {
  adjustments: AdjustmentInput[]; offers: { id: string; name: string }[]; disabled: boolean; onSave: (l: AdjustmentInput[]) => void;
}) {
  const [label, setLabel] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [who, setWho] = useState('');
  const add = () => {
    const s = amount.trim();
    const neg = s.startsWith('-');
    const c = centsFromInput(neg ? s.slice(1) : s);
    if (!label.trim() || !reason.trim() || c === null || Number.isNaN(c)) return;
    onSave([...adjustments, { offer_id: who || null, label: label.trim(), amount_cents: neg ? -c : c, reason: reason.trim() }]);
    setLabel(''); setAmount(''); setReason('');
  };
  return (
    <div className="mt-4">
      <p className={LABEL}>Adjustments</p>
      {adjustments.map((a, i) => (
        <Row key={a.id ?? i} label={`${a.label} — ${a.reason} (${a.offer_id ? offers.find((o) => o.id === a.offer_id)?.name ?? 'act' : 'house'})`}>
          <span className="flex items-center gap-2">{(a.amount_cents / 100).toFixed(2)}
            {!disabled && <button className={BTN} onClick={() => onSave(adjustments.filter((_, j) => j !== i))}>×</button>}</span>
        </Row>
      ))}
      {!disabled && (
        <div className="flex flex-wrap gap-2 items-end mt-2">
          <label><span className={LABEL}>For</span><select className={FLD} value={who} onChange={(e) => setWho(e.target.value)}>
            <option value="">House</option>{offers.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
          <label><span className={LABEL}>Label</span><input className={FLD} value={label} maxLength={120} onChange={(e) => setLabel(e.target.value)} /></label>
          <label><span className={LABEL}>Amount (− to deduct)</span><input className={FLD} value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
          <label className="flex-1 min-w-[160px]"><span className={LABEL}>Reason</span><input className={FLD} value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} /></label>
          <button className={BTN} disabled={!label.trim() || !reason.trim()} onClick={add}>Add</button>
        </div>
      )}
    </div>
  );
}

function Items({ items, cats, currency, finalized, onSave, onDelete }: {
  items: (FinanceItemRow & { category_name: string | null; gl_code: string | null })[]; cats: CategoryRow[]; currency: string; finalized: boolean;
  onSave: (it: Partial<FinanceItemRow>, id?: string) => void; onDelete: (id: string) => void;
}) {
  const [label, setLabel] = useState('');
  const [cat, setCat] = useState('');
  const [amount, setAmount] = useState('');
  const c = cats.find((x) => x.id === cat);
  return (
    <Section title="Income and expenses">
      {finalized && <p className="text-xs text-slate-500 mb-2">The finalized settlement keeps the numbers it froze; edits here show after a reopen.</p>}
      <table className="w-full text-sm">
        <thead><tr className="text-[10px] uppercase tracking-widest text-slate-400"><th className="text-left py-1">Item</th><th className="text-left">Category</th><th className="text-right">Amount</th><th className="text-right">Actual</th><th /></tr></thead>
        <tbody>
          {items.map((it) => (
            <tr key={it.id} className="border-t border-slate-100">
              <td className="py-1.5">{it.label}{it.auto ? <span className="text-xs text-slate-400"> (from the hold's rental)</span> : null}</td>
              <td className="text-xs text-slate-500">{it.category_name ?? '—'}{it.gl_code ? ` · ${it.gl_code}` : ''} · {it.kind}</td>
              <td className="text-right"><Money cents={it.amount_cents} currency={currency} /></td>
              <td className="text-right w-32"><input className={FLD} defaultValue={inputFromCents(it.actual_cents)}
                onBlur={(e) => { const v = centsFromInput(e.target.value); if (v === null ? it.actual_cents !== null : !Number.isNaN(v) && v !== it.actual_cents) onSave({ actual_cents: v }, it.id); }} /></td>
              <td className="text-right w-16"><button className={BTN} onClick={() => onDelete(it.id)}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="flex flex-wrap gap-2 items-end mt-3">
        <label className="flex-1 min-w-[160px]"><span className={LABEL}>Item</span><input className={FLD} value={label} maxLength={120} onChange={(e) => setLabel(e.target.value)} /></label>
        <label><span className={LABEL}>Category</span><select className={FLD} value={cat} onChange={(e) => setCat(e.target.value)}>
          <option value="">None (expense)</option>{cats.map((x) => <option key={x.id} value={x.id}>{x.name} ({x.kind})</option>)}</select></label>
        <label><span className={LABEL}>Amount</span><input className={FLD} value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <button className={BTN} disabled={!label.trim()} onClick={() => {
          const a = centsFromInput(amount);
          if (a === null || Number.isNaN(a)) return;
          onSave({ label: label.trim(), amount_cents: a, category_id: cat || null, kind: c?.kind === 'income' ? 'income' : 'expense' });
          setLabel(''); setAmount('');
        }}>Add</button>
      </div>
    </Section>
  );
}

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function TicketCounts({ eventId, canManage }: { eventId: string; canManage: boolean }) {
  const { toast } = useToast();
  const [tc, setTc] = useState<TicketCountsState | null>(null);
  const [email, setEmail] = useState('');
  useEffect(() => { getTicketCounts(eventId).then(setTc).catch(() => setTc(null)); }, [eventId]);
  if (!tc) return null;
  const save = async (p: Record<string, unknown>) => {
    try { setTc(await saveTicketCounts(eventId, p)); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  const recipients = tc.recipients.map((r) => ({ name: r.name, email: r.email, role: r.role }));
  return (
    <Section title="Ticket-count emails">
      <p className="text-xs text-slate-500 mb-3">Sold by ticket type, comps, gross, the last 24 hours and capacity, emailed to agents{tc.timezone ? ` (times in ${tc.timezone})` : ''}. Each email has its own opt-out link.</p>
      <div className="flex flex-wrap gap-2 items-end">
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" disabled={!canManage} checked={tc.enabled} onChange={(e) => save({ enabled: e.target.checked })} /> On</label>
        <label><span className={LABEL}>How often</span><select className={FLD} disabled={!canManage} value={tc.frequency} onChange={(e) => save({ frequency: e.target.value })}>
          <option value="daily">Daily</option><option value="weekly">Weekly</option></select></label>
        {tc.frequency === 'weekly' && <label><span className={LABEL}>On</span><select className={FLD} disabled={!canManage} value={tc.weekday} onChange={(e) => save({ weekday: Number(e.target.value) })}>
          {WEEKDAYS.map((d, i) => <option key={d} value={i}>{d}</option>)}</select></label>}
        <label><span className={LABEL}>At</span><input type="time" className={FLD} disabled={!canManage} defaultValue={tc.send_time} onBlur={(e) => e.target.value !== tc.send_time && save({ send_time: e.target.value })} /></label>
        {canManage && <button className={BTN} onClick={async () => {
          try { const r = await sendTicketCountsNow(eventId); toast({ kind: 'success', message: `Queued ${r.queued} email${r.queued === 1 ? '' : 's'}.` }); }
          catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
        }}>Send now</button>}
      </div>
      {tc.next_run_at && tc.enabled && <p className="text-xs text-slate-400 mt-2">Next: {new Date(tc.next_run_at).toLocaleString()}{tc.last_sent_at ? ` · last sent ${new Date(tc.last_sent_at).toLocaleString()} to ${tc.last_sent_count}` : ''}</p>}
      <div className="mt-3">
        {tc.recipients.map((r) => (
          <Row key={r.id} label={`${r.name ? `${r.name} · ` : ''}${r.email} (${r.role})${r.opted_out_at ? ' — opted out' : ''}`}>
            {canManage && <button className={BTN} onClick={() => save({ recipients: recipients.filter((x) => x.email !== r.email) })}>Remove</button>}
          </Row>
        ))}
        {canManage && (
          <div className="flex gap-2 items-end mt-2">
            <label className="flex-1"><span className={LABEL}>Add a recipient</span><input className={FLD} value={email} onChange={(e) => setEmail(e.target.value)} placeholder="agent@agency.com" /></label>
            <button className={BTN} disabled={!email.includes('@')} onClick={() => { save({ recipients: [...recipients, { email: email.trim(), role: 'agent' }] }); setEmail(''); }}>Add</button>
            {tc.suggested.filter((x) => !tc.recipients.some((r) => r.email === x.email)).map((x) => (
              <button key={x.email} className={BTN} onClick={() => save({ recipients: [...recipients, x] })}>Add {x.name}</button>
            ))}
          </div>
        )}
      </div>
    </Section>
  );
}
