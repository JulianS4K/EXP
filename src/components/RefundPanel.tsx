// Refund panel (seller side): send money back through Stripe from Exos.
//
// Lives on OrganizerEventReport. Owner / manager / finance pick an order, then
// refund the whole order, chosen tickets (full or a partial amount each), or a
// custom amount. A ticket refunded in full is voided once Stripe accepts the
// refund; a partial refund leaves it valid. "Refund everyone" (behind a typed
// confirmation) refunds every paid order, e.g. when the show is cancelled.
// The exos-refund edge function + mig 20260926040000 re-check every amount and
// the caller's role; nothing here is trusted. With payments off the panel is
// shown disabled.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { RotateCcw, ChevronDown, ChevronUp } from 'lucide-react';
import { Event } from '../types';
import { paymentsEnabled } from '../lib/payments';
import { cancelEvent } from '../lib/events';
import {
  formatCents,
  newRefundNonce,
  parseAmountToCents,
  planOrderAmount,
  planTicketRefund,
  type PlanResult,
  type RefundOrder,
  type RefundPreview,
} from '../lib/refunds';
import { getRefundPreview, listRefundOrders, refundEventBatch, refundOrder, retryRefund } from '../lib/refundsApi';
import { useToast } from '../context/ToastContext';

const CONFIRM_WORD = 'REFUND ALL';

export default function RefundPanel({
  event,
  canRefund,
  canCancel,
  onChanged,
}: {
  event: Event;
  /** owner / manager / finance */
  canRefund: boolean;
  /** owner / manager: may also cancel the event in the refund-everyone flow */
  canCancel: boolean;
  /** Called after money moved, so the page can reload tickets / analytics. */
  onChanged?: () => void;
}) {
  const enabled = paymentsEnabled();
  const { toast } = useToast();
  const [orders, setOrders] = useState<RefundOrder[]>([]);
  const [loading, setLoading] = useState(false);
  const [query, setQuery] = useState('');
  const [openId, setOpenId] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!enabled || !canRefund) return;
    setLoading(true);
    try {
      setOrders(await listRefundOrders(event.id));
    } catch (err: any) {
      console.error('refund orders load failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not load orders.' });
    } finally {
      setLoading(false);
    }
  }, [enabled, canRefund, event.id, toast]);

  useEffect(() => {
    load();
  }, [load]);

  const changed = useCallback(() => {
    void load();
    onChanged?.();
  }, [load, onChanged]);

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    const list = q
      ? orders.filter((o) => (o.buyerEmail ?? '').toLowerCase().includes(q) || o.sessionId.toLowerCase().includes(q))
      : orders;
    return list.slice(0, 50);
  }, [orders, query]);

  if (!canRefund) return null;

  const header = (
    <>
      <div className="flex items-center gap-2 mb-1">
        <RotateCcw className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Refunds</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Send money back to the card that paid. Tickets refunded in full are voided; a partial refund keeps them valid.
        Refunds come out of your Stripe balance.
      </p>
    </>
  );

  if (!enabled) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm mb-6 opacity-60" aria-disabled="true">
        {header}
        <p role="note" className="text-xs text-slate-500 border border-slate-200 rounded-lg px-3 py-2">
          Online payments are switched off, so there's nothing to refund here. To cancel a ticket, void it in the attendee list.
        </p>
      </div>
    );
  }

  const totalRefundable = orders.reduce((s, o) => s + o.refundableCents, 0);
  const currency = orders[0]?.currency || event.currency || 'USD';

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      {header}

      <div className="flex flex-wrap items-center gap-3 mb-3">
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search by buyer email or order id"
          className="flex-1 min-w-[200px] border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-1.5 text-sm rounded-lg"
        />
        <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">
          {orders.length} paid order{orders.length === 1 ? '' : 's'} · {formatCents(totalRefundable, currency)} refundable
        </span>
      </div>

      {loading && orders.length === 0 ? (
        <p className="text-xs text-slate-400">Loading orders…</p>
      ) : shown.length === 0 ? (
        <p className="text-xs text-slate-400">{orders.length === 0 ? 'No paid orders yet.' : 'No orders match.'}</p>
      ) : (
        <ul className="divide-y divide-slate-100 border border-slate-100 rounded-xl mb-2">
          {shown.map((o) => (
            <li key={o.sessionId} className="px-3 py-2">
              <button
                type="button"
                onClick={() => setOpenId(openId === o.sessionId ? null : o.sessionId)}
                className="w-full flex flex-wrap items-center gap-x-3 gap-y-1 text-left text-xs"
                aria-expanded={openId === o.sessionId}
              >
                <span className="font-bold text-slate-700 min-w-[160px] truncate">{o.buyerEmail || 'Unknown buyer'}</span>
                <span className="text-slate-400">{o.createdAt.toLocaleDateString()}</span>
                <span className="text-slate-500">
                  Paid {formatCents(o.amountCents, o.currency)}
                  {o.refundedCents > 0 ? ` · refunded ${formatCents(o.refundedCents, o.currency)}` : ''}
                </span>
                <span className="text-slate-400">
                  {o.activeTickets}/{o.tickets} valid
                </span>
                {o.openRequests > 0 && (
                  <span className="text-[10px] font-black uppercase tracking-widest text-amber-600">in progress</span>
                )}
                <span className="ml-auto font-bold text-slate-700">{formatCents(o.refundableCents, o.currency)} left</span>
                {openId === o.sessionId ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
              </button>
              {openId === o.sessionId && <OrderRefundForm sessionId={o.sessionId} onChanged={changed} />}
            </li>
          ))}
        </ul>
      )}
      {orders.length > shown.length && !query && (
        <p className="text-[10px] text-slate-400 mb-2">Showing the newest 50. Search to find others.</p>
      )}

      <RefundEveryone event={event} canCancel={canCancel} refundableCents={totalRefundable} currency={currency} onDone={changed} />
    </div>
  );
}

