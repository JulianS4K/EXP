// /orgs/:orgId/finance — profit and loss across shows (forecast, estimate,
// actual; CSV), finance categories and the chart of accounts
// (docs/offers-settlements.md). Owner / manager / finance.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import {
  deleteCategory, discardGlCode, getPnlInputs, listCategories, listGlCodes, saveCategory, saveGlCode,
  type CategoryRow, type GlCodeRow,
} from '../lib/offersApi';
import { orgPnl, orgPnlCsv, PNL_COLUMNS } from '../lib/dealMath';
import { downloadCsv } from '../lib/csv';
import { BTN, BTN_PRIMARY, FLD, LABEL, Money, Section } from '../components/finance/ui';

const day = (d: Date) => d.toISOString().slice(0, 10);

export default function OrgFinance() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [from, setFrom] = useState(() => day(new Date(Date.now() - 30 * 86_400_000)));
  const [to, setTo] = useState(() => day(new Date(Date.now() + 90 * 86_400_000)));
  const [raw, setRaw] = useState<Awaited<ReturnType<typeof getPnlInputs>> | null>(null);
  const [cats, setCats] = useState<CategoryRow[]>([]);
  const [codes, setCodes] = useState<GlCodeRow[]>([]);
  const [newCat, setNewCat] = useState({ name: '', kind: 'expense' as CategoryRow['kind'] });
  const [newCode, setNewCode] = useState({ code: '', name: '' });

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const effectiveRole = isAdmin ? 'owner' : role;
  const canView = effectiveRole === 'owner' || effectiveRole === 'manager' || effectiveRole === 'finance';

  const loadSetup = useCallback(async () => {
    if (!orgId || !canView) return;
    try {
      const [c, g] = await Promise.all([listCategories(orgId), listGlCodes(orgId)]);
      setCats(c); setCodes(g);
    } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  }, [orgId, canView, toast]);
  useEffect(() => { loadSetup(); }, [loadSetup]);

  const loadPnl = useCallback(async () => {
    if (!orgId || !canView) return;
    try { setRaw(await getPnlInputs(orgId, from, to)); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  }, [orgId, canView, from, to, toast]);
  useEffect(() => { loadPnl(); }, [loadPnl]);

  const pnl = useMemo(() => (raw ? orgPnl(raw.shows) : null), [raw]);
  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!canView || !orgId) return <div className="p-8 text-sm text-slate-500">Finance is for owners, managers and finance staff.</div>;

  const act = async (fn: () => Promise<void>) => {
    try { await fn(); await loadSetup(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Dashboard</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Finance</h1>
      <p className="text-sm text-slate-500 mb-6">{orgName} · profit and loss across shows, finance categories and ledger codes.</p>

      <Section title="Profit and loss" action={pnl && <button className={BTN} onClick={() => downloadCsv(`profit-and-loss-${from}-${to}.csv`, orgPnlCsv(pnl))}>CSV</button>}>
        <div className="flex flex-wrap gap-2 items-end mb-4">
          <label><span className={LABEL}>From</span><input type="date" className={FLD} value={from} onChange={(e) => setFrom(e.target.value)} /></label>
          <label><span className={LABEL}>To</span><input type="date" className={FLD} value={to} onChange={(e) => setTo(e.target.value)} /></label>
          <span className="text-xs text-slate-400">Shows starting in the range, at most 366 days and 100 shows{raw?.truncated ? ' (more exist: narrow the range)' : ''}.</span>
        </div>
        {pnl && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead><tr className="text-[10px] uppercase tracking-widest text-slate-400 text-right">
                <th className="text-left py-1">Show</th><th>Gross</th><th>Expenses</th><th>Payouts</th>
                {PNL_COLUMNS.map((c) => <th key={c}>Net {c}</th>)}
              </tr></thead>
              <tbody>
                {pnl.shows.map((s) => (
                  <tr key={s.eventId} className="border-t border-slate-100 text-right">
                    <td className="text-left py-1.5"><Link className="text-tm-blue" to={`/dashboard/event/${s.eventId}?tab=settlement`}>{s.name}</Link>
                      <span className="text-xs text-slate-400"> {s.startsAt ? new Date(s.startsAt).toLocaleDateString() : ''}{s.finalized ? ' · settled' : ''}</span></td>
                    <td><Money cents={s.gross} currency={s.currency} /></td>
                    <td><Money cents={-s.expenses} currency={s.currency} /></td>
                    <td><Money cents={-s.payouts} currency={s.currency} /></td>
                    {PNL_COLUMNS.map((c) => <td key={c}><Money cents={s.net[c]} currency={s.currency} /></td>)}
                  </tr>
                ))}
                {pnl.totals.map((t) => (
                  <tr key={t.currency} className="border-t-2 border-slate-200 font-bold text-right">
                    <td className="text-left py-1.5">Total, {t.shows} show{t.shows === 1 ? '' : 's'} ({t.currency})</td>
                    <td><Money cents={t.gross} currency={t.currency} /></td>
                    <td><Money cents={-t.expenses} currency={t.currency} /></td>
                    <td><Money cents={-t.payouts} currency={t.currency} /></td>
                    {PNL_COLUMNS.map((c) => <td key={c}><Money cents={t.net[c]} currency={t.currency} /></td>)}
                  </tr>
                ))}
                {!pnl.shows.length && <tr><td colSpan={7} className="p-6 text-center text-slate-400">No shows in this range.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </Section>

      <Section title="Finance categories">
        <table className="w-full text-sm">
          <tbody>
            {cats.map((c) => (
              <tr key={c.id} className="border-t border-slate-100">
                <td className="py-1.5"><input className={FLD} defaultValue={c.name} maxLength={60}
                  onBlur={(e) => e.target.value.trim() && e.target.value.trim() !== c.name && act(() => saveCategory(orgId, { name: e.target.value.trim() }, c.id))} /></td>
                <td className="text-xs text-slate-500 px-2">{c.kind}{c.system ? ' · built in' : ''}</td>
                <td className="w-56"><select className={FLD} value={c.gl_code_id ?? ''} onChange={(e) => act(() => saveCategory(orgId, { gl_code_id: e.target.value || null }, c.id))}>
                  <option value="">No ledger code</option>{codes.map((g) => <option key={g.id} value={g.id}>{g.code} {g.name}</option>)}</select></td>
                <td className="w-20 text-right">{!c.system && <button className={BTN} onClick={() => act(() => deleteCategory(c.id))}>×</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="flex gap-2 items-end mt-3">
          <label className="flex-1"><span className={LABEL}>New category</span><input className={FLD} value={newCat.name} maxLength={60} onChange={(e) => setNewCat({ ...newCat, name: e.target.value })} /></label>
          <label><span className={LABEL}>Kind</span><select className={FLD} value={newCat.kind} onChange={(e) => setNewCat({ ...newCat, kind: e.target.value as CategoryRow['kind'] })}>
            <option value="expense">Expense</option><option value="income">Income</option><option value="both">Both</option></select></label>
          <button className={BTN_PRIMARY} disabled={!newCat.name.trim()} onClick={() => act(async () => { await saveCategory(orgId, { name: newCat.name.trim(), kind: newCat.kind, position: 500 }); setNewCat({ name: '', kind: 'expense' }); })}>Add</button>
        </div>
      </Section>

      <Section title="Ledger codes">
        <table className="w-full text-sm">
          <tbody>
            {codes.map((g) => (
              <tr key={g.id} className="border-t border-slate-100">
                <td className="py-1.5 w-32 font-mono">{g.code}</td>
                <td>{g.name}</td>
                <td className="text-xs text-slate-500">{g.kind}</td>
                <td className="w-20 text-right"><button className={BTN} onClick={() => act(() => discardGlCode(g.id))}>Discard</button></td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="flex gap-2 items-end mt-3">
          <label><span className={LABEL}>Code</span><input className={FLD} value={newCode.code} maxLength={24} onChange={(e) => setNewCode({ ...newCode, code: e.target.value })} /></label>
          <label className="flex-1"><span className={LABEL}>Name</span><input className={FLD} value={newCode.name} maxLength={100} onChange={(e) => setNewCode({ ...newCode, name: e.target.value })} /></label>
          <button className={BTN_PRIMARY} disabled={!newCode.code.trim() || !newCode.name.trim()} onClick={() => act(async () => { await saveGlCode(orgId, { code: newCode.code.trim(), name: newCode.name.trim() }); setNewCode({ code: '', name: '' }); })}>Add</button>
        </div>
      </Section>
    </div>
  );
}
