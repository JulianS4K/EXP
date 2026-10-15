// Bring your own credentials (mig 20261016090000) and ticket backends (mig
// 20261016100000). The provider catalog and its field rules are pure; the
// RPC / edge calls are at the bottom. Secrets go in once and are never read
// back (Vault, service role only).

import { supabase } from './supabase';

export type ProviderId =
  | 'pretix' | 'hievents' | 'twilio' | 'telnyx'
  | 'stubhub' | 'seatgeek' | 'vivid' | 'tickpick' | 'gametime' | 'tevo';

export type ProviderGroup = 'backend' | 'sms' | 'marketplace';

export interface ProviderField {
  key: string;
  label: string;
  placeholder?: string;
  help?: string;
  /** Pre-filled for hosted services; overwrite for self-hosted. */
  defaultValue?: string;
  required?: boolean;
  kind?: 'url' | 'slug' | 'phone' | 'text';
}

export interface ProviderInfo {
  id: ProviderId;
  label: string;
  group: ProviderGroup;
  blurb: string;
  fields: ProviderField[];
  /** null: no secret (e.g. hi.events reads a check-in list's public feed). */
  secretLabel: string | null;
  secretHelp?: string;
  docsUrl?: string;
}

export const PROVIDERS: ProviderInfo[] = [
  {
    id: 'pretix', label: 'pretix', group: 'backend',
    blurb: 'Sell on your pretix shop (pretix.eu or your own server). Exos reads orders for the door; nothing is written back.',
    fields: [
      { key: 'base_url', label: 'pretix address', defaultValue: 'https://pretix.eu', kind: 'url', required: true,
        help: 'Your own server if you self-host, e.g. https://tickets.example.com' },
      { key: 'organizer', label: 'Organizer short name', placeholder: 'myclub', kind: 'slug', required: true,
        help: 'The part after the address in your shop links: pretix.eu/<organizer>/<event>/' },
    ],
    secretLabel: 'API token',
    secretHelp: 'Organizer settings → Teams → your team → API tokens. Give the team "Can view orders" only.',
    docsUrl: 'https://docs.pretix.eu/en/latest/api/tokenauth.html',
  },
  {
    id: 'hievents', label: 'hi.events', group: 'backend',
    blurb: 'Sell on hi.events (hosted or self-hosted). Exos reads a check-in list for the door; no password is stored.',
    fields: [
      { key: 'base_url', label: 'hi.events address', placeholder: 'https://tickets.example.com', kind: 'url', required: true,
        help: 'The address your hi.events backend answers on (its /api path). For the hosted service, the address your check-in links use.' },
    ],
    secretLabel: null,
    docsUrl: 'https://hi.events/docs',
  },
  {
    id: 'twilio', label: 'Twilio', group: 'sms',
    blurb: 'Send SMS from your own Twilio number. You own the sender and its registration (10DLC / toll-free).',
    fields: [
      { key: 'account_sid', label: 'Account SID', placeholder: 'AC…', kind: 'text', required: true },
      { key: 'from', label: 'Sending number or Messaging Service SID', placeholder: '+12125550100 or MG…', kind: 'text', required: true },
    ],
    secretLabel: 'Auth token',
    secretHelp: 'Twilio Console → Account info. For STOP replies, set the number\'s incoming-message webhook to …/functions/v1/exos-sms-drain/inbound/twilio?org=<your org id>.',
    docsUrl: 'https://www.twilio.com/docs/usage/api',
  },
  {
    id: 'telnyx', label: 'Telnyx', group: 'sms',
    blurb: 'Send SMS from your own Telnyx number.',
    fields: [
      { key: 'from', label: 'Sending number', placeholder: '+12125550100', kind: 'phone', required: true },
      { key: 'messaging_profile_id', label: 'Messaging profile id (optional)', kind: 'text' },
      { key: 'webhook_public', label: 'Webhook public key (for STOP replies)', kind: 'text',
        help: 'Telnyx portal → Keys & credentials → Public key. Inbound webhook: …/functions/v1/exos-sms-drain/inbound/telnyx?org=<your org id>' },
    ],
    secretLabel: 'API key',
    docsUrl: 'https://developers.telnyx.com/docs/messaging',
  },
  ...(['stubhub', 'seatgeek', 'vivid', 'tickpick', 'gametime', 'tevo'] as const).map((id): ProviderInfo => ({
    id, group: 'marketplace',
    label: { stubhub: 'StubHub', seatgeek: 'SeatGeek', vivid: 'Vivid Seats', tickpick: 'TickPick', gametime: 'Gametime', tevo: 'Ticket Evolution' }[id],
    blurb: 'Your own seller / API account, for reading listings and sales. Exos never changes prices or inventory there.',
    fields: [{ key: 'account_id', label: 'Account or client id', kind: 'text' }],
    secretLabel: 'API key or token',
  })),
];

