// The dashboard side of partner sales and the developer platform: RPC calls
// to migs 20261031130000 / 20261031130500 (docs/partner-sales.md,
// docs/developer-platform.md). Every call runs as the signed-in user; the SQL
// checks the role.

import { supabase } from './supabase';
import type { LinkView } from './ticketLink';

// -- Distribution partners ------------------------------------------------------

export const PARTNER_TYPES = ['automatiq', 'stubhub', 'vivid', 'seatgeek', 'ticketnetwork', 'victorylive', 'other'] as const;
export const PARTNER_TYPE_LABEL: Record<string, string> = {
  automatiq: 'Automatiq', stubhub: 'StubHub', vivid: 'Vivid Seats', seatgeek: 'SeatGeek',
  ticketnetwork: 'Ticket Network', victorylive: 'Victory Live', other: 'Other',
};

export interface DistributionPartner {
  id: string;
  label: string;
  partner_type: string;
  key_prefix: string;
  scopes: string[];
  active: boolean;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
}

export async function listDistributionPartners(orgId: string): Promise<DistributionPartner[]> {
  const { data, error } = await supabase.from('exos_distribution_partners')
    .select('id, label, partner_type, key_prefix, scopes, active, created_at, last_used_at, revoked_at')
    .eq('org_id', orgId).order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []) as DistributionPartner[];
}

/** Mint a key; `key` is in the answer this once. */
export async function createDistributionPartner(orgId: string, label: string, partnerType: string, scopes: string[]) {
  const { data, error } = await supabase.rpc('exos_create_distribution_partner', {
    p_org_id: orgId, p_label: label, p_partner_type: partnerType, p_scopes: scopes,
  });
  if (error) throw error;
  return data as DistributionPartner & { key: string };
}

export async function updateDistributionPartner(id: string, patch: Partial<Pick<DistributionPartner, 'label' | 'active' | 'scopes'>>) {
  const { error } = await supabase.rpc('exos_update_distribution_partner', { p_id: id, p_patch: patch });
  if (error) throw error;
}

export async function revokeDistributionPartner(id: string) {
  const { error } = await supabase.rpc('exos_revoke_distribution_partner', { p_id: id });
  if (error) throw error;
}

export interface TierDistribution {
  tier_id: string;
  name: string;
  table: boolean;
  enabled: boolean;
  partner_ids: string[];
  paused: boolean;
}

/** The event's ticket types with their partner switch (off when no row). */
export async function fetchTierDistribution(eventId: string): Promise<TierDistribution[]> {
  const [tiers, rows] = await Promise.all([
    supabase.from('exos_ticket_tiers').select('id, name, kind, sort_order').eq('event_id', eventId).order('sort_order'),
    supabase.from('exos_tier_distribution').select('tier_id, enabled, partner_ids, paused').eq('event_id', eventId),
  ]);
  if (tiers.error) throw tiers.error;
  if (rows.error) throw rows.error;
  const by = new Map((rows.data ?? []).map((r: { tier_id: string; enabled: boolean; partner_ids: string[]; paused: boolean }) => [r.tier_id, r]));
  return (tiers.data ?? []).map((t: { id: string; name: string; kind?: string | null }) => {
    const r = by.get(t.id);
    return {
      tier_id: t.id, name: t.name, table: t.kind === 'table', enabled: r?.enabled ?? false,
      partner_ids: r?.partner_ids ?? [], paused: r?.paused ?? false,
    };
  });
}

export async function setTierDistribution(eventId: string, tiers: Pick<TierDistribution, 'tier_id' | 'enabled' | 'partner_ids' | 'paused'>[]) {
  const { data, error } = await supabase.rpc('exos_set_tier_distribution', { p_event_id: eventId, p_tiers: tiers });
  if (error) throw error;
  return data as TierDistribution[];
}

/** Anyone with the link: the live ticket and its current door code. */
export async function fetchTicketLink(ticketId: string, key: string): Promise<LinkView> {
  const { data, error } = await supabase.rpc('exos_ticket_link_view', { p_ticket_id: ticketId, p_key: key });
  if (error) throw error;
  return (data ?? { ok: false }) as LinkView;
}

// -- Personal access tokens -------------------------------------------------------

export interface PersonalToken {
  id: string;
  org_id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
  expires_at: string | null;
  last_used_at: string | null;
  revoked_at: string | null;
  created_at: string;
}

export async function listPersonalTokens(): Promise<PersonalToken[]> {
  const { data, error } = await supabase.from('exos_personal_tokens')
    .select('id, org_id, name, key_prefix, scopes, expires_at, last_used_at, revoked_at, created_at')
    .is('revoked_at', null).order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as PersonalToken[];
}