type Mode = 'order' | 'tickets' | 'amount';

function OrderRefundForm({ sessionId, onChanged }: { sessionId: string; onChanged: () => void }) {
  const { toast } = useToast();
  const [preview, setPreview] = useState<RefundPreview | null>(null);
  const [mode, setMode] = useState<Mode>('order');
  const [picked, setPicked] = useState<Record<string, string>>({}); // ticketId -> '' (full) or partial amount text
  const [amountText, setAmountText] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  // One nonce per intended refund: a retry after a network error reuses it,
  // so the server hands back the same request instead of refunding twice.
  const [nonce, setNonce] = useState(newRefundNonce);

  const load = useCallback(async () => {
    try {
      setPreview(await getRefundPreview(sessionId));
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not load this order.' });
    }
  }, [sessionId, toast]);

  useEffect(() => {
    load();
  }, [load]);

  if (!preview) return <p className="text-xs text-slate-400 py-2">Loading…</p>;
  const cur = preview.currency;

  const plan: PlanResult = (() => {
    if (mode === 'order') {
      return preview.refundableCents > 0
        ? { ok: true as const, totalCents: preview.refundableCents, voids: preview.tickets.filter((t) => t.status === 'active').map((t) => t.ticketId), items: [] }
        : { ok: false as const, error: 'Nothing left to refund on this order.' };
    }
    if (mode === 'tickets') {
      const picks = Object.keys(picked).map((ticketId) => {
        const txt = picked[ticketId] ?? '';
        if (txt.trim() === '') return { ticketId };
        return { ticketId, amountCents: parseAmountToCents(txt) ?? -1 };
      });
      return planTicketRefund(preview, picks);
    }
    return planOrderAmount(preview.refundableCents, parseAmountToCents(amountText));
  })();

  const submit = async () => {
    if (!plan.ok) return;
    const voidNote = plan.voids.length > 0 ? ` ${plan.voids.length} ticket${plan.voids.length === 1 ? '' : 's'} will be voided.` : ' No tickets are voided.';
    if (!window.confirm(`Refund ${formatCents(plan.totalCents, cur)} to the buyer's card?${voidNote} This can't be undone.`)) return;
    setBusy(true);
    try {
      const out = await refundOrder({
        sessionId,
        nonce,
        reason: reason.trim() || undefined,
        wholeOrder: mode === 'order',
        items: mode === 'tickets' ? plan.items : undefined,
        amountCents: mode === 'amount' ? plan.totalCents : undefined,
      });
      if (out.status === 'succeeded' || out.status === 'pending') {
        toast({
          kind: 'success',
          message: `Refunded ${formatCents(out.amountCents ?? plan.totalCents, cur)}${out.status === 'pending' ? ' (processing)' : ''}.${
            out.voided ? ` ${out.voided} ticket${out.voided === 1 ? '' : 's'} voided.` : ''
          }`,
        });
        setNonce(newRefundNonce());
        setPicked({});
        setAmountText('');
        setReason('');
        onChanged();
      } else if (out.status === 'claimed') {
        toast({ kind: 'warn', message: out.error || "Stripe didn't answer. Try again; it won't refund twice." });
      } else {
        toast({ kind: 'error', message: out.error || 'Stripe refused the refund.' });
        setNonce(newRefundNonce());
      }
    } catch (err: any) {
      // Network or server error: keep the nonce so a retry can't double-refund.
      toast({ kind: 'error', message: err?.message || 'Refund failed.' });
    } finally {
      setBusy(false);
      await load();
    }
  };

  const retry = async (requestId: string) => {
    setBusy(true);
    try {
      const out = await retryRefund(requestId);
      toast({
        kind: out.status === 'succeeded' || out.status === 'pending' ? 'success' : 'error',
        message: out.status === 'succeeded' || out.status === 'pending' ? 'Refund sent.' : out.error || 'Refund failed.',
      });
      onChanged();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Retry failed.' });
    } finally {
      setBusy(false);
      await load();
    }
  };

  const tab = (m: Mode, label: string) => (
    <button
      type="button"
      onClick={() => setMode(m)}
      className={`px-3 py-1 rounded-lg text-[11px] font-bold ${mode === m ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-500'}`}
    >
      {label}
    </button>
  );

  return (
    <div className="mt-3 mb-1 border-t border-slate-100 pt-3 text-xs">
      <p className="text-slate-500 mb-3">
        Paid {formatCents(preview.amountCents, cur)} · refunded {formatCents(preview.refundedCents, cur)} ·{' '}
        <span className="font-bold text-slate-700">{formatCents(preview.refundableCents, cur)} refundable</span>
      </p>

      {preview.refundableCents > 0 && (
        <>
          <div className="flex gap-2 mb-3">
            {tab('order', 'Whole order')}
            {tab('tickets', 'Pick tickets')}
            {tab('amount', 'Custom amount')}
          </div>

          {mode === 'tickets' && (
            <ul className="space-y-1 mb-3">
              {preview.tickets.map((t) => {
                const left = Math.max(t.shareCents - t.refundedCents, 0);
                const on = t.ticketId in picked;
                return (
                  <li key={t.ticketId} className="flex flex-wrap items-center gap-2">
                    <label className="flex items-center gap-2 min-w-[220px]">
                      <input
                        type="checkbox"
                        disabled={left <= 0}
                        checked={on}
                        onChange={(e) =>
                          setPicked((p) => {
                            const next = { ...p };
                            if (e.target.checked) next[t.ticketId] = '';
                            else delete next[t.ticketId];
                            return next;
                          })
                        }
                      />
                      <span className="font-mono text-slate-500">{t.ticketId.slice(0, 8)}</span>
                      <span className="text-slate-400">{t.attendeeName || t.tierName || ''}</span>
                      {t.status !== 'active' && (
                        <span className="text-[10px] uppercase font-black text-slate-300">{t.status}</span>
                      )}
                    </label>
                    <span className="text-slate-500">{formatCents(left, cur)} left</span>
                    {on && (
                      <input
                        type="text"
                        inputMode="decimal"
                        value={picked[t.ticketId]}
                        onChange={(e) => setPicked((p) => ({ ...p, [t.ticketId]: e.target.value }))}
                        placeholder="Full, or a partial amount"
                        className="w-40 border-2 border-slate-200 focus:border-slate-900 outline-none px-2 py-1 rounded-lg"
                      />
                    )}
                  </li>
                );
              })}
            </ul>
          )}

          {mode === 'amount' && (
            <input
              type="text"
              inputMode="decimal"
              value={amountText}
              onChange={(e) => setAmountText(e.target.value)}
              placeholder={`Amount, up to ${formatCents(preview.refundableCents, cur)}`}
              className="w-56 border-2 border-slate-200 focus:border-slate-900 outline-none px-2 py-1.5 rounded-lg mb-3"
            />
          )}

          <textarea
            value={reason}
            maxLength={500}
            rows={2}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Reason (optional, kept in the audit log)"
            className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm rounded-lg resize-y mb-2"
          />
          <div className="flex flex-wrap items-center gap-3">
            <span className={plan.ok ? 'text-slate-500' : 'text-red-500'}>
              {plan.ok
                ? `Refund ${formatCents(plan.totalCents, cur)}. ${
                    plan.voids.length > 0 ? `${plan.voids.length} ticket${plan.voids.length === 1 ? '' : 's'} voided.` : 'Tickets stay valid.'
                  }`
                : (plan as { error: string }).error}
            </span>
            <button
              type="button"
              disabled={busy || !plan.ok}
              onClick={submit}
              className="ml-auto bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white px-4 py-2 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
            >
              {busy ? 'Refunding…' : 'Refund'}
            </button>
          </div>
        </>
      )}

      {preview.requests.length > 0 && (
        <ul className="mt-3 space-y-1 border-t border-slate-100 pt-2">
          {preview.requests.map((r) => (
            <li key={r.id} className="flex flex-wrap items-center gap-2 text-slate-500">
              <span>{r.createdAt.toLocaleString()}</span>
              <span className="font-bold text-slate-700">{formatCents(r.amountCents, cur)}</span>
              <span className={`text-[10px] font-black uppercase tracking-widest ${r.status === 'failed' ? 'text-red-500' : r.status === 'succeeded' ? 'text-emerald-600' : 'text-amber-600'}`}>
                {r.status === 'claimed' ? 'not confirmed' : r.status}
              </span>
              {r.reason && <span className="italic text-slate-400">{r.reason}</span>}
              {r.error && <span className="text-red-400">{r.error}</span>}
              {r.status === 'claimed' && (
                <button type="button" disabled={busy} onClick={() => retry(r.id)} className="underline text-slate-700">
                  Retry
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function RefundEveryone({
  event,
  canCancel,
  refundableCents,
  currency,
  onDone,
}: {
  event: Event;
  canCancel: boolean;
  refundableCents: number;
  currency: string;
  onDone: () => void;
}) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState('');
  const [reason, setReason] = useState('');
  const alreadyCancelled = event.status === 'cancelled';
  const [alsoCancel, setAlsoCancel] = useState(canCancel && !alreadyCancelled);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<{ refunded: number; failed: number; cents: number } | null>(null);
  const run = async () => {
    if (typed.trim().toUpperCase() !== CONFIRM_WORD) return;
    // Fresh nonce per run: orders already refunded have nothing left and are
    // skipped; one that failed last time gets a new attempt.
    const nonce = newRefundNonce();
    setRunning(true);
    const tally = { refunded: 0, failed: 0, cents: 0 };
    setProgress({ ...tally });
    try {
      if (alsoCancel && canCancel && !alreadyCancelled) {
        // Stop sales first so no new order lands mid-run; holders get the cancel email.
        await cancelEvent(event.id, reason.trim() || undefined);
      }
      let after: string | null = null;
      for (let i = 0; i < 1000; i++) {
        const batch = await refundEventBatch({ eventId: event.id, nonce, reason: reason.trim() || 'event cancelled', after });
        for (const r of batch.results) {
          if (r.status === 'succeeded' || r.status === 'pending') {
            tally.refunded += 1;
            tally.cents += r.amountCents ?? 0;
          } else {
            tally.failed += 1;
          }
        }
        setProgress({ ...tally });
        if (batch.done) break;
        after = batch.nextAfter;
      }
      toast({
        kind: tally.failed > 0 ? 'warn' : 'success',
        message: `Refunded ${tally.refunded} order${tally.refunded === 1 ? '' : 's'} (${formatCents(tally.cents, currency)}).${
          tally.failed > 0 ? ` ${tally.failed} need another look below.` : ''
        }`,
      });
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Refund run stopped. Run it again to pick up where it left off.' });
    } finally {
      setRunning(false);
      setTyped('');
      onDone();
    }
  };

  return (
    <div className="mt-4 border-t border-slate-100 pt-4">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="text-xs font-bold text-red-600 flex items-center gap-1"
        aria-expanded={open}
      >
        {canCancel && !alreadyCancelled ? 'Cancel event & refund everyone' : 'Refund everyone'}
        {open ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
      </button>
      {open && (
        <div className="mt-3 text-xs border-2 border-red-200 rounded-xl p-4 bg-red-50/40">
          <p className="text-slate-600 mb-3">
            Refunds every paid order in full ({formatCents(refundableCents, currency)} left to refund) and voids their tickets.
            This can't be undone.
          </p>
          {canCancel && !alreadyCancelled && (
            <label className="flex items-center gap-2 mb-3 text-slate-600">
              <input type="checkbox" checked={alsoCancel} onChange={(e) => setAlsoCancel(e.target.checked)} />
              Also cancel the event (stops sales and emails every holder)
            </label>
          )}
          <textarea
            value={reason}
            maxLength={500}
            rows={2}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Reason (optional), e.g. show cancelled"
            className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm rounded-lg resize-y mb-2"
          />
          <label className="block mb-2 text-slate-600">
            Type <span className="font-mono font-bold">{CONFIRM_WORD}</span> to confirm
            <input
              type="text"
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              className="mt-1 w-full border-2 border-slate-200 focus:border-red-500 outline-none px-3 py-1.5 rounded-lg"
              autoComplete="off"
            />
          </label>
          <div className="flex flex-wrap items-center gap-3">
            {progress && (
              <span className="text-slate-500">
                {progress.refunded} refunded · {formatCents(progress.cents, currency)}
                {progress.failed > 0 ? ` · ${progress.failed} failed` : ''}
                {running ? ' · working…' : ''}
              </span>
            )}
            <button
              type="button"
              disabled={running || typed.trim().toUpperCase() !== CONFIRM_WORD}
              onClick={run}
              className="ml-auto bg-red-600 hover:bg-red-700 disabled:bg-slate-200 disabled:text-slate-400 text-white px-4 py-2 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
            >
              {running ? 'Refunding…' : 'Refund everyone'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