export const providerInfo = (id: string): ProviderInfo | undefined => PROVIDERS.find((p) => p.id === id);

/** Why a settings form can't be saved, or null. Mirrors the SQL rules. */
export function configError(p: ProviderInfo, config: Record<string, string>, secret: string, hasSecret: boolean): string | null {
  for (const f of p.fields) {
    const v = (config[f.key] ?? '').trim();
    if (f.required && !v) return `${f.label} is needed.`;
    if (!v) continue;
    if (f.kind === 'url') {
      try {
        const u = new URL(v);
        if (u.protocol !== 'https:') return `${f.label} must start with https://`;
      } catch {
        return `${f.label} isn't a web address.`;
      }
    }
    if (f.kind === 'slug' && !/^[A-Za-z0-9._-]{1,64}$/.test(v)) return `${f.label}: letters, numbers, dots, dashes.`;
    if (f.kind === 'phone' && !/^\+[1-9][0-9]{6,14}$/.test(v)) return `${f.label}: international format, e.g. +12125550100.`;
    if (v.length > 300) return `${f.label} is too long.`;
  }
  if (p.id === 'twilio' && config.account_sid && !/^(AC|SK)[0-9a-fA-F]{32}$/.test(config.account_sid.trim())) {
    return 'The Account SID starts with AC and has 34 characters.';
  }
  if (p.secretLabel && !secret.trim() && !hasSecret) return `Paste the ${p.secretLabel.toLowerCase()}.`;
  return null;
}

/** Only the provider's own fields, trimmed, empty ones dropped. */
export function cleanConfig(p: ProviderInfo, config: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of p.fields) {
    const v = (config[f.key] ?? '').trim().replace(f.kind === 'url' ? /\/+$/ : /$^/, '');
    if (v) out[f.key] = v;
  }
  return out;
}

export interface IntegrationRow {
  provider: ProviderId;
  label: string | null;
  config: Record<string, string>;
  secretHint: string | null;
  hasSecret: boolean;
  status: 'unverified' | 'connected' | 'error' | 'disabled';
  accountName: string | null;
  lastCheckedAt: Date | null;
  lastError: string | null;
}

export function parseIntegration(r: any): IntegrationRow {
  return {
    provider: r.provider,
    label: r.label ?? null,
    config: r.config && typeof r.config === 'object' ? Object.fromEntries(Object.entries(r.config).map(([k, v]) => [k, String(v)])) : {},
    secretHint: r.secret_hint ?? null,
    hasSecret: r.has_secret === true,
    status: ['connected', 'error', 'disabled'].includes(r.status) ? r.status : 'unverified',
    accountName: r.account_name ?? null,
    lastCheckedAt: r.last_checked_at ? new Date(r.last_checked_at) : null,
    lastError: r.last_error ?? null,
  };
}

// ── Ticket backends ─────────────────────────────────────────────────────

export type TicketBackend = 'exos' | 'eventbrite' | 'pretix' | 'hievents';

export const BACKEND_LABEL: Record<TicketBackend, string> = {
  exos: 'Exos', eventbrite: 'Eventbrite', pretix: 'pretix', hievents: 'hi.events',
};

export const parseBackend = (v: unknown): TicketBackend =>
  v === 'eventbrite' || v === 'pretix' || v === 'hievents' ? v : 'exos';

/** The pretix event short name or hi.events check-in list id from a pasted link (or the id itself). */
export function refFromLink(provider: 'pretix' | 'hievents', input: string): string | null {
  const s = input.trim();
  if (/^[A-Za-z0-9._-]{1,64}$/.test(s)) return s;
  try {
    const parts = new URL(s).pathname.split('/').filter(Boolean);
    if (provider === 'pretix') return parts.length >= 2 && /^[A-Za-z0-9._-]{1,64}$/.test(parts[1]) ? parts[1] : null;
    const i = parts.findIndex((p) => p === 'check-in' || p === 'check-in-lists');
    const id = i >= 0 ? parts[i + 1] : parts[parts.length - 1];
    return id && /^[A-Za-z0-9._-]{1,64}$/.test(id) ? id : null;
  } catch {
    return null;
  }
}

