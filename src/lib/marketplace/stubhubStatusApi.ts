// Reads an event's StubHub row (mig 20260926190000). Org owners, managers and
// finance can read their events' distribution rows (RLS); nobody writes them
// from the browser: the exos_events trigger queues, exos-distribute plans.

import { supabase } from '../supabase';
import type { StubHubDistributionRow } from './stubhubStatus';

export async function getStubHubDistribution(eventId: string): Promise<StubHubDistributionRow | null> {
  const { data, error } = await supabase
    .from('exos_distribution_listings')
    .select('status, error, external_event_id, planned_request, last_synced_at, tier_id, requested_qty')
    .eq('event_id', eventId)
    .eq('channel', 'stubhub')
    .maybeSingle();
  if (error) throw error;
  return (data as StubHubDistributionRow | null) ?? null;
}

/**
 * How many seats of one ticket type go to StubHub (exos_set_channel_allocation).
 * Exos stops selling those seats at once; 0 gives them back. Refused when the
 * seats aren't free, or the event's overall cap is tighter than its ticket types.
 */
export async function setStubHubAllocation(eventId: string, tierId: string, qty: number): Promise<number> {
  const { data, error } = await supabase.rpc('exos_set_channel_allocation', {
    p_event_id: eventId,
    p_channel: 'stubhub',
    p_tier_id: tierId,
    p_qty: qty,
  });
  if (error) throw error;
  return data as number;
}
