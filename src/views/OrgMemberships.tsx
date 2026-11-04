// /orgs/:orgId/memberships — membership products, members and imported
// attendees as tables (mig 20261102100000, docs/memberships.md).
//
//   Products   every product with its status (draft, on sale, off sale,
//              archived) and live members; create (as a draft), edit,
//              publish / unpublish / archive. Archiving is final.
//   Members    every membership: filter by status / product, search, sort,
//              page; issue one (comp, or paid somewhere else), rename, notes,
//              move the end date, cancel / reactivate where staff may.
//   Imported   attendees imported from other platforms (door imports):
//              search, filter by event / source, edit, delete.
//
// Roles (membershipRoles): owner / manager write; finance reads products and
// members; imported attendees are owner / manager only. Write buttons are
// hidden from roles that can't use them; the RPCs re-check every write.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { formatCurrency } from '../lib/utils';
import { listOrgEvents } from '../lib/events';
import {
  attendeeChanges, canEditProduct, EMPTY_PRODUCT_FORM, endOfDayIso, issueFields, MEMBER_STATUS_LABEL, memberActions,
  memberLockReason, membershipRoles, pageCount, PRODUCT_STATUS_LABEL, PRODUCT_STATUSES, productActions, productFields,
  productToForm, rangeLabel, sortIndicator, tablePage, toggleSort, type ProductForm, type ProductStatus, type SortState,
} from '../lib/membershipAdmin';
import {
  deleteImportedAttendee, issueMembership, listAdminMemberships, listAdminProducts, listImportedAttendees,
  saveAdminProduct, transitionProduct, updateImportedAttendee, updateMembership,
  type AdminMembership, type AdminProduct, type ImportedAttendee,
} from '../lib/membershipAdminApi';
import { BTN, BTN_PRIMARY, FLD, LABEL, Section } from '../components/finance/ui';
import type { Event } from '../types';

type Tab = 'products' | 'members' | 'imported';
const PER_PAGE = 25;
const day = (iso: string | null | undefined) => (iso ? iso.slice(0, 10) : '—');

const STATUS_TONE: Record<string, string> = {
  draft: 'bg-slate-100 text-slate-600', published: 'bg-green-50 text-green-700', unpublished: 'bg-amber-50 text-amber-700',
  archived: 'bg-slate-200 text-slate-500', active: 'bg-green-50 text-green-700', past_due: 'bg-amber-50 text-amber-700',
  cancelled: 'bg-red-50 text-red-700', expired: 'bg-slate-200 text-slate-500', pending: 'bg-blue-50 text-blue-700',
};
function Badge({ status, label }: { status: string; label: string }) {
  return <span className={`inline-block px-2 py-0.5 rounded text-[10px] font-black uppercase tracking-widest ${STATUS_TONE[status] ?? 'bg-slate-100'}`}>{label}</span>;
}

function SortTh<K extends string>({ label, k, sort, onSort, right }: { label: string; k: K; sort: SortState<K>; onSort: (k: K) => void; right?: boolean }) {
  return (
    <th className={`p-3 ${right ? 'text-right' : ''}`} aria-sort={sort.key === k ? (sort.desc ? 'descending' : 'ascending') : 'none'}>
      <button type="button" className="uppercase tracking-widest hover:text-slate-900" onClick={() => onSort(k)}>
        {label} {sortIndicator(sort, k)}
      </button>
    </th>
  );
}

function Pager({ page, total, onPage }: { page: number; total: number; onPage: (p: number) => void }) {
  const pages = pageCount(total, PER_PAGE);
  return (
    <div className="flex items-center justify-between gap-2 p-3 text-xs text-slate-500">
      <span>{rangeLabel(page, PER_PAGE, total)}</span>
      <span className="flex gap-2">
        <button type="button" className={BTN} disabled={page <= 1} onClick={() => onPage(page - 1)}>Previous</button>
        <button type="button" className={BTN} disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</button>
      </span>
    </div>
  );
}