export interface BackendStatus {
  ticketBackend: TicketBackend;
  externalTicketUrl: string | null;
  canManage: boolean;
  connected: string[];
  link: null | {
    provider: 'pretix' | 'hievents';
    externalName: string | null;
    syncedCount: number;
    rowErrors: number;
    lastOkAt: Date | null;
    lastError: string | null;
  };
}

export function parseBackendStatus(d: any): BackendStatus {
  const l = d?.link;
  return {
    ticketBackend: parseBackend(d?.ticket_backend),
    externalTicketUrl: d?.external_ticket_url ?? null,
    canManage: d?.can_manage === true,
    connected: Array.isArray(d?.connected) ? d.connected : [],
    link: l ? {
      provider: l.provider === 'hievents' ? 'hievents' : 'pretix',
      externalName: l.external_name ?? null,
      syncedCount: Number(l.synced_count) || 0,
      rowErrors: Number(l.row_errors) || 0,
      lastOkAt: l.last_ok_at ? new Date(l.last_ok_at) : null,
      lastError: l.last_error ?? null,
    } : null,
  };
}

// ── Calls ───────────────────────────────────────────────────────────────

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

export async function callFn<T>(path: string, body: unknown): Promise<T> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Integrations are not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  let res: Response;
  try {
    res = await fetch(`${url}/functions/v1/exos-integrations${path}`, {
      method: 'POST',
      headers: { ...(env.VITE_SUPABASE_ANON_KEY ? { apikey: env.VITE_SUPABASE_ANON_KEY } : {}), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(typeof out?.error === 'string' ? out.error : res.status === 404 ? 'Integrations are not deployed yet.' : `Request failed (${res.status}).`);
  }
  return out as T;
}

const rpcMsg = (e: { message?: string }) => new Error((e.message ?? 'Not saved.').replace(/^exos_\w+: /, ''));

export async function listIntegrations(orgId: string): Promise<IntegrationRow[]> {
  const { data, error } = await supabase.rpc('exos_list_integrations', { p_org_id: orgId });
  if (error) throw rpcMsg(error);
  return (Array.isArray(data) ? data : []).map(parseIntegration);
}

export async function saveIntegration(orgId: string, provider: ProviderId, config: Record<string, string>, secret: string): Promise<void> {
  const { error } = await supabase.rpc('exos_save_integration', {
    p_org_id: orgId, p_provider: provider, p_config: config, p_secret: secret.trim() || null, p_label: null,
  });
  if (error) throw rpcMsg(error);
}

export async function removeIntegration(orgId: string, provider: ProviderId): Promise<void> {
  const { error } = await supabase.rpc('exos_remove_integration', { p_org_id: orgId, p_provider: provider });
  if (error) throw rpcMsg(error);
}

export const testIntegration = (orgId: string, provider: ProviderId) =>
  callFn<{ ok: boolean | null; account_name: string | null; error: string | null }>('/test', { org: orgId, provider });

export async function fetchBackendStatus(eventId: string): Promise<BackendStatus> {
  const { data, error } = await supabase.rpc('exos_backend_status', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
  return parseBackendStatus(data);
}

export async function setTicketBackend(eventId: string, backend: TicketBackend, url: string | null): Promise<void> {
  const { error } = await supabase.rpc('exos_set_ticket_backend', { p_event_id: eventId, p_backend: backend, p_url: url?.trim() || null });
  if (error) throw rpcMsg(error);
}

export const linkBackend = (eventId: string, provider: 'pretix' | 'hievents', ref: string) =>
  callFn<{ linked: boolean; sync: { ok: boolean; added?: number; error?: string } }>('/link', { event: eventId, provider, ref });

export const syncBackend = (eventId: string) =>
  callFn<{ sync: { ok: boolean; added?: number; error?: string; skipped?: string } }>('/sync', { event: eventId });

export async function unlinkBackend(eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_backend_unlink', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
}
