// The org's money journal on the Payouts page (mig 20261108100000,
// docs/journal.md): a period, its trial balance per currency, the journal
// CSV (date, entry, source, account, debit, credit, memo) and sales tax by
// jurisdiction. Read-only; owner / manager / finance (the reads refuse anyone
// else, and the panel hides when they answer null).

import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import { formatCents } from '../../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../../lib/csv';
import {
  JOURNAL_CSV_HEADER, journalCsvRows, periodBounds, summarizeTrialBalance, type SalesTaxRow, type TrialBalanceRow,
} from '../../lib/journal';
import { getSalesTax, getTrialBalance, listJournalLines } from '../../lib/journalApi';
import SalesTaxTable from './SalesTaxTable';

const day = (d: Date) => d.toISOString().slice(0, 10);

export default function JournalPanel({ orgId, orgName, canView }: { orgId?: string; orgName?: string; canView: boolean }) {
  const [fromDay, setFromDay] = useState(() => `${new Date().getUTCFullYear()}-01-01`);
  const [toDay, setToDay] = useState(() => day(new Date()));
  const [tb, setTb] = useState<TrialBalanceRow[] | null | undefined>(undefined);
  const [tax, setTax] = useState<SalesTaxRow[] | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [csvError, setCsvError] = useState<string | null>(null);
  const period = useMemo(() => periodBounds(fromDay, toDay), [fromDay, toDay]);

  useEffect(() => {
    if (!orgId || !canView) return undefined;
    let cancelled = false;
    setTb(undefined);
    setTax(undefined);
    void getTrialBalance(orgId, period).then((r) => { if (!cancelled) setTb(r); });
    void getSalesTax(orgId, period).then((r) => { if (!cancelled) setTax(r); });
    return () => {
      cancelled = true;
    };
  }, [orgId, canView, period]);

  const balances = useMemo(() => summarizeTrialBalance(tb ?? []), [tb]);

  if (!orgId || !canView || tb === null) return null;

  const exportJournal = async () => {
    setBusy(true);
    setCsvError(null);
    const lines = await listJournalLines(orgId, period);
    setBusy(false);
    if (!lines) {
      setCsvError("The journal couldn't be read. Try again.");
      return;
    }
    downloadCsv(csvFileName(['journal', orgName, fromDay, toDay]), toCsv(JOURNAL_CSV_HEADER, journalCsvRows(lines)));
  };

  return (
    <section className="mt-10" aria-labelledby="journal-h">
      <div className="flex flex-wrap items-end justify-between gap-4 mb-4">
        <div>
          <h2 id="journal-h" className="text-xl font-bold tracking-tight">Journal</h2>
          <p className="text-sm text-slate-600 max-w-prose">
            Every sale, refund, fee, dispute you bear, marketplace payout, promoter commission and door cash movement, as
            balanced double-entry lines. Nothing here can be edited: a later change is a new entry.
          </p>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
            From
            <input type="date" value={fromDay} onChange={(e) => setFromDay(e.target.value)}
              className="block mt-1 bg-white border border-slate-200 rounded px-2 py-1.5 text-sm text-slate-900" />
          </label>
          <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
            To
            <input type="date" value={toDay} onChange={(e) => setToDay(e.target.value)}
              className="block mt-1 bg-white border border-slate-200 rounded px-2 py-1.5 text-sm text-slate-900" />
          </label>
          <button type="button" onClick={() => void exportJournal()} disabled={busy}
            className="inline-flex items-center gap-1.5 px-4 py-2.5 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-40">
            <Download size={14} aria-hidden="true" /> {busy ? 'Preparing…' : 'Journal CSV'}
          </button>
        </div>
      </div>
      {csvError && <p role="alert" className="text-sm text-rose-600 mb-3">{csvError}</p>}

      <div className="bg-white rounded-2xl border border-slate-200 p-5 mb-6">
        <h3 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">Trial balance</h3>
        {tb === undefined ? (
          <p className="text-sm text-slate-400">Loading…</p>
        ) : balances.length === 0 ? (
          <p className="text-sm text-slate-500">No entries in this period.</p>
        ) : (
          balances.map((b) => (
            <div key={b.currency} className="overflow-x-auto mb-4 last:mb-0">
              <table className="w-full text-sm" aria-label={`Trial balance ${b.currency}`}>
                <thead>
                  <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                    <th className="py-2 font-black">Account</th>
                    <th className="py-2 font-black text-right">Debit</th>
                    <th className="py-2 font-black text-right">Credit</th>
                    <th className="py-2 font-black text-right">Balance</th>
                  </tr>
                </thead>
                <tbody>
                  {b.lines.map((l) => (
                    <tr key={l.account} className="border-b border-slate-50">
                      <td className="py-2 text-slate-700"><span className="text-slate-400 tabular-nums mr-2">{l.number}</span>{l.name}</td>
                      <td className="py-2 text-right tabular-nums">{l.debitCents ? formatCents(l.debitCents, b.currency) : ''}</td>
                      <td className="py-2 text-right tabular-nums">{l.creditCents ? formatCents(l.creditCents, b.currency) : ''}</td>
                      <td className={`py-2 text-right tabular-nums ${l.normalCents < 0 ? 'text-rose-600' : ''}`}>{formatCents(l.normalCents, b.currency)}</td>
                    </tr>
                  ))}
                  <tr className="font-bold">
                    <td className="py-2">Total{b.balanced ? '' : ' (does not balance)'}</td>
                    <td className="py-2 text-right tabular-nums">{formatCents(b.debitCents, b.currency)}</td>
                    <td className="py-2 text-right tabular-nums">{formatCents(b.creditCents, b.currency)}</td>
                    <td className="py-2 text-right tabular-nums text-slate-500 text-xs font-normal">
                      Net revenue {formatCents(b.netRevenueCents, b.currency)} · expenses {formatCents(b.expenseCents, b.currency)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          ))
        )}
      </div>

      {tax !== null && (
        <div className="bg-white rounded-2xl border border-slate-200 p-5">
          <h3 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">Sales tax by jurisdiction</h3>
          {tax === undefined ? <p className="text-sm text-slate-400">Loading…</p>
            : <SalesTaxTable rows={tax} fileParts={[orgName, fromDay, toDay]} />}
        </div>
      )}
    </section>
  );
}
