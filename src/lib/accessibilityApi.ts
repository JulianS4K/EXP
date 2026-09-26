// Accessible ticket options (mig 20260926090000) — RPC wrappers. Access needs
// are never read from exos_tickets directly (no column grant): the holder
// reads their own through exos_ticket_access_needs, staff through
// exos_event_access_requests / the door download.

import { supabase } from './supabase';
import { normalizeNeeds, type AccessNeed } from './accessibility';

export async function getMyTicketAccessNeeds(ticketId: string): Promise<AccessNeed[]> {
  const { data, error } = await supabase.rpc('exos_ticket_access_needs', { p_ticket_id: ticketId });
  if (error) throw error;
  return normalizeNeeds(data);
}

export async function setMyTicketAccessNeeds(ticketId: string, needs: AccessNeed[]): Promise<AccessNeed[]> {
  const { data, error } = await supabase.rpc('exos_set_ticket_access_needs', { p_ticket_id: ticketId, p_needs: needs });
  if (error) throw error;
  return normalizeNeeds(data);
}

export interface AccessRequest {
  source: 'ticket' | 'guest';
  refId: string;
  name: string;
  /** Ticket type for a ticket, list name for a guest. */
  detail: string;
  needs: AccessNeed[];
  checkedIn: boolean;
}

export async function listAccessRequests(eventId: string): Promise<AccessRequest[]> {
  const { data, error } = await supabase.rpc('exos_event_access_requests', { p_event_id: eventId });
  if (error) throw error;
  return ((data as any[]) ?? []).map((r) => ({
    source: r.source === 'guest' ? 'guest' : 'ticket',
    refId: String(r.ref_id),
    name: String(r.name ?? ''),
    detail: String(r.detail ?? ''),
    needs: normalizeNeeds(r.needs),
    checkedIn: !!r.checked_in,
  }));
}

export async function setGuestAccessNeeds(entryId: string, needs: AccessNeed[]): Promise<AccessNeed[]> {
  const { data, error } = await supabase.rpc('exos_set_guest_access_needs', { p_entry_id: entryId, p_needs: needs });
  if (error) throw error;
  return normalizeNeeds(data);
}

export async function promoterSetGuestAccessNeeds(token: string, entryId: string, needs: AccessNeed[]): Promise<AccessNeed[]> {
  const { data, error } = await supabase.rpc('exos_promoter_set_guest_access_needs', {
    p_token: token, p_entry_id: entryId, p_needs: needs,
  });
  if (error) throw error;
  return normalizeNeeds(data);
}
