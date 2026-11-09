// Sales tax for one event, by jurisdiction (the venue) and rate, under the
// event's Money section (mig 20261108100000). Read-only; owner / manager /
// finance. Hidden when the report can't be read or the event has no tax.

import { useEffect, useState } from 'react';
import type { Event } from '../../types';
import type { SalesTaxRow } from '../../lib/journal';
import { getSalesTax } from '../../lib/journalApi';
import SalesTaxTable from './SalesTaxTable';

export default function EventSalesTax({ event, canView }: { event: Event; canView: boolean }) {
  const [rows, setRows] = useState<SalesTaxRow[] | null>(null);

  useEffect(() => {
    if (!canView || !event.orgId) return undefined;
    let cancelled = false;
    void getSalesTax(event.orgId, { from: null, to: null, eventId: event.id }).then((r) => {
      if (!cancelled) setRows(r);
    });
    return () => {
      cancelled = true;
    };
  }, [event.id, event.orgId, canView]);

  if (!canView || !rows || rows.length === 0) return null;
  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="sales-tax-title">
      <h3 id="sales-tax-title" className="text-sm font-bold text-slate-700 mb-1">Sales tax</h3>
      <p className="text-xs text-slate-400 mb-4">
        Tax collected on this event's sales, by the venue's location and the tax rule, less tax on refunds. Exos doesn't file or
        remit sales tax: the rates are the ones you set.
      </p>
      <SalesTaxTable rows={rows} fileParts={[event.title]} />
    </section>
  );
}
