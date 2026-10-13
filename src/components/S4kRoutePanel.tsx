// Who lists this event on the marketplaces (mig 20261014100000): Exos
// directly (the grid below) or S4K from the Exos feed.

import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { useOrganization } from '../context/OrganizationContext';
import { setDistributionRoute, type DistributionRoute } from '../lib/marketplace/s4kNetwork';

export default function S4kRoutePanel({ eventId, route, onChanged }: {
  eventId: string;
  route: DistributionRoute;
  onChanged: (route: DistributionRoute) => void;
}) {
  const { activeOrg } = useOrganization();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Not in the network and not already on it: nothing to choose.
  if (!activeOrg?.s4kNetwork && route !== 's4k') return null;

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
            <button key={r} type="button" role="radio" aria-checked={route === r} disabled={busy}
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
          ? 'S4K lists every paid, public ticket type on the marketplaces from one shared count (minus one order\'s worth held back), and buys from Exos when a marketplace sells. Free tickets stay on Exos.'
          : 'You choose each marketplace\'s seats in the grid below. To hand the event to S4K, set every marketplace to 0 first.'}
      </p>
      {error && <p role="alert" className="type text-xs text-rose-400">{error}</p>}
    </div>
  );
}
