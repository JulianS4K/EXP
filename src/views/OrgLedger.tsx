// /orgs/:orgId/finance/ledger — the reporting-row feed (every money line with
// the ledger code it posts to; CSV for the accounting tool), imported ledger
// entries (CSV import, delete) and the ledger code of each revenue type
// (mig 20261102120000). Owner / manager / finance: all three read and write
// here; anyone else gets the notice and no rows (RLS).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, FileUp } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import { listGlCodes, type GlCodeRow } from '../lib/offersApi';
import {
  deleteImportedEntry, importLedgerEntries, listImportedEntries, listOrgEvents, listReportingRows, listRevenueCodes, setRevenueCode,
  type ImportedEntryRow, type ReportingRow, type RevenueCodeRow,
} from '../lib/financeExtrasApi';
import {
  IMPORT_SOURCES, label, PAYMENT_METHOD_LABEL, planLedgerImport, REVENUE_TYPE_LABEL, REVENUE_TYPES,
  reportingRowsCsv, SOURCE_TYPE_LABEL, totalsByCurrency,
} from '../lib/financeTables';
import { filterOptions, initialTable, type TableState } from '../lib/dataTable';
import { downloadCsv } from '../lib/csv';
import DataTable, { type DataColumn } from '../components/DataTable';
import { BTN, BTN_PRIMARY, FLD, LABEL, Money, Section } from '../components/finance/ui';

type Tab = 'rows' | 'imports' | 'codes';
const day = (d: Date) => d.toISOString().slice(0, 10);
const opts = (values: string[], map: Record<string, string>) => values.map((v) => ({ value: v, label: label(map, v) }));

