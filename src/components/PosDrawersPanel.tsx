// Event report → Cash drawers (POS, mig 20261104200000). Each drawer's float,
// expected cash, count and variance, with its recounts. Owners and managers
// can recount a closed drawer (the bill under the tray) for 7 days, 3 times at
// most, with a reason; the count it replaces stays in the audit trail.
// Owner / manager / finance; hidden when the event has no drawers.

import { useCallback, useEffect, useState } from 'react';
import { Calculator } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import {
  MAX_RECOUNTS, parseCash, RECOUNT_BLOCK_TEXT, recountBlock, recountsFor, recountVariance, validReason,
  type DrawerRow, type RecountRow,
} from '../lib/drawerRecount';
import { getEventDrawers, recountDrawer } from '../lib/drawerRecountApi';

export default function PosDrawersPanel({ eventId, currency, canView, canAct }: {
  eventId: string; currency: string; canView: boolean; canAct: boolean;
}) {
  const { toast } = useToast();
  const [data, setData] = useState<{ drawers: DrawerRow[]; recounts: RecountRow[]; settled: boolean } | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    if (canView) void getEventDrawers(eventId).then(setData);
  }, [eventId, canView]);
  useEffect(load, [load]);

  if (!canView || !data || data.drawers.length === 0) return null;
  const money = (c: number | null) => (c === null ? '—' : formatCents(c, currency));

  const submit = async (d: DrawerRow) => {
    const cents = parseCash(amount);
    if (cents === null) { toast({ kind: 'error', message: 'Enter the counted cash, e.g. 412.50' }); return; }
    if (!validReason(reason)) { toast({ kind: 'error', message: 'Say why (3-500 characters).' }); return; }
    setBusy(true);
    try {
      const r = await recountDrawer(d.id, cents, reason.trim());
      toast({ kind: 'success', message: r.replay ? 'Already recorded.' : `Recount ${r.recount_no} saved: variance ${money(r.variance_cents)}` });
      setOpen(null); setAmount(''); setReason('');
      load();
    } catch (e) {
      toast({ kind: 'error', message: String((e as { message?: string })?.message ?? e).replace(/^exos_pos_recount_drawer: /, '') });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8 border border-slate-100" aria-labelledby="drawers-title">
      <div className="flex items-center gap-2 mb-1">
        <Calculator className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 id="drawers-title" className="text-sm font-bold text-slate-700">Cash drawers</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Expected = float + cash taken. A miscounted drawer can be recounted by an owner or manager for 7 days
        ({MAX_RECOUNTS} times at most); every earlier count is kept.
      </p>
      <ul className="space-y-3">
        {data.drawers.map((d, i) => {
          const rec = recountsFor(data.recounts, d.id);
          const block = recountBlock(d, rec.length, { canAct, settled: data.settled });
          const preview = parseCash(amount);
          return (
            <li key={d.id} className="border border-slate-100 rounded-lg p-4">
              <div className="flex flex-wrap items-baseline gap-x-6 gap-y-1 text-sm">
                <span className="font-bold text-slate-800">Drawer {i + 1}</span>
                <span className="text-slate-500">{d.status === 'open' ? 'Open' : 'Closed'}</span>
                <span>Float {money(d.open_float_cents)}</span>
                <span>Expected {money(d.expected_cents)}</span>
                <span>Counted {money(d.counted_cents)}</span>
                <span className={d.variance_cents && d.variance_cents < 0 ? 'text-rose-600 font-bold' : d.variance_cents ? 'text-amber-600 font-bold' : 'text-emerald-600 font-bold'}>
                  Variance {money(d.variance_cents)}
                </span>
              </div>
              {rec.length > 0 && (
                <ol className="mt-2 space-y-1 text-[11px] text-slate-500">
                  {rec.map((r) => (
                    <li key={r.id}>
                      Recount {r.recount_no}: {money(r.previous_counted_cents)} → {money(r.counted_cents)} (variance{' '}
                      {money(r.previous_variance_cents)} → {money(r.variance_cents)}) · {r.reason}
                    </li>
                  ))}
                </ol>
              )}
              {d.status === 'closed' && canAct && (
                block ? (
                  <p className="mt-2 text-[11px] text-slate-400">{RECOUNT_BLOCK_TEXT[block]}</p>
                ) : open === d.id ? (
                  <div className="mt-3 flex flex-col md:flex-row gap-2">
                    <input inputMode="decimal" placeholder="Counted cash" aria-label="Counted cash" value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                      className="md:w-36 border border-slate-200 rounded px-3 py-2 text-sm" />
                    <input placeholder="Why (e.g. $10 found under the tray)" aria-label="Reason" value={reason} maxLength={500}
                      onChange={(e) => setReason(e.target.value)}
                      className="flex-1 border border-slate-200 rounded px-3 py-2 text-sm" />
                    <button type="button" disabled={busy} onClick={() => submit(d)}
                      className="bg-tm-blue text-white px-4 py-2 rounded text-xs font-bold disabled:opacity-50">
                      Save recount{preview !== null && d.expected_cents !== null ? ` (variance ${money(recountVariance(d.expected_cents, preview))})` : ''}
                    </button>
                    <button type="button" onClick={() => setOpen(null)} className="text-xs text-slate-400 px-2">Cancel</button>
                  </div>
                ) : (
                  <button type="button" onClick={() => { setOpen(d.id); setAmount(''); setReason(''); }}
                    className="mt-2 text-[11px] font-bold uppercase tracking-widest text-tm-blue">
                    Recount
                  </button>
                )
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
