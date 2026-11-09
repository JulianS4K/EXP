// /orgs/:orgId/giving — giving tables (mig 20261102110000, docs/giving.md).
//
//   Campaigns      sort / filter / page; edit, activate, turn off, complete
//                  (cancels its monthly gifts in Stripe), delete (no gifts only)
//   Donations      sort / filter / page; record an offline refund, delete an
//                  offline gift with no payment behind it
//   Monthly gifts  sort / filter / page; cancel
//   Imported cards import a Gift Up! (or any) CSV; sort / filter / page the
//                  imported cards
//
// Roles (givingPermissions, the SQL re-checks): owner / manager everything;
// finance reads, records refunds, cancels monthly gifts; others see nothing.
// No Stripe card field on this page (docs/pci.md).

import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { ArrowDown, ArrowLeft, ArrowUp, HeartHandshake, Upload } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import {
  campaignActions, campaignStatus, donationActions, donationKind, donationLeftCents, filterCampaigns, filterDonations,
  filterImportedCards, filterRecurring, formatMoney, givingPermissions, goalPercent, importBatches, majorCents, nextSort,
  pageRows, parseGiftCardFile, recurringActions, sortRows,
  type CampaignAction, type CampaignFilter, type ImportCard, type CampaignRow, type DonationFilter, type DonationRow, type GivingPermissions,
  type ImportedCardFilter, type ImportedCardRow, type ImportParse, type RecurringFilter, type RecurringRow, type SortState,
} from '../lib/givingTables';
import {
  campaignOp, cancelRecurring, completeCampaign, deleteDonation, importGiftCards, listCampaignRows, listDonationRows,
  listImportedCards, listRecurringRows, offlineRefund,
} from '../lib/givingApi';

type Tab = 'campaigns' | 'donations' | 'monthly' | 'imports';

const card = 'bg-white rounded-2xl border border-slate-200 p-5';
const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50';
const btnDark = 'inline-flex items-center gap-1.5 px-3 py-2 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50';
const field = 'w-full bg-slate-50 border border-slate-200 rounded px-3 py-2 text-sm text-slate-900';
const label = 'block text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1';
const act = 'text-xs font-bold underline text-slate-700 hover:text-slate-900 disabled:opacity-50';
const danger = 'text-xs font-bold underline text-rose-600 hover:text-rose-700 disabled:opacity-50';
const PER_PAGE = 25;

const day = (s: string | null) => (s ? new Date(s).toLocaleDateString(undefined, { dateStyle: 'medium' }) : '—');

