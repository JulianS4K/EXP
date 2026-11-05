// Price steps editor (mig 20261106130000; DICE PriceTier): per ticket type,
// prices that move on their own ("Early bird $20 for the first 100 or until
// Dec 1, then $25 for 200, then $30") and a door price. Every step but the
// last ends on a number sold, a date, or both (whichever comes first); the
// last is the final price. Saved with exos_set_price_steps (owner / manager),
// which also keeps the type's price and old price_schedule in sync. Shown in
// the event editor's ticket section and the event report's settings.
// Prices here are face prices: buyers see them all-in (fees + tax inside).

import { useEffect, useState } from 'react';
import { Plus, Trash2, TrendingUp } from 'lucide-react';
import {
  getPriceSteps, priceStepsError, savePriceSteps, type PriceStepInput, type TierPriceSteps,
} from '../lib/priceSteps';
import { formatCurrency } from '../lib/utils';
import { getBrowserTimezone, utcToZonedWallClock, zonedWallClockToUtc } from '../lib/datetime';
import { useToast } from '../context/ToastContext';

interface TierOption { id: string; name: string }

const cell =
  'border-2 border-slate-200 focus:border-slate-900 outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 ' +
  'px-2 py-1.5 text-xs rounded-lg bg-white min-w-0';

interface Row { id?: string; name: string; price: string; count: string; endsAt: string; sold: number; held: number }

const toRows = (s: TierPriceSteps, tz: string): Row[] => s.steps.map((x) => ({
  id: x.id, name: x.name, price: (x.priceCents / 100).toFixed(2), count: x.endsAfterCount == null ? '' : String(x.endsAfterCount),
  endsAt: x.endsAt ? utcToZonedWallClock(new Date(x.endsAt), tz) : '', sold: x.sold, held: x.held,
}));

export function rowsToSteps(rows: readonly Row[], tz: string): PriceStepInput[] {
  return rows.map((r) => ({
    ...(r.id ? { id: r.id } : {}),
    name: r.name,
    priceCents: Math.round((parseFloat(r.price) || 0) * 100),
    endsAfterCount: r.count.trim() === '' ? null : Number(r.count),
    endsAt: r.endsAt ? zonedWallClockToUtc(r.endsAt, tz)?.toISOString() ?? null : null,
  }));
}

