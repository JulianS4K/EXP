// Reads an event's StubHub row (mig 20260926190000). Org owners, managers and
// finance can read their events' distribution rows (RLS); nobody writes them
// from the browser: the exos_events trigger queues, exos-distribute plans.

import { supabase } from '../supabase';
import type { StubHubDistributionRow } from './stubhubStatus';

export async function getStubHubDistribution(eventId: string): Promise<StubHubDistributionRow | null> {
  const { data, error } = await supabase
    .from('exos_distribution_listings')
    .select('status, error, external_event_id, planned_request, last_synced_at')
    .eq('event_id', eventId)
    .eq('channel', 'stubhub')
    .maybeSingle();
  if (error) throw error;
  return (data as StubHubDistributionRow | null) ?? null;
}
