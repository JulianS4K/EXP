// Read behind the Disputes block (event report, org Payouts). Read-only:
// RLS on exos_disputes (mig 20261001101000) lets org owner / manager /
// finance read their org's rows. A missing table (older schema) or a refused
// read comes back as null and the block hides.

import { supabase } from './supabase';
import { DISPUTE_COLS, type DisputeRow } from './disputesView';

/** An event's (eventId) or an org's (orgId) disputes, newest first; null when unreadable. */
export async function getDisputes(scope: { eventId?: string; orgId?: string }): Promise<DisputeRow[] | null> {
  try {
    let q = supabase.from('exos_disputes')
      .select(scope.orgId ? `${DISPUTE_COLS}, event:exos_events(name)` : DISPUTE_COLS);
    if (scope.eventId) q = q.eq('event_id', scope.eventId);
    if (scope.orgId) q = q.eq('org_id', scope.orgId);
    const { data, error } = await q.order('created_at', { ascending: false }).limit(500);
    if (error) throw error;
    return (data as unknown as DisputeRow[] | null) ?? [];
  } catch (e) {
    console.warn('disputes read unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
}

/** Buyer email per dispute row id (mig 20261021120000); empty when unavailable. */
export async function getDisputeBuyers(ids: string[]): Promise<Map<string, string>> {
  if (ids.length === 0) return new Map();
  try {
    const { data, error } = await supabase.rpc('exos_dispute_buyers', { p_dispute_ids: ids.slice(0, 500) });
    if (error) throw error;
    return new Map(((data as { id: string; buyer_email: string | null }[] | null) ?? [])
      .filter((r) => r.buyer_email)
      .map((r) => [r.id, r.buyer_email as string]));
  } catch (e) {
    console.warn('dispute buyers unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return new Map();
  }
}
