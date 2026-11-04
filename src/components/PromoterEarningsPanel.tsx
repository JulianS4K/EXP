// PromoterEarningsPanel — the promoter's own commission on /p/:token (mig
// 20260926020000; live, steps, payout status and Stripe payouts: mig
// 20261102150000). Reads exos_promoter_earnings with the kit token and
// refreshes every 30 seconds while the page is open; renders nothing until
// the organizer has set terms or there are earnings to show.
//
// When the organizer pays promoters by Stripe, the promoter sets up their own
// Stripe Express payout account here (exos-promoter-payouts /onboard), and a
// payout in progress shows as "processing" until Stripe has sent it.

import { useCallback, useEffect, useState } from 'react';
import { Landmark, RefreshCw, Wallet } from 'lucide-react';
import { formatCurrency } from '../lib/utils';
import { formatDateOnly, stepFrom, tieredLabel } from '../lib/commissions';
import {
  getPromoterEarnings, promoterPayoutOnboarding, promoterPayoutStatus, type PromoterEarnings,
} from '../lib/promoters';
import { useToast } from '../context/ToastContext';

const money = (cents: number, currency?: string | null) => formatCurrency((Number(cents) || 0) / 100, (currency || 'usd').toUpperCase());
const label = 'type text-[10px] uppercase tracking-widest text-white/50';
const REFRESH_MS = 30_000;

export default function PromoterEarningsPanel({ token }: { token: string }) {
  const { toast } = useToast();
  const [data, setData] = useState<PromoterEarnings | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const d = await getPromoterEarnings(token).catch(() => null);
    if (d) setData(d);
  }, [token]);

  useEffect(() => {
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      await load();
      if (live && typeof document !== 'undefined' && document.visibilityState !== 'hidden') timer = setTimeout(tick, REFRESH_MS);
      else if (live) timer = setTimeout(tick, REFRESH_MS * 4);
    };
    void tick();
    return () => { live = false; if (timer) clearTimeout(timer); };
  }, [load]);

  // Back from Stripe onboarding: refresh the account state once.
  useEffect(() => {
    if (typeof window === 'undefined' || !/[?&]payouts=return\b/.test(window.location.search)) return;
    promoterPayoutStatus(token).then(() => load()).catch(() => {});
  }, [token, load]);

  if (!data) return null;
  const terms = {
    rateBps: data.terms.rate_bps, flatCents: data.terms.flat_cents,
    step: stepFrom(data.terms.step_after, data.terms.step_rate_bps, data.terms.step_flat_cents),
  };
  const hasTerms = terms.rateBps > 0 || terms.flatCents > 0 || !!terms.step;
  if (!hasTerms && data.totals.length === 0 && data.payouts.length === 0) return null;
  const acct = data.payout_account;

  const connect = async () => {
    setBusy(true);
    try {
      const back = `${window.location.origin}${window.location.pathname}?payouts=return`;
      const { url } = await promoterPayoutOnboarding(token, back);
      if (/^https:\/\/connect\.stripe\.com\//.test(url)) window.location.assign(url);
      else throw new Error('Stripe didn\'t return a setup link.');
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not start payout setup.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="bg-[#111] border border-white/10 p-4 mb-8" aria-live="polite">
      <div className="flex items-center justify-between gap-3 mb-2">
        <p className="type text-[10px] uppercase tracking-widest text-brand-primary flex items-center gap-2">
          <Wallet className="w-3 h-3" /> Your earnings
        </p>
        <button onClick={() => void load()} className="text-white/40 hover:text-white" aria-label="Refresh earnings" title="Updates every 30 seconds">
          <RefreshCw className="w-3 h-3" />
        </button>
      </div>
      <p className="text-xs text-white/60 mb-3">
        Your rate: {tieredLabel(terms)} on each paid ticket, after tax (steps count per event). Refunded tickets come off.
        {acct?.transfers_enabled ? ' The organizer pays you by Stripe.' : ' Payouts are sent by the organizer.'}
      </p>

      {data.totals.length === 0 ? (
        <p className="text-[11px] text-white/40 italic">No paid sales yet.</p>
      ) : (
        <div className="grid gap-2 grid-cols-2 sm:grid-cols-4 mb-4">
          {data.totals.map((t) => (
            <div key={t.currency} className="contents">
              <Tile title="Owed to you" value={money(t.owed_cents, t.currency)} accent />
              <Tile title="Paid" value={money(t.paid_cents, t.currency)} />
              <Tile title={t.processing_cents ? 'On its way' : 'Paid tickets'}
                value={t.processing_cents ? money(t.processing_cents, t.currency) : String(t.tickets)} />
              <Tile title="Your sales" value={`${t.tickets} · ${money(t.sales_cents ?? 0, t.currency)}`} />
            </div>
          ))}
        </div>
      )}

      {acct?.transfers_enabled && (
        <div className="bg-black border border-white/10 px-3 py-3 mb-4 flex flex-wrap items-center gap-3">
          <Landmark className="w-4 h-4 text-white/60" aria-hidden="true" />
          <p className="flex-1 min-w-0 text-xs text-white/70">
            {acct.ready
              ? 'Your payout account is ready. Stripe sends your money to your bank when the organizer pays you.'
              : acct.connected
                ? 'Finish setting up your payout account with Stripe to get paid.'
                : 'Get paid straight to your bank: set up a free Stripe payout account (about 5 minutes).'}
          </p>
          {!acct.ready && (
            <button onClick={connect} disabled={busy}
              className="bg-brand-primary text-black px-3 py-2 text-[11px] font-black uppercase disabled:opacity-50">
              {acct.connected ? 'Finish setup' : 'Set up payouts'}
            </button>
          )}
        </div>
      )}

      {data.events.length > 0 && (
        <div className="mb-4">
          <p className={`${label} mb-1`}>By event</p>
          <div className="divide-y divide-white/10">
            {data.events.map((e) => (
              <div key={`${e.event_id}-${e.currency}`} className="flex flex-wrap items-center gap-x-3 py-2 text-sm">
                <span className="flex-1 min-w-0 truncate text-white">{e.name}</span>
                <span className="type text-[10px] uppercase tracking-widest text-white/50">
                  {e.tickets} sold · {tieredLabel({ rateBps: e.rate_bps, flatCents: e.flat_cents, step: stepFrom(e.step_after, e.step_rate_bps, e.step_flat_cents) })}
                </span>
                <span className="type text-[11px] text-white/80 w-full sm:w-auto">
                  {money(e.accrued_cents, e.currency)} owed · {money(e.paid_cents, e.currency)} paid
                  {e.reversed_cents > 0 ? ` · ${money(e.reversed_cents, e.currency)} refunded` : ''}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {data.payouts.length > 0 && (
        <div>
          <p className={`${label} mb-1`}>Payouts</p>
          <div className="divide-y divide-white/10">
            {data.payouts.map((p, i) => (
              <div key={i} className="flex items-center gap-3 py-2 text-sm">
                <span className="flex-1 text-white/80">{formatDateOnly(p.paid_on)} · {p.method}</span>
                {p.status === 'processing' && <span className="type text-[10px] uppercase tracking-widest text-brand-primary">Processing</span>}
                <span className="font-black text-white">{money(p.amount_cents, p.currency)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}

function Tile({ title, value, accent = false }: { title: string; value: string; accent?: boolean }) {
  return (
    <div className="bg-black border border-white/10 px-3 py-2">
      <p className={label}>{title}</p>
      <p className={`font-black ${accent ? 'text-brand-primary' : 'text-white'}`}>{value}</p>
    </div>
  );
}