export default function OrgMemberships() {
  const { orgId = '' } = useParams();
  const { user, isAdmin } = useAuth();
  const { orgs, loading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const roles = membershipRoles(entry?.membership.role, isAdmin);
  const [params, setParams] = useSearchParams();
  const tabs: { id: Tab; label: string; show: boolean }[] = [
    { id: 'products', label: 'Products', show: roles.canRead },
    { id: 'members', label: 'Members', show: roles.canRead },
    { id: 'imported', label: 'Imported attendees', show: roles.canImports },
  ];
  const visible = tabs.filter((t) => t.show);
  const tab: Tab = visible.find((t) => t.id === params.get('tab'))?.id ?? 'products';
  const [products, setProducts] = useState<AdminProduct[]>([]);
  const { toast } = useToast();
  const reloadProducts = useCallback(() => {
    if (!orgId || !roles.canRead) return;
    listAdminProducts(orgId).then(setProducts).catch((e) => toast({ kind: 'error', message: (e as Error).message }));
  }, [orgId, roles.canRead, toast]);
  useEffect(reloadProducts, [reloadProducts]);

  if (!user) return <div className="p-8 text-sm text-slate-500">Sign in required.</div>;
  if (!loading && !roles.canRead) return <div className="p-8 text-sm text-slate-500">Memberships are for the organization's owners, managers and finance team.</div>;

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to={`/orgs/${orgId}/settings`} className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Org settings</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Memberships</h1>
      <p className="text-sm text-slate-500 mb-6">{entry?.org.name} · products, members and attendees imported from other platforms. Editing a product changes nothing for current members: they keep the benefits and price they joined with.</p>
      <div role="tablist" className="flex gap-1 border-b border-slate-200 mb-6">
        {visible.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} onClick={() => setParams({ tab: t.id }, { replace: true })}
            className={`px-4 py-3 text-xs font-bold uppercase tracking-widest border-b-2 -mb-px ${tab === t.id ? 'border-[#026cdf] text-slate-900' : 'border-transparent text-slate-400'}`}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'products' && <ProductsTab orgId={orgId} products={products} canWrite={roles.canWrite} reload={reloadProducts} />}
      {tab === 'members' && <MembersTab orgId={orgId} products={products} canWrite={roles.canWrite} />}
      {tab === 'imported' && roles.canImports && <ImportedTab orgId={orgId} />}
    </div>
  );
}

// ── Products ───────────────────────────────────────────────────────────────

type ProductSort = 'name' | 'price_cents' | 'status' | 'members_count' | 'created_at';

