// PromoterCommissionPanel — one promoter's commission terms, per-event
// overrides and the "record payout" flow (mig 20260926020000). Mounted per row
// in OrgPromoters. The RPCs enforce roles (owner / manager write, finance
// reads); canWrite only hides controls.
//
// A payout here records money the organizer already sent (Venmo, cash...),
// or, when the org owner has turned Stripe payouts on and the promoter has a
// ready payout account, sends it through Stripe (mig 20261102150000): the
// settle is idempotent (one key per click, safe to retry), the SQL caps the
// amount at what the organizer received for those orders, and the transfer
// itself is exos-promoter-payouts (dry run unless EXOS_PROMOTER_TRANSFERS=on).
// Step terms ("10%, then 15% after 20 tickets") are set here too.

import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Banknote, Percent, Send, TrendingUp, Trash2, XCircle } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCurrency } from '../lib/utils';
import {
  bpsToPercent, canSendOrCancel, formatDateOnly, moneyToCents, newSettleKey, payoutNetCents, payoutStatusLabel,
  percentToBps, termsLabel, tieredLabel, type StepTerms, type TransferStatus,
} from '../lib/commissions';
import {
  cancelPromoterPayout, listPromoterPayouts, listSettleRows, sendPromoterPayout, setPromoterStep, setPromoterTerms,
  settlePromoter,
  type PromoterCommissionSummary, type PromoterEventTerms, type PromoterPayoutRow, type SettleRow,
} from '../lib/promoters';

const money = (cents: number, currency?: string | null) => formatCurrency(cents / 100, (currency || 'usd').toUpperCase());
const today = () => new Date().toISOString().slice(0, 10);
const field = 'bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';
const label = 'type text-[10px] uppercase tracking-widest text-white/50';

