// InstantPayoutPanel — "get paid now" on /orgs/:orgId/payouts (mig
// 20261102150000, docs/payouts.md "Instant payouts"). Org OWNER only.
//
// Exos checkout money is already on the organizer's Stripe account
// (destination charges); Stripe pays it out on the account's schedule. Where
// Stripe offers it, the owner can ask for part of that balance now, as an
// Instant Payout to their debit card or bank, after seeing the fee. Hidden
// when exos-instant-payouts is off (EXOS_INSTANT_PAYOUTS) or not deployed.

import { useEffect, useMemo, useState } from 'react';
import { Zap } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { newSettleKey } from '../lib/commissions';
import {
  instantFeeCents, instantQuote, listInstantPayouts, maxInstantPayout, requestInstantPayout,
  type InstantPayoutRow, type InstantQuote,
} from '../lib/fastPayouts';

export default function InstantPayoutPanel({ orgId, isOwner }: { orgId: string; isOwner: boolean }) {
  const { toast } = useToast();
  const [quote, setQuote] = useState<InstantQuote | null>(null);
  const [history, setHistory] = useState<InstantPayoutRow[]>([]);
  const [currency, setCurrency] = useState('');
  const [amount, setAmount] = useState('');
  const [key, setKey] = useState(() => newSettleKey());
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = async () => {
    const q = await instantQuote(orgId);
    setQuote(q);
    if (q?.balances?.length) {
      setCurrency((c) => c || q.balances![0].currency);
    }
    setHistory(await listInstantPayouts(orgId));
  };
  useEffect(() => { if (isOwner) void load(); }, [orgId, isOwner]);

  const bal = quote?.balances?.find((b) => b.currency === currency);
  const cfg = { bps: quote?.fee_bps ?? 150, minCents: quote?.fee_min_cents ?? 50 };
  const cents = useMemo(() => {
    const s = amount.trim().replace(/^\$/, '');
    if (!/^\d{1,7}(\.\d{1,2})?$/.test(s)) return null;
    const [w, f = ''] = s.split('.');
    return Number(w) * 100 + Number((f + '00').slice(0, 2));
  }, [amount]);
  const fee = cents ? instantFeeCents(cents, cfg) : 0;
  const max = bal ? maxInstantPayout(bal.instant_available_cents, cfg) : 0;
  const valid = cents !== null && cents >= 100 && cents <= max;

  if (!isOwner || !quote || !quote.enabled) return null;

  const send = async () => {
    if (!valid || cents === null) return;
    setBusy(true);
    try {
      const r = await requestInstantPayout({ orgId, amountCents: cents, currency, key });
      if (r.status === 'sent') {
        toast({ kind: 'success', message: `Instant payout of ${formatCents(cents, currency)} requested. It usually lands within 30 minutes.` });
        setAmount(''); setKey(newSettleKey()); setConfirming(false);
      } else {
        toast({ kind: 'error', message: r.error || 'Stripe didn\'t send it.' });
      }
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not request the payout.' });
    } finally {
      setBusy(false);
      await load();
    }
  };

  return (
    <section className="bg-white rounded-2xl border border-slate-200 p-6 mb-8">
      <h2 className="text-lg font-bold flex items-center gap-2 mb-1"><Zap size={18} className="text-amber-500" aria-hidden="true" /> Get paid now</h2>
      <p className="text-sm text-slate-600 mb-4 max-w-prose">
        Your ticket money is already in your Stripe account and pays out on Stripe's schedule. Where Stripe allows it, you can
        send part of it to your debit card or bank now. Stripe charges a fee for this: about {(cfg.bps / 100).toFixed(1)}%
        (at least {formatCents(cfg.minCents, currency || 'usd')}), taken from your Stripe balance.
      </p>
      {!quote.eligible ? (
        <p className="text-sm text-slate-500">{quote.reason || 'Instant payouts aren\'t available for your account right now.'}</p>
      ) : (
        <div className="grid gap-3 md:grid-cols-4 items-end">
          {(quote.balances?.length ?? 0) > 1 && (
            <label className="text-xs font-bold text-slate-600">Currency
              <select className="mt-1 w-full border border-slate-200 rounded-lg px-2 py-2 text-sm" value={currency}
                onChange={(e) => { setCurrency(e.target.value); setConfirming(false); }}>
                {quote.balances!.map((b) => <option key={b.currency} value={b.currency}>{b.currency.toUpperCase()}</option>)}
              </select>
            </label>
          )}
          <label className="text-xs font-bold text-slate-600">Amount
            <input className="mt-1 w-full border border-slate-200 rounded-lg px-2 py-2 text-sm" inputMode="decimal" value={amount}
              placeholder={bal ? (max / 100).toFixed(2) : ''} onChange={(e) => { setAmount(e.target.value); setConfirming(false); }} />
          </label>
          <div className="text-xs text-slate-600 md:col-span-2">
            Available now: <strong>{bal ? formatCents(bal.instant_available_cents, currency) : '—'}</strong> · up to{' '}
            <button type="button" className="underline" onClick={() => setAmount((max / 100).toFixed(2))}>{formatCents(max, currency)}</button> after the fee
            {cents !== null && cents > 0 && (
              <p className="mt-1">Fee about <strong>{formatCents(fee, currency)}</strong>; you get <strong>{formatCents(cents, currency)}</strong> in your bank.</p>
            )}
          </div>
          {!confirming ? (
            <button type="button" disabled={!valid} onClick={() => setConfirming(true)}
              className="md:col-span-4 justify-self-start px-4 py-2.5 rounded bg-slate-900 text-white text-xs font-black uppercase tracking-widest disabled:opacity-40">
              Review instant payout
            </button>
          ) : (
            <div className="md:col-span-4 flex flex-wrap items-center gap-3 bg-amber-50 border border-amber-200 rounded-lg px-4 py-3 text-sm">
              <span className="flex-1">Send {formatCents(cents ?? 0, currency)} now for a fee of about {formatCents(fee, currency)}?</span>
              <button type="button" disabled={busy} onClick={() => void send()}
                className="px-4 py-2 rounded bg-amber-500 text-white text-xs font-black uppercase tracking-widest disabled:opacity-40">Yes, pay me now</button>
              <button type="button" onClick={() => setConfirming(false)} className="text-xs font-bold text-slate-500">Cancel</button>
            </div>
          )}
        </div>
      )}
      {history.length > 0 && (
        <ul className="mt-6 divide-y divide-slate-100 text-sm">
          {history.map((h) => (
            <li key={h.id} className="flex items-center gap-3 py-2">
              <span className="flex-1 text-slate-600">{new Date(h.createdAt).toLocaleString()}</span>
              <span className={`text-[10px] font-black uppercase tracking-widest ${h.status === 'failed' ? 'text-rose-600' : 'text-slate-500'}`} title={h.error ?? undefined}>{h.status}</span>
              <span className="font-bold">{formatCents(h.amountCents, h.currency)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