function ProductsTab({ orgId, products, canWrite, reload }: { orgId: string; products: AdminProduct[]; canWrite: boolean; reload: () => void }) {
  const { toast } = useToast();
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<'live' | 'all' | ProductStatus>('live');
  const [sort, setSort] = useState<SortState<ProductSort>>({ key: 'created_at', desc: true });
  const [page, setPage] = useState(1);
  const [editing, setEditing] = useState<{ id: string | null; form: ProductForm; before?: AdminProduct } | null>(null);
  const [busy, setBusy] = useState(false);

  const view = useMemo(() => tablePage(products, {
    search, searchIn: ['name', 'description'], sort, page, perPage: PER_PAGE,
    filter: (p) => (status === 'all' ? true : status === 'live' ? p.status !== 'archived' : p.status === status),
  }), [products, search, sort, page, status]);
  useEffect(() => setPage(1), [search, status]);

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try { await fn(); toast({ kind: 'success', message: ok }); reload(); }
    catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
    finally { setBusy(false); }
  };
  const save = async () => {
    if (!editing) return;
    let fields: Record<string, unknown>;
    try { fields = productFields(editing.form, editing.id ? 'update' : 'create', editing.before as unknown as Record<string, unknown>); }
    catch (e) { toast({ kind: 'error', message: (e as Error).message }); return; }
    if (editing.id && Object.keys(fields).length === 0) { setEditing(null); return; }
    await act(async () => { await saveAdminProduct(orgId, editing.id, fields); setEditing(null); },
      editing.id ? 'Saved. Current members keep what they joined with.' : 'Created as a draft: publish it to put it on sale.');
  };
  const transition = (p: AdminProduct, a: 'publish' | 'unpublish' | 'archive') => {
    if (a === 'archive' && !window.confirm(`Archive "${p.name}"? It goes off sale for good and can't be published again. ${p.members_count} current member(s) keep their benefits until their period ends.`)) return;
    void act(() => transitionProduct(p.id, a), a === 'publish' ? 'On sale.' : a === 'unpublish' ? 'Off sale.' : 'Archived.');
  };
  const onSort = (k: ProductSort) => setSort(toggleSort(sort, k, ['created_at', 'members_count']));

  return (
    <>
      <div className="flex flex-wrap gap-2 items-end mb-3">
        <label className="flex-1 min-w-[200px]"><span className={LABEL}>Search</span>
          <input className={FLD} value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Name" maxLength={100} /></label>
        <label><span className={LABEL}>Status</span>
          <select className={FLD} value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
            <option value="live">Not archived</option><option value="all">All</option>
            {PRODUCT_STATUSES.map((s) => <option key={s} value={s}>{PRODUCT_STATUS_LABEL[s]}</option>)}
          </select></label>
        {canWrite && <button className={BTN_PRIMARY} onClick={() => setEditing({ id: null, form: { ...EMPTY_PRODUCT_FORM } })}>New membership</button>}
      </div>
      {editing && <ProductEditor editing={editing} setEditing={setEditing} onSave={save} busy={busy} />}
      <div className="bg-white border border-slate-200 rounded overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
            <SortTh label="Name" k="name" sort={sort} onSort={onSort} />
            <SortTh label="Price" k="price_cents" sort={sort} onSort={onSort} />
            <th className="p-3">Benefits</th>
            <SortTh label="Members" k="members_count" sort={sort} onSort={onSort} right />
            <SortTh label="Status" k="status" sort={sort} onSort={onSort} />
            <SortTh label="Created" k="created_at" sort={sort} onSort={onSort} />
            {canWrite && <th className="p-3 text-right">Actions</th>}
          </tr></thead>
          <tbody>
            {view.rows.map((p) => (
              <tr key={p.id} className="border-t border-slate-100">
                <td className="p-3 font-bold text-slate-900">{p.name}</td>
                <td className="p-3 whitespace-nowrap">{formatCurrency(p.price_cents / 100, p.currency)} / {p.billing === 'once' ? `${p.duration_days} days` : p.billing}</td>
                <td className="p-3 text-xs text-slate-500">{Number(p.discount_percent)}% off{p.presale ? ' · presales' : ''}{p.free_tickets_per_period ? ` · ${p.free_tickets_per_period} free / period` : ''}{p.household_seats ? ` · ${p.household_seats} household` : ''}</td>
                <td className="p-3 text-right tabular-nums">{p.members_count}</td>
                <td className="p-3"><Badge status={p.status} label={PRODUCT_STATUS_LABEL[p.status]} /></td>
                <td className="p-3 whitespace-nowrap">{day(p.created_at)}</td>
                {canWrite && (
                  <td className="p-3 text-right whitespace-nowrap space-x-1">
                    {canEditProduct(p.status) && <button className={BTN} disabled={busy} onClick={() => setEditing({ id: p.id, form: productToForm(p as unknown as Record<string, unknown>), before: p })}>Edit</button>}
                    {productActions(p.status).map((a) => (
                      <button key={a} className={BTN} disabled={busy} onClick={() => transition(p, a)}>{a}</button>
                    ))}
                  </td>
                )}
              </tr>
            ))}
            {!view.rows.length && <tr><td colSpan={canWrite ? 7 : 6} className="p-6 text-center text-slate-400">No membership products here.</td></tr>}
          </tbody>
        </table>
        <Pager page={view.page} total={view.total} onPage={setPage} />
      </div>
    </>
  );
}