export default function PromoterCommissionPanel({
  promoterId,
  promoterName,
  defaults,
  summaries,
  overrides,
  events,
  canWrite,
  onChanged,
  step = null,
  stripeOn = false,
  accountReady = false,
}: {
  promoterId: string;
  promoterName: string;
  defaults: { rateBps: number; flatCents: number };
  summaries: PromoterCommissionSummary[];
  overrides: PromoterEventTerms[];
  events: { id: string; title: string }[];
  canWrite: boolean;
  onChanged: () => void | Promise<void>;
  /** The default terms' step (mig 20261102150000). */
  step?: StepTerms | null;
  /** The org pays promoters by Stripe (owner's switch). */
  stripeOn?: boolean;
  /** This promoter's Stripe payout account can receive transfers. */
  accountReady?: boolean;
}) {
  const { toast } = useToast();
  const [pct, setPct] = useState(bpsToPercent(defaults.rateBps));
  const [flat, setFlat] = useState(defaults.flatCents ? (defaults.flatCents / 100).toFixed(2) : '');
  const [reprice, setReprice] = useState(false);
  const [saving, setSaving] = useState(false);
  const [evId, setEvId] = useState('');
  const [evPct, setEvPct] = useState('');
  const [evFlat, setEvFlat] = useState('');

  useEffect(() => {
    setPct(bpsToPercent(defaults.rateBps));
    setFlat(defaults.flatCents ? (defaults.flatCents / 100).toFixed(2) : '');
  }, [defaults.rateBps, defaults.flatCents]);

  const eventName = (id: string) => events.find((e) => e.id === id)?.title ?? 'Event';

  const parseTerms = (p: string, f: string) => {
    const rateBps = percentToBps(p);
    const flatCents = moneyToCents(f);
    if (rateBps === null) { toast({ kind: 'error', message: 'Percent must be a number from 0 to 100.' }); return null; }
    if (flatCents === null) { toast({ kind: 'error', message: 'Flat amount must be from 0 to 1,000.' }); return null; }
    return { rateBps, flatCents };
  };

  const saveDefault = async (e: FormEvent) => {
    e.preventDefault();
    const t = parseTerms(pct, flat);
    if (!t) return;
    setSaving(true);
    try {
      const n = await setPromoterTerms(promoterId, t, { repriceAccrued: reprice });
      toast({ kind: 'success', message: reprice ? `Saved. ${n} unpaid sale${n === 1 ? '' : 's'} re-priced.` : 'Saved. New sales use these terms.' });
      setReprice(false);
      await onChanged();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not save the terms.' });
    } finally {
      setSaving(false);
    }
  };

  const saveOverride = async (e: FormEvent) => {
    e.preventDefault();
    if (!evId) { toast({ kind: 'error', message: 'Pick an event.' }); return; }
    const t = parseTerms(evPct, evFlat);
    if (!t) return;
    setSaving(true);
    try {
      await setPromoterTerms(promoterId, t, { eventId: evId, repriceAccrued: reprice });
      toast({ kind: 'success', message: `Terms for ${eventName(evId)} saved.` });
      setEvId(''); setEvPct(''); setEvFlat('');
      await onChanged();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not save the event terms.' });
    } finally {
      setSaving(false);
    }
  };

  const removeOverride = async (eventId: string) => {
    try {
      await setPromoterTerms(promoterId, { rateBps: null, flatCents: null }, { eventId });
      toast({ kind: 'success', message: `${eventName(eventId)} uses the default terms again.` });
      await onChanged();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not remove the event terms.' });
    }
  };

  return (
    <div className="border-t border-white/10 mt-3 pt-4 grid gap-5">
      <div className="grid gap-2 sm:grid-cols-4">
        {summaries.filter((s) => s.currency).map((s) => (
          <div key={s.currency} className="contents">
            <Stat title="Owed" value={money(s.owedCents, s.currency)} accent={s.owedCents !== 0} />
            <Stat title="Paid" value={money(s.paidCents, s.currency)} />
            <Stat title="Reversed" value={money(s.reversedCents, s.currency)} />
            <Stat title="Paid tickets" value={`${s.tickets} · ${money(s.baseCents, s.currency)} net`} />
          </div>
        ))}
        {summaries.every((s) => !s.currency) && <p className="sm:col-span-4 text-[11px] text-white/40 italic">No paid sales yet.</p>}
        {summaries.some((s) => s.clawbackCents > 0) && (
          <p className="sm:col-span-4 text-[11px] text-white/50">
            Some sales were refunded after you paid them out. That amount comes off the next payout.
          </p>
        )}
      </div>

      <form onSubmit={saveDefault} className="grid gap-2 sm:grid-cols-4 items-end">
        <p className={`${label} sm:col-span-4 flex items-center gap-1`}><Percent className="w-3 h-3" /> Commission · now {tieredLabel({ ...defaults, step })}</p>
        <input className={field} inputMode="decimal" placeholder="% of ticket" aria-label={`Commission percent for ${promoterName}`} value={pct} onChange={(e) => setPct(e.target.value)} disabled={!canWrite} />
        <input className={field} inputMode="decimal" placeholder="$ per ticket" aria-label={`Flat commission per ticket for ${promoterName}`} value={flat} onChange={(e) => setFlat(e.target.value)} disabled={!canWrite} />
        {canWrite && (
          <>
            <label className="flex items-center gap-2 text-[11px] text-white/60">
              <input type="checkbox" checked={reprice} onChange={(e) => setReprice(e.target.checked)} /> Also re-price unpaid sales
            </label>
            <button disabled={saving} className="bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">Save</button>
          </>
        )}
        <p className="sm:col-span-4 text-[11px] text-white/40">
          Paid on the ticket price after tax, not add-ons. Comps and free tickets earn nothing; refunded tickets are taken back.
        </p>
      </form>

      <StepForm promoterId={promoterId} promoterName={promoterName} step={step} canWrite={canWrite} onDone={onChanged} />

      <div className="grid gap-2">
        <p className={label}>Per-event terms (replace the default for that event, step included)</p>
        {overrides.length === 0 && <p className="text-[11px] text-white/40 italic">None.</p>}
        {overrides.map((o) => (
          <div key={o.eventId} className="flex items-center gap-3 text-sm text-white/80">
            <span className="flex-1 truncate">{eventName(o.eventId)}</span>
            <span className="type text-[11px] text-white/60">{termsLabel(o)}</span>
            {canWrite && (
              <button onClick={() => removeOverride(o.eventId)} className="p-1 text-white/40 hover:text-white" aria-label={`Remove terms for ${eventName(o.eventId)}`}>
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        ))}
        {canWrite && (
          <form onSubmit={saveOverride} className="grid gap-2 sm:grid-cols-4">
            <select className={field} aria-label="Event" value={evId} onChange={(e) => setEvId(e.target.value)}>
              <option value="">Event…</option>
              {events.map((e) => <option key={e.id} value={e.id}>{e.title}</option>)}
            </select>
            <input className={field} inputMode="decimal" placeholder="% of ticket" aria-label="Event commission percent" value={evPct} onChange={(e) => setEvPct(e.target.value)} />
            <input className={field} inputMode="decimal" placeholder="$ per ticket" aria-label="Event flat commission" value={evFlat} onChange={(e) => setEvFlat(e.target.value)} />
            <button disabled={saving} className="border border-white/20 text-white px-4 py-2 text-sm font-black uppercase disabled:opacity-50">Set for event</button>
          </form>
        )}
      </div>

      {canWrite && (
        <PayoutForm promoterId={promoterId} promoterName={promoterName} summaries={summaries} onDone={onChanged}
          stripeOk={stripeOn && accountReady} />
      )}
      <PayoutHistory promoterId={promoterId} canWrite={canWrite} onChanged={onChanged} stripeOn={stripeOn} />
    </div>
  );
}

// "10%, then 15% after 20 tickets": one step on the default terms.
function StepForm({ promoterId, promoterName, step, canWrite, onDone }: {
  promoterId: string; promoterName: string; step: StepTerms | null; canWrite: boolean; onDone: () => void | Promise<void>;
}) {
  const { toast } = useToast();
  const [after, setAfter] = useState(step ? String(step.after) : '');
  const [pct, setPct] = useState(step ? bpsToPercent(step.rateBps) : '');
  const [flat, setFlat] = useState(step?.flatCents ? (step.flatCents / 100).toFixed(2) : '');
  const [reprice, setReprice] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    setAfter(step ? String(step.after) : '');
    setPct(step ? bpsToPercent(step.rateBps) : '');
    setFlat(step?.flatCents ? (step.flatCents / 100).toFixed(2) : '');
  }, [step?.after, step?.rateBps, step?.flatCents]);

  const save = async (clear: boolean) => {
    const n = Number(after);
    const rateBps = percentToBps(pct);
    const flatCents = moneyToCents(flat);
    if (!clear && (!Number.isInteger(n) || n < 1 || n > 100000)) { toast({ kind: 'error', message: 'Enter after how many tickets the step starts.' }); return; }
    if (!clear && (rateBps === null || flatCents === null)) { toast({ kind: 'error', message: 'Percent 0-100, flat amount 0-1,000.' }); return; }
    setBusy(true);
    try {
      const r = await setPromoterStep(promoterId, clear ? { after: null, rateBps: 0, flatCents: 0 } : { after: n, rateBps: rateBps!, flatCents: flatCents! },
        { repriceAccrued: reprice });
      toast({ kind: 'success', message: clear ? 'Step removed.' : reprice ? `Step saved. ${r} unpaid sale${r === 1 ? '' : 's'} re-priced.` : 'Step saved for new sales.' });
      setReprice(false);
      await onDone();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the step.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid gap-2 sm:grid-cols-4 items-end">
      <p className={`${label} sm:col-span-4 flex items-center gap-1`}>
        <TrendingUp className="w-3 h-3" /> Step up · {step ? `${termsLabel(step)} after ${step.after} tickets at an event` : 'none'}
      </p>
      <input className={field} inputMode="numeric" placeholder="After N tickets" aria-label={`Step after how many tickets for ${promoterName}`}
        value={after} onChange={(e) => setAfter(e.target.value.replace(/[^0-9]/g, ''))} disabled={!canWrite} />
      <input className={field} inputMode="decimal" placeholder="% after" aria-label={`Step percent for ${promoterName}`}
        value={pct} onChange={(e) => setPct(e.target.value)} disabled={!canWrite} />
      <input className={field} inputMode="decimal" placeholder="$ per ticket after" aria-label={`Step flat amount for ${promoterName}`}
        value={flat} onChange={(e) => setFlat(e.target.value)} disabled={!canWrite} />
      {canWrite && (
        <div className="flex gap-2">
          <button type="button" disabled={busy} onClick={() => void save(false)} className="border border-white/20 text-white px-3 py-2 text-[11px] font-black uppercase disabled:opacity-50">Save step</button>
          {step && <button type="button" disabled={busy} onClick={() => void save(true)} className="text-[11px] font-black uppercase text-white/50 hover:text-white">Clear</button>}
        </div>
      )}
      {canWrite && (
        <label className="sm:col-span-4 flex items-center gap-2 text-[11px] text-white/60">
          <input type="checkbox" checked={reprice} onChange={(e) => setReprice(e.target.checked)} /> Also re-price unpaid sales (paid ones keep their rate)
        </label>
      )}
      <p className="sm:col-span-4 text-[11px] text-white/40">Counts per event: with "after 20", tickets 21 and up at each event earn the step rate.</p>
    </div>
  );
}

// Recent payouts; Stripe ones not yet sent can be sent (or cancelled).
function PayoutHistory({ promoterId, canWrite, stripeOn, onChanged }: {
  promoterId: string; canWrite: boolean; stripeOn: boolean; onChanged: () => void | Promise<void>;
}) {
  const { toast } = useToast();
  const [rows, setRows] = useState<PromoterPayoutRow[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const load = async () => setRows(await listPromoterPayouts(promoterId));
  useEffect(() => { void load(); }, [promoterId]);

  const act = async (id: string, what: 'send' | 'cancel') => {
    setBusy(id);
    try {
      const r = what === 'send' ? await sendPromoterPayout(id) : await cancelPromoterPayout(id);
      toast({
        kind: r.status === 'failed' ? 'error' : 'success',
        message: r.status === 'sent' ? 'Sent. Stripe pays it to the promoter\'s bank.'
          : r.status === 'dry_run' ? 'Dry run: nothing was sent (Stripe payouts to promoters aren\'t live yet).'
          : r.status === 'cancelled' ? 'Cancelled. Those sales are unpaid again.'
          : `Not sent: ${(r as { error?: string }).error ?? 'try again'}`,
      });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not reach Stripe.' });
    } finally {
      setBusy(null);
      await load();
      await onChanged();
    }
  };

  if (rows.length === 0) return null;
  return (
    <div className="grid gap-1">
      <p className={label}>Payouts</p>
      {rows.map((r) => (
        <div key={r.id} className="flex flex-wrap items-center gap-3 text-sm text-white/80">
          <span className="flex-1 min-w-0 truncate">{formatDateOnly(r.paidOn)} · {r.method} · {r.rowCount} sale{r.rowCount === 1 ? '' : 's'}</span>
          <span className={`type text-[10px] uppercase tracking-widest ${r.transferStatus === 'failed' ? 'text-rose-400' : 'text-white/50'}`}
            title={r.transferError ?? undefined}>
            {payoutStatusLabel(r.via, r.transferStatus as TransferStatus | null)}
          </span>
          <span className="font-black text-white">{money(r.amountCents, r.currency)}</span>
          {canWrite && canSendOrCancel(r.via, r.transferStatus as TransferStatus | null) && (
            <>
              {stripeOn && (
                <button onClick={() => void act(r.id, 'send')} disabled={busy === r.id} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary disabled:opacity-40">
                  <Send className="w-3 h-3" /> Send
                </button>
              )}
              <button onClick={() => void act(r.id, 'cancel')} disabled={busy === r.id} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-white/50 hover:text-white disabled:opacity-40">
                <XCircle className="w-3 h-3" /> Cancel
              </button>
            </>
          )}
        </div>
      ))}
    </div>
  );
}

function Stat({ title, value, accent = false }: { title: string; value: string; accent?: boolean }) {
  return (
    <div className="bg-black border border-white/10 px-3 py-2">
      <p className={label}>{title}</p>
      <p className={`font-black ${accent ? 'text-brand-primary' : 'text-white'}`}>{value}</p>
    </div>
  );
}

function PayoutForm({
  promoterId, promoterName, summaries, onDone, stripeOk,
}: {
  promoterId: string;
  promoterName: string;
  summaries: PromoterCommissionSummary[];
  onDone: () => void | Promise<void>;
  /** Org switch on and the promoter's account ready. */
  stripeOk: boolean;
}) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [allRows, setAllRows] = useState<SettleRow[]>([]);
  const [via, setVia] = useState<'manual' | 'stripe'>('manual');
  // One key per payout attempt: a retry after a dropped answer can't pay twice.
  const [key, setKey] = useState(() => newSettleKey());
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [currency, setCurrency] = useState<string>('');
  const [method, setMethod] = useState('');
  const [note, setNote] = useState('');
  const [paidOn, setPaidOn] = useState(today());
  const [busy, setBusy] = useState(false);

  const rows = via === 'stripe' ? allRows.filter((r) => r.fundable) : allRows;
  const load = async (mode: 'manual' | 'stripe' = via) => {
    try {
      const all = await listSettleRows(promoterId);
      setAllRows(all);
      const r = mode === 'stripe' ? all.filter((x) => x.fundable) : all;
      const cur = r[0]?.currency ?? '';
      setCurrency(cur);
      setPicked(new Set(r.filter((x) => x.currency === cur).map((x) => x.id)));
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not load unpaid sales.' });
    }
  };

  const currencies = useMemo(() => [...new Set(rows.map((r) => r.currency))], [rows]);
  const shown = rows.filter((r) => r.currency === currency);
  const selected = shown.filter((r) => picked.has(r.id));
  const clawback = summaries.find((s) => s.currency === currency)?.clawbackCents ?? 0;
  const net = payoutNetCents(selected, clawback);

  const byEvent = useMemo(() => {
    const m = new Map<string, { name: string; rows: SettleRow[] }>();
    for (const r of shown) {
      const g = m.get(r.eventId) ?? { name: r.eventName ?? 'Event', rows: [] };
      g.rows.push(r);
      m.set(r.eventId, g);
    }
    return [...m.entries()];
  }, [shown]);

  const toggleEvent = (ids: string[], on: boolean) => {
    const next = new Set(picked);
    ids.forEach((id) => (on ? next.add(id) : next.delete(id)));
    setPicked(next);
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (net === null) { toast({ kind: 'error', message: 'Pick sales worth at least what was refunded after the last payout.' }); return; }
    if (via === 'manual' && !method.trim()) { toast({ kind: 'error', message: 'Say how you paid (e.g. Venmo).' }); return; }
    setBusy(true);
    try {
      const r = await settlePromoter({
        promoterId, commissionIds: selected.map((x) => x.id), amountCents: net, key, via,
        method: via === 'stripe' ? 'Stripe transfer' : method.trim(), note: note.trim() || undefined, paidOn,
      });
      if (via === 'stripe') {
        const sent = await sendPromoterPayout(r.payoutId).catch((e: any) => ({ status: 'failed', error: e?.message }));
        toast({
          kind: sent.status === 'failed' ? 'error' : 'success',
          message: sent.status === 'sent' ? `Sent ${money(net, currency)} to ${promoterName} through Stripe.`
            : sent.status === 'dry_run' ? 'Saved as a dry run: nothing was sent (Stripe payouts to promoters aren\'t live yet).'
            : `Saved, but Stripe didn't send it: ${(sent as { error?: string }).error ?? 'try Send again below'}.`,
        });
      } else {
        toast({ kind: 'success', message: `Recorded ${money(net, currency)} paid to ${promoterName}.` });
      }
      setOpen(false); setMethod(''); setNote(''); setKey(newSettleKey());
      await onDone();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not record the payout.' });
      await load();
    } finally {
      setBusy(false);
    }
  };

  if (!open) {
    return (
      <button
        onClick={() => { setOpen(true); void load(); }}
        className="justify-self-start inline-flex items-center gap-2 border border-brand-primary text-brand-primary px-4 py-2 text-[11px] font-black uppercase"
      >
        <Banknote className="w-4 h-4" /> Record payout
      </button>
    );
  }

  return (
    <form onSubmit={submit} className="bg-black border border-white/10 p-4 grid gap-3">
      {stripeOk ? (
        <div className="flex flex-wrap gap-4 text-[11px] text-white/70" role="radiogroup" aria-label="How to pay">
          <label className="flex items-center gap-2"><input type="radio" checked={via === 'manual'} onChange={() => { setVia('manual'); void load('manual'); }} /> I paid them (record it)</label>
          <label className="flex items-center gap-2"><input type="radio" checked={via === 'stripe'} onChange={() => { setVia('stripe'); void load('stripe'); }} /> Pay through Stripe</label>
        </div>
      ) : null}
      <p className={label}>
        {via === 'stripe'
          ? `Stripe takes the commission back from what you were paid for these orders and sends it to ${promoterName}'s bank. Only online Stripe sales can go this way.`
          : `Record a payout you sent ${promoterName}. Exos doesn't move the money.`}
      </p>
      {rows.length === 0 ? (
        <p className="text-[11px] text-white/40 italic">Nothing unpaid right now.</p>
      ) : (
        <>
          {currencies.length > 1 && (
            <select className={field} aria-label="Currency" value={currency}
              onChange={(e) => { setCurrency(e.target.value); setPicked(new Set(rows.filter((r) => r.currency === e.target.value).map((r) => r.id))); }}>
              {currencies.map((c) => <option key={c} value={c}>{c.toUpperCase()}</option>)}
            </select>
          )}
          <div className="grid gap-1">
            {byEvent.map(([eventId, g]) => {
              const ids = g.rows.map((r) => r.id);
              const on = ids.every((id) => picked.has(id));
              const sum = g.rows.reduce((n, r) => n + r.commissionCents, 0);
              return (
                <label key={eventId} className="flex items-center gap-3 text-sm text-white/80">
                  <input type="checkbox" checked={on} onChange={(e) => toggleEvent(ids, e.target.checked)} />
                  <span className="flex-1 truncate">{g.name}</span>
                  <span className="type text-[11px] text-white/60">{g.rows.length} sale{g.rows.length === 1 ? '' : 's'} · {money(sum, currency)}</span>
                </label>
              );
            })}
          </div>
          {clawback > 0 && (
            <p className="text-[11px] text-white/60">Less {money(clawback, currency)} for sales refunded after an earlier payout.</p>
          )}
          <div className="grid gap-2 sm:grid-cols-3">
            {via === 'manual'
              ? <input className={field} placeholder="How (Venmo, cash…)" aria-label="Payout method" maxLength={60} value={method} onChange={(e) => setMethod(e.target.value)} />
              : <span className="text-[11px] text-white/50 self-center">Stripe transfer</span>}
            <input className={field} type="date" aria-label="Paid on" value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />
            <input className={field} placeholder="Note (optional, staff only)" aria-label="Payout note" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div className="flex items-center gap-3">
            <button disabled={busy || net === null} className="bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">
              {via === 'stripe' ? 'Send' : 'Record'} {net === null ? '' : money(net, currency)}
            </button>
            <button type="button" onClick={() => setOpen(false)} className="text-[11px] font-black uppercase text-white/50 hover:text-white">Cancel</button>
          </div>
        </>
      )}
      {rows.length === 0 && (
        <button type="button" onClick={() => setOpen(false)} className="justify-self-start text-[11px] font-black uppercase text-white/50 hover:text-white">Close</button>
      )}
    </form>
  );
}