function TierSteps({ tier, tz, currency, canManage }: { tier: TierOption; tz: string; currency: string; canManage: boolean }) {
  const { toast } = useToast();
  const [data, setData] = useState<TierPriceSteps | null>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [door, setDoor] = useState('');
  const [busy, setBusy] = useState(false);

  const load = (d: TierPriceSteps) => {
    setData(d);
    setRows(toRows(d, tz));
    setDoor(d.doorPriceCents == null ? '' : (d.doorPriceCents / 100).toFixed(2));
  };
  useEffect(() => {
    getPriceSteps(tier.id).then(load).catch((e) => console.error('getPriceSteps failed:', e));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tier.id]);

  if (!data) return null;
  const set = (i: number, patch: Partial<Row>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const add = () => {
    // The previous last step gets an end (it isn't final any more): 100 sold by default.
    const prev = rows.map((r, j) => (j === rows.length - 1 && !r.count && !r.endsAt ? { ...r, count: '100' } : r));
    const lastPrice = rows.length ? parseFloat(rows[rows.length - 1].price) || 0 : 0;
    setRows([...prev, { name: '', price: lastPrice.toFixed(2), count: '', endsAt: '', sold: 0, held: 0 }]);
  };
  const save = async () => {
    const steps = rowsToSteps(rows, tz);
    const err = priceStepsError(steps);
    if (err) { toast({ kind: 'error', message: err }); return; }
    const doorCents = door.trim() === '' ? null : Math.round((parseFloat(door) || 0) * 100);
    setBusy(true);
    try {
      load(await savePriceSteps(tier.id, steps, { cents: doorCents }));
      toast({ kind: 'success', message: `Prices saved for ${tier.name}.` });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the prices.' });
    } finally {
      setBusy(false);
    }
  };
  const cur = data.current;

  return (
    <div className="border border-slate-100 rounded-2xl p-4" data-testid={`price-steps-${tier.id}`}>
      <div className="flex items-center justify-between gap-4 mb-3">
        <div className="min-w-0">
          <p className="text-sm font-bold text-slate-800 truncate">{tier.name}</p>
          <p className="text-[11px] text-slate-400">
            Now <span className="font-bold text-slate-700">{formatCurrency((cur?.priceCents ?? 0) / 100, currency)}</span>
            {cur?.source === 'step' && cur.stepIndex != null && <> · step {cur.stepIndex} of {cur.stepCount}</>}
            {cur?.stepRemaining != null && <> · {cur.stepRemaining} left at this price</>}
          </p>
        </div>
        {canManage && (
          <button type="button" onClick={add}
            className="inline-flex items-center gap-1 px-3 py-1.5 bg-slate-100 hover:bg-slate-200 text-slate-700 rounded-lg text-[10px] font-black uppercase tracking-widest">
            <Plus size={12} aria-hidden="true" /> Add step
          </button>
        )}
      </div>

      {rows.length === 0 ? (
        <p className="text-[11px] text-slate-400 italic">One price. Add a step for early bird → GA → final.</p>
      ) : (
        <div className="space-y-2">
          <div className="hidden sm:grid grid-cols-[1.2fr_0.8fr_0.8fr_1.4fr_auto] gap-2 text-[10px] font-bold text-slate-400 uppercase tracking-widest">
            <span>Step</span><span>Price</span><span>Ends after</span><span>or ends on ({tz})</span><span />
          </div>
          {rows.map((r, i) => {
            const last = i === rows.length - 1;
            const live = cur?.stepId != null && cur.stepId === r.id;
            return (
              <div key={r.id ?? `new-${i}`} className="grid grid-cols-2 sm:grid-cols-[1.2fr_0.8fr_0.8fr_1.4fr_auto] gap-2 items-center">
                <input value={r.name} disabled={!canManage} maxLength={80} placeholder={last ? 'Final' : i === 0 ? 'Early bird' : `Step ${i + 1}`}
                  aria-label={`Step ${i + 1} name`} onChange={(e) => set(i, { name: e.target.value })} className={cell} />
                <input value={r.price} disabled={!canManage} type="number" min={0} step="0.01" aria-label={`Step ${i + 1} price`}
                  onChange={(e) => set(i, { price: e.target.value })} className={cell} />
                {last ? (
                  <span className="col-span-2 sm:col-span-2 text-[11px] text-slate-400 italic">Final price: no end</span>
                ) : (<>
                  <input value={r.count} disabled={!canManage} type="number" min={1} step={1} placeholder="# sold"
                    aria-label={`Step ${i + 1} ends after this many sold`} onChange={(e) => set(i, { count: e.target.value })} className={cell} />
                  <input value={r.endsAt} disabled={!canManage} type="datetime-local" aria-label={`Step ${i + 1} ends on`}
                    onChange={(e) => set(i, { endsAt: e.target.value })} className={cell} />
                </>)}
                <div className="flex items-center gap-2 justify-end">
                  <span className={`text-[10px] font-bold ${live ? 'text-emerald-600' : 'text-slate-400'}`}>
                    {live ? 'now · ' : ''}{r.sold} sold{r.held ? ` · ${r.held} held` : ''}
                  </span>
                  {canManage && (
                    <button type="button" aria-label={`Remove step ${i + 1}`} onClick={() => setRows(rows.filter((_, j) => j !== i))}
                      className="p-1 text-slate-400 hover:text-rose-600">
                      <Trash2 size={14} aria-hidden="true" />
                    </button>
                  )}
                </div>
              </div>
            );
          })}
          <p className="text-[11px] text-slate-400">
            A step ends at its number sold or its date, whichever comes first. Once its number has sold it stays ended.
          </p>
        </div>
      )}

      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-xs font-bold text-slate-500">
          Door price
          <input value={door} disabled={!canManage} type="number" min={0} step="0.01" placeholder="same as online"
            aria-label={`${tier.name} door price`} onChange={(e) => setDoor(e.target.value)} className={`${cell} w-28`} />
        </label>
        {canManage && (
          <button type="button" disabled={busy} onClick={() => void save()}
            className="bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white px-4 py-2 rounded-lg font-black uppercase tracking-tighter italic text-xs">
            {busy ? 'Saving…' : 'Save prices'}
          </button>
        )}
      </div>
    </div>
  );
}

export default function PriceStepsEditor({
  tiers, timezone, currency, canManage,
}: { tiers: TierOption[]; timezone?: string | null; currency?: string | null; canManage: boolean }) {
  const saved = tiers.filter((t) => t.id);
  if (saved.length === 0) return null;
  const tz = timezone || getBrowserTimezone();
  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-4" data-testid="price-steps">
      <div className="flex items-center space-x-3">
        <TrendingUp className="text-brand-primary w-5 h-5" />
        <h2 className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Price steps</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold">
        Let a ticket type's price move on its own: early bird for the first 100 or until a date, then GA, then a final
        price, plus an optional door price. Buyers see the current price (all-in, with your fees and tax inside) and when
        it goes up. Checkout locks the price a buyer sees.
      </p>
      <div className="space-y-4">
        {saved.map((t) => <div key={t.id}><TierSteps tier={t} tz={tz} currency={currency || 'USD'} canManage={canManage} /></div>)}
      </div>
    </section>
  );
}