export default function OrgLedger() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [tab, setTab] = useState<Tab>('rows');
  const [from, setFrom] = useState(() => day(new Date(Date.now() - 90 * 86_400_000)));
  const [to, setTo] = useState(() => day(new Date(Date.now() + 86_400_000)));
  const [rows, setRows] = useState<ReportingRow[]>([]);
  const [truncated, setTruncated] = useState(false);
  const [entries, setEntries] = useState<ImportedEntryRow[]>([]);
  const [codes, setCodes] = useState<GlCodeRow[]>([]);
  const [revenue, setRevenue] = useState<RevenueCodeRow[]>([]);
  const [events, setEvents] = useState<{ id: string; name: string; starts_at: string | null }[]>([]);
  const [rowTable, setRowTable] = useState<TableState>(() => initialTable('occurred_at', 'desc', 50));
  const [entryTable, setEntryTable] = useState<TableState>(() => initialTable('posted_at', 'desc'));
  const [importEvent, setImportEvent] = useState('');
  const [importSystem, setImportSystem] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const effectiveRole = isAdmin ? 'owner' : role;
  const canView = effectiveRole === 'owner' || effectiveRole === 'manager' || effectiveRole === 'finance';
  // Ledger codes and imports are finance's work too (as GL codes): the same three roles write.
  const canWrite = canView;

  const fail = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);
  const loadSetup = useCallback(async () => {
    if (!orgId || !canView) return;
    try {
      const [g, r, e, ev] = await Promise.all([listGlCodes(orgId), listRevenueCodes(orgId), listImportedEntries(orgId), listOrgEvents(orgId)]);
      setCodes(g); setRevenue(r); setEntries(e); setEvents(ev);
    } catch (e) { fail(e); }
  }, [orgId, canView, fail]);
  useEffect(() => { loadSetup(); }, [loadSetup]);
  const loadRows = useCallback(async () => {
    if (!orgId || !canView) return;
    try {
      const r = await listReportingRows(orgId, new Date(from).toISOString(), new Date(to).toISOString());
      setRows(r.rows); setTruncated(r.truncated);
    } catch (e) { fail(e); }
  }, [orgId, canView, from, to, fail]);
  useEffect(() => { loadRows(); }, [loadRows]);

  const eventName = useMemo(() => {
    const m = new Map(events.map((e) => [e.id, e.name]));
    return (id: string | null) => (id ? m.get(id) ?? '' : '');
  }, [events]);

  const rowColumns = useMemo<DataColumn<ReportingRow>[]>(() => [
    { key: 'occurred_at', header: 'Date', value: (r) => r.occurred_at, render: (r) => new Date(r.occurred_at).toLocaleString() },
    { key: 'event', header: 'Event', value: (r) => eventName(r.event_id), searchable: true },
    { key: 'source_type', header: 'Source', value: (r) => r.source_type, render: (r) => (
      <span>{label(SOURCE_TYPE_LABEL, r.source_type)}{r.imported && <span className="ml-1 text-[10px] font-black uppercase tracking-widest px-1.5 py-0.5 rounded bg-amber-50 text-amber-700">imported</span>}</span>
    ) },
    { key: 'revenue_type', header: 'Revenue type', value: (r) => r.revenue_type, render: (r) => label(REVENUE_TYPE_LABEL, r.revenue_type) },
    { key: 'gl_code', header: 'Ledger code', value: (r) => r.gl_code, searchable: true, render: (r) => r.gl_code
      ? <span className="font-mono">{r.gl_code}</span> : <span className="text-xs text-amber-700">uncoded</span> },
    { key: 'payment_method', header: 'Paid by', value: (r) => r.payment_method, render: (r) => label(PAYMENT_METHOD_LABEL, r.payment_method) },
    { key: 'description', header: 'Description', value: (r) => r.description, searchable: true },
    { key: 'amount_cents', header: 'Amount', align: 'right', value: (r) => r.amount_cents, render: (r) => <Money cents={r.amount_cents} currency={r.currency} /> },
  ], [eventName]);

  const entryColumns = useMemo<DataColumn<ImportedEntryRow>[]>(() => [
    { key: 'posted_at', header: 'Posted', value: (r) => r.posted_at, render: (r) => new Date(r.posted_at).toLocaleDateString() },
    { key: 'event', header: 'Event', value: (r) => eventName(r.event_id), searchable: true },
    { key: 'source', header: 'Source', value: (r) => r.source, render: (r) => label(REVENUE_TYPE_LABEL, r.source) },
    { key: 'source_system', header: 'System', value: (r) => r.source_system, searchable: true },
    { key: 'source_line_id', header: 'Line', value: (r) => r.source_line_id, searchable: true, render: (r) => <span className="font-mono text-xs">{r.source_line_id}</span> },
    { key: 'description', header: 'Description', value: (r) => r.description, searchable: true },
    { key: 'gl_code', header: 'Code', value: (r) => r.gl_code, render: (r) => <span className="font-mono">{r.gl_code ?? ''}</span> },
    { key: 'amount_cents', header: 'Amount', align: 'right', value: (r) => r.amount_cents, render: (r) => <Money cents={r.amount_cents} currency={r.currency} /> },
    { key: 'tax_amount_cents', header: 'Tax', align: 'right', value: (r) => r.tax_amount_cents, render: (r) => <Money cents={r.tax_amount_cents} currency={r.currency} /> },
  ], [eventName]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!canView || !orgId) return <div className="p-8 text-sm text-slate-500">The ledger is for owners, managers and finance staff.</div>;

  const onImport = async (file: File) => {
    const plan = planLedgerImport(await file.text(), { event_id: importEvent || null, source_system: importSystem.trim() || undefined, import_run_id: file.name.slice(0, 100) });
    if (!plan.rows.length) {
      toast({ kind: 'error', message: plan.errors.map((e) => (e.row ? `Row ${e.row}: ${e.error}` : e.error)).slice(0, 3).join(' ') || 'Nothing to import.' });
      return;
    }
    setBusy(true);
    try {
      const r = await importLedgerEntries(orgId, plan.rows);
      const bad = [...plan.errors.map((e) => `row ${e.row}: ${e.error}`), ...r.results.filter((x) => x.status === 'error').map((x) => `entry ${x.index}: ${x.error}`)];
      toast({ kind: bad.length ? 'info' : 'success', message: `Imported ${r.created}, already there ${r.exists}${bad.length ? `; ${bad.length} skipped (${bad.slice(0, 2).join('; ')})` : ''}.` });
      await Promise.all([loadSetup(), loadRows()]);
    } catch (e) { fail(e); } finally { setBusy(false); }
  };

  const act = async (fn: () => Promise<void>, reload: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); await reload(); } catch (e) { fail(e); } finally { setBusy(false); }
  };

  const codeOf = new Map<string, string>(revenue.map((r) => [r.revenue_type, r.gl_code_id]));
  const liveCodes = codes.filter((g) => !g.discarded_at);

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to={`/orgs/${orgId}/finance`} className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Finance</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Ledger</h1>
      <p className="text-sm text-slate-500 mb-6">{orgName} · every money line with the ledger code it posts to, entries imported from other systems, and your codes per revenue type.</p>
      <div role="tablist" className="flex gap-1 border-b border-slate-200 mb-6">
        {([['rows', 'Reporting rows'], ['imports', 'Imported entries'], ['codes', 'Revenue codes']] as [Tab, string][]).map(([t, name]) => (
          <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
            className={`px-4 py-3 text-xs font-bold uppercase tracking-widest border-b-2 -mb-px ${tab === t ? 'border-[#026cdf] text-slate-900' : 'border-transparent text-slate-400'}`}>
            {name}
          </button>
        ))}
      </div>

      {tab === 'rows' && (
        <Section title="Reporting rows" action={<button className={BTN} disabled={!rows.length}
          onClick={() => downloadCsv(`ledger-${from}-${to}.csv`, reportingRowsCsv(rows, eventName))}>CSV</button>}>
          <p className="text-xs text-slate-400 mb-3">
            A show's order lines appear once it is backfilled (Event report → Settlement → Ledger codes); imported entries at once.
            Payout rows are money moved, not revenue.{truncated ? ' More rows exist: narrow the dates.' : ''}
          </p>
          <DataTable<ReportingRow> dense label="Reporting rows" rows={rows} rowKey={(r) => r.id} columns={rowColumns} state={rowTable} onState={setRowTable}
            searchPlaceholder="Event, code, description"
            filters={[
              { key: 'source_type', label: 'Source', options: opts(filterOptions<ReportingRow>(rows, (r) => r.source_type), SOURCE_TYPE_LABEL) },
              { key: 'revenue_type', label: 'Revenue type', options: opts(filterOptions<ReportingRow>(rows, (r) => r.revenue_type), REVENUE_TYPE_LABEL) },
              { key: 'gl_code', label: 'Code', options: filterOptions<ReportingRow>(rows, (r) => r.gl_code).map((v) => ({ value: v, label: v })) },
            ]}
            toolbar={<>
              <label><span className={LABEL}>From</span><input type="date" className={FLD} value={from} onChange={(e) => setFrom(e.target.value)} /></label>
              <label><span className={LABEL}>To</span><input type="date" className={FLD} value={to} onChange={(e) => setTo(e.target.value)} /></label>
            </>}
            empty="No rows in this range." />
          <div className="mt-3 text-sm flex flex-wrap gap-4">
            {totalsByCurrency(rows.filter((r) => r.source_type !== 'payout')).map((t) => (
              <span key={t.currency}>Net ({t.currency}, payouts excluded): <Money cents={t.cents} currency={t.currency} strong /></span>
            ))}
          </div>
        </Section>
      )}

      {tab === 'imports' && (
        <Section title="Imported entries">
          {canWrite && (
            <div className="flex flex-wrap gap-2 items-end mb-4">
              <label><span className={LABEL}>Event (blanks)</span>
                <select className={FLD} value={importEvent} onChange={(e) => setImportEvent(e.target.value)}>
                  <option value="">None (org-wide)</option>
                  {events.map((e) => <option key={e.id} value={e.id}>{e.name}{e.starts_at ? ` · ${new Date(e.starts_at).toLocaleDateString()}` : ''}</option>)}
                </select></label>
              <label><span className={LABEL}>System (blanks)</span>
                <input className={FLD} value={importSystem} maxLength={40} placeholder="square" onChange={(e) => setImportSystem(e.target.value)} /></label>
              <label className={`${BTN_PRIMARY} inline-flex items-center gap-1 cursor-pointer ${busy ? 'opacity-40 pointer-events-none' : ''}`}>
                <FileUp size={12} /> Import CSV
                <input type="file" accept=".csv,text/csv" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) onImport(f); }} />
              </label>
              <span className="text-xs text-slate-400 basis-full">Columns: source ({IMPORT_SOURCES.join(', ')}), amount (or amount_cents; negative for a cost), tax_amount, gl_code, tax_gl_code, posted_at, source_system, source_line_id, description, source_order_id, event_id. Up to 500 rows; a line already imported is skipped.</span>
            </div>
          )}
          <DataTable<ImportedEntryRow> dense label="Imported ledger entries" rows={entries} rowKey={(r) => r.id} columns={entryColumns} state={entryTable} onState={setEntryTable}
            searchPlaceholder="System, line, description"
            filters={[
              { key: 'source', label: 'Source', options: opts(filterOptions<ImportedEntryRow>(entries, (r) => r.source), REVENUE_TYPE_LABEL) },
              { key: 'source_system', label: 'System', options: filterOptions<ImportedEntryRow>(entries, (r) => r.source_system).map((v) => ({ value: v, label: v })) },
            ]}
            actions={canWrite ? (r) => (
              <button className={BTN} disabled={busy} onClick={() => {
                if (window.confirm(`Delete ${r.source_system} line ${r.source_line_id}? Its reporting rows go too.`)) act(() => deleteImportedEntry(r.id), async () => { await loadSetup(); await loadRows(); });
              }}>Delete</button>
            ) : undefined}
            empty="Nothing imported yet." />
        </Section>
      )}

      {tab === 'codes' && (
        <Section title="Ledger code per revenue type">
          <p className="text-xs text-slate-400 mb-3">A show can override any of these (Event report → Settlement → Ledger codes). After a change, backfill a show to re-tag its rows. Codes come from your <Link className="text-tm-blue" to={`/orgs/${orgId}/finance`}>chart of accounts</Link>.</p>
          <table className="w-full text-sm">
            <tbody>
              {REVENUE_TYPES.map((t) => (
                <tr key={t} className="border-t border-slate-100">
                  <td className="py-1.5">{label(REVENUE_TYPE_LABEL, t)}</td>
                  <td className="w-72">
                    {canWrite ? (
                      <select className={FLD} value={codeOf.get(t) ?? ''} disabled={busy}
                        onChange={(e) => act(() => setRevenueCode(orgId, t, e.target.value || null), loadSetup)}>
                        <option value="">Uncoded</option>
                        {liveCodes.map((g) => <option key={g.id} value={g.id}>{g.code} {g.name}</option>)}
                      </select>
                    ) : <span className="font-mono">{liveCodes.find((g) => g.id === codeOf.get(t))?.code ?? '—'}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}
    </div>
  );
}