function SortTh<K extends string>({ k, sort, onSort, children, first = 'asc', right }: {
  k: K; sort: SortState<K>; onSort: (s: SortState<K>) => void; children: ReactNode; first?: 'asc' | 'desc'; right?: boolean;
}) {
  const on = sort.key === k;
  return (
    <th scope="col" aria-sort={on ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'}
      className={`px-3 py-2 text-[10px] font-black uppercase tracking-widest text-slate-400 ${right ? 'text-right' : 'text-left'}`}>
      <button type="button" className="inline-flex items-center gap-1 hover:text-slate-700" onClick={() => onSort(nextSort(sort, k, first))}>
        {children}{on && (sort.dir === 'asc' ? <ArrowUp size={11} /> : <ArrowDown size={11} />)}
      </button>
    </th>
  );
}

function Pager({ page, pages, from, to, total, onPage }: { page: number; pages: number; from: number; to: number; total: number; onPage: (p: number) => void }) {
  return (
    <div className="flex items-center justify-between text-xs text-slate-500 mt-3">
      <span>{total === 0 ? 'Nothing here yet.' : `${from}–${to} of ${total}`}</span>
      <span className="flex gap-2">
        <button type="button" className={btn} disabled={page <= 1} onClick={() => onPage(page - 1)}>Previous</button>
        <span className="self-center">Page {page} of {pages}</span>
        <button type="button" className={btn} disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</button>
      </span>
    </div>
  );
}

const STATUS_CLS: Record<string, string> = {
  active: 'bg-emerald-50 text-emerald-700', draft: 'bg-slate-100 text-slate-600', completed: 'bg-slate-900 text-white',
  received: 'bg-emerald-50 text-emerald-700', refunded: 'bg-rose-50 text-rose-700', pending: 'bg-amber-50 text-amber-700',
  past_due: 'bg-amber-50 text-amber-700', cancelled: 'bg-slate-100 text-slate-600', ended: 'bg-slate-100 text-slate-600',
  voided: 'bg-rose-50 text-rose-700',
};
const Badge = ({ s, text }: { s: string; text?: string }) => (
  <span className={`px-2 py-0.5 rounded-full text-[10px] font-black uppercase tracking-widest ${STATUS_CLS[s] ?? 'bg-slate-100 text-slate-600'}`}>{text ?? s.replace('_', ' ')}</span>
);

export default function OrgGiving() {
  const { orgId = '' } = useParams();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { orgs, loading: orgsLoading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const perms = givingPermissions(entry?.membership.role ?? null, isAdmin);
  const [params, setParams] = useSearchParams();
  const tabs: { id: Tab; label: string }[] = [
    { id: 'campaigns', label: 'Campaigns' }, { id: 'donations', label: 'Donations' },
    { id: 'monthly', label: 'Monthly gifts' }, { id: 'imports', label: 'Imported gift cards' },
  ];
  const tab: Tab = tabs.find((t) => t.id === params.get('tab'))?.id ?? 'campaigns';
  const [campaigns, setCampaigns] = useState<CampaignRow[]>([]);
  const [monthlyCount, setMonthlyCount] = useState<Record<string, number>>({});
  const reloadCampaigns = useCallback(() => {
    if (!orgId || !perms.read) return;
    listCampaignRows(orgId).then((r) => { setCampaigns(r.rows); setMonthlyCount(r.monthly); }).catch(() => setCampaigns([]));
  }, [orgId, perms.read]);
  useEffect(reloadCampaigns, [reloadCampaigns]);

  if (!user) return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  if (!orgsLoading && !perms.read) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 text-sm">Giving is visible to the org's owners, managers and finance team.</div>;
  }
  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-6xl mx-auto px-4 py-10">
        <button onClick={() => navigate('/dashboard')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} strokeWidth={2.5} /> Dashboard
        </button>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">{entry?.org.name ?? 'Organization'}</p>
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight mb-6 flex items-center gap-3"><HeartHandshake /> Giving</h1>
        <div role="tablist" className="flex flex-wrap gap-2 mb-6">
          {tabs.map((t) => (
            <button key={t.id} role="tab" aria-selected={tab === t.id} type="button"
              onClick={() => setParams({ tab: t.id }, { replace: true })}
              className={`px-3 py-2 rounded text-xs font-bold ${tab === t.id ? 'bg-slate-900 text-white' : 'bg-white border border-slate-200 text-slate-600'}`}>
              {t.label}
            </button>
          ))}
        </div>
        {tab === 'campaigns' && <CampaignsTab orgId={orgId} rows={campaigns} monthly={monthlyCount} perms={perms} reload={reloadCampaigns} />}
        {tab === 'donations' && <DonationsTab orgId={orgId} campaigns={campaigns} perms={perms} onChanged={reloadCampaigns} />}
        {tab === 'monthly' && <MonthlyTab orgId={orgId} campaigns={campaigns} perms={perms} />}
        {tab === 'imports' && <ImportsTab orgId={orgId} perms={perms} />}
      </div>
    </div>
  );
}

