// Reads for the "Where buyers are" panel (mig 20261106140000). The RPCs check
// the caller is the org's owner, manager or finance (or a platform admin).

import { supabase } from './supabase';
import { parseBuyerGeo, type BuyerGeoReport } from './buyerGeo';

/** One event's report, or null when it can't be read (role, or the migration not applied). */
export async function getEventBuyerGeo(eventId: string, limit = 10): Promise<BuyerGeoReport | null> {
  const { data, error } = await supabase.rpc('exos_event_buyer_geo', { p_event_id: eventId, p_limit: limit });
  if (error) {
    console.warn('buyer locations unavailable (non-fatal):', error.message);
    return null;
  }
  return parseBuyerGeo(data);
}

/** The whole org's report (optionally since an ISO date), or null. */
export async function getOrgBuyerGeo(orgId: string, since: string | null = null, limit = 10): Promise<BuyerGeoReport | null> {
  const { data, error } = await supabase.rpc('exos_org_buyer_geo', { p_org_id: orgId, p_since: since, p_limit: limit });
  if (error) {
    console.warn('org buyer locations unavailable (non-fatal):', error.message);
    return null;
  }
  return parseBuyerGeo(data);
}
