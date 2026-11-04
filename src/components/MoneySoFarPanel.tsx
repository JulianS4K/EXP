// MoneySoFarPanel — the end-of-night money summary on the event report (mig
// 20261102150000, exos_event_money_so_far): online gross, fees, refunds and
// net; door cash / card / tips; promoter commission owed; tickets and
// check-ins. Owner / manager / finance (the RPC re-checks); hidden before the
// migration. Refreshes every minute; "Copy" gives a text for the group chat.

import { useEffect, useState } from 'react';
import { ClipboardCopy, Moon, RefreshCw } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import { getMoneySoFar } from '../lib/fastPayouts';
import { admitted, moneySoFarText, takeHomeCents, type MoneySoFar } from '../lib/moneySoFar';
import { Link } from 'react-router-dom';

export default function MoneySoFarPanel({ eventId, orgId, canView }: { eventId: string; orgId?: string | null; canView: boolean }) {
  const [m, setM] = useState<MoneySoFar | null>(null);
  const [copied, setCopied] = useState(false);
  const [tick, setTick] = useState(0);

  useEffect(() => { setM(null); }, [eventId]);
  useEffect(() => {
    if (!canView) return undefined;
    let live = true;
    getMoneySoFar(eventId).then((x) => { if (live) setM(x); });
    const t = setInterval(() => setTick((n) => n + 1), 60_000);
    return () => { live = false; clearInterval(t); };
  }, [eventId, canView, tick]);

  if (!canView || !m) return null;
  const fmt = (c: number) => formatCents(c, m.currency);
  const copy = async () => {
    try { await navigator.clipboard.writeText(moneySoFarText(m, fmt)); setCopied(true); setTimeout(() => setCopied(false), 2000); } catch { /* ignore */ }
  };

  return (
    <section className="bg-white rounded-2xl border border-slate-200 p-6 mb-8">
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
        <h2 className="text-lg font-bold flex items-center gap-2"><Moon size={18} aria-hidden="true" /> Money so far</h2>
        <div className="flex items-center gap-2">
          <button type="button" onClick={() => setTick((n) => n + 1)} className="p-2 text-slate-400 hover:text-slate-700" aria-label="Refresh"><RefreshCw size={14} /></button>
          <button type="button" onClick={copy} className="inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-700">
            <ClipboardCopy size={14} aria-hidden="true" /> {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <Tile label="Take-home so far" value={fmt(takeHomeCents(m))} strong />
        <Tile label="Online to you" value={fmt(m.online.net_cents)} sub={`${fmt(m.online.gross_cents)} gross · ${fmt(m.online.fees_cents)} fees`} />
        <Tile label="Door" value={fmt(m.door.cash_cents + m.door.card_cents)} sub={`${fmt(m.door.cash_cents)} cash · ${fmt(m.door.tips_cents)} tips`} />
        <Tile label="Promoters owed" value={fmt(m.promoters.owed_cents)} sub={`${fmt(m.promoters.paid_cents)} paid`} />
      </div>
      <p className="text-xs text-slate-500">
        {m.online.orders} online order{m.online.orders === 1 ? '' : 's'} ({fmt(m.online.last_hour_gross_cents)} in the last hour)
        {m.online.refunded_cents ? ` · ${fmt(m.online.refunded_cents)} refunded` : ''} · {admitted(m)} tickets out
        ({m.tickets.paid} paid, {m.tickets.free} free{m.tickets.phone_rsvps ? `, ${m.tickets.phone_rsvps} by phone` : ''}, {m.tickets.comps} comps)
        · {m.tickets.checked_in} checked in.
        {m.online.paypal_net_cents ? ` ${fmt(m.online.paypal_net_cents)} of it came by PayPal, which Exos pays out to you.` : ''}
        {' '}Stripe money is in your Stripe account; {orgId ? <Link to={`/orgs/${orgId}/payouts`} className="underline">get paid now</Link> : 'get paid now'} where Stripe allows it.
      </p>
    </section>
  );
}

function Tile({ label, value, sub, strong = false }: { label: string; value: string; sub?: string; strong?: boolean }) {
  return (
    <div className={`rounded-xl border px-4 py-3 ${strong ? 'border-slate-900 bg-slate-900 text-white' : 'border-slate-200'}`}>
      <p className={`text-[10px] font-black uppercase tracking-widest ${strong ? 'text-white/60' : 'text-slate-400'}`}>{label}</p>
      <p className="text-xl font-black">{value}</p>
      {sub && <p className={`text-[11px] ${strong ? 'text-white/60' : 'text-slate-500'}`}>{sub}</p>}
    </div>
  );
}
