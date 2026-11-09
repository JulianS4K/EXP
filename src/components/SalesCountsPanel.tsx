// "Sold elsewhere" on the event report (mig 20261030120000): tickets sold
// outside Exos, typed in by hand (box office, consignment) or imported from
// another platform's sales CSV with a column-mapping step. Owners, managers
// and finance see and change it (RLS + the RPCs re-check); the panel hides for
// anyone else. The numbers are shown beside Exos's own, never added to them.
//
// The file is read in the browser (src/lib/salesCounts.ts: the Exos Door CSV
// reader, then the mapping and per-ticket-type sums shared with exos-api);
// only the sums are sent. Importing a platform again replaces its entry, so
// the same file twice changes nothing.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { FileUp, Loader2, Pencil, Store, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import {
  FIELD_LABELS, MAX_ENTRIES, MAX_IMPORT_BYTES, PLATFORMS, PLATFORM_LABELS, SALES_FIELDS,
  cleanLabel, deleteSalesCount, eventValues, guessPlatform, importSalesCounts, listSalesCounts,
  parseAmount, parseCsv, planSalesImport, salesTotals, setManualCount, suggestSalesMapping, totalSold,
  type Platform, type SalesCountRow, type SalesField, type SalesMapping,
} from '../lib/salesCounts';

const inputCls = 'w-full border border-slate-200 rounded-lg px-2 py-2 bg-white text-sm';
const labelCls = 'block text-xs font-bold text-slate-600 mb-1';
const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-40';

const emptyForm = (currency: string) => ({ label: '', sold: '', gross: '', currency, capacity: '', note: '' });