function ProductEditor({ editing, setEditing, onSave, busy }: {
  editing: { id: string | null; form: ProductForm; before?: AdminProduct };
  setEditing: (e: { id: string | null; form: ProductForm; before?: AdminProduct } | null) => void;
  onSave: () => void; busy: boolean;
}) {
  const f = editing.form;
  const set = (patch: Partial<ProductForm>) => setEditing({ ...editing, form: { ...f, ...patch } });
  const num = (k: keyof ProductForm, label: string) => (
    <label><span className={LABEL}>{label}</span><input className={FLD} inputMode="numeric" value={f[k] as string} onChange={(e) => set({ [k]: e.target.value } as Partial<ProductForm>)} /></label>
  );
  return (
    <Section title={editing.id ? `Edit ${editing.before?.name ?? 'membership'}` : 'New membership (draft)'}>
      <div className="grid gap-3 sm:grid-cols-4 mb-3">
        <label className="sm:col-span-2"><span className={LABEL}>Name</span><input className={FLD} maxLength={120} value={f.name} onChange={(e) => set({ name: e.target.value })} /></label>
        <label><span className={LABEL}>Price</span><input className={FLD} inputMode="decimal" value={f.price} onChange={(e) => set({ price: e.target.value })} /></label>
        <label><span className={LABEL}>Billing{editing.id ? ' (set once)' : ''}</span>
          <select className={FLD} value={f.billing} disabled={!!editing.id} onChange={(e) => set({ billing: e.target.value as ProductForm['billing'] })}>
            <option value="month">Monthly</option><option value="year">Yearly</option><option value="once">One-time term</option>
          </select></label>
        <label className="sm:col-span-4"><span className={LABEL}>Description</span><input className={FLD} maxLength={2000} value={f.description} onChange={(e) => set({ description: e.target.value })} /></label>
        {num('discount_percent', '% off tickets')}
        {num('free_tickets_per_period', 'Free tickets / period')}
        {num('guest_allowance', 'Guests')}
        {num('household_seats', 'Household seats')}
        {f.billing === 'once' && num('duration_days', 'Term (days)')}
        <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={f.presale} onChange={(e) => set({ presale: e.target.checked })} /> Member presales</label>
        <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={f.giftable} onChange={(e) => set({ giftable: e.target.checked })} /> Can be gifted</label>
      </div>
      <div className="flex gap-2">
        <button className={BTN_PRIMARY} disabled={busy} onClick={onSave}>{editing.id ? 'Save' : 'Create draft'}</button>
        <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
      </div>
      {editing.id && <p className="text-xs text-slate-400 mt-2">New price and benefits apply to new members; current members keep theirs.</p>}
    </Section>
  );
}

// ── Members ────────────────────────────────────────────────────────────────

type MemberSort = 'created_at' | 'current_period_end' | 'holder_email' | 'product_name' | 'status';