export async function createPersonalToken(orgId: string, name: string, scopes: string[], expiresDays: number | null) {
  const { data, error } = await supabase.rpc('exos_create_personal_token', {
    p_org_id: orgId, p_name: name, p_scopes: scopes, p_expires_days: expiresDays,
  });
  if (error) throw error;
  return data as { id: string; token: string; key_prefix: string; scopes: string[]; expires_at: string | null };
}

export async function revokePersonalToken(id: string) {
  const { error } = await supabase.rpc('exos_revoke_personal_token', { p_id: id });
  if (error) throw error;
}

// -- OAuth apps ---------------------------------------------------------------------

export interface OAuthApp {
  client_id: string;
  name: string;
  logo_url: string | null;
  homepage_url: string | null;
  redirect_uris: string[];
  scopes: string[];
  client_type: 'confidential' | 'public';
  secret_prefix: string | null;
  source: 'developer' | 'dcr';
  created_at: string;
}

export async function listMyApps(): Promise<OAuthApp[]> {
  const { data, error } = await supabase.from('exos_oauth_apps')
    .select('client_id, name, logo_url, homepage_url, redirect_uris, scopes, client_type, secret_prefix, source, created_at')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as OAuthApp[];
}

export async function createApp(input: {
  name: string; redirectUris: string[]; scopes: string[]; clientType: 'confidential' | 'public'; logoUrl?: string; homepageUrl?: string;
}) {
  const { data, error } = await supabase.rpc('exos_oauth_app_create', {
    p_name: input.name, p_redirect_uris: input.redirectUris, p_scopes: input.scopes, p_client_type: input.clientType,
    p_logo_url: input.logoUrl || null, p_homepage_url: input.homepageUrl || null,
  });
  if (error) throw error;
  return data as OAuthApp & { client_secret?: string };
}

export async function rotateAppSecret(clientId: string) {
  const { data, error } = await supabase.rpc('exos_oauth_app_rotate_secret', { p_client_id: clientId });
  if (error) throw error;
  return data as { client_secret: string };
}

export async function deleteApp(clientId: string) {
  const { error } = await supabase.rpc('exos_oauth_app_delete', { p_client_id: clientId });
  if (error) throw error;
}

export interface Grant {
  grant_id: string;
  org_id: string;
  org_name: string;
  user_id: string;
  user_email?: string;
  scopes: string[];
  created_at: string;
  last_used_at: string | null;
  app: { client_id: string; name: string; logo_url: string | null; homepage_url: string | null; verified: boolean };
}

export async function myConnectedApps(): Promise<Grant[]> {
  const { data, error } = await supabase.rpc('exos_oauth_my_grants');
  if (error) throw error;
  return (data ?? []) as Grant[];
}

export async function orgConnectedApps(orgId: string): Promise<Grant[]> {
  const { data, error } = await supabase.rpc('exos_oauth_org_grants', { p_org_id: orgId });
  if (error) throw error;
  return (data ?? []) as Grant[];
}

export async function disconnectApp(grantId: string) {
  const { error } = await supabase.rpc('exos_oauth_revoke_grant', { p_grant_id: grantId });
  if (error) throw error;
}

export interface AuthorizeInfo {
  ok: boolean;
  redirect_ok: boolean;
  error?: string;
  error_description?: string;
  app?: { client_id: string; name: string; logo_url: string | null; homepage_url: string | null; verified: boolean; scopes: string[] };
  redirect_host?: string;
  scopes?: string[];
  orgs?: { org_id: string; name: string; role: string; grantable: string[] }[];
}

export async function authorizeInfo(clientId: string, redirectUri: string, scope: string): Promise<AuthorizeInfo> {
  const { data, error } = await supabase.rpc('exos_oauth_authorize_info', {
    p_client_id: clientId, p_redirect_uri: redirectUri, p_scope: scope,
  });
  if (error) throw error;
  return data as AuthorizeInfo;
}

export async function authorizeApprove(input: {
  clientId: string; redirectUri: string; scope: string; orgId: string;
  codeChallenge: string | null; codeChallengeMethod: string | null; resource: string | null;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_oauth_authorize_approve', {
    p_client_id: input.clientId, p_redirect_uri: input.redirectUri, p_scope: input.scope, p_org_id: input.orgId,
    p_code_challenge: input.codeChallenge, p_code_challenge_method: input.codeChallengeMethod, p_resource: input.resource,
  });
  if (error) throw error;
  return (data as { code: string }).code;
}

/** "invalid_scope: the reason" -> the reason, for toasts. */
export function sqlMessage(e: unknown): string {
  const m = String((e as { message?: string })?.message ?? e ?? 'Something went wrong');
  return m.replace(/^[a-z_]+: /, '').slice(0, 200);
}