export default function SalesCountsPanel({ eventId, currency, canView, onTotal }: {
  eventId: string;
  currency: string;
  /** Owner / manager / finance (or admin). */
  canView: boolean;
  /** On load and after each write: the total sold elsewhere. */
  onTotal?: (soldElsewhere: number) => void;
}) {
  const { toast } = useToast();
  const [rows, setRows] = useState<SalesCountRow[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [form, setForm] = useState(() => emptyForm(currency));

  // CSV import state.
  const [fileName, setFileName] = useState('');
  const [table, setTable] = useState<string[][] | null>(null);
  const [mapping, setMapping] = useState<SalesMapping>({});
  const [platform, setPlatform] = useState<Platform>('other');
  const [importCurrency, setImportCurrency] = useState(currency);
  const [eventFilter, setEventFilter] = useState('');
  const [fileError, setFileError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const r = await listSalesCounts(eventId);
    setRows(r);
    if (r) onTotal?.(totalSold(r));
    return r;
  }, [eventId, onTotal]);

  useEffect(() => {
    if (canView) void load();
  }, [canView, load]);

  const plan = useMemo(
    () => (table ? planSalesImport(table, mapping, { currency: importCurrency, event: eventFilter || null }) : null),
    [table, mapping, importCurrency, eventFilter],
  );
  const events = useMemo(() => (table ? eventValues(table, mapping) : []), [table, mapping]);

  if (!canView || rows === null) return null;
  const totals = salesTotals(rows);
  const header = table?.[0] ?? [];
  const existing = rows.find((r) => r.kind === 'import' && r.platform === platform);

  const after = async () => {
    await load();
  };

  const run = async (key: string, fn: () => Promise<void>) => {
    setBusy(key);
    try {
      await fn();
    } catch (err) {
      toast({ kind: 'error', message: (err as Error).message || 'That didn’t save.' });
    } finally {
      setBusy(null);
    }
  };

  const saveManual = () => run('save', async () => {
    const label = cleanLabel(form.label);
    if (!label) throw new Error('Say where these tickets were sold (1-40 characters), e.g. “Box office”.');
    const sold = Number(form.sold);
    if (!Number.isInteger(sold) || sold < 0) throw new Error('Tickets sold must be a whole number.');
    const gross = form.gross.trim() === '' ? 0 : parseAmount(form.gross);
    if (gross === null || gross < 0) throw new Error('Gross must be an amount, e.g. 240 or 240.00.');
    const capacity = form.capacity.trim() === '' ? null : Number(form.capacity);
    if (capacity !== null && (!Number.isInteger(capacity) || capacity < 0)) throw new Error('Capacity must be a whole number.');
    const r = await setManualCount(eventId, {
      label, sold, grossCents: Math.round(gross * 100), currency: form.currency.trim().toUpperCase() || currency,
      capacity, note: form.note.trim() || null,
    });
    setForm(emptyForm(currency));
    toast({ kind: 'success', message: r.status === 'unchanged' ? 'Nothing changed.' : `Saved “${label}”.` });
    await after();
  });

  const edit = (r: SalesCountRow) => setForm({
    label: r.label, sold: String(r.sold), gross: (r.gross_cents / 100).toFixed(2), currency: r.currency,
    capacity: r.capacity === null ? '' : String(r.capacity), note: r.note ?? '',
  });

  const remove = (r: SalesCountRow) => {
    if (!window.confirm(`Delete “${r.label}” (${r.sold} tickets)?`)) return;
    void run(`del-${r.id}`, async () => {
      await deleteSalesCount(r.id);
      await after();
    });
  };

  const readFile = async (f: File) => {
    setFileError(null);
    if (f.size > MAX_IMPORT_BYTES) {
      setFileError('That file is over 2 MB. Export just this event’s sales, or a summary per ticket type.');
      return;
    }
    const t = parseCsv(await f.text());
    if (t.length < 2) {
      setFileError('No rows found. Export the sales as CSV (comma, semicolon or tab separated).');
      setTable(null);
      return;
    }
    setFileName(f.name);
    setTable(t);
    setMapping(suggestSalesMapping(t[0]));
    setPlatform(guessPlatform(f.name));
    setEventFilter('');
  };

  const runImport = () => run('import', async () => {
    if (!plan || plan.errors.length) return;
    if (existing && !window.confirm(`Replace the ${PLATFORM_LABELS[platform]} numbers imported earlier (${existing.sold} tickets) with this file?`)) return;
    const r = await importSalesCounts(eventId, {
      platform, currency: plan.currency, tiers: plan.tiers, sold: plan.sold, grossCents: plan.grossCents,
      capacity: plan.capacity, fileName: fileName || null, rowCount: plan.rows,
    });
    toast({
      kind: 'success',
      message: r.status === 'unchanged'
        ? `Same numbers as the last ${PLATFORM_LABELS[platform]} import: nothing changed.`
        : `Imported ${r.sold} ${PLATFORM_LABELS[platform]} tickets.`,
    });
    setTable(null);
    setFileName('');
    await after();
  });

  const setField = (f: SalesField, v: string) => setMapping((m) => {
    const next = { ...m };
    if (v === '') delete next[f];
    else next[f] = Number(v);
    return next;
  });

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="sold-elsewhere-title">
      <div className="flex items-center gap-2 mb-1">
        <Store className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 id="sold-elsewhere-title" className="text-sm font-bold text-slate-700">Sold elsewhere</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Tickets sold outside Exos: a box office, a consignment, or another platform. Shown beside your Exos sales and
        never added to them. Staff only; the public page shows just the total.
      </p>

      {rows.length === 0 ? (
        <p className="text-sm text-slate-400 mb-6">Nothing recorded yet.</p>
      ) : (
        <div className="overflow-x-auto -mx-6 px-6 mb-6">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th scope="col" className="py-2 pr-4">Where</th>
                <th scope="col" className="py-2 pr-4 text-right">Sold</th>
                <th scope="col" className="py-2 pr-4 text-right">Gross</th>
                <th scope="col" className="py-2 pr-4 text-right">Capacity</th>
                <th scope="col" className="py-2"><span className="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-slate-50 last:border-0 align-top">
                  <td className="py-2 pr-4 text-slate-700">
                    <span className="block">{r.label}</span>
                    <span className="block text-[10px] text-slate-400">
                      {r.kind === 'import' ? `Imported${r.file_name ? ` · ${r.file_name}` : ''}` : 'Typed in'}
                      {' · '}{new Date(r.updated_at).toLocaleDateString()}
                      {r.note ? ` · ${r.note}` : ''}
                    </span>
                    {r.tiers.length > 0 && (
                      <span className="block text-[10px] text-slate-500 mt-0.5">
                        {r.tiers.map((t) => `${t.name}: ${t.sold}`).join(' · ')}
                      </span>
                    )}
                  </td>
                  <td className="py-2 pr-4 text-right tabular-nums">{r.sold}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{formatCents(r.gross_cents, r.currency)}</td>
                  <td className="py-2 pr-4 text-right tabular-nums text-slate-400">{r.capacity ?? ''}</td>
                  <td className="py-2 text-right whitespace-nowrap">
                    {r.kind === 'manual' && (
                      <button type="button" onClick={() => edit(r)} aria-label={`Edit ${r.label}`}
                        className="p-2 text-slate-400 hover:text-slate-700"><Pencil size={14} /></button>
                    )}
                    <button type="button" onClick={() => remove(r)} disabled={busy === `del-${r.id}`} aria-label={`Delete ${r.label}`}
                      className="p-2 text-slate-400 hover:text-rose-600 disabled:opacity-40"><Trash2 size={14} /></button>
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              {totals.map((t) => (
                <tr key={t.currency} className="font-bold text-slate-700 border-t border-slate-200">
                  <td className="py-2 pr-4">Total{totals.length > 1 ? ` (${t.currency})` : ''}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{t.sold}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{formatCents(t.grossCents, t.currency)}</td>
                  <td colSpan={2} />
                </tr>
              ))}
            </tfoot>
          </table>
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Manual count */}
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            void saveManual();
          }}
        >
          <h4 className="text-xs font-black uppercase tracking-widest text-slate-500">Add a count</h4>
          <div className="grid grid-cols-2 gap-3">
            <label className="col-span-2">
              <span className={labelCls}>Where</span>
              <input className={inputCls} value={form.label} maxLength={40} placeholder="Box office"
                onChange={(e) => setForm({ ...form, label: e.target.value })} />
            </label>
            <label>
              <span className={labelCls}>Tickets sold</span>
              <input className={inputCls} inputMode="numeric" value={form.sold}
                onChange={(e) => setForm({ ...form, sold: e.target.value })} />
            </label>
            <label>
              <span className={labelCls}>Gross</span>
              <input className={inputCls} inputMode="decimal" value={form.gross} placeholder="0.00"
                onChange={(e) => setForm({ ...form, gross: e.target.value })} />
            </label>
            <label>
              <span className={labelCls}>Currency</span>
              <input className={inputCls} value={form.currency} maxLength={3}
                onChange={(e) => setForm({ ...form, currency: e.target.value.toUpperCase() })} />
            </label>
            <label>
              <span className={labelCls}>Capacity (optional)</span>
              <input className={inputCls} inputMode="numeric" value={form.capacity}
                onChange={(e) => setForm({ ...form, capacity: e.target.value })} />
            </label>
            <label className="col-span-2">
              <span className={labelCls}>Note (optional)</span>
              <input className={inputCls} value={form.note} maxLength={200}
                onChange={(e) => setForm({ ...form, note: e.target.value })} />
            </label>
          </div>
          <p className="text-[11px] text-slate-400">Saving a name that’s already listed replaces its numbers.</p>
          <button type="submit" disabled={busy !== null || rows.length >= MAX_ENTRIES && !rows.some((r) => r.kind === 'manual' && r.label.toLowerCase() === form.label.trim().toLowerCase())}
            className={`${btn} bg-slate-900 text-white`}>
            {busy === 'save' ? <Loader2 size={12} className="animate-spin" /> : null} Save count
          </button>
        </form>

        {/* CSV import */}
        <div className="space-y-3">
          <h4 className="text-xs font-black uppercase tracking-widest text-slate-500">Import a sales CSV</h4>
          <label className="flex items-center justify-center gap-2 border-2 border-dashed border-slate-200 rounded-2xl py-6 text-sm text-slate-600 cursor-pointer hover:border-slate-300">
            <FileUp className="w-4 h-4" aria-hidden="true" />
            {fileName ? `${fileName} · ${Math.max(0, (table?.length ?? 1) - 1)} rows` : 'Choose a CSV from DICE, RA, Posh…'}
            <input type="file" accept=".csv,text/csv,text/plain,.tsv" className="sr-only"
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) void readFile(f);
                e.target.value = '';
              }} />
          </label>
          {fileError && <p className="text-xs text-rose-600" role="alert">{fileError}</p>}

          {table && plan && (
            <>
              <div className="grid grid-cols-2 gap-3">
                <label>
                  <span className={labelCls}>Sold on</span>
                  <select className={inputCls} value={platform} onChange={(e) => setPlatform(e.target.value as Platform)}>
                    {PLATFORMS.map((p) => <option key={p} value={p}>{PLATFORM_LABELS[p]}</option>)}
                  </select>
                </label>
                <label>
                  <span className={labelCls}>Currency</span>
                  <input className={inputCls} value={importCurrency} maxLength={3}
                    onChange={(e) => setImportCurrency(e.target.value.toUpperCase())} />
                </label>
                {SALES_FIELDS.map((f) => (
                  <label key={f}>
                    <span className={labelCls}>{FIELD_LABELS[f]}{f === 'sold' ? ' *' : ''}</span>
                    <select className={inputCls} value={mapping[f] ?? ''} onChange={(e) => setField(f, e.target.value)}>
                      <option value="">Not in this file</option>
                      {header.map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
                    </select>
                  </label>
                ))}
                {mapping.event !== undefined && (
                  <label className="col-span-2">
                    <span className={labelCls}>Which event in the file is this one?</span>
                    <select className={inputCls} value={eventFilter} onChange={(e) => setEventFilter(e.target.value)}>
                      <option value="">All rows</option>
                      {events.map((v) => <option key={v} value={v}>{v}</option>)}
                    </select>
                  </label>
                )}
              </div>

              <div className="rounded-xl bg-slate-50 p-3 text-xs text-slate-600 space-y-1" aria-live="polite">
                {plan.errors.length > 0 ? (
                  <ul className="text-rose-600 space-y-0.5" role="alert">
                    {plan.errors.slice(0, 8).map((e, i) => (
                      <li key={i}>{e.row > 1 ? `Line ${e.row}: ` : ''}{e.message}</li>
                    ))}
                    {plan.errors.length > 8 && <li>…and {plan.errors.length - 8} more.</li>}
                  </ul>
                ) : (
                  <>
                    <p className="font-bold text-slate-800">
                      {plan.sold} tickets · {formatCents(plan.grossCents, plan.currency)}
                      {plan.capacity !== null ? ` · capacity ${plan.capacity}` : ''}
                    </p>
                    {plan.tiers.length > 0 && <p>{plan.tiers.map((t) => `${t.name}: ${t.sold}`).join(' · ')}</p>}
                    <p className="text-slate-400">
                      {plan.rows} row{plan.rows === 1 ? '' : 's'} counted
                      {plan.voided ? ` · ${plan.voided} refunded / cancelled left out` : ''}
                      {plan.otherEvents ? ` · ${plan.otherEvents} for other events left out` : ''}
                    </p>
                  </>
                )}
                {plan.warnings.map((w, i) => <p key={i} className="text-amber-700">{w.message}</p>)}
                {existing && plan.errors.length === 0 && (
                  <p className="text-amber-700">Replaces the earlier {PLATFORM_LABELS[platform]} import ({existing.sold} tickets).</p>
                )}
              </div>

              <div className="flex gap-2">
                <button type="button" onClick={() => void runImport()}
                  disabled={busy !== null || plan.errors.length > 0 || (!existing && rows.length >= MAX_ENTRIES)}
                  className={`${btn} bg-slate-900 text-white`}>
                  {busy === 'import' ? <Loader2 size={12} className="animate-spin" /> : null} Import
                </button>
                <button type="button" onClick={() => { setTable(null); setFileName(''); }}
                  className={`${btn} border border-slate-200 text-slate-600`}>
                  Cancel
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </section>
  );
}
