// PromoterEarningsPanel — the promoter's own commission on /p/:token (mig
// 20260926020000): owed, paid, per-event breakdown and payouts. Reads
// exos_promoter_earnings with the kit token; renders nothing until the
// organizer has set terms or there are earnings to show.

import { useEffect, useState } from 'react';
import { Wallet } from 'lucide-react';
import { formatCurrency } from '../lib/utils';
import { formatDateOnly, termsLabel } from '../lib/commissions';
import { getPromoterEarnings, type PromoterEarnings } from '../lib/promoters';

const money = (cents: number, currency?: string | null) => formatCurrency((Number(cents) || 0) / 100, (currency || 'usd').toUpperCase());
const label = 'type text-[10px] uppercase tracking-widest text-white/50';

export default function PromoterEarningsPanel({ token }: { token: string }) {
  const [data, setData] = useState<PromoterEarnings | null>(null);

  useEffect(() => {
    let live = true;
    getPromoterEarnings(token).then((d) => { if (live) setData(d); }).catch(() => {});
    return () => { live = false; };
  }, [token]);

  if (!data) return null;
  const terms = { rateBps: data.terms.rate_bps, flatCents: data.terms.flat_cents };
  const hasTerms = terms.rateBps > 0 || terms.flatCents > 0;
  if (!hasTerms && data.totals.length === 0 && data.payouts.length === 0) return null;

  return (
    <section className="bg-[#111] border border-white/10 p-4 mb-8">
      <p className="type text-[10px] uppercase tracking-widest text-brand-primary mb-2 flex items-center gap-2">
        <Wallet className="w-3 h-3" /> Your earnings
      </p>
      <p className="text-xs text-white/60 mb-3">
        Your rate: {termsLabel(terms)} on each paid ticket, after tax. Refunded tickets come off; payouts are sent by the organizer.
      </p>

      {data.totals.length === 0 ? (
        <p className="text-[11px] text-white/40 italic">No paid sales yet.</p>
      ) : (
        <div className="grid gap-2 sm:grid-cols-3 mb-4">
          {data.totals.map((t) => (
            <div key={t.currency} className="contents">
              <div className="bg-black border border-white/10 px-3 py-2">
                <p className={label}>Owed to you</p>
                <p className="font-black text-brand-primary">{money(t.owed_cents, t.currency)}</p>
              </div>
              <div className="bg-black border border-white/10 px-3 py-2">
                <p className={label}>Paid</p>
                <p className="font-black text-white">{money(t.paid_cents, t.currency)}</p>
              </div>
              <div className="bg-black border border-white/10 px-3 py-2">
                <p className={label}>Paid tickets</p>
                <p className="font-black text-white">{t.tickets}</p>
              </div>
            </div>
          ))}
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
                  {e.tickets} sold · {termsLabel({ rateBps: e.rate_bps, flatCents: e.flat_cents })}
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
                <span className="font-black text-white">{money(p.amount_cents, p.currency)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}
