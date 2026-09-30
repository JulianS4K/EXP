// Money (settlement) for one event, on OrganizerEventReport. Read-only.
//
// Owner / manager / finance see what the event took and where it went: Exos
// checkouts (gross, tax, refunds, the Exos fee, card fees: Stripe's actual fee
// once recorded, else the checkout estimate), marketplace orders (proceeds,
// Exos fee, organizer net), promoter commissions, and the organizer's net;
// plus a per-order CSV. Aggregation is src/lib/settlement.ts; reads are
// src/lib/settlementApi.ts. Renders nothing for other roles or when the money
// views aren't on this database yet (mig 20260929131000). Per-order invoice
// numbers (links to the printable receipt) and the CSV's invoice_number come
// from exos_invoice_totals (mig 20261001100000) when it's there.

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Download, Landmark } from 'lucide-react';
import { Event } from '../types';
import { formatCents } from '../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import { getEventMoney, type EventMoneyData } from '../lib/settlementApi';
import { SETTLEMENT_CSV_HEADER, settlementCsvRows, summarizeSettlement } from '../lib/settlement';
import { formatDocNumber, invoicePath, invoicesBySession, type EventInvoiceRow } from '../lib/invoices';
import { listEventInvoices } from '../lib/invoicesApi';

export default function SettlementPanel({ event, canView }: { event: Event; canView: boolean }) {
  const [data, setData] = useState<EventMoneyData | null>(null);
  const [invoices, setInvoices] = useState<EventInvoiceRow[]>([]);

  useEffect(() => {
    if (!canView) return undefined;
    let cancelled = false;
    void getEventMoney(event.id).then((d) => {
      if (!cancelled) setData(d);
    });
    void listEventInvoices(event.id).then((rows) => {
      if (!cancelled) setInvoices(rows);
    });
    return () => {
      cancelled = true;
    };
  }, [event.id, canView]);

  const s = useMemo(
    () => (data ? summarizeSettlement({ ...data, currency: event.currency || 'USD' }) : null),
    [data, event.currency],
  );

  if (!canView || !data || !s) return null;
  const money = (cents: number) => formatCents(cents, s.currency);
  const cardLabel =
    s.exos.cardFeeBasis === 'actual' ? 'Card fees (actual)'
      : s.exos.cardFeeBasis === 'estimate' ? 'Card fees (estimate)'
      : s.exos.cardFeeBasis === 'mixed' ? 'Card fees (actual + estimate)'
      : 'Card fees';
  const hasMarketplace = s.marketplace.orders + s.marketplace.cancelledOrders > 0;

  const exportCsv = () => {
    downloadCsv(
      csvFileName(['settlement', event.title]),
      toCsv(SETTLEMENT_CSV_HEADER, settlementCsvRows(data.orders, data.marketplace,
        new Map([...invoicesBySession(invoices)].map(([sid, i]) => [sid, i.number])))),
    );
  };

  const stat = (label: string, value: string, hint?: string) => (
    <div className="bg-slate-50 rounded-xl px-4 py-3">
      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{label}</p>
      <p className="text-lg font-black text-slate-800">{value}</p>
      {hint && <p className="text-[10px] text-slate-400 mt-0.5">{hint}</p>}
    </div>
  );

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="money-title">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-1">
        <div className="flex items-center gap-2">
          <Landmark className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h3 id="money-title" className="text-sm font-bold text-slate-700">Money</h3>
        </div>
        <button
          type="button"
          onClick={exportCsv}
          disabled={data.orders.length + data.marketplace.length === 0}
          className="inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600 hover:bg-slate-50 disabled:opacity-40"
        >
          <Download size={12} aria-hidden="true" /> Orders CSV
        </button>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Exos sales are paid out by Stripe directly to your connected account. Exos never holds that money.
        {hasMarketplace && ' Marketplace sales are paid by Exos after the marketplace pays us (see Payouts).'}
      </p>

      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Exos checkout</p>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        {stat('Tickets sold', s.exos.tickets === null ? '—' : String(s.exos.tickets), `${s.exos.orders} order${s.exos.orders === 1 ? '' : 's'}`)}
        {stat('Gross', money(s.exos.grossCents))}
        {stat('Tax (included)', money(s.exos.taxCents))}
        {stat('Refunds', money(s.exos.refundedCents))}
        {stat('Exos fee', money(s.exos.exosFeeCents), s.exos.feeFreeOrders > 0 ? `${s.exos.feeFreeOrders} in the fee-free period` : undefined)}
        {stat(cardLabel, money(s.exos.cardFeeCents),
          s.exos.cardFeeBasis === 'mixed' ? `${s.exos.cardFeeActualOrders} actual, ${s.exos.cardFeeEstimateOrders} estimated` : undefined)}
        {stat('Your net', money(s.exos.organizerNetCents), 'gross − application fee (Exos fee + card-fee estimate)')}
        {stat('Your net after refunds', money(s.exos.organizerNetAfterRefundsCents), 'fees come back in proportion')}
      </div>

      {hasMarketplace && (
        <>
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Marketplaces</p>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            {stat('Tickets sold', String(s.marketplace.tickets), `${s.marketplace.orders} order${s.marketplace.orders === 1 ? '' : 's'}${s.marketplace.cancelledOrders ? `, ${s.marketplace.cancelledOrders} cancelled` : ''}`)}
            {stat('Proceeds', money(s.marketplace.proceedsCents), 'after the marketplace fee')}
            {stat('Exos fee', money(s.marketplace.exosFeeCents))}
            {stat('Your net', money(s.marketplace.organizerNetCents), `${money(s.marketplace.paidCents)} paid out so far`)}
          </div>
        </>
      )}

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-3">
        {stat('Promoter commissions', money(s.commissions.accruedCents), s.commissions.tickets ? `${money(s.commissions.paidCents)} paid` : undefined)}
        {stat('Organizer net', money(s.organizerNetCents), 'after refunds, all channels')}
        {stat('After commissions', money(s.organizerNetAfterCommissionsCents))}
      </div>

      {invoices.length > 0 && (
        <details className="mt-4">
          <summary className="text-[10px] font-black text-slate-400 uppercase tracking-widest cursor-pointer hover:text-slate-600">
            Receipts ({invoices.length})
          </summary>
          <div className="overflow-x-auto mt-2">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                  <th className="py-2 font-black">Invoice</th>
                  <th className="py-2 font-black">Order</th>
                  <th className="py-2 font-black">Date</th>
                  <th className="py-2 font-black text-right">Total</th>
                  <th className="py-2 font-black text-right">Refunded</th>
                </tr>
              </thead>
              <tbody>
                {invoices.map((i) => (
                  <tr key={i.id} className="border-b border-slate-50 last:border-b-0">
                    <td className="py-2">
                      <Link to={invoicePath(i.id)} className="font-mono text-tm-blue hover:underline">{formatDocNumber(i.number)}</Link>
                    </td>
                    <td className="py-2 font-mono text-xs text-slate-500 break-all">{i.session_id ?? '—'}</td>
                    <td className="py-2 text-slate-600 text-xs">{i.issued_at ? new Date(i.issued_at).toLocaleDateString() : ''}</td>
                    <td className="py-2 text-right">{formatCents(i.total_cents, i.currency)}</td>
                    <td className="py-2 text-right text-slate-500">{i.refunded_cents ? formatCents(i.refunded_cents, i.currency) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
      )}

      {(s.exos.ordersWithoutFees > 0 || s.marketplace.unpricedOrders > 0 || s.mixedCurrencies) && (
        <ul className="text-xs text-amber-700 space-y-1 mt-3">
          {s.exos.ordersWithoutFees > 0 && (
            <li>{s.exos.ordersWithoutFees} older order{s.exos.ordersWithoutFees === 1 ? ' has' : 's have'} no fee record, so {s.exos.ordersWithoutFees === 1 ? "it isn't" : "they aren't"} in the fee and net totals.</li>
          )}
          {s.marketplace.unpricedOrders > 0 && (
            <li>{s.marketplace.unpricedOrders} marketplace order{s.marketplace.unpricedOrders === 1 ? ' has' : 's have'} no proceeds reported yet.</li>
          )}
          {s.mixedCurrencies && <li>These orders are in more than one currency; the totals add them as they are.</li>}
        </ul>
      )}
    </section>
  );
}
