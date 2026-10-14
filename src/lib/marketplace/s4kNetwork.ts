// The S4K network switches (mig 20261014100000, docs/marketplace/s4k-feed.md):
// an org joins (owner), then each event picks who lists it on the
// marketplaces: Exos directly, or S4K (which reads the Exos feed and lists
// through Automatiq on its own accounts).

import { supabase } from '../supabase';
import { isMissingRpc } from '../door/net';
import { parsePoolStatus, type PoolStatus } from './s4kPools';

export type DistributionRoute = 'direct' | 's4k';

export async function setS4kNetwork(orgId: string, on: boolean): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_set_s4k_network', { p_org_id: orgId, p_on: on });
  if (error) throw error;
  return data === true;
}

export async function setDistributionRoute(eventId: string, route: DistributionRoute): Promise<DistributionRoute> {
  const { data, error } = await supabase.rpc('exos_set_distribution_route', { p_event_id: eventId, p_route: route });
  if (error) throw error;
  return data === 's4k' ? 's4k' : 'direct';
}

/** Both pools per ticket type (mig 20261014130000); null before the migration. */
export async function fetchS4kPools(eventId: string): Promise<PoolStatus | null> {
  const { data, error } = await supabase.rpc('exos_s4k_pool_status', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parsePoolStatus(data);
}

/** Set S4K's split per ticket type (seats = S4K's total, sold included). All or none. */
export async function setS4kSplit(eventId: string, splits: { tierId: string; seats: number }[]): Promise<PoolStatus> {
  const { data, error } = await supabase.rpc('exos_set_s4k_split', {
    p_event_id: eventId,
    p_splits: splits.map((s) => ({ tier_id: s.tierId, seats: s.seats })),
  });
  if (error) throw error;
  return parsePoolStatus(data);
}
