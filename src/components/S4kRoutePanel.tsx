// Who lists this event on the marketplaces (mig 20261014100000): Exos
// directly (the grid below) or S4K from the Exos feed, with the split
// between S4K's pool and Exos + Eventbrite's (mig 20261014130000).

import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { useOrganization } from '../context/OrganizationContext';
import { setDistributionRoute, type DistributionRoute } from '../lib/marketplace/s4kNetwork';
import S4kSplitPanel from './S4kSplitPanel';
import { resaleLockedText, resaleUnlocked } from '../lib/marketplace/resaleGate';

export default function S4kRoutePanel({ eventId, route, onChanged, maxCapacity, optInNeeded }: {
  eventId: string;
  route: DistributionRoute;
  onChanged: (route: DistributionRoute) => void;
  /** The event's max capacity (lib/marketplace/resaleGate): S4K needs more than the free tier's 150. */
  maxCapacity?: number;
  /** Big enough, but not opted in to resale yet (ResaleConsentPanel). */
  optInNeeded?: boolean;
}) {
  const { activeOrg } = useOrganization();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Not in the network and not already on it: nothing to choose.
  if (!activeOrg?.s4kNetwork && route !== 's4k') return null;
  const tooSmall = maxCapacity !== undefined && !resaleUnlocked(maxCapacity);
  const locked = tooSmall || !!optInNeeded;

  const change = async (next: DistributionRoute) => {
    setBusy(true);
    setError(null);
    try {
      onChanged(await setDistributionRoute(eventId, next));
    } catch (err) {
      setError((err as Error)?.message || 'Not saved.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-2 border border-white/10 p-4">
      <div className="flex flex-wrap items-center gap-3">
        <span className="type text-[11px] text-white/60 uppercase tracking-widest">Who lists it</span>
        <div role="radiogroup" aria-label="Who lists it" className="flex gap-2">
          {(['s4k', 'direct'] as const).map((r) => (
            <button key={r} type="button" role="radio" aria-checked={route === r} disabled={busy || (r === 's4k' && locked && route !== 's4k')}
              onClick={() => route !== r && void change(r)}
              className={`px-3 py-1 text-[10px] uppercase tracking-widest border ${route === r ? 'border-brand-primary text-brand-primary' : 'border-white/20 text-white/50'} disabled:opacity-50`}>
              {r === 's4k' ? 'S4K network' : 'Exos, per marketplace'}
            </button>
          ))}
        </div>
        {busy && <Loader2 className="w-3 h-3 animate-spin text-white/50" />}
      </div>
      <p className="type text-xs text-white/60">
        {route === 's4k'
          ? 'S4K lists the seats you give it below on the marketplaces, and buys from Exos when a marketplace sells. Exos and Eventbrite sell the rest. Free tickets stay off resale.'
          : 'You choose each marketplace\'s seats in the grid below. To hand the event to S4K, set every marketplace to 0 first.'}
      </p>
      {tooSmall && maxCapacity !== undefined && <p role="status" className="type text-xs text-amber-400">{resaleLockedText(maxCapacity)}</p>}
      {!tooSmall && optInNeeded && route !== 's4k' && (
        <p role="status" className="type text-xs text-amber-400">Opt this event in to resale (above) before handing it to S4K.</p>
      )}
      {error && <p role="alert" className="type text-xs text-rose-400">{error}</p>}
      {route === 's4k' && <S4kSplitPanel eventId={eventId} />}
    </div>
  );
}
