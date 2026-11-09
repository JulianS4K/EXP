// "Where buyers checked out": checkout conversion inside Instagram /
// Facebook / TikTok browsers vs real browsers, on the event report's Marketing
// tab (mig 20261105140000, lib/inAppReport.ts). Owner / manager / finance;
// hidden before the migration or when there's nothing to show.

import { useEffect, useState } from 'react';
import { Smartphone } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import { getInAppReport, pct, type InAppSummary } from '../lib/inAppReport';

export default function InAppReportPanel({ eventId, canView }: { eventId: string; canView: boolean }) {
  const [s, setS] = useState<InAppSummary | null>(null);
  useEffect(() => {
    if (!canView) return undefined;
    let live = true;
    void getInAppReport(eventId).then((r) => { if (live) setS(r); });
    return () => { live = false; };
  }, [eventId, canView]);

  if (!canView || !s || s.lines.length === 0) return null;
  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="in-app-title">
      <div className="flex items-center gap-2 mb-1">
        <Smartphone className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 id="in-app-title" className="text-sm font-bold text-slate-700">Where buyers checked out</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Checkouts started inside an app&rsquo;s browser (Instagram, Facebook, TikTok…) or in a real browser, and how many were paid.
        {s.inApp.started > 0 && s.browser.started > 0 && (
          <> In-app conversion is <strong className="text-slate-600">{pct(s.inApp.conversion)}</strong> against{' '}
            <strong className="text-slate-600">{pct(s.browser.conversion)}</strong> in browsers
            {s.ratio !== null && ` (${s.ratio >= 1 ? 'at or above' : `${pct(1 - s.ratio)} below`} the browser)`}.</>
        )}
        {s.inAppGrossShare !== null && ` ${pct(s.inAppGrossShare)} of paid gross came from in-app traffic.`}
      </p>
      <div className="overflow-x-auto -mx-6 px-6">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
              <th scope="col" className="py-2 pr-4">Browser</th>
              <th scope="col" className="py-2 pr-4 text-right">Started</th>
              <th scope="col" className="py-2 pr-4 text-right">Paid</th>
              <th scope="col" className="py-2 pr-4 text-right">Conversion</th>
              <th scope="col" className="py-2 pr-4 text-right">Tickets</th>
              <th scope="col" className="py-2 text-right">Gross</th>
            </tr>
          </thead>
          <tbody>
            {s.lines.map((l) => (
              <tr key={l.key} className="border-b border-slate-50 last:border-0">
                <td className={`py-2 pr-4 ${l.group === 'unknown' ? 'text-slate-400 italic' : 'text-slate-700'}`}>{l.label}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.started}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.paid}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{pct(l.conversion)}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.tickets}</td>
                <td className="py-2 text-right tabular-nums">{formatCents(l.grossCents, s.currency)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-[11px] text-slate-400 mt-3">
        &ldquo;Opened from&rdquo; rows are buyers who used the page&rsquo;s &ldquo;open in your browser&rdquo; link. Gross is before refunds.
      </p>
    </section>
  );
}
