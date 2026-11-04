// The dashboard side of organizer-controlled access (mig 20261104180000,
// docs/org-access.md): per-role API permissions, venue booking requests and
// event grants, and the partner presale setting. Every call runs as the
// signed-in user; the SQL checks the role. Pure rules live in
// supabase/functions/_shared/api/orgAccess.ts (shared with exos-api).

import { supabase } from './supabase';

export {
  CONFIGURABLE_ROLES, DEFAULT_GRANT_SCOPES, effectivePartnerPresale, GRANT_SCOPE_INFO, GRANT_SCOPES, ORG_SCOPES,
  PARTNER_PRESALE_INFO, PARTNER_PRESALE_MODES, ROLE_SCOPE_CEILING, toggleScope, venueApprovalVenue,
  type GrantScope, type PartnerPresaleMode,
} from '../../supabase/functions/_shared/api/orgAccess.ts';

// -- Role API permissions ---------------------------------------------------------------

export interface RoleScopesRow {
  role: string;
  configurable: boolean;
  default: string[];
  ceiling: string[];
  configured: string[] | null;
  effective: string[];
  key_default: string[];
  key_effective: string[];
  updated_at: string | null;
}

export interface RoleScopesView {
  scopes: string[];
  roles: RoleScopesRow[];
  editable: boolean;
}

export async function getRoleScopes(orgId: string): Promise<RoleScopesView> {
  const { data, error } = await supabase.rpc('exos_org_role_scopes_get', { p_org_id: orgId });
  if (error) throw error;
  return data as RoleScopesView;
}

export async function setRoleScopes(orgId: string, role: string, scopes: string[]): Promise<RoleScopesView> {
  const { data, error } = await supabase.rpc('exos_org_role_scopes_set', { p_org_id: orgId, p_role: role, p_scopes: scopes });
  if (error) throw error;
  return data as RoleScopesView;
}

export async function resetRoleScopes(orgId: string, role: string): Promise<RoleScopesView> {
  const { data, error } = await supabase.rpc('exos_org_role_scopes_reset', { p_org_id: orgId, p_role: role });
  if (error) throw error;
  return data as RoleScopesView;
}

/** The set a role's row shows: the owner's choice, else today's token default. */
export function shownScopes(row: RoleScopesRow): string[] {
  return row.configured ?? row.default;
}

// -- Venue requests -------------------------------------------------------------------------

export interface DirectoryVenue {
  id: string;
  name: string;
  city: string | null;
  region: string | null;
  timezone: string | null;
  capacity: number | null;
  org: { id: string; name: string };
  rooms: { id: string; name: string; capacity: number | null }[];
}

export interface VenueRequest {
  id: string;
  status: 'pending' | 'approved' | 'declined' | 'withdrawn';
  date: string;
  start_time: string | null;
  title: string;
  message: string;
  expected_draw: number | null;
  venue: { id: string; name: string; city: string | null; timezone: string | null };
  room: { id: string; name: string; capacity: number | null } | null;
  venue_org: { id: string; name: string };
  requester_org: { id: string; name: string };
  outcome: 'hold' | 'event' | null;
  hold_id: string | null;
  event_id: string | null;
  grant_scopes: string[] | null;
  grant: { id: string; event_id: string; scopes: string[]; revoked_at: string | null } | null;
  decline_reason: string | null;
  decided_at: string | null;
  created_via: string;
  created_at: string;
}

export async function searchVenueDirectory(orgId: string, q: string): Promise<DirectoryVenue[]> {
  const { data, error } = await supabase.rpc('exos_venue_directory', { p_org_id: orgId, p_q: q });
  if (error) throw error;
  return (data ?? []) as DirectoryVenue[];
}

export async function listVenueRequests(orgId: string, direction: 'received' | 'sent', status?: string): Promise<VenueRequest[]> {
  const { data, error } = await supabase.rpc('exos_venue_requests', {
    p_org_id: orgId, p_direction: direction, p_status: status ?? null,
  });
  if (error) throw error;
  return ((data as { data?: VenueRequest[] })?.data ?? []) as VenueRequest[];
}

