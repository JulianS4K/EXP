// /invoice/:id and /credit-note/:id — the printable receipt / credit note
// (mig 20261001100000, docs/invoices.md). Bare layout (no navbar / footer) so
// the browser's "Print" / "Save as PDF" gives a clean page. The buyer of the
// order and the org's owner / manager / finance can open it; the RPC decides.

import { useEffect, useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Printer } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { formatInTz } from '../lib/datetime';
import {
  addressLines,
  creditNotePath,
  documentFileName,
  documentTitle,
  documentTotals,
  formatCredit,
  formatDocNumber,
  formatMoney,
  formatRate,
  invoicePath,
  refundState,
  taxLines,
  type InvoiceDocument,
} from '../lib/invoices';
import { getCreditNoteDocument, getInvoiceDocument } from '../lib/invoicesApi';

function day(iso: string | null | undefined, tz?: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : formatInTz(d, tz ?? undefined, { dateStyle: 'long' });
}

export default function InvoiceView({ kind }: { kind: 'invoice' | 'credit_note' }) {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { user, loading: authLoading, openAuthModal } = useAuth();
  // undefined = loading; null = not found / not allowed.
  const [doc, setDoc] = useState<InvoiceDocument | null | undefined>(undefined);

  useEffect(() => {
    if (!user || !id) return undefined;
    let cancelled = false;
    setDoc(undefined);
    (kind === 'credit_note' ? getCreditNoteDocument(id) : getInvoiceDocument(id))
      .then((d) => { if (!cancelled) setDoc(d); })
      .catch((e) => {
        console.warn('invoice document unavailable:', e?.message ?? e);
        if (!cancelled) setDoc(null);
      });
    return () => { cancelled = true; };
  }, [user, id, kind]);

  useEffect(() => {
    if (!doc) return undefined;
    const before = document.title;
    document.title = documentFileName(doc);
    return () => { document.title = before; };
  }, [doc]);

  const shell = (body: ReactNode) => (
    <div className="min-h-screen bg-slate-100 text-slate-900 print:bg-white">
      <div className="max-w-3xl mx-auto px-4 py-8 print:p-0 print:max-w-none">{body}</div>
    </div>
  );

  if (!user) {
    return shell(
      <div className="bg-white rounded-2xl border border-slate-200 p-10 text-center">
        <p className="text-sm text-slate-600 mb-4">{authLoading ? 'Loading…' : 'Sign in to see this receipt.'}</p>
        {!authLoading && (
          <button type="button" onClick={() => openAuthModal()}
            className="px-5 py-2.5 rounded bg-slate-900 text-white text-xs font-bold uppercase tracking-widest">
            Sign in
          </button>
        )}
      </div>,
    );
  }
  if (doc === undefined) return shell(<p className="text-center text-slate-400 text-sm py-24">Loading…</p>);
  if (doc === null) {
    return shell(
      <div className="bg-white rounded-2xl border border-slate-200 p-10 text-center">
        <h1 className="text-lg font-bold mb-2">Not found</h1>
        <p className="text-sm text-slate-600">This document doesn't exist, or it isn't on your account.</p>
        <Link to="/my-tickets" className="inline-block mt-4 text-sm font-bold text-tm-blue">My tickets</Link>
      </div>,
    );
  }

  const inv = doc.invoice;
  const cur = inv.currency;
  const cn = doc.credit_note;
  const title = documentTitle(doc);
  const totals = documentTotals(doc);
  const taxes = taxLines(doc.lines, inv.tax_cents);
  const state = refundState(totals);
  const seller = doc.seller;
  const sellerName = seller?.legal_name || seller?.name || 'Organizer';
  const tz = doc.event?.timezone ?? null;

  return shell(
    <>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4 print:hidden">
        <button type="button" onClick={() => (window.history.length > 1 ? navigate(-1) : navigate('/my-tickets'))}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest">
          <ArrowLeft size={14} strokeWidth={2.5} /> Back
        </button>
        <button type="button" onClick={() => window.print()}
          className="inline-flex items-center gap-1.5 px-4 py-2.5 rounded bg-slate-900 text-white text-xs font-bold hover:bg-slate-700">
          <Printer size={14} aria-hidden="true" /> Print / save as PDF
        </button>
      </div>

      <article className="bg-white rounded-2xl border border-slate-200 p-8 md:p-12 print:border-0 print:rounded-none print:p-0 text-sm"
        aria-labelledby="doc-title">
        <header className="flex flex-wrap justify-between gap-6 mb-10">
          <div>
            <h1 id="doc-title" className="text-3xl font-bold tracking-tight">{title}</h1>
            <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-0.5 text-slate-600">
              {cn ? (
                <>
                  <dt>Credit note no.</dt><dd className="font-mono text-slate-900">{formatDocNumber(cn.number)}</dd>
                  <dt>Date</dt><dd>{day(cn.created_at, tz)}</dd>
                  <dt>For invoice</dt>
                  <dd className="font-mono">
                    <Link to={invoicePath(inv.id)} className="text-slate-900 underline print:no-underline">{formatDocNumber(inv.number)}</Link>
                    {' '}of {day(inv.issued_at, tz)}
                  </dd>
                </>
              ) : (
                <>
                  <dt>Invoice no.</dt><dd className="font-mono text-slate-900">{formatDocNumber(inv.number)}</dd>
                  <dt>Date</dt><dd>{day(inv.issued_at, tz)}</dd>
                </>
              )}
              {inv.session_id && (<><dt>Order</dt><dd className="font-mono break-all">{inv.session_id}</dd></>)}
            </dl>
          </div>
          <div className="text-right" aria-label="Seller">
            <p className="font-bold text-base">{sellerName}</p>
            {seller?.legal_name && seller?.name && seller.name !== seller.legal_name && (
              <p className="text-slate-500">trading as {seller.name}</p>
            )}
            {addressLines(seller?.legal_address).map((l) => <p key={l} className="text-slate-600">{l}</p>)}
            {seller?.tax_id && <p className="text-slate-600 mt-1">Tax ID: {seller.tax_id}</p>}
          </div>
        </header>

        <section className="grid md:grid-cols-2 print:grid-cols-2 gap-6 mb-8">
          <div>
            <h2 className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1">Billed to</h2>
            {doc.buyer.name && <p className="font-semibold">{doc.buyer.name}</p>}
            <p className="text-slate-700 break-all">{doc.buyer.email || '—'}</p>
          </div>
          {doc.event && (
            <div>
              <h2 className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1">Event</h2>
              <p className="font-semibold">{doc.event.name}</p>
              <p className="text-slate-600">
                {doc.event.starts_at ? formatInTz(new Date(doc.event.starts_at), tz ?? undefined) : ''}
                {doc.event.venue_name ? ` · ${doc.event.venue_name}` : ''}
              </p>
            </div>
          )}
        </section>

        {cn ? (
          <section aria-label="Credit">
            <table className="w-full mb-6">
              <thead>
                <tr className="text-left text-[10px] font-black uppercase tracking-widest text-slate-400 border-b border-slate-200">
                  <th className="py-2">Description</th>
                  <th className="py-2 text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                <tr className="border-b border-slate-100">
                  <td className="py-2">
                    Refund on invoice {formatDocNumber(inv.number)}
                    {cn.reason ? <span className="text-slate-500"> ({cn.reason.replace(/_/g, ' ')})</span> : null}
                  </td>
                  <td className="py-2 text-right">{formatCredit(cn.amount_cents, cur)}</td>
                </tr>
              </tbody>
            </table>
            <dl className="ml-auto max-w-xs grid grid-cols-[1fr_auto] gap-x-6 gap-y-1">
              <dt className="text-slate-600">Of which tax</dt><dd className="text-right">{formatCredit(cn.tax_cents, cur)}</dd>
              <dt className="font-bold border-t border-slate-200 pt-1">Total credited</dt>
              <dd className="font-bold text-right border-t border-slate-200 pt-1">{formatCredit(cn.amount_cents, cur)}</dd>
            </dl>
            <p className="text-xs text-slate-500 mt-6">The amount goes back to the card that paid for the order.</p>
          </section>
        ) : (
          <section aria-label="Items">
            <table className="w-full mb-6">
              <thead>
                <tr className="text-left text-[10px] font-black uppercase tracking-widest text-slate-400 border-b border-slate-200">
                  <th className="py-2">Item</th>
                  <th className="py-2 text-right">Qty</th>
                  <th className="py-2 text-right">Unit price</th>
                  <th className="py-2 text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {doc.lines.map((l, i) => (
                  <tr key={i} className="border-b border-slate-100">
                    <td className="py-2">
                      {l.name}
                      {l.kind === 'addon' && <span className="text-slate-400 text-xs"> · add-on</span>}
                      {l.tax_cents !== null && l.tax_cents > 0 && (
                        <span className="block text-xs text-slate-400">incl. {formatMoney(l.tax_cents, cur)} {l.tax_name || 'tax'}{formatRate(l.tax_rate) && !l.tax_name ? ` ${formatRate(l.tax_rate)}` : ''}</span>
                      )}
                    </td>
                    <td className="py-2 text-right">{l.quantity}</td>
                    <td className="py-2 text-right">{formatMoney(l.unit_cents, cur)}</td>
                    <td className="py-2 text-right">{formatMoney(l.total_cents, cur)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <dl className="ml-auto max-w-xs grid grid-cols-[1fr_auto] gap-x-6 gap-y-1" aria-label="Totals">
              <dt className="text-slate-600">Subtotal (excl. tax)</dt><dd className="text-right">{formatMoney(totals.netCents, cur)}</dd>
              {taxes.map((t) => (
                <div key={t.label} className="contents">
                  <dt className="text-slate-600">{t.label}{t.rate !== null && !t.label.includes('%') ? ` (${formatRate(t.rate)})` : ''}</dt>
                  <dd className="text-right">{formatMoney(t.cents, cur)}</dd>
                </div>
              ))}
              <dt className="font-bold border-t border-slate-200 pt-1">Total paid</dt>
              <dd className="font-bold text-right border-t border-slate-200 pt-1">{formatMoney(totals.totalCents, cur)}</dd>
              {doc.credit_notes.map((c) => (
                <div key={c.id} className="contents">
                  <dt className="text-slate-600">
                    Refund <Link to={creditNotePath(c.id)} className="font-mono underline print:no-underline">{formatDocNumber(c.number)}</Link>
                  </dt>
                  <dd className="text-right text-rose-700">{formatCredit(c.amount_cents, cur)}</dd>
                </div>
              ))}
              {doc.credit_notes.length > 0 && (
                <>
                  <dt className="font-bold border-t border-slate-200 pt-1">Balance</dt>
                  <dd className="font-bold text-right border-t border-slate-200 pt-1">{formatMoney(totals.balanceCents, cur)}</dd>
                </>
              )}
            </dl>
            <p className="text-xs text-slate-500 mt-6">
              {inv.total_cents > 0 ? 'Prices are all-in: tax is included and no fees were added at checkout.' : ''}
              {state === 'full' && ' This order was refunded in full.'}
              {state === 'partial' && ' Part of this order was refunded (see the credit notes above).'}
              {doc.order.paid_at ? ` Paid by card on ${day(doc.order.paid_at, tz)}.` : ''}
            </p>
          </section>
        )}

        {seller?.invoice_footer && (
          <footer className="mt-10 pt-4 border-t border-slate-200 text-xs text-slate-500 whitespace-pre-line">{seller.invoice_footer}</footer>
        )}
      </article>
    </>,
  );
}
