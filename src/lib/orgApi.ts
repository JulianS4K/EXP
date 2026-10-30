// Org developer surface — API keys + outbound webhooks (Hi.Events parity).
//
// API keys are managed only through SECDEF RPCs (the plaintext is returned once
// at creation and never again — only a hash is stored). Webhooks are managed
// directly via staff RLS on exos_webhooks.

import { supabase } from './supabase';
import { LEGACY_READ, READ_SCOPES, type Scope } from '../../supabase/functions/_shared/api/scopes.ts';

export interface ApiKey {
  id: string;
  name: string | null;
  keyPrefix: string;
  scopes: string[];
  lastUsedAt: string | null;
  revokedAt: string | null;
  createdAt: string;
}

export interface Webhook {
  id: string;
  orgId: string;
  url: string;
  secret: string;
  eventTypes: string[];
  enabled: boolean;
  description: string | null;
  createdAt: string;
}

export const WEBHOOK_EVENT_TYPES = [
  'ticket.created',
  'ticket.checked_in',
  'order.fulfilled',
  'order.refunded',
  'event.published',
  'hold.created',
  'hold.updated',
  'hold.converted',
] as const;

/** At most this many active (unrevoked) keys per org (mig 20261027090000). */
export const MAX_ACTIVE_API_KEYS = 10;

/** Scopes a new key starts with in the picker: every `:read` scope. */
export const DEFAULT_KEY_SCOPES: readonly Scope[] = READ_SCOPES;

/**
 * Create an API key held to `scopes` (_shared/api/scopes.ts); returns the
 * plaintext ONCE (store it now — irrecoverable). At most
 * MAX_ACTIVE_API_KEYS active keys per org: over it the RPC raises 54000,
 * surfaced as an ApiKeyLimitError.
 */
export async function createApiKey(orgId: string, name: string | undefined, scopes: readonly string[]): Promise<string> {
  const { data, error } = await supabase.rpc('exos_create_api_key', {
    p_org_id: orgId, p_name: name ?? null, p_scopes: [...scopes],
  });
  if (error) throw apiKeyError(error);
  return data as string;
}

/** Narrow or widen a live key's scopes (owner / manager). Returns the stored, normalized list. */
export async function setApiKeyScopes(keyId: string, scopes: readonly string[]): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_set_api_key_scopes', { p_key_id: keyId, p_scopes: [...scopes] });
  if (error) throw apiKeyError(error);
  return (data ?? []) as string[];
}

export class ApiKeyLimitError extends Error {}

/** The RPCs' errors without their function-name prefix; the key cap as ApiKeyLimitError. */
function apiKeyError(error: { code?: string; message?: string }): Error {
  const msg = String(error.message ?? 'Request failed').replace(/^exos_[a-z_]+:\s*/, '');
  if (error.code === '54000') {
    return new ApiKeyLimitError(
      `Your organization already has ${MAX_ACTIVE_API_KEYS} active API keys, the most it can have. Revoke one before creating another.`,
    );
  }
  return new Error(msg.charAt(0).toUpperCase() + msg.slice(1));
}

/** True for a key made before scopes existed: `read` = every `:read` scope. */
export function isLegacyReadKey(scopes: readonly string[]): boolean {
  return scopes.includes(LEGACY_READ);
}

export async function revokeApiKey(keyId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_revoke_api_key', { p_key_id: keyId });
  if (error) throw error;
  return data === true;
}

export async function listApiKeys(orgId: string): Promise<ApiKey[]> {
  const { data, error } = await supabase.rpc('exos_list_api_keys', { p_org_id: orgId });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, name: r.name, keyPrefix: r.key_prefix, scopes: r.scopes ?? [],
    lastUsedAt: r.last_used_at, revokedAt: r.revoked_at, createdAt: r.created_at,
  }));
}

function mapWebhook(r: any): Webhook {
  return {
    id: r.id, orgId: r.org_id, url: r.url, secret: r.secret,
    eventTypes: r.event_types ?? ['*'], enabled: r.enabled,
    description: r.description ?? null, createdAt: r.created_at,
  };
}

export async function listWebhooks(orgId: string): Promise<Webhook[]> {
  const { data, error } = await supabase
    .from('exos_webhooks').select('*').eq('org_id', orgId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapWebhook);
}

export async function createWebhook(orgId: string, url: string, eventTypes: string[]): Promise<Webhook> {
  const { data, error } = await supabase
    .from('exos_webhooks')
    .insert({ org_id: orgId, url: url.trim(), event_types: eventTypes.length ? eventTypes : ['*'] })
    .select('*').single();
  if (error) throw error;
  return mapWebhook(data);
}

export async function setWebhookEnabled(id: string, enabled: boolean): Promise<void> {
  const { error } = await supabase.from('exos_webhooks').update({ enabled }).eq('id', id);
  if (error) throw error;
}

export async function deleteWebhook(id: string): Promise<void> {
  const { error } = await supabase.from('exos_webhooks').delete().eq('id', id);
  if (error) throw error;
}
