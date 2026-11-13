// Edit event → Event tokens (mig 20261114110000; docs/pos.md "Event tokens"):
// drink tickets, ride credits, tasting tickets. Owners and managers set a
// product up (price per token, bundles, max per order, expiry grace, whether
// unused tokens are refundable); each offer becomes an add-on online and an
// item at the door, kept in step by the server. Below it, the report: sold /
// redeemed / expired / refunded / outstanding per product, the exceptions
// offline devices ran into, CSV / XLSX (logged as export.run), refunds of
// unused tokens and the expiry. Every rule is enforced in SQL; this panel
// only mirrors them. Hidden before the migration (the products call fails).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Coins, Download, Plus, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import { logExport } from '../lib/orgAuditApi';
import { saveXlsx } from '../lib/xlsxDownload';
import {
  bundleUnitCents, reportAddsUp, TOKEN_EXCEPTION_HEADER, TOKEN_REPORT_HEADER, tokenDraftProblem, tokenExceptionRows,
  tokenReportRows, tokenRuleText, type TokenProductDraft, type TokenReport,
} from '../lib/eventTokens';
import {
  cancelTokenRefund, expireTokens, listTokenProducts, refundUnusedTokens, saveTokenProduct, tokenReport, type TokenProduct,
} from '../lib/eventTokensApi';

const BLANK: TokenProductDraft = {
  name: '', unit_label: 'token', price_cents: 500, bundles: [], max_per_order: 50, refundable: false, grace_hours: 0, active: true,
};

const inputCls =
  'w-full bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-4 text-slate-900 font-bold ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary focus:bg-white transition-all';
const labelCls = 'block text-[10px] font-bold text-slate-600 uppercase tracking-widest ml-1 mb-1';
const smallBtn = 'px-3 py-2 rounded-xl text-[11px] font-black uppercase tracking-widest border border-slate-300 text-slate-700 '
  + 'hover:border-slate-900 disabled:opacity-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

const dollars = (cents: number) => (cents / 100).toFixed(2);
const toCents = (v: string) => Math.round((parseFloat(v) || 0) * 100);

