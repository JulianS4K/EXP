// The split between the two pools on an S4K-route event (mig
// 20261014130000): per ticket type, how many seats S4K gets; Exos and
// Eventbrite share the rest. Owner / manager save it; finance sees it.

import { useEffect, useMemo, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { fetchS4kPools, setResaleOptions, setS4kSplit } from '../lib/marketplace/s4kNetwork';
import { maxSplit, poolsAfter, splitError, splitForPercent, type PoolStatus, type PrimarySource } from '../lib/marketplace/s4kPools';

export default function S4kSplitPanel({ eventId }: { eventId: string }) {
  const [status, setStatus] = useState<PoolStatus | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'hidden' | 'error'>('loading');
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [pct, setPct] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);

  const seed = (s: PoolStatus) => {
    setStatus(s);
    setDraft(Object.fromEntries(s.tiers.map((t) => [t.tierId, String(t.s4kSplit)])));
  };

  useEffect(() => {
    let alive = true;
    setState('loading');
    fetchS4kPools(eventId)
      .then((s) => {
        if (!alive) return;
        if (!s) return setState('hidden');
        seed(s);
        setState('ready');
      })
      .catch((err) => {
        console.warn('S4K pools unavailable', err);
        if (alive) setState('error');
      });
    return () => {
      alive = false;
    };
  }, [eventId]);

  const tiers = status?.tiers ?? [];
  const errors = useMemo(
    () => Object.fromEntries(tiers.map((t) => [t.tierId, splitError(t, Number(draft[t.tierId] ?? t.s4kSplit))])),
    [tiers, draft],
  );
  const changed = tiers.filter((t) => Number(draft[t.tierId] ?? t.s4kSplit) !== t.s4kSplit);
  const blocked = changed.some((t) => errors[t.tierId]);

  if (state === 'hidden') return null;
  if (state === 'loading') return <p className="type text-xs text-white/40">Loading the split…</p>;
  if (state === 'error' || !status) return <p className="type text-xs text-rose-400">Couldn't load the split.</p>;

  const applyPct = () => {
    const p = Number(pct);
    if (!Number.isFinite(p)) return;
    setDraft((d) => ({
      ...d,
      ...Object.fromEntries(tiers.filter((t) => t.splittable).map((t) => [t.tierId, String(splitForPercent(t, p))])),
    }));
  };

  const saveOptions = async (opts: { listingQty?: number; primarySource?: PrimarySource; rebalance?: boolean }) => {
    setBusy(true);
    setMsg(null);
    try {
      await setResaleOptions(eventId, opts);
      const next = await fetchS4kPools(eventId);
      if (next) seed(next);
      setMsg({ text: 'Saved. Albert sees the new listings within a minute.', ok: true });
    } catch (err) {
      setMsg({ text: (err as Error)?.message?.replace(/^exos_set_resale_options: /, '') || 'Not saved.', ok: false });
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    setBusy(true);
    setMsg(null);
    try {
      const next = await setS4kSplit(eventId, changed.map((t) => ({ tierId: t.tierId, seats: Number(draft[t.tierId]) })));
      seed(next);
      setMsg({ text: 'Split saved. The S4K feed shows the new numbers within a minute.', ok: true });
    } catch (err) {
      setMsg({ text: (err as Error)?.message?.replace(/^exos_set_s4k_split: /, '') || 'Not saved.', ok: false });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 border border-white/10 p-4">
      <div>
        <p className="type text-[11px] text-white/60 uppercase tracking-widest">Two pools</p>
        <p className="type text-xs text-white/60 mt-1">
          S4K gets the seats you give it here and lists them on the resale marketplaces. Exos and Eventbrite share
          the rest. Neither pool can sell the other's seats. Lowering S4K's share gives its unsold seats back at
          once; raising it only takes seats that are still free.
        </p>
      </div>
      <div className="space-y-2 border-t border-white/10 pt-3">
        <p className="type text-xs text-white/60">
          S4K gets three listings per ticket type (through Albert), each refilled from S4K's seats as it sells.
          {status.rebalance
            ? ` When S4K runs short, it takes more from Exos + Eventbrite until one listing (${status.listingQty}) is left there, for ${status.primarySource === 'eventbrite' ? 'Eventbrite' : 'Exos'}.`
            : ' Rebalancing is off: S4K only sells what you give it.'}
        </p>
        <div className="flex flex-wrap items-center gap-3">
          <label className="type text-[11px] text-white/60 flex items-center gap-2">
            Tickets per listing
            <input aria-label="Tickets per listing" inputMode="numeric" defaultValue={status.listingQty} key={`q${status.listingQty}`}
              onBlur={(e) => {
                const v = Number(e.target.value);
                if (Number.isInteger(v) && v >= 1 && v <= 50 && v !== status.listingQty) void saveOptions({ listingQty: v });
              }}
              className="w-14 bg-transparent border border-white/20 px-2 py-1 text-xs text-white" />
          </label>
          <label className="type text-[11px] text-white/60 flex items-center gap-2">
            <input type="checkbox" checked={status.rebalance} disabled={busy}
              onChange={(e) => void saveOptions({ rebalance: e.target.checked })} className="accent-brand-primary" />
            Refill S4K from Exos + Eventbrite
          </label>
          {status.eventbriteLinked && (
            <label className="type text-[11px] text-white/60 flex items-center gap-2">
              Primary QR source
              <select value={status.primarySource} disabled={busy}
                onChange={(e) => void saveOptions({ primarySource: e.target.value as PrimarySource })}
                className="bg-black border border-white/20 px-2 py-1 text-xs text-white">
                <option value="exos">Exos</option>
                <option value="eventbrite">Eventbrite</option>
              </select>
            </label>
          )}
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <label htmlFor="s4k-pct" className="type text-[11px] text-white/60">Give S4K</label>
        <input id="s4k-pct" inputMode="numeric" value={pct} onChange={(e) => setPct(e.target.value.replace(/[^0-9]/g, '').slice(0, 3))}
          className="w-14 bg-transparent border border-white/20 px-2 py-1 text-xs text-white" placeholder="20" />
        <span className="type text-[11px] text-white/60">% of each ticket type</span>
        <button type="button" onClick={applyPct} disabled={!pct}
          className="px-3 py-1 text-[10px] uppercase tracking-widest border border-white/20 text-white/70 disabled:opacity-40">
          Fill
        </button>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-xs text-white/80">
          <thead>
            <tr className="text-left text-[10px] uppercase tracking-widest text-white/40">
              <th className="py-1 pr-3 font-normal">Ticket type</th>
              <th className="py-1 pr-3 font-normal">Capacity</th>
              <th className="py-1 pr-3 font-normal">S4K seats</th>
              <th className="py-1 pr-3 font-normal">S4K left</th>
              <th className="py-1 pr-3 font-normal">Listings</th>
              <th className="py-1 font-normal">Exos + Eventbrite free</th>
            </tr>
          </thead>
          <tbody>
            {tiers.map((t) => {
              const seats = Number(draft[t.tierId] ?? t.s4kSplit);
              const after = poolsAfter(t, Number.isFinite(seats) ? seats : t.s4kSplit);
              const err = errors[t.tierId];
              return (
                <tr key={t.tierId} className="align-top">
                  <td className="py-1.5 pr-3">
                    {t.name}
                    {t.eventbriteMapped && <span className="block text-[10px] text-white/40">shared with Eventbrite</span>}
                  </td>
                  <td className="py-1.5 pr-3">{t.capacity || '—'}</td>
                  <td className="py-1.5 pr-3">
                    {t.splittable ? (
                      <>
                        <input
                          aria-label={`S4K seats for ${t.name}`}
                          inputMode="numeric"
                          value={draft[t.tierId] ?? ''}
                          onChange={(e) => setDraft((d) => ({ ...d, [t.tierId]: e.target.value.replace(/[^0-9]/g, '').slice(0, 5) }))}
                          className={`w-16 bg-transparent border px-2 py-1 ${err && seats !== t.s4kSplit ? 'border-rose-400' : 'border-white/20'}`}
                        />
                        <span className="block text-[10px] text-white/40">max {maxSplit(t)}{t.s4kSold ? ` · ${t.s4kSold} sold` : ''}</span>
                        {err && seats !== t.s4kSplit && <span className="block text-[10px] text-rose-400">{err}</span>}
                      </>
                    ) : (
                      <span className="text-white/40">Not on S4K</span>
                    )}
                  </td>
                  <td className="py-1.5 pr-3">{after.s4k}</td>
                  <td className="py-1.5 pr-3">{t.listings.length ? t.listings.join(' · ') : '—'}</td>
                  <td className="py-1.5">{after.shared ?? 'no cap'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="flex items-center gap-3">
        <button type="button" onClick={() => void save()} disabled={busy || changed.length === 0 || blocked}
          className="px-4 py-1.5 text-[10px] uppercase tracking-widest border border-brand-primary text-brand-primary disabled:opacity-40">
          Save split
        </button>
        {busy && <Loader2 className="w-3 h-3 animate-spin text-white/50" />}
        {!status.onFeed && (
          <span className="type text-[11px] text-white/40">Not on the S4K feed yet (publish the event, before doors).</span>
        )}
      </div>
      {msg && <p role={msg.ok ? 'status' : 'alert'} className={`type text-xs ${msg.ok ? 'text-emerald-400' : 'text-rose-400'}`}>{msg.text}</p>}
    </div>
  );
}