export async function createVenueRequest(orgId: string, req: {
  venue_id: string; room_id?: string | null; date: string; start_time?: string | null; title: string; message?: string;
  expected_draw?: number | null;
}): Promise<VenueRequest> {
  const { data, error } = await supabase.rpc('exos_venue_request_create', { p_org_id: orgId, p_request: req });
  if (error) throw error;
  return data as VenueRequest;
}

export async function decideVenueRequest(id: string, action: 'approve' | 'decline' | 'withdraw',
  args: Record<string, unknown> = {}): Promise<VenueRequest> {
  const { data, error } = await supabase.rpc('exos_venue_request_decide', { p_id: id, p_action: action, p_args: args });
  if (error) throw error;
  return data as VenueRequest;
}

export interface PartnerGrant {
  id: string;
  event: { id: string; name: string; starts_at: string | null; status: string };
  grantee_org: { id: string; name: string };
  request_id: string | null;
  scopes: string[];
  revoked_at: string | null;
  created_at: string;
}

export async function listPartnerGrants(orgId: string): Promise<PartnerGrant[]> {
  const { data, error } = await supabase.rpc('exos_partner_grants', { p_org_id: orgId });
  if (error) throw error;
  return (data ?? []) as PartnerGrant[];
}

export async function setPartnerGrant(id: string, scopes: string[]): Promise<PartnerGrant> {
  const { data, error } = await supabase.rpc('exos_partner_grant_set', { p_grant_id: id, p_scopes: scopes });
  if (error) throw error;
  return data as PartnerGrant;
}

export async function revokePartnerGrant(id: string): Promise<PartnerGrant> {
  const { data, error } = await supabase.rpc('exos_partner_grant_revoke', { p_grant_id: id });
  if (error) throw error;
  return data as PartnerGrant;
}

export interface CohostedEvent {
  id: string;
  name: string;
  status: string;
  starts_at: string | null;
  timezone: string | null;
  venue_name: string | null;
  host_org: { id: string; name: string };
  grant_id: string;
  scopes: string[];
}

export async function listCohostedEvents(orgId: string): Promise<CohostedEvent[]> {
  const { data, error } = await supabase.rpc('exos_cohost_events', { p_org_id: orgId });
  if (error) throw error;
  return (data ?? []) as CohostedEvent[];
}

// -- Partner presale ----------------------------------------------------------------------

export interface PartnerPresaleView {
  org_mode: 'block' | 'allow';
  event_id?: string;
  event_mode?: 'block' | 'allow' | null;
  effective?: 'block' | 'allow';
}

export async function getPartnerPresale(orgId: string, eventId?: string): Promise<PartnerPresaleView> {
  const { data, error } = await supabase.rpc('exos_partner_presale_get', { p_org_id: orgId, p_event_id: eventId ?? null });
  if (error) throw error;
  return data as PartnerPresaleView;
}

export async function setOrgPartnerPresale(orgId: string, mode: 'block' | 'allow'): Promise<PartnerPresaleView> {
  const { data, error } = await supabase.rpc('exos_partner_presale_set', { p_org_id: orgId, p_mode: mode });
  if (error) throw error;
  return data as PartnerPresaleView;
}

/** mode null: follow the organization. */
export async function setEventPartnerPresale(eventId: string, mode: 'block' | 'allow' | null): Promise<PartnerPresaleView> {
  const { data, error } = await supabase.rpc('exos_event_partner_presale_set', { p_event_id: eventId, p_mode: mode ?? 'inherit' });
  if (error) throw error;
  return data as PartnerPresaleView;
}

export const REQUEST_STATUS_LABEL: Record<VenueRequest['status'], string> = {
  pending: 'Pending', approved: 'Approved', declined: 'Declined', withdrawn: 'Withdrawn',
};