function MembersTab({ orgId, products, canWrite }: { orgId: string; products: AdminProduct[]; canWrite: boolean }) {
  const { toast } = useToast();
  const [status, setStatus] = useState('');
  const [productId, setProductId] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<SortState<MemberSort>>({ key: 'created_at', desc: true });
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ total: number; rows: AdminMembership[] } | null>(null);
  const [issuing, setIssuing] = useState(false);
  const [editing, setEditing] = useState<{ m: AdminMembership; name: string; notes: string; ends: string } | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await listAdminMemberships(orgId, { status, productId, search: query, sort: sort.key, desc: sort.desc, limit: PER_PAGE, offset: (page - 1) * PER_PAGE }));
    } catch (e) { toast({ kind: 'error', message: (e as Error).message }); setData({ total: 0, rows: [] }); }
  }, [orgId, status, productId, query, sort, page, toast]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => setPage(1), [status, productId, query, sort]);

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try { await fn(); toast({ kind: 'success', message: ok }); setEditing(null); void load(); }
    catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  const onSort = (k: MemberSort) => setSort(toggleSort(sort, k, ['created_at', 'current_period_end']));
  const issuable = products.filter((p) => p.status !== 'archived');

  return (
    <>
      <div className="flex flex-wrap gap-2 items-end mb-3">
        <form className="flex gap-2 flex-1 min-w-[220px] items-end" onSubmit={(e) => { e.preventDefault(); setQuery(search); }}>
          <label className="flex-1"><span className={LABEL}>Search</span>
            <input className={FLD} value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Email, name or product" maxLength={100} /></label>
          <button type="submit" className={BTN}>Search</button>
        </form>
        <label><span className={LABEL}>Status</span>
          <select className={FLD} value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">Any</option>
            {Object.entries(MEMBER_STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
        <label><span className={LABEL}>Membership</span>
          <select className={FLD} value={productId} onChange={(e) => setProductId(e.target.value)}>
            <option value="">Any</option>
            {products.map((p) => <option key={p.id} value={p.id}>{p.name}{p.status === 'archived' ? ' (archived)' : ''}</option>)}
          </select></label>
        {canWrite && <button className={BTN_PRIMARY} disabled={!issuable.length} onClick={() => setIssuing((v) => !v)}>Issue membership</button>}
      </div>
      {issuing && <IssueForm orgId={orgId} products={issuable} onDone={() => { setIssuing(false); void load(); }} />}
      {editing && (
        <Section title={`Edit ${editing.m.holder_email ?? 'membership'}`}>
          <div className="grid gap-3 sm:grid-cols-3 mb-3">
            <label><span className={LABEL}>Member name</span><input className={FLD} maxLength={120} value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            {memberActions(editing.m).includes('extend') && (
              <label><span className={LABEL}>Ends on</span><input type="date" className={FLD} value={editing.ends} onChange={(e) => setEditing({ ...editing, ends: e.target.value })} /></label>
            )}
            <label className="sm:col-span-3"><span className={LABEL}>Staff notes (never shown to the member)</span><input className={FLD} maxLength={2000} value={editing.notes} onChange={(e) => setEditing({ ...editing, notes: e.target.value })} /></label>
          </div>
          <div className="flex gap-2">
            <button className={BTN_PRIMARY} onClick={() => {
              const fields: Record<string, unknown> = { member_name: editing.name, staff_notes: editing.notes };
              try {
                if (memberActions(editing.m).includes('extend') && editing.ends && editing.ends !== day(editing.m.current_period_end)) fields.expires_at = endOfDayIso(editing.ends);
              } catch (e) { toast({ kind: 'error', message: (e as Error).message }); return; }
              void act(() => updateMembership(editing.m.id, fields), 'Saved.');
            }}>Save</button>
            <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </Section>
      )}
      <div className="bg-white border border-slate-200 rounded overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
            <SortTh label="Member" k="holder_email" sort={sort} onSort={onSort} />
            <SortTh label="Membership" k="product_name" sort={sort} onSort={onSort} />
            <SortTh label="Status" k="status" sort={sort} onSort={onSort} />
            <SortTh label="Ends" k="current_period_end" sort={sort} onSort={onSort} />
            <th className="p-3">Source</th>
            <SortTh label="Since" k="created_at" sort={sort} onSort={onSort} />
            {canWrite && <th className="p-3 text-right">Actions</th>}
          </tr></thead>
          <tbody>
            {(data?.rows ?? []).map((m) => {
              const actions = memberActions(m);
              const lock = memberLockReason(m);
              return (
                <tr key={m.id} className="border-t border-slate-100">
                  <td className="p-3"><span className="block font-bold text-slate-900">{m.member_name || m.holder_email}</span>
                    {m.member_name && <span className="block text-xs text-slate-500">{m.holder_email}</span>}
                    {!m.has_account && <span className="block text-[10px] text-slate-400">No account yet</span>}</td>
                  <td className="p-3">{m.product_name}</td>
                  <td className="p-3"><Badge status={m.effective_status} label={MEMBER_STATUS_LABEL[m.effective_status] ?? m.effective_status} /></td>
                  <td className="p-3 whitespace-nowrap">{day(m.current_period_end)}</td>
                  <td className="p-3 text-xs">{m.source}{m.stripe_billed ? ' · Stripe' : ''}</td>
                  <td className="p-3 whitespace-nowrap">{day(m.created_at)}</td>
                  {canWrite && (
                    <td className="p-3 text-right whitespace-nowrap space-x-1" title={lock ?? undefined}>
                      <button className={BTN} onClick={() => setEditing({ m, name: m.member_name ?? '', notes: m.staff_notes ?? '', ends: day(m.current_period_end) })}>Edit</button>
                      {actions.includes('cancel') && <button className={BTN} onClick={() => {
                        if (window.confirm('Cancel this membership now? Its benefits end today.')) void act(() => updateMembership(m.id, { status: 'cancelled' }), 'Cancelled.');
                      }}>Cancel</button>}
                      {actions.includes('reactivate') && <button className={BTN} onClick={() => {
                        const until = window.prompt('Reactivate until (YYYY-MM-DD)?', '');
                        if (!until) return;
                        try { const iso = endOfDayIso(until); void act(() => updateMembership(m.id, { status: 'active', expires_at: iso }), 'Reactivated.'); }
                        catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
                      }}>Reactivate</button>}
                    </td>
                  )}
                </tr>
              );
            })}
            {data && !data.rows.length && <tr><td colSpan={canWrite ? 7 : 6} className="p-6 text-center text-slate-400">No memberships match.</td></tr>}
          </tbody>
        </table>
        <Pager page={page} total={data?.total ?? 0} onPage={setPage} />
      </div>
    </>
  );
}

function IssueForm({ orgId, products, onDone }: { orgId: string; products: AdminProduct[]; onDone: () => void }) {
  const { toast } = useToast();
  const [f, setF] = useState({ product_id: products[0]?.id ?? '', email: '', member_name: '', source: 'comp' as 'comp' | 'import', expires_on: '', staff_notes: '' });
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true);
    try {
      await issueMembership(orgId, issueFields(f));
      toast({ kind: 'success', message: 'Membership issued. It is active now; with no account yet, it waits for that email.' });
      onDone();
    } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
    finally { setBusy(false); }
  };
  return (
    <Section title="Issue a membership">
      <div className="grid gap-3 sm:grid-cols-3 mb-3">
        <label><span className={LABEL}>Membership</span>
          <select className={FLD} value={f.product_id} onChange={(e) => setF({ ...f, product_id: e.target.value })}>
            {products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select></label>
        <label><span className={LABEL}>Email</span><input className={FLD} type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
        <label><span className={LABEL}>Name</span><input className={FLD} maxLength={120} value={f.member_name} onChange={(e) => setF({ ...f, member_name: e.target.value })} /></label>
        <label><span className={LABEL}>Kind</span>
          <select className={FLD} value={f.source} onChange={(e) => setF({ ...f, source: e.target.value as 'comp' | 'import' })}>
            <option value="comp">Comp (free)</option><option value="import">Paid somewhere else</option>
          </select></label>
        <label><span className={LABEL}>Ends on (blank: one period)</span><input type="date" className={FLD} value={f.expires_on} onChange={(e) => setF({ ...f, expires_on: e.target.value })} /></label>
        <label><span className={LABEL}>Staff notes</span><input className={FLD} maxLength={2000} value={f.staff_notes} onChange={(e) => setF({ ...f, staff_notes: e.target.value })} /></label>
      </div>
      <button className={BTN_PRIMARY} disabled={busy} onClick={() => void submit()}>Issue</button>
      <p className="text-xs text-slate-400 mt-2">No card is charged. To send it as a gift the member claims, use Comp a membership in Org settings.</p>
    </Section>
  );
}

