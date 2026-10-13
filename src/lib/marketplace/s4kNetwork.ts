// The S4K network switches (mig 20261014100000, docs/marketplace/s4k-feed.md):
// an org joins (owner), then each event picks who lists it on the
// marketplaces: Exos directly, or S4K (which reads the Exos feed and lists
// through Automatiq on its own accounts).

import { supabase } from '../supabase';

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