// ── Campaigns ──────────────────────────────────────────────────────────────────
function CampaignsTab({ orgId, rows, monthly, perms, reload }: {
  orgId: string; rows: CampaignRow[]; monthly: Record<string, number>; perms: GivingPermissions; reload: () => void;
}) {
  const { toast } = useToast();
  const [filter, setFilter] = useState<CampaignFilter>({ status: 'all', search: '' });
  const [sort, setSort] = useState<SortState<'name' | 'status' | 'raised_cents' | 'goal_cents' | 'created_at'>>({ key: 'created_at', dir: 'desc' });
  const [page, setPage] = useState(1);
  const [editing, setEditing] = useState<CampaignRow | 'new' | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const view = useMemo(() => pageRows(sortRows(filterCampaigns(rows, filter), sort,
    (r, k) => (k === 'status' ? campaignStatus(r as CampaignRow) : (r as unknown as Record<string, unknown>)[k])), page, PER_PAGE), [rows, filter, sort, page]);

  const run = async (c: CampaignRow, a: CampaignAction) => {
    if (a === 'edit') { setEditing(c); return; }
    if (a === 'complete' && !window.confirm(`Complete "${c.name}"? It closes for good and its monthly gifts are cancelled.`)) return;
    if (a === 'delete' && !window.confirm(`Delete "${c.name}"?`)) return;
    setBusy(c.id);
    try {
      if (a === 'complete') {
        const r = await completeCampaign(c.id);
        toast({ kind: r.not_cancelled.length ? 'error' : 'success',
          message: r.not_cancelled.length ? `Completed. ${r.not_cancelled.length} monthly gift(s) didn't cancel in Stripe: cancel them under Monthly gifts.` : 'Completed.' });
      } else if (a === 'deactivate') {
        await campaignOp('update', { id: c.id, body: { active: false } });
        toast({ kind: 'success', message: 'Turned off.' });
      } else {
        await campaignOp(a, { id: c.id });
        toast({ kind: 'success', message: a === 'activate' ? 'Activated.' : 'Deleted.' });
      }
      reload();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(null);
    }
  };
  const LABEL: Record<CampaignAction, string> = { edit: 'Edit', activate: 'Activate', deactivate: 'Turn off', complete: 'Complete', delete: 'Delete' };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2 items-end">
        <div className="flex-1 min-w-[200px]"><label className={label} htmlFor="gc-search">Search</label>
          <input id="gc-search" className={field} value={filter.search} onChange={(e) => { setFilter({ ...filter, search: e.target.value }); setPage(1); }} placeholder="Name or slug" /></div>
        <div><label className={label} htmlFor="gc-status">Status</label>
          <select id="gc-status" className={field} value={filter.status} onChange={(e) => { setFilter({ ...filter, status: e.target.value as CampaignFilter['status'] }); setPage(1); }}>
            <option value="all">All</option><option value="active">Active</option><option value="draft">Draft</option><option value="completed">Completed</option>
          </select></div>
        {perms.editCampaigns && <button type="button" className={btnDark} onClick={() => setEditing('new')}>New campaign</button>}
      </div>
      {editing && <CampaignEditor orgId={orgId} row={editing === 'new' ? null : editing} onDone={(saved) => { setEditing(null); if (saved) reload(); }} />}
      <div className={`${card} overflow-x-auto p-0`}>
        <table className="w-full text-sm">
          <thead className="border-b border-slate-100"><tr>
            <SortTh k="name" sort={sort} onSort={setSort}>Campaign</SortTh>
            <SortTh k="status" sort={sort} onSort={setSort}>Status</SortTh>
            <SortTh k="raised_cents" sort={sort} onSort={setSort} first="desc" right>Raised</SortTh>
            <SortTh k="goal_cents" sort={sort} onSort={setSort} first="desc" right>Goal</SortTh>
            <SortTh k="created_at" sort={sort} onSort={setSort} first="desc">Created</SortTh>
            {perms.editCampaigns && <th scope="col" className="px-3 py-2 text-[10px] font-black uppercase tracking-widest text-slate-400 text-right">Actions</th>}
          </tr></thead>
          <tbody>
            {view.rows.map((c) => {
              const pct = goalPercent(c);
              return (
                <tr key={c.id} className="border-b border-slate-50 last:border-0">
                  <td className="px-3 py-2"><span className="font-bold">{c.name}</span><span className="block text-xs text-slate-400">/{c.slug}{c.checkout_add_on ? ' · at checkout' : ''}{monthly[c.id] ? ` · ${monthly[c.id]} monthly` : ''}</span></td>
                  <td className="px-3 py-2"><Badge s={campaignStatus(c)} /></td>
                  <td className="px-3 py-2 text-right tabular-nums">{formatMoney(c.raised_cents, c.currency)}<span className="block text-xs text-slate-400">{c.donation_count} gift{c.donation_count === 1 ? '' : 's'}</span></td>
                  <td className="px-3 py-2 text-right tabular-nums">{c.goal_cents ? formatMoney(c.goal_cents, c.currency) : '—'}{pct !== null && <span className="block text-xs text-slate-400">{pct}%</span>}</td>
                  <td className="px-3 py-2 text-xs text-slate-500">{day(c.created_at)}</td>
                  {perms.editCampaigns && (
                    <td className="px-3 py-2 text-right space-x-3 whitespace-nowrap">
                      {campaignActions(c, perms, (monthly[c.id] ?? 0) > 0).map((a) => (
                        <button key={a} type="button" disabled={busy === c.id} className={a === 'delete' || a === 'complete' ? danger : act} onClick={() => void run(c, a)}>{LABEL[a]}</button>
                      ))}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <Pager {...view} onPage={setPage} />
    </div>
  );
}

function CampaignEditor({ orgId, row, onDone }: { orgId: string; row: CampaignRow | null; onDone: (saved: boolean) => void }) {
  const { toast } = useToast();
  const [name, setName] = useState(row?.name ?? '');
  const [goal, setGoal] = useState(row?.goal_cents ? (row.goal_cents / 100).toFixed(2) : '');
  const [description, setDescription] = useState(row?.description ?? '');
  const [receipt, setReceipt] = useState(row?.tax_receipt_text ?? '');
  const [addOn, setAddOn] = useState(row?.checkout_add_on ?? false);
  const [ends, setEnds] = useState(row?.ends_at ? row.ends_at.slice(0, 10) : '');
  const [busy, setBusy] = useState(false);
  const save = async () => {
    const goalCents = goal.trim() ? majorCents(goal) : 0;
    if (goalCents === null) { toast({ kind: 'error', message: 'The goal must be an amount.' }); return; }
    const body = { name: name.trim(), goal_cents: goalCents, description: description.trim() || null, tax_receipt_text: receipt.trim() || null,
      checkout_add_on: addOn, ends_at: ends ? new Date(`${ends}T23:59:59`).toISOString() : null };
    setBusy(true);
    try {
      if (row) await campaignOp('update', { id: row.id, body });
      else await campaignOp('create', { orgId, body });
      toast({ kind: 'success', message: row ? 'Saved.' : 'Created as a draft: activate it to take gifts.' });
      onDone(true);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={`${card} grid gap-3 sm:grid-cols-2`}>
      <div><label className={label} htmlFor="ce-name">Name</label><input id="ce-name" className={field} maxLength={120} value={name} onChange={(e) => setName(e.target.value)} /></div>
      <div><label className={label} htmlFor="ce-goal">Goal (optional)</label><input id="ce-goal" className={field} inputMode="decimal" value={goal} onChange={(e) => setGoal(e.target.value)} /></div>
      <div className="sm:col-span-2"><label className={label} htmlFor="ce-desc">Description</label><textarea id="ce-desc" className={field} rows={2} maxLength={5000} value={description} onChange={(e) => setDescription(e.target.value)} /></div>
      <div className="sm:col-span-2"><label className={label} htmlFor="ce-receipt">Receipt text (legal name, charity status, tax id)</label><textarea id="ce-receipt" className={field} rows={2} maxLength={2000} value={receipt} onChange={(e) => setReceipt(e.target.value)} /></div>
      <div><label className={label} htmlFor="ce-ends">Ends (optional)</label><input id="ce-ends" type="date" className={field} value={ends} onChange={(e) => setEnds(e.target.value)} /></div>
      <label className="flex items-center gap-2 text-xs self-end"><input type="checkbox" checked={addOn} onChange={(e) => setAddOn(e.target.checked)} /> Offer at ticket checkout</label>
      <div className="sm:col-span-2 flex gap-2">
        <button type="button" className={btnDark} disabled={busy || !name.trim()} onClick={() => void save()}>{row ? 'Save' : 'Create draft'}</button>
        <button type="button" className={btn} onClick={() => onDone(false)}>Cancel</button>
      </div>
    </div>
  );
}

// ── Donations ──────────────────────────────────────────────────────────────────
function DonationsTab({ orgId, campaigns, perms, onChanged }: { orgId: string; campaigns: CampaignRow[]; perms: GivingPermissions; onChanged: () => void }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<DonationRow[] | null>(null);
  const [filter, setFilter] = useState<DonationFilter>({ campaignId: 'all', status: 'all', kind: 'all', search: '' });
  const [sort, setSort] = useState<SortState<'created_at' | 'total_cents' | 'donor_name' | 'method' | 'receipt_number'>>({ key: 'created_at', dir: 'desc' });
  const [page, setPage] = useState(1);
  const [refunding, setRefunding] = useState<DonationRow | null>(null);
  const load = useCallback(() => { listDonationRows(orgId).then(setRows).catch((e) => { toast({ kind: 'error', message: (e as Error).message }); setRows([]); }); }, [orgId, toast]);
  useEffect(load, [load]);
  const names = useMemo(() => new Map(campaigns.map((c) => [c.id, c.name])), [campaigns]);
  const view = useMemo(() => pageRows(sortRows(filterDonations(rows ?? [], filter), sort), page, PER_PAGE), [rows, filter, sort, page]);
  const set = (p: Partial<DonationFilter>) => { setFilter({ ...filter, ...p }); setPage(1); };
  const remove = async (d: DonationRow) => {
    if (!window.confirm(`Delete this ${d.method} gift of ${formatMoney(d.total_cents, d.currency)}? The deletion is kept in the ledger.`)) return;
    try { await deleteDonation(d.id); toast({ kind: 'success', message: 'Deleted.' }); load(); onChanged(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  const hasActions = perms.refundDonations || perms.deleteDonations;
  return (
    <div className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-4 items-end">
        <div><label className={label} htmlFor="dn-search">Search</label><input id="dn-search" className={field} value={filter.search} placeholder="Donor, email, receipt no." onChange={(e) => set({ search: e.target.value })} /></div>
        <div><label className={label} htmlFor="dn-camp">Campaign</label>
          <select id="dn-camp" className={field} value={filter.campaignId} onChange={(e) => set({ campaignId: e.target.value })}>
            <option value="all">All campaigns</option>{campaigns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></div>
        <div><label className={label} htmlFor="dn-status">Status</label>
          <select id="dn-status" className={field} value={filter.status} onChange={(e) => set({ status: e.target.value as DonationFilter['status'] })}>
            <option value="all">All</option><option value="received">Received</option><option value="partly_refunded">Partly refunded</option><option value="refunded">Refunded</option>
          </select></div>
        <div><label className={label} htmlFor="dn-kind">Kind</label>
          <select id="dn-kind" className={field} value={filter.kind} onChange={(e) => set({ kind: e.target.value as DonationFilter['kind'] })}>
            <option value="all">All</option><option value="online">Online / checkout</option><option value="monthly">Monthly</option><option value="offline">Cash / check</option>
          </select></div>
      </div>
      {refunding && <RefundForm d={refunding} onDone={(ok) => { setRefunding(null); if (ok) { load(); onChanged(); } }} />}
      <div className={`${card} overflow-x-auto p-0`}>
        <table className="w-full text-sm">
          <thead className="border-b border-slate-100"><tr>
            <SortTh k="created_at" sort={sort} onSort={setSort} first="desc">Date</SortTh>
            <SortTh k="donor_name" sort={sort} onSort={setSort}>Donor</SortTh>
            <th scope="col" className="px-3 py-2 text-left text-[10px] font-black uppercase tracking-widest text-slate-400">Campaign</th>
            <SortTh k="method" sort={sort} onSort={setSort}>Method</SortTh>
            <SortTh k="total_cents" sort={sort} onSort={setSort} first="desc" right>Amount</SortTh>
            <SortTh k="receipt_number" sort={sort} onSort={setSort} first="desc">Receipt</SortTh>
            {hasActions && <th scope="col" className="px-3 py-2 text-right text-[10px] font-black uppercase tracking-widest text-slate-400">Actions</th>}
          </tr></thead>
          <tbody>
            {view.rows.map((d) => (
              <tr key={d.id} className="border-b border-slate-50 last:border-0">
                <td className="px-3 py-2 text-xs text-slate-500">{day(d.created_at)}</td>
                <td className="px-3 py-2">{d.donor_name || (d.anonymous ? 'Anonymous' : '—')}<span className="block text-xs text-slate-400">{d.donor_email ?? ''}</span></td>
                <td className="px-3 py-2 text-xs">{names.get(d.campaign_id) ?? '—'}</td>
                <td className="px-3 py-2 text-xs">{d.method}{donationKind(d) === 'monthly' ? ' · monthly' : ''}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(d.total_cents, d.currency)}
                  {d.refunded_cents > 0 && <span className="block text-xs text-rose-600">−{formatMoney(d.refunded_cents, d.currency)} refunded</span>}
                  {d.status === 'refunded' && <span className="block"><Badge s="refunded" /></span>}</td>
                <td className="px-3 py-2 text-xs">{d.receipt_number ?? '—'}</td>
                {hasActions && (
                  <td className="px-3 py-2 text-right space-x-3 whitespace-nowrap">
                    {donationActions(d, perms).map((a) => a === 'offline_refund'
                      ? <button key={a} type="button" className={act} onClick={() => setRefunding(d)}>Offline refund</button>
                      : <button key={a} type="button" className={danger} onClick={() => void remove(d)}>Delete</button>)}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows === null ? <p className="text-xs text-slate-400">Loading…</p> : <Pager {...view} onPage={setPage} />}
    </div>
  );
}

function RefundForm({ d, onDone }: { d: DonationRow; onDone: (ok: boolean) => void }) {
  const { toast } = useToast();
  const left = donationLeftCents(d);
  const [amount, setAmount] = useState((left / 100).toFixed(2));
  const [method, setMethod] = useState('check');
  const [reference, setReference] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const save = async () => {
    const cents = majorCents(amount);
    if (!cents || cents > left) { toast({ kind: 'error', message: `Enter an amount up to ${formatMoney(left, d.currency)}.` }); return; }
    setBusy(true);
    try {
      await offlineRefund(d.id, { amountCents: cents, method, reference: reference || `dash-${Date.now()}`, note });
      toast({ kind: 'success', message: 'Refund recorded. Nothing was charged or refunded through Stripe.' });
      onDone(true);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={`${card} grid gap-3 sm:grid-cols-4 items-end`}>
      <p className="sm:col-span-4 text-xs text-slate-500">Record money you gave back outside Stripe for {d.donor_name || 'this gift'} ({formatMoney(left, d.currency)} left).</p>
      <div><label className={label} htmlFor="rf-amt">Amount</label><input id="rf-amt" className={field} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
      <div><label className={label} htmlFor="rf-m">How</label>
        <select id="rf-m" className={field} value={method} onChange={(e) => setMethod(e.target.value)}>
          <option value="check">Check</option><option value="cash">Cash</option><option value="bank_transfer">Bank transfer</option><option value="card">Card (outside Exos)</option><option value="other">Other</option>
        </select></div>
      <div><label className={label} htmlFor="rf-ref">Reference (prevents doubles)</label><input id="rf-ref" className={field} value={reference} onChange={(e) => setReference(e.target.value.replace(/[^A-Za-z0-9_:.-]/g, ''))} /></div>
      <div><label className={label} htmlFor="rf-note">Note</label><input id="rf-note" className={field} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} /></div>
      <div className="sm:col-span-4 flex gap-2"><button type="button" className={btnDark} disabled={busy} onClick={() => void save()}>Record refund</button>
        <button type="button" className={btn} onClick={() => onDone(false)}>Cancel</button></div>
    </div>
  );
}

// ── Monthly gifts ────────────────────────────────────────────────────────────────
function MonthlyTab({ orgId, campaigns, perms }: { orgId: string; campaigns: CampaignRow[]; perms: GivingPermissions }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<RecurringRow[] | null>(null);
  const [filter, setFilter] = useState<RecurringFilter>({ campaignId: 'all', status: 'all', search: '' });
  const [sort, setSort] = useState<SortState<'created_at' | 'amount_cents' | 'donor_email' | 'status' | 'last_paid_at'>>({ key: 'created_at', dir: 'desc' });
  const [page, setPage] = useState(1);
  const load = useCallback(() => { listRecurringRows(orgId).then(setRows).catch((e) => { toast({ kind: 'error', message: (e as Error).message }); setRows([]); }); }, [orgId, toast]);
  useEffect(load, [load]);
  const names = useMemo(() => new Map(campaigns.map((c) => [c.id, c.name])), [campaigns]);
  const view = useMemo(() => pageRows(sortRows(filterRecurring(rows ?? [], filter), sort), page, PER_PAGE), [rows, filter, sort, page]);
  const set = (p: Partial<RecurringFilter>) => { setFilter({ ...filter, ...p }); setPage(1); };
  const cancel = async (r: RecurringRow) => {
    if (!window.confirm(`Cancel ${r.donor_email}'s monthly gift? They won't be charged again.`)) return;
    try { await cancelRecurring(r.id); toast({ kind: 'success', message: 'Cancelled.' }); load(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  return (
    <div className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-3 items-end">
        <div><label className={label} htmlFor="mg-search">Search</label><input id="mg-search" className={field} value={filter.search} placeholder="Donor or email" onChange={(e) => set({ search: e.target.value })} /></div>
        <div><label className={label} htmlFor="mg-camp">Campaign</label>
          <select id="mg-camp" className={field} value={filter.campaignId} onChange={(e) => set({ campaignId: e.target.value })}>
            <option value="all">All campaigns</option>{campaigns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></div>
        <div><label className={label} htmlFor="mg-status">Status</label>
          <select id="mg-status" className={field} value={filter.status} onChange={(e) => set({ status: e.target.value as RecurringFilter['status'] })}>
            <option value="all">All</option><option value="active">Active</option><option value="past_due">Past due</option><option value="pending">Pending</option><option value="cancelled">Cancelled</option><option value="ended">Ended</option>
          </select></div>
      </div>
      <div className={`${card} overflow-x-auto p-0`}>
        <table className="w-full text-sm">
          <thead className="border-b border-slate-100"><tr>
            <SortTh k="donor_email" sort={sort} onSort={setSort}>Donor</SortTh>
            <th scope="col" className="px-3 py-2 text-left text-[10px] font-black uppercase tracking-widest text-slate-400">Campaign</th>
            <SortTh k="amount_cents" sort={sort} onSort={setSort} first="desc" right>Monthly</SortTh>
            <SortTh k="status" sort={sort} onSort={setSort}>Status</SortTh>
            <SortTh k="last_paid_at" sort={sort} onSort={setSort} first="desc">Last paid</SortTh>
            <SortTh k="created_at" sort={sort} onSort={setSort} first="desc">Started</SortTh>
            {perms.cancelMonthly && <th scope="col" className="px-3 py-2 text-right text-[10px] font-black uppercase tracking-widest text-slate-400">Actions</th>}
          </tr></thead>
          <tbody>
            {view.rows.map((r) => (
              <tr key={r.id} className="border-b border-slate-50 last:border-0">
                <td className="px-3 py-2">{r.donor_name || r.donor_email}<span className="block text-xs text-slate-400">{r.donor_name ? r.donor_email : ''}</span></td>
                <td className="px-3 py-2 text-xs">{names.get(r.campaign_id) ?? '—'}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(r.amount_cents + r.cover_fees_cents, r.currency)}</td>
                <td className="px-3 py-2"><Badge s={r.status} />{r.failed_payments > 0 && <span className="block text-xs text-amber-700">{r.failed_payments} failed</span>}
                  {r.cancel_requested_at && r.status !== 'cancelled' && <span className="block text-xs text-slate-400">cancel asked</span>}</td>
                <td className="px-3 py-2 text-xs text-slate-500">{day(r.last_paid_at)}</td>
                <td className="px-3 py-2 text-xs text-slate-500">{day(r.created_at)}</td>
                {perms.cancelMonthly && (
                  <td className="px-3 py-2 text-right">{recurringActions(r, perms).map((a) => <button key={a} type="button" className={danger} onClick={() => void cancel(r)}>Cancel</button>)}</td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows === null ? <p className="text-xs text-slate-400">Loading…</p> : <Pager {...view} onPage={setPage} />}
    </div>
  );
}

// ── Imported gift cards ────────────────────────────────────────────────────────────
function ImportsTab({ orgId, perms }: { orgId: string; perms: GivingPermissions }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<ImportedCardRow[] | null>(null);
  const [filter, setFilter] = useState<ImportedCardFilter>({ source: 'all', state: 'all', search: '' });
  const [sort, setSort] = useState<SortState<'created_at' | 'balance_cents' | 'initial_cents' | 'last4' | 'expires_at'>>({ key: 'created_at', dir: 'desc' });
  const [page, setPage] = useState(1);
  const [source, setSource] = useState('gift_up');
  const [parsed, setParsed] = useState<ImportParse | null>(null);
  const [fileKey, setFileKey] = useState('');
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => { listImportedCards(orgId).then(setRows).catch((e) => { toast({ kind: 'error', message: (e as Error).message }); setRows([]); }); }, [orgId, toast]);
  useEffect(load, [load]);
  const sources = useMemo(() => [...new Set((rows ?? []).map((r) => r.external_source).filter((s): s is string => !!s))], [rows]);
  const view = useMemo(() => pageRows(sortRows(filterImportedCards(rows ?? [], filter), sort), page, PER_PAGE), [rows, filter, sort, page]);
  const set = (p: Partial<ImportedCardFilter>) => { setFilter({ ...filter, ...p }); setPage(1); };

  const pick = async (f: File | undefined) => {
    if (!f) return;
    if (f.size > 2 * 1024 * 1024) { toast({ kind: 'error', message: 'The file is over 2 MB.' }); return; }
    const text = await f.text();
    setParsed(parseGiftCardFile(text));
    // The same file sent twice is one import (the batch key is the file's own hash).
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
    setFileKey(Array.from(new Uint8Array(digest)).slice(0, 16).map((b) => b.toString(16).padStart(2, '0')).join(''));
  };
  const run = async () => {
    if (!parsed?.cards.length) return;
    setBusy(true);
    let created = 0; let dup = 0; let bad = 0;
    try {
      const batches = importBatches<ImportCard>(parsed.cards);
      for (let i = 0; i < batches.length; i++) {
        const r = await importGiftCards(orgId, source, batches[i], `dash:${fileKey}:${i}`);
        created += r.created; dup += r.duplicates; bad += r.errors;
      }
      toast({ kind: bad ? 'error' : 'success', message: `Imported ${created}; ${dup} already there${bad ? `; ${bad} refused` : ''}.` });
      setParsed(null);
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      {perms.importGiftCards && (
        <div className={`${card} space-y-3`}>
          <h2 className="text-sm font-black uppercase tracking-widest flex items-center gap-2"><Upload size={14} /> Import gift cards</h2>
          <p className="text-xs text-slate-500">A CSV from Gift Up! (or any provider) with a code and a balance column. Each card keeps its code and pays at
            checkout like an Exos card; the Exos fee is owed on what an imported card pays, as for box-office cards. A card already imported from the same source is skipped.</p>
          <div className="grid gap-2 sm:grid-cols-3 items-end">
            <div><label className={label} htmlFor="im-src">Source</label>
              <input id="im-src" className={field} value={source} onChange={(e) => setSource(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '').slice(0, 40))} /></div>
            <div><label className={label} htmlFor="im-file">CSV file</label>
              <input id="im-file" type="file" accept=".csv,text/csv" className="text-xs" onChange={(e) => void pick(e.target.files?.[0])} /></div>
            <button type="button" className={btnDark} disabled={busy || !parsed?.cards.length || source.length < 2} onClick={() => void run()}>
              {parsed ? `Import ${parsed.cards.length} card${parsed.cards.length === 1 ? '' : 's'}` : 'Import'}</button>
          </div>
          {parsed && parsed.errors.length > 0 && (
            <ul className="text-xs text-rose-600 max-h-32 overflow-y-auto">{parsed.errors.slice(0, 50).map((e) => <li key={e.line}>Line {e.line}: {e.error}</li>)}</ul>
          )}
        </div>
      )}
      <div className="grid gap-2 sm:grid-cols-3 items-end">
        <div><label className={label} htmlFor="ic-search">Search</label><input id="ic-search" className={field} value={filter.search} placeholder="Last 4, email" onChange={(e) => set({ search: e.target.value })} /></div>
        <div><label className={label} htmlFor="ic-src">Source</label>
          <select id="ic-src" className={field} value={filter.source} onChange={(e) => set({ source: e.target.value })}>
            <option value="all">All sources</option>{sources.map((s) => <option key={s} value={s}>{s}</option>)}
          </select></div>
        <div><label className={label} htmlFor="ic-state">State</label>
          <select id="ic-state" className={field} value={filter.state} onChange={(e) => set({ state: e.target.value as ImportedCardFilter['state'] })}>
            <option value="all">All</option><option value="with_balance">With balance</option><option value="spent">Spent</option><option value="expired">Expired</option><option value="voided">Voided</option>
          </select></div>
      </div>
      <div className={`${card} overflow-x-auto p-0`}>
        <table className="w-full text-sm">
          <thead className="border-b border-slate-100"><tr>
            <SortTh k="last4" sort={sort} onSort={setSort}>Card</SortTh>
            <SortTh k="balance_cents" sort={sort} onSort={setSort} first="desc" right>Balance</SortTh>
            <SortTh k="initial_cents" sort={sort} onSort={setSort} first="desc" right>Value</SortTh>
            <th scope="col" className="px-3 py-2 text-left text-[10px] font-black uppercase tracking-widest text-slate-400">Source</th>
            <SortTh k="expires_at" sort={sort} onSort={setSort}>Expires</SortTh>
            <SortTh k="created_at" sort={sort} onSort={setSort} first="desc">Imported</SortTh>
          </tr></thead>
          <tbody>
            {view.rows.map((c) => (
              <tr key={c.id} className="border-b border-slate-50 last:border-0">
                <td className="px-3 py-2 font-mono">…{c.last4}{c.status === 'voided' && <> <Badge s="voided" /></>}<span className="block text-xs text-slate-400 font-sans">{c.recipient_email ?? ''}</span></td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(c.balance_cents, c.currency)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(c.initial_cents, c.currency)}</td>
                <td className="px-3 py-2 text-xs">{c.external_source ?? '—'}</td>
                <td className="px-3 py-2 text-xs text-slate-500">{day(c.expires_at)}</td>
                <td className="px-3 py-2 text-xs text-slate-500">{day(c.created_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows === null ? <p className="text-xs text-slate-400">Loading…</p> : <Pager {...view} onPage={setPage} />}
    </div>
  );
}
