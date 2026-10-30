// /orgs/:orgId/offers/:offerId — one offer: terms, agent, the budget it
// shares with its lineup, the pool, a live projection (break-even and the
// acts' payouts at the forecast), send / record an answer / cancel, the PDF
// and the history (docs/offers-settlements.md). Owners and managers edit;
// finance reads.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Copy, Download } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import {
  addBudgetLine, cancelOffer, deleteBudgetLine, deleteOffer, downloadBytes, effectiveStatus, getBudget, getOffer, getPool,
  listBudgetLines, listCategories, listOffersForBudget, recordOfferResponse, savePool, sendOffer, updateBudget, updateBudgetLine,
  updateOffer, type BudgetLineRow, type BudgetRow, type CategoryRow, type OfferRow, type PoolRow,
} from '../lib/offersApi';
import {
  formatCents, offerPdf, poolTermsFromJson, projectBudget, termsFromJson, type TermsJson,
} from '../lib/dealMath';
import TermsEditor from '../components/finance/TermsEditor';
import { BTN, BTN_PRIMARY, centsFromInput, FLD, inputFromCents, LABEL, Money, Row, Section, StatusBadge } from '../components/finance/ui';

export default function OfferEditor() {
  const { orgId, offerId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [offer, setOffer] = useState<OfferRow | null>(null);
  const [draft, setDraft] = useState<Partial<OfferRow>>({});
  const [budget, setBudget] = useState<BudgetRow | null>(null);
  const [lines, setLines] = useState<BudgetLineRow[]>([]);
  const [lineup, setLineup] = useState<OfferRow[]>([]);
  const [pool, setPool] = useState<PoolRow | null>(null);
  const [cats, setCats] = useState<CategoryRow[]>([]);
  const [link, setLink] = useState<string | null>(null);
  const [sendTo, setSendTo] = useState('');
  const [busy, setBusy] = useState(false);
  const [loadKey, setLoadKey] = useState(0);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const effectiveRole = isAdmin ? 'owner' : role;
  const canEdit = effectiveRole === 'owner' || effectiveRole === 'manager';

  const load = useCallback(async () => {
    if (!offerId || !orgId) return;
    try {
      const o = await getOffer(offerId);
      setOffer(o);
      setDraft({});
      if (!o) return;
      const [b, ls, lu, p, c] = await Promise.all([
        getBudget(o.budget_id), listBudgetLines(o.budget_id), listOffersForBudget(o.budget_id), getPool(o.budget_id), listCategories(orgId),
      ]);
      setBudget(b); setLines(ls); setLineup(lu); setPool(p); setCats(c);
      setLoadKey((k) => k + 1);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  }, [offerId, orgId, toast]);
  useEffect(() => { load(); }, [load]);

  const merged = offer ? { ...offer, ...draft } as OfferRow : null;
  const status = offer ? effectiveStatus(offer) : 'draft';
  const editable = canEdit && (status === 'draft' || status === 'sent');
  const catKey = useMemo(() => new Map(cats.map((c) => [c.id, c.key])), [cats]);

  // Projection at the budget's forecast, with the lineup's terms (this offer's unsaved edits included).
  const projection = useMemo(() => {
    if (!budget || !merged) return null;
    const acts = lineup.filter((o) => ['draft', 'sent', 'accepted'].includes(effectiveStatus(o))).map((o) => (o.id === merged.id ? merged : o));
    const poolOn = pool?.mode === 'pool';
    return projectBudget({
      capacity: budget.capacity, averagePrice: budget.average_price_cents, sellThroughPercent: budget.sell_through_percent,
      expenses: lines.filter((l) => l.kind === 'expense').map((l) => ({ amount: l.amount_cents, talent: catKey.get(l.category_id ?? '') === 'talent' })),
      income: lines.filter((l) => l.kind === 'income').map((l) => ({ amount: l.amount_cents, merch: catKey.get(l.category_id ?? '') === 'merch-income' })),
      slots: acts.map((o) => ({ slotId: o.id, name: o.artist_name, terms: termsFromJson(o.terms), poolId: poolOn ? budget.id : null, poolShare: o.pool_share_percent })),
      pools: poolOn && pool ? [{ poolId: budget.id, terms: poolTermsFromJson(pool.terms) }] : [],
    });
  }, [budget, lines, lineup, merged, pool, catKey]);

  if (!offer || !merged) return <div className="p-8 text-sm text-slate-500">{offer === null ? 'Offer not found.' : 'Loading…'}</div>;
  const cur = offer.currency;

  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast({ kind: 'success', message: ok });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const save = () => act(() => updateOffer(offer.id, draft), 'Saved.');
  const send = () => act(async () => {
    if (Object.keys(draft).length) await updateOffer(offer.id, draft);
    const r = await sendOffer(offer.id, sendTo);
    setLink(`${window.location.origin}${(import.meta as { env?: { BASE_URL?: string } }).env?.BASE_URL?.replace(/\/$/, '') ?? ''}${r.link_path}`);
  }, 'Sent.');
  const pdf = () => downloadBytes(offerPdf({
    title: merged.title, status, org: { name: orgName }, artist_name: merged.artist_name, act_type: merged.act_type, dates: merged.dates,
    currency: cur, venue: null, terms: merged.terms, budget: budget ? { capacity: budget.capacity, average_price_cents: budget.average_price_cents } : null,
    agent_name: merged.agent_name, boilerplate: merged.boilerplate, expires_at: merged.expires_at, response: offer.response as never,
  }), `offer-${merged.artist_name}.pdf`, 'application/pdf');

  const setD = (p: Partial<OfferRow>) => setDraft({ ...draft, ...p });
  const terms = merged.terms;
  const agentPatch = (p: Partial<{ name: string; email: string; company: string; phone: string }>) => {
    const a = { name: merged.agent_name ?? '', email: merged.agent_email ?? '', company: merged.agent_company ?? '', phone: merged.agent_phone ?? '', ...p };
    setDraft({ ...draft, agent_name: a.name, agent_email: a.email, agent_company: a.company, agent_phone: a.phone, agent: a } as Partial<OfferRow>);
  };

  return (
    <div className="max-w-5xl mx-auto px-4 py-8">
      <Link to={`/orgs/${orgId}/offers`} className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Offers</Link>
      <div className="flex flex-wrap items-center gap-3 mb-6">
        <h1 className="text-2xl font-black text-slate-900">{merged.artist_name}</h1>
        <StatusBadge status={status} />
        <span className="text-sm text-slate-500">{merged.title}</span>
        <div className="flex-1" />
        <button className={BTN} onClick={pdf}><Download size={12} className="inline mr-1" />PDF</button>
      </div>
      {!editable && canEdit && (status === 'accepted' || status === 'declined' || status === 'expired' || status === 'cancelled') && (
        <p className="text-xs text-slate-500 mb-4">A {status} offer keeps its terms; notes and the show link can still change.</p>
      )}
      {status === 'sent' && editable && <p className="text-xs text-amber-700 mb-4">Changing what the agent sees takes the offer back to draft and stops its link; send it again after.</p>}

      <Section title="Show">
        <div className="grid gap-3 sm:grid-cols-3">
          <label><span className={LABEL}>Title</span><input className={FLD} disabled={!editable} value={merged.title} maxLength={150} onChange={(e) => setD({ title: e.target.value })} /></label>
          <label><span className={LABEL}>Artist</span><input className={FLD} disabled={!editable} value={merged.artist_name} maxLength={150} onChange={(e) => setD({ artist_name: e.target.value })} /></label>
          <label><span className={LABEL}>Billing</span>
            <select className={FLD} disabled={!editable} value={merged.act_type} onChange={(e) => setD({ act_type: e.target.value as OfferRow['act_type'] })}>
              {['headliner', 'co_headliner', 'support', 'opener', 'other'].map((a) => <option key={a} value={a}>{a.replace('_', '-')}</option>)}
            </select></label>
          <label className="sm:col-span-2"><span className={LABEL}>Dates (YYYY-MM-DD, comma separated)</span>
            <input className={FLD} disabled={!editable} defaultValue={merged.dates.join(', ')} key={`d${loadKey}`}
              onBlur={(e) => setD({ dates: e.target.value.split(',').map((s) => s.trim()).filter(Boolean) })} /></label>
          <label><span className={LABEL}>Expires</span>
            <input className={FLD} type="datetime-local" disabled={!editable} key={`x${loadKey}`}
              defaultValue={merged.expires_at ? new Date(merged.expires_at).toISOString().slice(0, 16) : ''}
              onBlur={(e) => setD({ expires_at: e.target.value ? new Date(`${e.target.value}Z`).toISOString() : null })} /></label>
        </div>
        {offer.event_id && <p className="text-xs mt-3"><Link className="text-tm-blue" to={`/dashboard/event/${offer.event_id}?tab=settlement`}>Open the show's settlement</Link></p>}
      </Section>

      <Section title="Terms">
        <TermsEditor key={`t${loadKey}`} terms={terms} disabled={!editable} onChange={(t: TermsJson) => setD({ terms: t })} />
        {pool?.mode === 'pool' && (
          <label className="block mt-3 max-w-xs"><span className={LABEL}>Share of the pool % (blank = equal part of the rest)</span>
            <input className={FLD} disabled={!editable} key={`p${loadKey}`} defaultValue={merged.pool_share_percent ?? ''}
              onBlur={(e) => setD({ pool_share_percent: e.target.value.trim() ? Math.min(100, Math.max(0, Number(e.target.value) || 0)) : null })} /></label>
        )}
        <label className="block mt-3"><span className={LABEL}>Conditions shown to the agent</span>
          <textarea className={FLD} rows={4} disabled={!editable} maxLength={10000} value={merged.boilerplate} onChange={(e) => setD({ boilerplate: e.target.value })} /></label>
      </Section>

      <Section title="Agent">
        <div className="grid gap-3 sm:grid-cols-4">
          {(['name', 'email', 'company', 'phone'] as const).map((k) => (
            <label key={k}><span className={LABEL}>{k}</span>
              <input className={FLD} disabled={!editable} value={(merged[`agent_${k}` as keyof OfferRow] as string | null) ?? ''}
                onChange={(e) => agentPatch({ [k]: e.target.value })} /></label>
          ))}
        </div>
        <label className="block mt-3"><span className={LABEL}>Internal notes (never shown to the agent)</span>
          <textarea className={FLD} rows={2} disabled={!canEdit} maxLength={4000} value={merged.notes} onChange={(e) => setD({ notes: e.target.value })} /></label>
      </Section>

      {canEdit && (
        <div className="flex flex-wrap gap-2 items-end mb-6">
          <button className={BTN_PRIMARY} disabled={busy || !Object.keys(draft).length} onClick={save}>Save</button>
          {editable && <>
            <label className="min-w-[220px]"><span className={LABEL}>Send to (blank = agent)</span>
              <input className={FLD} value={sendTo} onChange={(e) => setSendTo(e.target.value)} placeholder={merged.agent_email ?? 'agent@agency.com'} /></label>
            <button className={BTN_PRIMARY} disabled={busy} onClick={send}>{status === 'sent' ? 'Send again' : 'Send'}</button>
            <button className={BTN} disabled={busy} onClick={() => { const n = window.prompt('Who accepted?') ?? ''; if (n !== null) act(() => recordOfferResponse(offer.id, 'accept', n, ''), 'Recorded.'); }}>Record accept</button>
            <button className={BTN} disabled={busy} onClick={() => { const n = window.prompt('Who declined?') ?? ''; act(() => recordOfferResponse(offer.id, 'decline', n, ''), 'Recorded.'); }}>Record decline</button>
          </>}
          {['draft', 'sent', 'accepted'].includes(status) && <button className={BTN} disabled={busy} onClick={() => { if (window.confirm('Cancel this offer?')) act(() => cancelOffer(offer.id), 'Cancelled.'); }}>Cancel offer</button>}
          {status === 'draft' && <button className={BTN} disabled={busy} onClick={async () => { if (window.confirm('Delete this draft?')) { try { await deleteOffer(offer.id); navigate(`/orgs/${orgId}/offers`); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); } } }}>Delete</button>}
        </div>
      )}
      {link && (
        <div className="bg-blue-50 border border-blue-200 rounded p-3 mb-6 text-xs flex items-center gap-2">
          <span className="truncate">The agent's link (also emailed): {link}</span>
          <button className={BTN} onClick={() => navigator.clipboard?.writeText(link)}><Copy size={12} /></button>
        </div>
      )}
      {offer.response && (
        <Section title="Answer">
          <Row label="Answer">{offer.response.action === 'accept' ? 'Accepted' : 'Declined'}{offer.response.name ? ` by ${offer.response.name}` : ''}</Row>
          {offer.response.note && <Row label="Note">{offer.response.note}</Row>}
          <Row label="When">{offer.response.at ? new Date(offer.response.at).toLocaleString() : ''} ({offer.response.via})</Row>
        </Section>
      )}

      {budget && (
        <Section title={`Budget${lineup.length > 1 ? ` (shared by ${lineup.length} offers)` : ''}`}>
          <BudgetForm key={`b${loadKey}`} budget={budget} canEdit={canEdit} onSave={(p) => act(() => updateBudget(budget.id, p), 'Budget saved.')} />
          <table className="w-full text-sm mt-4">
            <tbody>
              {lines.map((l) => (
                <tr key={l.id} className="border-t border-slate-100">
                  <td className="py-1.5">{l.label}</td>
                  <td className="py-1.5 text-xs text-slate-400">{cats.find((c) => c.id === l.category_id)?.name ?? ''} · {l.kind}</td>
                  <td className="py-1.5 text-right w-32">
                    <input className={FLD} disabled={!canEdit} defaultValue={inputFromCents(l.amount_cents)}
                      onBlur={(e) => { const c = centsFromInput(e.target.value); if (c !== null && !Number.isNaN(c) && c !== l.amount_cents) act(() => updateBudgetLine(l.id, { amount_cents: c })); }} />
                  </td>
                  <td className="py-1.5 text-right w-20">{canEdit && <button className={BTN} onClick={() => act(() => deleteBudgetLine(l.id))}>×</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {canEdit && orgId && <AddLine cats={cats} onAdd={(l) => act(() => addBudgetLine(orgId, budget.id, l))} />}
          {projection && (
            <div className="mt-4 bg-slate-50 rounded p-3">
              <p className={LABEL}>At the forecast</p>
              <Row label={`${projection.projectedSold} tickets`}><Money cents={projection.projectedGross} currency={cur} /></Row>
              {projection.slots.map((s) => <Row key={s.slotId} label={`${s.name}${s.poolId ? ` (pool ${s.poolSharePercent ?? 0}%)` : ''}`}><Money cents={-s.payout} currency={cur} /></Row>)}
              <Row label="Expenses"><Money cents={-projection.expensesTotal} currency={cur} /></Row>
              <Row label="Promoter net" strong><Money cents={projection.promoterNet} currency={cur} strong /></Row>
              <p className="text-xs text-slate-500 mt-2">{projection.breakEvenTickets === null ? 'Does not break even at capacity.' : `Breaks even at ${projection.breakEvenTickets} tickets (${formatCents(projection.breakEvenGross ?? 0, cur)}).`}</p>
            </div>
          )}
        </Section>
      )}

      {budget && (
        <Section title="Offer pool">
          <PoolForm key={`pool${loadKey}`} pool={pool} canEdit={canEdit} onSave={(mode, t) => act(() => savePool(budget.id, mode, t), 'Pool saved.')} />
          <p className="text-xs text-slate-400 mt-2">In pool mode the shared deal pays the whole lineup on this budget, split by each offer's share (blank shares split what is left equally). Bonuses, merch and deposits stay per act.</p>
        </Section>
      )}

      <Section title="History">
        {[...offer.history].reverse().map((h, i) => (
          <Row key={i} label={`${h.action.replace(/_/g, ' ')}${h.to ? ` to ${h.to}` : ''}${h.name ? ` (${h.name})` : ''}${h.note ? `: ${h.note}` : ''}`}>
            <span className="text-xs text-slate-400">{new Date(h.at).toLocaleString()}{h.via ? ` · ${h.via}` : ''}</span>
          </Row>
        ))}
      </Section>
    </div>
  );
}

function BudgetForm({ budget, canEdit, onSave }: { budget: BudgetRow; canEdit: boolean; onSave: (p: Partial<BudgetRow>) => void; key?: string }) {
  const [cap, setCap] = useState(String(budget.capacity));
  const [avg, setAvg] = useState(inputFromCents(budget.average_price_cents));
  const [sell, setSell] = useState(String(budget.sell_through_percent));
  const save = () => {
    const a = centsFromInput(avg);
    if (!Number.isInteger(Number(cap)) || a === null || Number.isNaN(a)) return;
    onSave({ capacity: Number(cap), average_price_cents: a, sell_through_percent: Math.min(100, Math.max(0, Number(sell) || 0)) });
  };
  return (
    <div className="flex flex-wrap gap-2 items-end">
      <label><span className={LABEL}>Capacity</span><input className={FLD} disabled={!canEdit} value={cap} onChange={(e) => setCap(e.target.value)} /></label>
      <label><span className={LABEL}>Average price</span><input className={FLD} disabled={!canEdit} value={avg} onChange={(e) => setAvg(e.target.value)} /></label>
      <label><span className={LABEL}>Sell-through %</span><input className={FLD} disabled={!canEdit} value={sell} onChange={(e) => setSell(e.target.value)} /></label>
      {canEdit && <button className={BTN} onClick={save}>Save forecast</button>}
    </div>
  );
}

function AddLine({ cats, onAdd }: { cats: CategoryRow[]; onAdd: (l: { kind: 'income' | 'expense'; label: string; amount_cents: number; category_id: string | null }) => void }) {
  const [label, setLabel] = useState('');
  const [amount, setAmount] = useState('');
  const [cat, setCat] = useState('');
  const c = cats.find((x) => x.id === cat);
  const kind: 'income' | 'expense' = c?.kind === 'income' ? 'income' : 'expense';
  return (
    <div className="flex flex-wrap gap-2 items-end mt-3">
      <label className="flex-1 min-w-[160px]"><span className={LABEL}>Line</span><input className={FLD} value={label} maxLength={120} onChange={(e) => setLabel(e.target.value)} /></label>
      <label><span className={LABEL}>Category</span><select className={FLD} value={cat} onChange={(e) => setCat(e.target.value)}>
        <option value="">None (expense)</option>{cats.map((x) => <option key={x.id} value={x.id}>{x.name} ({x.kind})</option>)}</select></label>
      <label><span className={LABEL}>Amount</span><input className={FLD} value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
      <button className={BTN} disabled={!label.trim()} onClick={() => {
        const a = centsFromInput(amount);
        if (a === null || Number.isNaN(a)) return;
        onAdd({ kind, label: label.trim(), amount_cents: a, category_id: cat || null });
        setLabel(''); setAmount('');
      }}>Add line</button>
    </div>
  );
}

function PoolForm({ pool, canEdit, onSave }: { pool: PoolRow | null; canEdit: boolean; onSave: (mode: "independent" | "pool", t: TermsJson) => void; key?: string }) {
  const [mode, setMode] = useState<'independent' | 'pool'>(pool?.mode ?? 'independent');
  const [terms, setTerms] = useState<TermsJson>(pool?.terms ?? { deal_type: 'versus', percentage: 80 });
  return (
    <div>
      <label className="block max-w-xs mb-3"><span className={LABEL}>Mode</span>
        <select className={FLD} disabled={!canEdit} value={mode} onChange={(e) => setMode(e.target.value as 'independent' | 'pool')}>
          <option value="independent">Independent: each act's own deal</option>
          <option value="pool">Pool: one shared deal for the lineup</option>
        </select></label>
      {mode === 'pool' && <TermsEditor pool terms={terms} disabled={!canEdit} onChange={setTerms} />}
      {canEdit && <button className={`${BTN} mt-3`} onClick={() => onSave(mode, terms)}>Save pool</button>}
    </div>
  );
}