// ── Imported attendees ─────────────────────────────────────────────────────

type ImportSort = 'created_at' | 'guest_name' | 'event' | 'source';

function ImportedTab({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [events, setEvents] = useState<Event[]>([]);
  const [eventId, setEventId] = useState('');
  const [source, setSource] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<SortState<ImportSort>>({ key: 'created_at', desc: true });
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ total: number; rows: ImportedAttendee[] } | null>(null);
  const [editing, setEditing] = useState<{ a: ImportedAttendee; guest_name: string; email: string; code: string; ticket_label: string; note: string } | null>(null);

  useEffect(() => { listOrgEvents(orgId).then(setEvents).catch(() => setEvents([])); }, [orgId]);
  const load = useCallback(async () => {
    try {
      setData(await listImportedAttendees(orgId, { eventId, source, search: query, sort: sort.key, desc: sort.desc, limit: PER_PAGE, offset: (page - 1) * PER_PAGE }));
    } catch (e) { toast({ kind: 'error', message: (e as Error).message }); setData({ total: 0, rows: [] }); }
  }, [orgId, eventId, source, query, sort, page, toast]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => setPage(1), [eventId, source, query, sort]);
  const onSort = (k: ImportSort) => setSort(toggleSort(sort, k, ['created_at', 'event']));
  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try { await fn(); toast({ kind: 'success', message: ok }); setEditing(null); void load(); }
    catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };

  return (
    <>
      <div className="flex flex-wrap gap-2 items-end mb-3">
        <form className="flex gap-2 flex-1 min-w-[220px] items-end" onSubmit={(e) => { e.preventDefault(); setQuery(search); }}>
          <label className="flex-1"><span className={LABEL}>Search</span>
            <input className={FLD} value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Name, email or code" maxLength={100} /></label>
          <button type="submit" className={BTN}>Search</button>
        </form>
        <label><span className={LABEL}>Event</span>
          <select className={FLD} value={eventId} onChange={(e) => setEventId(e.target.value)}>
            <option value="">Any</option>
            {events.map((ev) => <option key={ev.id} value={ev.id}>{ev.name}</option>)}
          </select></label>
        <label><span className={LABEL}>Source</span><input className={FLD} value={source} maxLength={40} placeholder="e.g. Posh" onChange={(e) => setSource(e.target.value)} /></label>
      </div>
      <p className="text-xs text-slate-500 mb-3">Attendees from door imports of other platforms' exports. Import more from an event's guest lists. Rows synced from Eventbrite change there.</p>
      {editing && (
        <Section title={`Edit ${editing.a.guest_name}`}>
          <div className="grid gap-3 sm:grid-cols-3 mb-3">
            <label><span className={LABEL}>Name</span><input className={FLD} maxLength={80} value={editing.guest_name} onChange={(e) => setEditing({ ...editing, guest_name: e.target.value })} /></label>
            <label><span className={LABEL}>Email</span><input className={FLD} type="email" value={editing.email} onChange={(e) => setEditing({ ...editing, email: e.target.value })} /></label>
            <label><span className={LABEL}>Code{editing.a.arrived ? ' (checked in: fixed)' : ''}</span><input className={FLD} maxLength={128} disabled={editing.a.arrived > 0} value={editing.code} onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label><span className={LABEL}>Ticket</span><input className={FLD} maxLength={80} value={editing.ticket_label} onChange={(e) => setEditing({ ...editing, ticket_label: e.target.value })} /></label>
            <label className="sm:col-span-2"><span className={LABEL}>Note</span><input className={FLD} maxLength={200} value={editing.note} onChange={(e) => setEditing({ ...editing, note: e.target.value })} /></label>
          </div>
          <div className="flex gap-2">
            <button className={BTN_PRIMARY} onClick={() => {
              let fields: Record<string, unknown>;
              try { fields = attendeeChanges(editing.a, editing); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); return; }
              if (!Object.keys(fields).length) { setEditing(null); return; }
              void act(() => updateImportedAttendee(editing.a.id, fields), 'Saved.');
            }}>Save</button>
            <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </Section>
      )}
      <div className="bg-white border border-slate-200 rounded overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
            <SortTh label="Attendee" k="guest_name" sort={sort} onSort={onSort} />
            <SortTh label="Event" k="event" sort={sort} onSort={onSort} />
            <th className="p-3">Code</th><th className="p-3">Ticket</th>
            <SortTh label="Source" k="source" sort={sort} onSort={onSort} />
            <th className="p-3">Door</th>
            <SortTh label="Imported" k="created_at" sort={sort} onSort={onSort} />
            <th className="p-3 text-right">Actions</th>
          </tr></thead>
          <tbody>
            {(data?.rows ?? []).map((a) => (
              <tr key={a.id} className="border-t border-slate-100">
                <td className="p-3"><span className="block font-bold text-slate-900">{a.guest_name}{a.plus_ones ? ` +${a.plus_ones}` : ''}</span><span className="block text-xs text-slate-500">{a.email}</span></td>
                <td className="p-3"><span className="block">{a.event_name}</span><span className="block text-xs text-slate-500">{day(a.starts_at)} · {a.list_name}</span></td>
                <td className="p-3 font-mono text-xs">{a.code ?? '—'}</td>
                <td className="p-3">{a.ticket_label ?? '—'}</td>
                <td className="p-3">{a.source ?? '—'}{a.synced ? ' (synced)' : ''}</td>
                <td className="p-3">{a.voided ? <Badge status="cancelled" label="Voided" /> : a.arrived ? <Badge status="active" label="Checked in" /> : '—'}</td>
                <td className="p-3 whitespace-nowrap">{day(a.created_at)}</td>
                <td className="p-3 text-right whitespace-nowrap space-x-1">
                  {!a.synced && !a.voided && <button className={BTN} onClick={() => setEditing({ a, guest_name: a.guest_name, email: a.email ?? '', code: a.code ?? '', ticket_label: a.ticket_label ?? '', note: a.note ?? '' })}>Edit</button>}
                  {!a.synced && !a.arrived && <button className={BTN} onClick={() => {
                    if (window.confirm(`Delete ${a.guest_name} from ${a.event_name}? Their code stops working at the door.`)) void act(() => deleteImportedAttendee(a.id), 'Deleted.');
                  }}>Delete</button>}
                </td>
              </tr>
            ))}
            {data && !data.rows.length && <tr><td colSpan={8} className="p-6 text-center text-slate-400">No imported attendees match.</td></tr>}
          </tbody>
        </table>
        <Pager page={page} total={data?.total ?? 0} onPage={setPage} />
      </div>
    </>
  );
}
