// PromoterCommissionPanel — one promoter's commission terms, per-event
// overrides and the "record payout" flow (mig 20260926020000). Mounted per row
// in OrgPromoters. The RPCs enforce roles (owner / manager write, finance
// reads); canWrite only hides controls.
//
// A payout here records money the organizer already sent (Venmo, cash...).
// Nothing moves through Exos yet.

import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Banknote, Percent, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCurrency } from '../lib/utils';
import {
  bpsToPercent, moneyToCents, payoutNetCents, percentToBps, termsLabel,
} from '../lib/commissions';
import {
  listUnpaidCommissions, recordPromoterPayout, setPromoterTerms,
  type PromoterCommissionSummary, type PromoterEventTerms, type UnpaidCommission,
} from '../lib/promoters';

const money = (cents: number, currency?: string | null) => formatCurrency(cents / 100, (currency || 'usd').toUpperCase());
const today = () => new Date().toISOString().slice(0, 10);
const field = 'bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus:border-brand-primary';
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
}: {
  promoterId: string;
  promoterName: string;
  defaults: { rateBps: number; flatCents: number };
  summaries: PromoterCommissionSummary[];
  overrides: PromoterEventTerms[];
  events: { id: string; title: string }[];
  canWrite: boolean;
  onChanged: () => void | Promise<void>;
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
        <p className={`${label} sm:col-span-4 flex items-center gap-1`}><Percent className="w-3 h-3" /> Commission · now {termsLabel(defaults)}</p>
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

      <div className="grid gap-2">
        <p className={label}>Per-event terms (replace the default for that event)</p>
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
        <PayoutForm promoterId={promoterId} promoterName={promoterName} summaries={summaries} onDone={onChanged} />
      )}
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
  promoterId, promoterName, summaries, onDone,
}: {
  promoterId: string;
  promoterName: string;
  summaries: PromoterCommissionSummary[];
  onDone: () => void | Promise<void>;
}) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<UnpaidCommission[]>([]);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [currency, setCurrency] = useState<string>('');
  const [method, setMethod] = useState('');
  const [note, setNote] = useState('');
  const [paidOn, setPaidOn] = useState(today());
  const [busy, setBusy] = useState(false);

  const load = async () => {
    try {
      const r = await listUnpaidCommissions(promoterId);
      setRows(r);
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
    const m = new Map<string, { name: string; rows: UnpaidCommission[] }>();
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
    if (!method.trim()) { toast({ kind: 'error', message: 'Say how you paid (e.g. Venmo).' }); return; }
    setBusy(true);
    try {
      await recordPromoterPayout({
        promoterId, commissionIds: selected.map((r) => r.id), amountCents: net,
        method: method.trim(), note: note.trim() || undefined, paidOn,
      });
      toast({ kind: 'success', message: `Recorded ${money(net, currency)} paid to ${promoterName}.` });
      setOpen(false); setMethod(''); setNote('');
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
      <p className={label}>Record a payout you sent {promoterName}. Exos doesn't move the money.</p>
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
            <input className={field} placeholder="How (Venmo, cash…)" aria-label="Payout method" maxLength={60} value={method} onChange={(e) => setMethod(e.target.value)} />
            <input className={field} type="date" aria-label="Paid on" value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />
            <input className={field} placeholder="Note (optional, staff only)" aria-label="Payout note" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div className="flex items-center gap-3">
            <button disabled={busy || net === null} className="bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">
              Record {net === null ? '' : money(net, currency)}
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
