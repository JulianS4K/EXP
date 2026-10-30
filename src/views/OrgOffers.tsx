// /orgs/:orgId/offers — offers, templates, imports and deals
// (docs/offers-settlements.md). Owners and managers make and send offers;
// finance reads. Everything here holds money figures, so scanners and
// content staff get nothing (RLS returns no rows; the page says so).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, FileUp, Plus } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import {
  createOffer, discardDeal, effectiveStatus, importOffers, listDeals, listOffers, listTemplates, saveDeal, saveTemplate,
  deleteTemplate, type DealRow, type OfferRow, type TemplateRow,
} from '../lib/offersApi';
import { planOfferImport } from '../lib/offerImport';
import { describeDeal, formatCents } from '../lib/dealMath';
import TermsEditor from '../components/finance/TermsEditor';
import { BTN, BTN_PRIMARY, centsFromInput, FLD, LABEL, Section, StatusBadge } from '../components/finance/ui';

type Tab = 'offers' | 'templates' | 'deals';

export default function OrgOffers() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [tab, setTab] = useState<Tab>('offers');
  const [offers, setOffers] = useState<OfferRow[]>([]);
  const [templates, setTemplates] = useState<TemplateRow[]>([]);
  const [deals, setDeals] = useState<DealRow[]>([]);
  const [filter, setFilter] = useState<string>('open');
  const [busy, setBusy] = useState(false);
  const [newArtist, setNewArtist] = useState('');
  const [newTemplate, setNewTemplate] = useState('');

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const effectiveRole = isAdmin ? 'owner' : role;
  const canEdit = effectiveRole === 'owner' || effectiveRole === 'manager';
  const canView = canEdit || effectiveRole === 'finance';

  const load = useCallback(async () => {
    if (!orgId || !canView) return;
    try {
      const [o, t, d] = await Promise.all([listOffers(orgId), listTemplates(orgId), listDeals(orgId)]);
      setOffers(o); setTemplates(t); setDeals(d);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  }, [orgId, canView, toast]);
  useEffect(() => { load(); }, [load]);

  const shown = useMemo(() => offers.filter((o) => {
    const s = effectiveStatus(o);
    if (filter === 'open') return s === 'draft' || s === 'sent';
    if (filter === 'all') return true;
    return s === filter;
  }), [offers, filter]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!canView) return <div className="p-8 text-sm text-slate-500">Offers are for owners, managers and finance staff.</div>;

  const create = async () => {
    if (!orgId || !newArtist.trim()) return;
    setBusy(true);
    try {
      const o = await createOffer(orgId, { artist_name: newArtist.trim(), ...(newTemplate ? { template_id: newTemplate } : {}) });
      navigate(`/orgs/${orgId}/offers/${o.id}`);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const onImport = async (file: File) => {
    if (!orgId) return;
    const plan = planOfferImport(await file.text());
    if (!plan.rows.length) {
      toast({ kind: 'error', message: plan.errors.map((e) => (e.row ? `Row ${e.row}: ${e.error}` : e.error)).join(' ') || 'Nothing to import.' });
      return;
    }
    setBusy(true);
    try {
      const r = await importOffers(orgId, file.name.slice(0, 200), plan.rows);
      const skipped = plan.errors.length + r.errors.length;
      toast({ kind: skipped ? 'info' : 'success', message: `Imported ${r.created_count} offer${r.created_count === 1 ? '' : 's'} as drafts${skipped ? `; ${skipped} row${skipped === 1 ? '' : 's'} skipped (${[...plan.errors, ...r.errors].slice(0, 3).map((e) => `row ${e.row}: ${e.error}`).join('; ')})` : ''}.` });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Dashboard</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Offers</h1>
      <p className="text-sm text-slate-500 mb-6">{orgName} · deals you offer acts, templates for them, and your sales and fundraising pipeline.</p>
      <div role="tablist" className="flex gap-1 border-b border-slate-200 mb-6">
        {(['offers', 'templates', 'deals'] as Tab[]).map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
            className={`px-4 py-3 text-xs font-bold uppercase tracking-widest border-b-2 -mb-px ${tab === t ? 'border-[#026cdf] text-slate-900' : 'border-transparent text-slate-400'}`}>
            {t}
          </button>
        ))}
      </div>

      {tab === 'offers' && (<>
        {canEdit && (
          <Section title="New offer">
            <div className="flex flex-wrap gap-2 items-end">
              <label className="flex-1 min-w-[200px]"><span className={LABEL}>Artist</span>
                <input className={FLD} value={newArtist} onChange={(e) => setNewArtist(e.target.value)} placeholder="Who is the offer for?" maxLength={150} /></label>
              <label className="min-w-[180px]"><span className={LABEL}>Template</span>
                <select className={FLD} value={newTemplate} onChange={(e) => setNewTemplate(e.target.value)}>
                  <option value="">None</option>
                  {templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select></label>
              <button className={BTN_PRIMARY} disabled={busy || !newArtist.trim()} onClick={create}><Plus size={12} className="inline mr-1" />Create draft</button>
              <label className={`${BTN} cursor-pointer`}>
                <FileUp size={12} className="inline mr-1" />Import CSV
                <input type="file" accept=".csv,text/csv" className="hidden" disabled={busy}
                  onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) onImport(f); }} />
              </label>
            </div>
            <p className="text-xs text-slate-400 mt-2">From a hold: open it on the booking calendar and choose Make offer. CSV columns: artist, date, deal, guarantee, percentage, agent, agent email, capacity, average price, group (rows with one group share a budget).</p>
          </Section>
        )}
        <div className="flex gap-2 mb-3">
          {['open', 'accepted', 'declined', 'expired', 'cancelled', 'all'].map((f) => (
            <button key={f} className={`${BTN} ${filter === f ? 'border-slate-900 text-slate-900' : ''}`} onClick={() => setFilter(f)}>{f}</button>
          ))}
        </div>
        <div className="bg-white border border-slate-200 rounded overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
              <th className="p-3">Artist</th><th className="p-3">Show</th><th className="p-3">Dates</th><th className="p-3">Deal</th><th className="p-3">Status</th>
            </tr></thead>
            <tbody>
              {shown.map((o) => (
                <tr key={o.id} className="border-t border-slate-100 hover:bg-slate-50 cursor-pointer" onClick={() => navigate(`/orgs/${orgId}/offers/${o.id}`)}>
                  <td className="p-3 font-bold text-slate-900">{o.artist_name}</td>
                  <td className="p-3">{o.title}</td>
                  <td className="p-3 whitespace-nowrap">{o.dates.join(', ') || '—'}</td>
                  <td className="p-3">{describeDeal(o.terms, o.currency)}</td>
                  <td className="p-3"><StatusBadge status={effectiveStatus(o)} /></td>
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={5} className="p-6 text-center text-slate-400">No offers here.</td></tr>}
            </tbody>
          </table>
        </div>
      </>)}

      {tab === 'templates' && orgId && <Templates orgId={orgId} templates={templates} canEdit={canEdit} reload={load} />}
      {tab === 'deals' && orgId && <Deals orgId={orgId} deals={deals} canEdit={canEdit} reload={load} />}
    </div>
  );
}

function Templates({ orgId, templates, canEdit, reload }: { orgId: string; templates: TemplateRow[]; canEdit: boolean; reload: () => void }) {
  const { toast } = useToast();
  const [editing, setEditing] = useState<Partial<TemplateRow> & { id?: string } | null>(null);
  const save = async () => {
    if (!editing?.name?.trim()) return;
    try {
      const { id, ...rest } = editing;
      await saveTemplate(orgId, {
        name: rest.name, currency: rest.currency ?? 'USD', terms: rest.terms ?? {}, boilerplate: rest.boilerplate ?? '',
        expires_in_days: rest.expires_in_days ?? null, average_price_cents: rest.average_price_cents ?? null,
        sell_through_percent: rest.sell_through_percent ?? null,
      }, id);
      setEditing(null);
      reload();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  };
  return (
    <>
      {canEdit && !editing && <button className={`${BTN_PRIMARY} mb-4`} onClick={() => setEditing({ name: '', terms: { deal_type: 'versus', percentage: 85 } })}>New template</button>}
      {editing && (
        <Section title={editing.id ? 'Edit template' : 'New template'}>
          <div className="grid gap-3 sm:grid-cols-3 mb-4">
            <label><span className={LABEL}>Name</span><input className={FLD} value={editing.name ?? ''} maxLength={100} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label><span className={LABEL}>Currency</span><input className={FLD} value={editing.currency ?? 'USD'} maxLength={3} onChange={(e) => setEditing({ ...editing, currency: e.target.value.toUpperCase() })} /></label>
            <label><span className={LABEL}>Expires after (days)</span><input className={FLD} inputMode="numeric" value={editing.expires_in_days ?? ''}
              onChange={(e) => setEditing({ ...editing, expires_in_days: e.target.value ? Math.max(1, Math.min(365, Number(e.target.value) || 1)) : null })} /></label>
            <label><span className={LABEL}>Average ticket price</span><input className={FLD} inputMode="decimal"
              defaultValue={editing.average_price_cents ? (editing.average_price_cents / 100).toFixed(2) : ''}
              onBlur={(e) => { const c = centsFromInput(e.target.value); if (c === null || !Number.isNaN(c)) setEditing({ ...editing, average_price_cents: c }); }} /></label>
            <label><span className={LABEL}>Sell-through %</span><input className={FLD} inputMode="decimal" value={editing.sell_through_percent ?? ''}
              onChange={(e) => setEditing({ ...editing, sell_through_percent: e.target.value ? Math.min(100, Math.max(0, Number(e.target.value) || 0)) : null })} /></label>
          </div>
          <TermsEditor terms={editing.terms ?? {}} onChange={(t) => setEditing({ ...editing, terms: t })} />
          <label className="block mt-3"><span className={LABEL}>Conditions (boilerplate)</span>
            <textarea className={FLD} rows={4} maxLength={10000} value={editing.boilerplate ?? ''} onChange={(e) => setEditing({ ...editing, boilerplate: e.target.value })} /></label>
          <div className="flex gap-2 mt-4">
            <button className={BTN_PRIMARY} onClick={save}>Save</button>
            <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </Section>
      )}
      <div className="grid gap-3">
        {templates.map((t) => (
          <div key={t.id} className="bg-white border border-slate-200 rounded p-4 flex justify-between items-center">
            <div><p className="font-bold text-slate-900">{t.name}</p><p className="text-xs text-slate-500">{describeDeal(t.terms, t.currency)}{t.expires_in_days ? ` · expires after ${t.expires_in_days} days` : ''}</p></div>
            {canEdit && <div className="flex gap-2">
              <button className={BTN} onClick={() => setEditing(t)}>Edit</button>
              <button className={BTN} onClick={async () => { if (window.confirm(`Delete ${t.name}?`)) { await deleteTemplate(t.id).catch((e) => toast({ kind: 'error', message: e.message })); reload(); } }}>Delete</button>
            </div>}
          </div>
        ))}
        {!templates.length && <p className="text-sm text-slate-400">No templates yet.</p>}
      </div>
    </>
  );
}

const SALES_STAGES = ['lead', 'qualified', 'proposal', 'negotiation', 'closed_won', 'closed_lost'];
const FUND_STAGES = ['identification', 'qualification', 'cultivation', 'solicitation', 'stewardship', 'closed_won', 'closed_lost', 'not_a_prospect'];

function Deals({ orgId, deals, canEdit, reload }: { orgId: string; deals: DealRow[]; canEdit: boolean; reload: () => void }) {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [type, setType] = useState<'sales' | 'fundraising'>('sales');
  const [amount, setAmount] = useState('');
  const add = async () => {
    const c = centsFromInput(amount);
    if (!name.trim() || (c !== null && Number.isNaN(c))) return;
    try {
      await saveDeal(orgId, { name: name.trim(), deal_type: type, stage: type === 'sales' ? 'lead' : 'identification', amount_cents: c ?? 0 });
      setName(''); setAmount('');
      reload();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  };
  const stage = async (d: DealRow, s: string) => {
    try { await saveDeal(orgId, { stage: s }, d.id); reload(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  const open = deals.filter((d) => d.status === 'open');
  const weighted = open.reduce((s, d) => s + Math.round((d.amount_cents * (d.probability ?? 0)) / 100), 0);
  return (
    <>
      {canEdit && (
        <Section title="New deal">
          <div className="flex flex-wrap gap-2 items-end">
            <label className="flex-1 min-w-[200px]"><span className={LABEL}>Name</span><input className={FLD} value={name} maxLength={150} onChange={(e) => setName(e.target.value)} placeholder="Sponsor, rental, donor…" /></label>
            <label><span className={LABEL}>Type</span><select className={FLD} value={type} onChange={(e) => setType(e.target.value as 'sales' | 'fundraising')}><option value="sales">Sales</option><option value="fundraising">Fundraising</option></select></label>
            <label><span className={LABEL}>Amount</span><input className={FLD} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
            <button className={BTN_PRIMARY} onClick={add} disabled={!name.trim()}>Add</button>
          </div>
        </Section>
      )}
      <p className="text-xs text-slate-500 mb-2">{open.length} open · weighted {formatCents(weighted, 'USD')} (amount × probability, USD deals)</p>
      <div className="bg-white border border-slate-200 rounded overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-[10px] uppercase tracking-widest text-slate-400"><th className="p-3">Deal</th><th className="p-3">Stage</th><th className="p-3 text-right">Amount</th><th className="p-3" /></tr></thead>
          <tbody>
            {deals.map((d) => (
              <tr key={d.id} className="border-t border-slate-100">
                <td className="p-3"><p className="font-bold">{d.name}</p><p className="text-xs text-slate-400">{d.deal_type}{d.company ? ` · ${d.company}` : ''}</p></td>
                <td className="p-3">
                  <select className={FLD} value={d.stage} disabled={!canEdit} onChange={(e) => stage(d, e.target.value)}>
                    {(d.deal_type === 'sales' ? SALES_STAGES : FUND_STAGES).map((s) => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}
                  </select>
                </td>
                <td className="p-3 text-right tabular-nums">{formatCents(d.amount_cents, d.currency)}</td>
                <td className="p-3 text-right">{canEdit && <button className={BTN} onClick={async () => { await discardDeal(d.id).catch((e) => toast({ kind: 'error', message: e.message })); reload(); }}>Discard</button>}</td>
              </tr>
            ))}
            {!deals.length && <tr><td colSpan={4} className="p-6 text-center text-slate-400">No deals yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
