// Calls for event location modes and the org type (mig 20261105130000,
// docs/promoter-events.md). Every call runs as the signed-in user (or, for
// the live ticket link, with its key); the SQL checks who may see what.

import { supabase } from './supabase';
import type { HolderLocationView, OrgType } from './eventLocation';
import type { StaffLocationView } from './eventLocation';

export interface VenueMatch {
  venue_id: string;
  name: string;
  city: string | null;
  region: string | null;
  verified: boolean;
  org: { id: string; name: string };
}

export interface EventLocationAnswer extends StaffLocationView, HolderLocationView {
  event_id: string;
  revealed: boolean;
  reveal_at: string | null;
  sales_open: boolean;
  has_secret?: boolean | null;
  viewer?: 'staff' | 'holder' | 'public';
  venue_suggestions?: VenueMatch[];
}

// Whether mig 20261105130000 is on this database (one probe per page load);
// the location picker stays hidden until it answers yes.
let probe: Promise<boolean> | null = null;
export function hasLocationModes(): Promise<boolean> {
  if (!probe) {
    probe = Promise.resolve(supabase.from('exos_events').select('location_mode').limit(1))
      .then(({ error }) => !error, () => false);
  }
  return probe;
}

/** Staff: everything; a ticket holder: the address once revealed; anyone else: the public part. */
export async function getEventLocation(eventId: string): Promise<EventLocationAnswer> {
  const { data, error } = await supabase.rpc('exos_event_location', { p_event_id: eventId });
  if (error) throw error;
  return data as EventLocationAnswer;
}

/** Owners and managers. Returns the saved location (with venue_suggestions). */
export async function setEventLocation(eventId: string, payload: Record<string, unknown>): Promise<EventLocationAnswer> {
  const { data, error } = await supabase.rpc('exos_event_location_set', { p_event_id: eventId, p_location: payload });
  if (error) throw error;
  return data as EventLocationAnswer;
}

/** A live ticket link (no account): that ticket's location. */
export async function getTicketLinkLocation(ticketId: string, key: string): Promise<(EventLocationAnswer & { ok: boolean }) | null> {
  const { data, error } = await supabase.rpc('exos_ticket_link_location', { p_ticket_id: ticketId, p_key: key });
  if (error) throw error;
  const v = data as (EventLocationAnswer & { ok: boolean }) | null;
  return v?.ok ? v : null;
}

/** "This venue is on Exos": owned venues of other orgs taking requests, same name and city. */
export async function venueMatches(orgId: string, name: string, city: string): Promise<VenueMatch[]> {
  if (!name.trim() || !city.trim()) return [];
  const { data, error } = await supabase.rpc('exos_location_venue_matches', { p_org_id: orgId, p_name: name, p_city: city });
  if (error) throw error;
  return (data ?? []) as VenueMatch[];
}

/** The org owner: declare the org a promoter / collective (or an organizer again). */
export async function setOrgType(orgId: string, type: OrgType): Promise<void> {
  const { error } = await supabase.rpc('exos_org_type_set', { p_org_id: orgId, p_type: type });
  if (error) throw error;
}
