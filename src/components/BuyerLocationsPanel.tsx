// "Where buyers are", on the event report's Marketing tab (mig 20261106140000).
// Read-only. Top countries and cities of this event's orders (or, switched,
// every event of the org), with orders, tickets and gross; free orders,
// RSVPs and orders without an address count as unknown. The location is the
// billing address Stripe or PayPal gave (never an IP lookup, never a street);
// aggregation is in SQL (exos_event_buyer_geo / exos_org_buyer_geo, owner /
// manager / finance), display logic in src/lib/buyerGeo.ts. Hidden when the
// report can't be read (role, or the migration not applied yet).

import { useEffect, useState } from 'react';
import { Globe2 } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import { cityLabel, countryName, countryRows, sharePct, type BuyerGeoReport, type GeoRow } from '../lib/buyerGeo';
import { getEventBuyerGeo, getOrgBuyerGeo } from '../lib/buyerGeoApi';

type Scope = 'event' | 'org';

export default function BuyerLocationsPanel({ eventId, orgId, canView }: { eventId: string; orgId?: string | null; canView: boolean }) {
  const [scope, setScope] = useState<Scope>('event');
  const [report, setReport] = useState<BuyerGeoReport | null>(null);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    setLoaded(false);
    const read = scope === 'org' && orgId ? getOrgBuyerGeo(orgId) : getEventBuyerGeo(eventId);
    void read.then((r) => {
      if (cancelled) return;
      setReport(r);
      setLoaded(true);
    });
    return () => {
      cancelled = true;
    };
  }, [eventId, orgId, scope, canView]);

  if (!canView || (loaded && !report && scope === 'event')) return null;

  const table = (title: string, rows: GeoRow[], label: (r: GeoRow) => string, total: number) => (
    <div className="min-w-0">
      <p className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-2">{title}</p>
      {rows.length === 0 ? (
        <p className="text-xs text-slate-400">None yet.</p>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
              <th scope="col" className="py-2 pr-3 font-black">Where</th>
              <th scope="col" className="py-2 pr-3 text-right font-black">Orders</th>
              <th scope="col" className="py-2 pr-3 text-right font-black">Tickets</th>
              <th scope="col" className="py-2 text-right font-black">Gross</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={`${r.country}-${r.region}-${r.city}-${r.currency}-${i}`} className="border-b border-slate-50 last:border-0">
                <td className={`py-2 pr-3 break-words ${r.country ? 'text-slate-700' : 'text-slate-400 italic'}`}>
                  {label(r)}
                  <span className="ml-1 text-[10px] text-slate-400 tabular-nums">{sharePct(r.orders, total)}%</span>
                </td>
                <td className="py-2 pr-3 text-right tabular-nums">{r.orders}</td>
                <td className="py-2 pr-3 text-right tabular-nums">{r.tickets}</td>
                <td className="py-2 text-right tabular-nums">{formatCents(r.gross_cents, r.currency)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="buyer-geo-title">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
        <div className="flex items-center gap-2">
          <Globe2 className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h3 id="buyer-geo-title" className="text-sm font-bold text-slate-700">Where buyers are</h3>
        </div>
        {orgId && (
          <div role="group" aria-label="Report scope" className="inline-flex rounded border border-slate-200 overflow-hidden">
            {(['event', 'org'] as const).map((s) => (
              <button
                key={s}
                type="button"
                aria-pressed={scope === s}
                onClick={() => setScope(s)}
                className={`px-3 py-2 text-[10px] font-black uppercase tracking-widest ${scope === s ? 'bg-slate-900 text-white' : 'bg-white text-slate-600 hover:bg-slate-50'}`}
              >
                {s === 'event' ? 'This event' : 'All events'}
              </button>
            ))}
          </div>
        )}
      </div>
      <p className="text-xs text-slate-400 mb-4">
        From the billing address on each payment (country, state and city); we never look up IP addresses.
        {report && report.orders > 0 && ` ${report.located_orders} of ${report.orders} order${report.orders === 1 ? '' : 's'} have a location.`}
        {' '}Free orders and RSVPs show as unknown. Gross is what buyers paid, before refunds.
      </p>

      {!loaded ? (
        <p className="text-sm text-slate-400">Loading…</p>
      ) : !report ? (
        <p className="text-sm text-slate-400">The org-wide report isn’t available.</p>
      ) : report.orders === 0 ? (
        <p className="text-sm text-slate-400">No orders yet.</p>
      ) : (
        <div className="grid gap-6 md:grid-cols-2">
          {table('Top countries', countryRows(report), (r) => countryName(r.country), report.orders)}
          {table('Top cities', report.cities, (r) => cityLabel(r), report.orders)}
        </div>
      )}
      {report && report.other_tickets > 0 && (
        <p className="text-xs text-slate-400 mt-3">
          {report.other_tickets} more ticket{report.other_tickets === 1 ? '' : 's'} came from RSVPs, comps, door sales or imports, with no location.
        </p>
      )}
    </section>
  );
}
