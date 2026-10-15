// exos_attendee_lookup (mig 20261014120000). Model: ./attendeeLookup.

import { supabase } from './supabase';
import { isMissingRpc } from './door/net';
import { parseLookup, type LookupResult, type StatusWord } from './attendeeLookup';

/** null when the migration isn't deployed. */
export async function lookupAttendees(
  eventId: string, query: string | null, status: StatusWord | null, limit = 100,
): Promise<LookupResult | null> {
  const { data, error } = await supabase.rpc('exos_attendee_lookup', {
    p_event_id: eventId, p_query: query && query.trim() ? query.trim() : null, p_status: status, p_limit: limit,
  });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseLookup(data);
}