export default function EventTokensPanel({ eventId, eventName, orgId }: { eventId: string; eventName: string; orgId?: string | null }) {
  const { toast } = useToast();
  const [products, setProducts] = useState<TokenProduct[] | null>(null);
  const [draft, setDraft] = useState<TokenProductDraft>({ ...BLANK });
  const [saving, setSaving] = useState(false);
  const [report, setReport] = useState<TokenReport | null>(null);
  const [refundLot, setRefundLot] = useState<string | null>(null);
  const [refundWhy, setRefundWhy] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const list = await listTokenProducts(eventId);
      setProducts(list);
      if (list.length > 0) setReport(await tokenReport(eventId).catch(() => null));
    } catch {
      setProducts(null);
    }
  }, [eventId]);
  useEffect(() => { void load(); }, [load]);

  const problem = useMemo(() => tokenDraftProblem(draft), [draft]);
  if (products === null) return null;

  const save = async () => {
    if (problem) return;
    setSaving(true);
    try {
      await saveTokenProduct(eventId, { ...draft, name: draft.name.trim(), unit_label: draft.unit_label.trim() });
      toast({ kind: 'success', message: draft.id ? 'Event tokens saved.' : 'Event tokens added: on sale online and at the door.' });
      setDraft({ ...BLANK });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message || 'Could not save.' });
    } finally {
      setSaving(false);
    }
  };

  const edit = (p: TokenProduct) => setDraft({
    id: p.id, name: p.name, unit_label: p.unit_label, price_cents: p.price_cents, bundles: p.bundles ?? [],
    max_per_order: p.max_per_order, refundable: p.refundable, grace_hours: p.grace_hours, active: p.active,
  });

  const setBundle = (i: number, patch: Partial<{ credits: number; price_cents: number }>) =>
    setDraft({ ...draft, bundles: draft.bundles.map((b, j) => (j === i ? { ...b, ...patch } : b)) });

  const currency = report?.currency ?? 'USD';
  const exportCsv = async () => {
    const rows = tokenReportRows(report);
    const ex = tokenExceptionRows(report);
    downloadCsv(csvFileName(['event-tokens', eventName]), toCsv(TOKEN_REPORT_HEADER, rows)
      + (ex.length ? '\r\n\r\n' + toCsv(TOKEN_EXCEPTION_HEADER, ex).replace(/^﻿/, '') : ''));
    await logExport(orgId ?? null, 'event_tokens', rows.length + ex.length, eventId);
  };
  const exportXlsx = () => void saveXlsx(['event-tokens', eventName], [
    { name: 'Event tokens', header: TOKEN_REPORT_HEADER, rows: tokenReportRows(report), moneyColumns: [3, 5, 7, 9, 11] },
    { name: 'Exceptions', header: TOKEN_EXCEPTION_HEADER, rows: tokenExceptionRows(report) },
  ], { orgId, eventId, kind: 'event_tokens' });

  const refund = async (lotId: string) => {
    if (refundWhy.trim().length < 3) return;
    setBusy(true);
    try {
      const r = await refundUnusedTokens(eventId, lotId, refundWhy.trim());
      toast({ kind: 'success', message: r.source === 'pos'
        ? `Hand back ${formatCents(r.amount_cents, currency)} from your drawer.`
        : r.pending ? `Refunding ${formatCents(r.amount_cents, currency)} to the buyer's payment: the tokens come off once it goes through.`
        : r.amount_cents > 0 ? `Refunded ${formatCents(r.amount_cents, currency)}.` : 'Tokens taken off.' });
      setRefundLot(null);
      setRefundWhy('');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      await load();
    }
  };

  // A pending refund: ask again (the same key, or a new one once the last request failed).
  const retry = async (lotId: string) => {
    setBusy(true);
    try {
      await refundUnusedTokens(eventId, lotId, 'retry the refund');
      toast({ kind: 'success', message: 'Refund sent again: the tokens come off once it goes through.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      await load();
    }
  };

  const putBack = async (lotId: string) => {
    setBusy(true);
    try {
      const r = await cancelTokenRefund(eventId, lotId);
      toast({ kind: 'success', message: `Put back: ${r.credits} tokens can be spent again.` });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      await load();
    }
  };

  const expire = async () => {
    setBusy(true);
    try {
      const r = await expireTokens(eventId);
      toast({ kind: 'success', message: r.lots ? `${r.credits} unused tokens expired.` : 'Nothing to expire yet.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      await load();
    }
  };

  return (
    <section data-testid="event-tokens-panel" aria-labelledby="event-tokens-title"
      className="bg-white p-6 md:p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6">
      <div className="flex items-center space-x-3">
        <Coins className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 id="event-tokens-title" className="text-xs font-bold text-slate-600 uppercase tracking-widest leading-none">Event tokens</h2>
      </div>
      <p className="text-slate-600 text-xs font-bold -mt-2">
        Drink tickets, ride credits, tasting tickets. Sold online with the order and at the door; staff take them off the
        guest&apos;s ticket or token code in the door app&apos;s Tokens tab.
      </p>

      {products.length > 0 && (
        <ul className="space-y-2">
          {products.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-3 bg-slate-50 rounded-2xl px-5 py-3">
              <div className="min-w-0">
                <p className="font-bold text-slate-900 text-sm truncate">{p.name}{p.active ? '' : ' (not on sale)'}</p>
                <p className="text-slate-600 text-xs font-bold">
                  {formatCents(p.price_cents, currency)} a {p.unit_label}
                  {(p.bundles ?? []).map((b) => ` · ${b.credits} for ${formatCents(b.price_cents, currency)}`).join('')}
                  {` · up to ${p.max_per_order} an order · ${p.refundable ? 'refundable' : 'not refundable'}`}
                </p>
              </div>
              <button type="button" className={smallBtn} onClick={() => edit(p)} aria-label={`Edit ${p.name}`}>Edit</button>
            </li>
          ))}
        </ul>
      )}

      {/* Not a <form>: Edit event's own form wraps this panel. */}
      <div className="space-y-4" role="group" aria-label={draft.id ? 'Edit event tokens' : 'Add event tokens'}>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <label className="sm:col-span-2">
            <span className={labelCls}>Name</span>
            <input value={draft.name} maxLength={60} placeholder="Drink token" className={inputCls}
              onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
          </label>
          <label>
            <span className={labelCls}>One token is a</span>
            <input value={draft.unit_label} maxLength={20} placeholder="drink" className={inputCls}
              onChange={(e) => setDraft({ ...draft, unit_label: e.target.value })} />
          </label>
          <label>
            <span className={labelCls}>Price per token ($)</span>
            <input type="number" min={0.01} step="0.01" value={dollars(draft.price_cents)} className={inputCls}
              onChange={(e) => setDraft({ ...draft, price_cents: toCents(e.target.value) })} />
          </label>
          <label>
            <span className={labelCls}>Max tokens per order</span>
            <input type="number" min={1} max={500} value={draft.max_per_order} className={inputCls}
              onChange={(e) => setDraft({ ...draft, max_per_order: parseInt(e.target.value, 10) || 0 })} />
          </label>
          <label>
            <span className={labelCls}>Expire hours after the event</span>
            <input type="number" min={0} max={720} value={draft.grace_hours} className={inputCls}
              onChange={(e) => setDraft({ ...draft, grace_hours: parseInt(e.target.value, 10) || 0 })} />
          </label>
        </div>

        <fieldset className="space-y-2">
          <legend className={labelCls}>Bundles (optional)</legend>
          {draft.bundles.map((b, i) => (
            <div key={i} className="flex flex-wrap items-end gap-3">
              <label className="w-28">
                <span className={labelCls}>Tokens</span>
                <input type="number" min={2} max={500} value={b.credits} className={inputCls}
                  onChange={(e) => setBundle(i, { credits: parseInt(e.target.value, 10) || 0 })} />
              </label>
              <label className="w-36">
                <span className={labelCls}>Price ($)</span>
                <input type="number" min={0.01} step="0.01" value={dollars(b.price_cents)} className={inputCls}
                  onChange={(e) => setBundle(i, { price_cents: toCents(e.target.value) })} />
              </label>
              <span className="text-xs font-bold text-slate-600 pb-3">{formatCents(bundleUnitCents(b), currency)} each</span>
              <button type="button" className="pb-3 text-slate-500 hover:text-red-600" aria-label={`Remove the bundle of ${b.credits}`}
                onClick={() => setDraft({ ...draft, bundles: draft.bundles.filter((_, j) => j !== i) })}>
                <Trash2 className="w-4 h-4" aria-hidden="true" />
              </button>
            </div>
          ))}
          {draft.bundles.length < 5 && (
            <button type="button" className={smallBtn}
              onClick={() => setDraft({ ...draft, bundles: [...draft.bundles, { credits: 10, price_cents: draft.price_cents * 9 }] })}>
              <Plus className="inline w-3 h-3 mr-1" aria-hidden="true" />Add a bundle
            </button>
          )}
        </fieldset>

        <label className="flex items-start gap-2 text-sm font-bold text-slate-700">
          <input type="checkbox" className="mt-1" checked={draft.refundable} onChange={(e) => setDraft({ ...draft, refundable: e.target.checked })} />
          <span>Unused tokens are refundable
            <span className="block text-xs font-normal text-slate-600">After the event you refund what a buyer didn&apos;t use, to how they paid. Off: unused tokens expire.</span>
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm font-bold text-slate-700">
          <input type="checkbox" className="mt-1" checked={draft.active} onChange={(e) => setDraft({ ...draft, active: e.target.checked })} />
          <span>On sale</span>
        </label>
        <p className="text-xs text-slate-600" data-testid="event-tokens-rule">Buyers see: {tokenRuleText(eventName || 'this event', draft)}</p>
        {problem && draft.name.trim() !== '' && <p role="alert" className="text-xs font-bold text-red-700">{problem}</p>}
        <div className="flex gap-3">
          <button type="button" onClick={() => void save()} disabled={saving || !!problem}
            className="flex-1 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase tracking-widest text-xs disabled:opacity-50">
            {saving ? 'Saving…' : draft.id ? 'Save tokens' : 'Add tokens'}
          </button>
          {draft.id && <button type="button" className={smallBtn} onClick={() => setDraft({ ...BLANK })}>Cancel</button>}
        </div>
      </div>

      {report && report.products.length > 0 && (
        <div className="space-y-4 border-t border-slate-100 pt-6" data-testid="event-tokens-report">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-xs font-bold text-slate-600 uppercase tracking-widest flex-1">Token report</h3>
            <button type="button" className={smallBtn} onClick={() => void exportCsv()}><Download className="inline w-3 h-3 mr-1" aria-hidden="true" />CSV</button>
            <button type="button" className={smallBtn} onClick={exportXlsx}><Download className="inline w-3 h-3 mr-1" aria-hidden="true" />XLSX</button>
            <button type="button" className={smallBtn} disabled={busy} onClick={() => void expire()}>Expire unused</button>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <caption className="sr-only">Event tokens per product</caption>
              <thead className="text-slate-600 uppercase tracking-widest">
                <tr>
                  <th scope="col" className="py-2 pr-3">Tokens</th><th scope="col" className="py-2 pr-3">Sold</th>
                  <th scope="col" className="py-2 pr-3">Redeemed</th><th scope="col" className="py-2 pr-3">Expired</th>
                  <th scope="col" className="py-2 pr-3">Refunded</th><th scope="col" className="py-2 pr-3">Outstanding</th>
                  <th scope="col" className="py-2">Exceptions</th>
                </tr>
              </thead>
              <tbody className="text-slate-900 font-bold">
                {report.products.map((p) => (
                  <tr key={p.product_id} className="border-t border-slate-100">
                    <th scope="row" className="py-2 pr-3">{p.name}{reportAddsUp(p) ? '' : ' (check)'}</th>
                    <td className="py-2 pr-3">{p.sold_credits} · {formatCents(p.sold_cents, currency)}</td>
                    <td className="py-2 pr-3">{p.redeemed_credits} · {formatCents(p.redeemed_cents, currency)}</td>
                    <td className="py-2 pr-3">{p.expired_credits} · {formatCents(p.expired_cents, currency)}</td>
                    <td className="py-2 pr-3">{p.refunded_credits} · {formatCents(p.refunded_cents, currency)}</td>
                    <td className="py-2 pr-3">{p.outstanding_credits} · {formatCents(p.outstanding_cents, currency)}</td>
                    <td className="py-2">{p.overspent_count + p.rejected_count
                      ? `${p.overspent_credits} overspent, ${p.rejected_credits} refused at sync` : 'none'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {report.exceptions.length > 0 && (
            <div>
              <h4 className="text-[11px] font-bold text-slate-600 uppercase tracking-widest mb-1">Exceptions from offline devices</h4>
              <ul className="text-xs text-slate-700 space-y-1">
                {report.exceptions.slice(0, 50).map((x) => (
                  <li key={x.id}>
                    {x.kind === 'overspent' ? `${x.credits_short} of ${x.credits_asked} ${x.product} given beyond the balance`
                      : `${x.credits_short} ${x.product} refused at sync (${x.reason ?? 'code'})`}
                    {` · ${x.on_ticket ? 'on a ticket' : `code …${x.card_last4 ?? ''}`} · ${x.device ?? 'device'} · ${new Date(x.offline_at).toLocaleString()}`}
                  </li>
                ))}
              </ul>
            </div>
          )}
          {report.refundable.length > 0 && (
            <div>
              <h4 className="text-[11px] font-bold text-slate-600 uppercase tracking-widest mb-1">Unused, refundable</h4>
              <ul className="space-y-2">
                {report.refundable.slice(0, 100).map((l) => (
                  <li key={l.lot_id} className="flex flex-wrap items-center gap-2 text-xs text-slate-700">
                    <span className="flex-1 min-w-0">
                      {l.credits_left} {l.product} · {formatCents(l.value_left, currency)} · {l.source === 'online' ? 'bought online' : l.source === 'pos' ? 'cash at the door' : 'comp'}
                      {l.on_ticket ? ' · on a ticket' : ` · code …${l.card_last4 ?? ''}`}
                      {l.status === 'refund_pending' && (l.request_status === 'failed' || l.request_status === 'canceled'
                        ? ' · refund didn\'t go through' : ' · refund pending')}
                    </span>
                    {l.status === 'refund_pending' && (
                      <>
                        <button type="button" className={smallBtn} disabled={busy}
                          onClick={() => void retry(l.lot_id)}>
                          Try again
                        </button>
                        {l.request_status !== 'claimed' && l.request_status !== 'pending' && (
                          <button type="button" className={smallBtn} disabled={busy} onClick={() => void putBack(l.lot_id)}>Put back</button>
                        )}
                      </>
                    )}
                    {l.status === 'refund_pending' ? null : refundLot === l.lot_id ? (
                      <>
                        <label className="sr-only" htmlFor={`refund-why-${l.lot_id}`}>Why</label>
                        <input id={`refund-why-${l.lot_id}`} value={refundWhy} maxLength={300} placeholder="Why"
                          className="border border-slate-300 rounded-lg px-2 py-1" onChange={(e) => setRefundWhy(e.target.value)} />
                        <button type="button" className={smallBtn} disabled={busy || refundWhy.trim().length < 3} onClick={() => void refund(l.lot_id)}>
                          Refund {formatCents(l.value_left, currency)}
                        </button>
                      </>
                    ) : (
                      <button type="button" className={smallBtn} onClick={() => { setRefundLot(l.lot_id); setRefundWhy(''); }}>Refund unused</button>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
