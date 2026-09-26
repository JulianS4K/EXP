// PriceDisclosureExport — download the all-in price record for an event.
//
// For each checkout: what the buyer was shown per line (face price, tax, buyer
// fees, all-in unit price, total) and what Stripe charged, with a flag when
// they differ. Proof of all-in pricing for NY Arts & Cultural Affairs Law
// 25.07 and the FTC fee rule. Data: exos_price_disclosure_export (owner /
// manager / finance; mig 20260926070000). Loaded on click, not on mount.

import { useState } from 'react';
import { Download, Receipt } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import {
  PRICE_DISCLOSURE_HEADER, priceDisclosureCsvRows, summarizePriceDisclosure,
  type PriceDisclosureRow, type PriceDisclosureSummary,
} from '../lib/priceDisclosure';

export default function PriceDisclosureExport({ eventId, eventTitle }: { eventId: string; eventTitle?: string }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [summary, setSummary] = useState<PriceDisclosureSummary | null>(null);

  const exportCsv = async () => {
    setBusy(true);
    setError(null);
    try {
      const { data, error: rpcErr } = await supabase.rpc('exos_price_disclosure_export', { p_event_id: eventId });
      if (rpcErr) throw rpcErr;
      const rows = (data ?? []) as PriceDisclosureRow[];
      setSummary(summarizePriceDisclosure(rows));
      if (rows.length === 0) return;
      downloadCsv(
        csvFileName(['price-record', eventTitle]),
        toCsv(PRICE_DISCLOSURE_HEADER, priceDisclosureCsvRows(rows)),
      );
    } catch (err: any) {
      console.warn('exos_price_disclosure_export failed:', err);
      setError(`Could not export: ${err?.message ? String(err.message) : 'unknown error'}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
      <div className="px-5 py-4 flex items-center justify-between gap-2">
        <div className="min-w-0">
          <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest flex items-center gap-2">
            <Receipt className="w-4 h-4 text-slate-500" aria-hidden="true" /> Price record
          </h2>
          <p className="text-xs text-slate-500 mt-1">
            What each buyer was shown and what they were charged. Keep it as proof of all-in pricing.
          </p>
        </div>
        <button
          type="button"
          onClick={exportCsv}
          disabled={busy || !eventId}
          aria-label="Export price record as CSV"
          className="inline-flex items-center gap-1 px-2 py-1 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:bg-slate-50 disabled:opacity-40 shrink-0"
        >
          <Download className="w-3 h-3" aria-hidden="true" /> {busy ? 'Exporting…' : 'CSV'}
        </button>
      </div>
      {error && <p className="px-5 pb-4 text-xs text-rose-500">{error}</p>}
      {summary && !error && (
        <p className="px-5 pb-4 text-xs text-slate-500">
          {summary.orders === 0
            ? 'No checkouts recorded yet.'
            : `${summary.orders} checkouts, ${summary.charged} charged.`}
          {summary.mismatches > 0 && (
            <span className="text-rose-600 font-bold">
              {' '}{summary.mismatches} charged a different amount than shown.
            </span>
          )}
        </p>
      )}
    </div>
  );
}
