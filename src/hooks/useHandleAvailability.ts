import { useEffect, useState } from 'react';
import { isOrgHandleAvailable, isValidOrgSlug } from '../lib/orgs';

export type HandleState = 'idle' | 'checking' | 'available' | 'taken' | 'unknown';

/** Live "is this org handle free?" as the user types (debounced). */
export function useHandleAvailability(slug: string, delayMs = 350): HandleState {
  const [state, setState] = useState<HandleState>('idle');
  useEffect(() => {
    if (!isValidOrgSlug(slug)) {
      setState('idle');
      return undefined;
    }
    let cancelled = false;
    setState('checking');
    const t = setTimeout(() => {
      isOrgHandleAvailable(slug)
        .then((ok) => { if (!cancelled) setState(ok === null ? 'unknown' : ok ? 'available' : 'taken'); })
        .catch(() => { if (!cancelled) setState('unknown'); });
    }, delayMs);
    return () => { cancelled = true; clearTimeout(t); };
  }, [slug, delayMs]);
  return state;
}
