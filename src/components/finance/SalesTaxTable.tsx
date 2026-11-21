// Sales tax by jurisdiction (mig 20261108100000): one row per venue location,
// tax rule and source, with collected / refunded / net and a CSV. Used on the
// Payouts page (the org, a period) and in the event's Money section.

import { Download } from 'lucide-react';
import { formatCents } from '../../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../../lib/csv';
import {
  jurisdictionLabel, SALES_TAX_CSV_HEADER, salesTaxCsvRows, salesTaxTotals, taxRateLabel, type SalesTaxRow,
} from '../../lib/journal';
import { salesTaxSheet } from '../../lib/financeWorkbooks';
import { saveXlsx } from '../../lib/xlsxDownload';

export default function SalesTaxTable({ rows, fileParts, orgId, eventId }: {
  rows: SalesTaxRow[]; fileParts: Array<string | undefined | null>;
  /** For the XLSX's export.run log (claude/exos-attendance-report): the org, or the event. */
  orgId?: string | null; eventId?: string | null;
}) {
  const totals = salesTaxTotals(rows);
  const exportCsv = () => downloadCsv(csvFileName(['sales-tax', ...fileParts]), toCsv(SALES_TAX_CSV_HEADER, salesTaxCsvRows(rows)));
  const exportXlsx = () => void saveXlsx(['sales-tax', ...fileParts], [salesTaxSheet(rows)], { orgId, eventId, kind: 'sales_tax' });
  if (rows.length === 0) {
    return <p className="text-sm text-slate-500">No sales tax in this period.</p>;
  }
  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-2">
        <p className="text-xs text-slate-500">
          {totals.map((t) => `${formatCents(t.netCents, t.currency)} net (${formatCents(t.collectedCents, t.currency)} collected, ${formatCents(t.refundedCents, t.currency)} refunded)`).join(' · ')}
        </p>
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={exportCsv}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50">
            <Download size={14} aria-hidden="true" /> Sales tax CSV
          </button>
          <button type="button" onClick={exportXlsx}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50">
            <Download size={14} aria-hidden="true" /> Sales tax XLSX
          </button>
        </div>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm" aria-label="Sales tax by jurisdiction">
          <thead>
            <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
              <th className="py-2 font-black">Jurisdiction</th>
              <th className="py-2 font-black">Tax</th>
              <th className="py-2 font-black">Where sold</th>
              <th className="py-2 font-black text-right">Orders</th>
              <th className="py-2 font-black text-right">Taxable</th>
              <th className="py-2 font-black text-right">Collected</th>
              <th className="py-2 font-black text-right">Refunded</th>
              <th className="py-2 font-black text-right">Net</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-b border-slate-50 last:border-b-0">
                <td className="py-2 text-slate-700">{jurisdictionLabel(r)}</td>
                <td className="py-2 text-slate-700">{taxRateLabel(r)}</td>
                <td className="py-2 text-slate-500 text-xs">{r.source === 'pos' ? 'Door' : 'Online'}</td>
                <td className="py-2 text-right tabular-nums">{r.orders}</td>
                <td className="py-2 text-right tabular-nums">{formatCents(r.taxable_cents, r.currency)}</td>
                <td className="py-2 text-right tabular-nums">{formatCents(r.tax_collected_cents, r.currency)}</td>
                <td className="py-2 text-right tabular-nums text-slate-500">{r.tax_refunded_cents ? formatCents(r.tax_refunded_cents, r.currency) : '—'}</td>
                <td className="py-2 text-right tabular-nums font-bold">{formatCents(r.net_tax_cents, r.currency)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
