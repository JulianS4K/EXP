// The auto split switch above the Marketplaces grid (mig 20261014090000).

import { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { describeSplit, fetchChannelSplit, setChannelSplit, type ChannelSplit } from '../lib/marketplace/channelSplit';

export default function ChannelSplitPanel({ eventId, tierNames, labels, onChanged }: {
  eventId: string;
  tierNames: Record<string, string>;
  labels: Record<string, string>;
  onChanged?: () => void;
}) {
  const [split, setSplit] = useState<ChannelSplit | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setSplit(undefined);
    fetchChannelSplit(eventId)
      .then((s) => { if (alive) setSplit(s); })
      .catch((err) => { console.warn('channel split unavailable', err); if (alive) setSplit(null); });
    return () => { alive = false; };
  }, [eventId]);

  if (!split) return null;

  const change = async (mode: 'auto' | 'manual') => {
    setBusy(true);
    setError(null);
    try {
      setSplit(await setChannelSplit(eventId, mode));
      onChanged?.();
    } catch (err) {
      setError((err as Error)?.message?.replace(/^exos_set_channel_split: /, '') || 'Not saved.');
    } finally {
      setBusy(false);
    }
  };

  const auto = split.mode === 'auto';
  return (
    <div className="space-y-2 border border-white/10 p-4">
      <div className="flex flex-wrap items-center gap-3">
        <span className="type text-[11px] text-white/60 uppercase tracking-widest">How seats are shared</span>
        <div role="radiogroup" aria-label="How seats are shared" className="flex gap-2">
          {(['auto', 'manual'] as const).map((m) => (
            <button key={m} type="button" role="radio" aria-checked={split.mode === m} disabled={busy}
              onClick={() => split.mode !== m && void change(m)}
              className={`px-3 py-1 text-[10px] uppercase tracking-widest border ${split.mode === m ? 'border-brand-primary text-brand-primary' : 'border-white/20 text-white/50'} disabled:opacity-50`}>
              {m === 'auto' ? 'Auto (recommended)' : 'Manual'}
            </button>
          ))}
        </div>
        {busy && <Loader2 className="w-3 h-3 animate-spin text-white/50" />}
      </div>
      {auto ? (
        <>
          <p className="type text-xs text-white/60">
            {describeSplit(split)} Rebalanced daily, every 6 hours in the last week, hourly in the last 2 days. Free
            ticket types stay on Exos. Changing a number in the grid switches to manual.
          </p>
          {split.tiers.length > 0 && (
            <ul className="type text-xs text-white/50 space-y-1">
              {split.tiers.map((t) => (
                <li key={t.tierId}>
                  <span className="text-white/80">{tierNames[t.tierId] ?? 'Ticket type'}</span>: {t.unsold} unsold · Exos {t.reserve}
                  {Object.entries(t.shares).map(([ch, n]) => ` · ${labels[ch] ?? ch} ${n}`).join('')}
                </li>
              ))}
            </ul>
          )}
        </>
      ) : (
        <p className="type text-xs text-white/50">You set each marketplace's seats in the grid below.</p>
      )}
      {error && <p role="alert" className="type text-xs text-rose-400">{error}</p>}
    </div>
  );
}
