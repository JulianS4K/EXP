import { useEffect, useState } from 'react';
import { getOrgPaymentsReady } from '../lib/orgPaymentsApi';
import { paymentsEnabled } from '../lib/payments';

/** Stripe Connect state for an org: true / false, or null while unknown. */
export function useOrgPaymentsReady(orgId: string | null | undefined): boolean | null {
  const [ready, setReady] = useState<boolean | null>(null);
  useEffect(() => {
    setReady(null);
    // Platform payments off: nothing to check (PaymentsOffNotice covers it).
    if (!orgId || !paymentsEnabled()) return undefined;
    let cancelled = false;
    getOrgPaymentsReady(orgId)
      .then((r) => { if (!cancelled) setReady(r); })
      .catch(() => { if (!cancelled) setReady(null); });
    return () => { cancelled = true; };
  }, [orgId]);
  return ready;
}
