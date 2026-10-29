// Exos Door: the Eventbrite sync, client side (mig 20261013100000; the
// exos-eventbrite-sync edge function). Status is an RPC; connect, link and
// sync go through the edge function, which holds the token and only ever
// reads from Eventbrite.

import { supabase } from '../supabase';
import { isMissingRpc } from './net';
import { isEventbriteAuthorizeUrl } from '../eventbriteConnect';
import { parseInventoryStatus, type EbInventoryStatus, type EbTicketClassChoice } from './eventbriteInventoryModel';

export interface EventbriteLink {
  ebEventId: string;
  ebEventName: string | null;
  lastSyncedAt: string | null;
  lastOkAt: string | null;
  lastError: string | null;
  syncing: boolean;
  attendees: number;
  voided: number;
  /** Checked in on Eventbrite's own app (mig 20261014120000): the Exos door counts them as in. */
  checkedInOnEventbrite: number;
  /** Attendees the last pass couldn't add (e.g. a barcode another guest has); retried each pass. */
  rowErrors: number;
}

export type EventbriteAuthMethod = 'oauth' | 'private_token';

export interface EventbriteStatus {
  canManage: boolean;
  connected: boolean;
  accountName: string | null;
  /** How the org's account was connected (mig 20261029140000); null on older installs. */
  authMethod: EventbriteAuthMethod | null;
  link: EventbriteLink | null;
}

const authMethodOf = (v: unknown): EventbriteAuthMethod | null =>
  v === 'oauth' || v === 'private_token' ? v : null;

export interface EventbriteEventChoice { id: string; name: string; start: string | null; status: string | null }

export interface SyncSummary {
  state?: 'done' | 'more' | 'error';
  rows?: number;
  added?: number;
  voided?: number;
  restored?: number;
  error?: string;
  skipped?: 'recent' | 'not_linked';
}

export function parseEventbriteStatus(raw: any): EventbriteStatus {
  const l = raw?.link;
  return {
    canManage: raw?.can_manage === true,
    connected: raw?.connected === true,
    accountName: typeof raw?.account_name === 'string' ? raw.account_name : null,
    authMethod: authMethodOf(raw?.auth_method),
    link: l && typeof l === 'object' && typeof l.eb_event_id === 'string'
      ? {
        ebEventId: l.eb_event_id,
        ebEventName: l.eb_event_name ?? null,
        lastSyncedAt: l.last_synced_at ?? null,
        lastOkAt: l.last_ok_at ?? null,
        lastError: l.last_error ?? null,
        syncing: l.syncing === true,
        attendees: Number(l.attendees) || 0,
        voided: Number(l.voided) || 0,
        checkedInOnEventbrite: Number(l.checked_in_on_eventbrite) || 0,
        rowErrors: Number(l.row_errors) || 0,
      }
      : null,
  };
}

/** One line for the result of a sync. */
export function syncSummaryText(s: SyncSummary | null | undefined): string {
  if (!s) return 'Sync failed. Try again in a minute.';
  if (s.skipped === 'recent') return 'Synced a moment ago.';
  if (s.skipped === 'not_linked') return 'Not linked to an Eventbrite event.';
  if (s.state === 'error') return s.error ?? 'Sync failed.';
  const parts: string[] = [];
  if (s.added) parts.push(`${s.added} new`);
  if (s.voided) parts.push(`${s.voided} refunded or cancelled`);
  if (s.restored) parts.push(`${s.restored} back`);
  const head = parts.length ? parts.join(', ') : 'No changes';
  return s.state === 'more' ? `${head} so far; the rest follows in a couple of minutes.` : `${head}. Up to date.`;
}

/** null when the migration isn't deployed. */
export async function fetchEventbriteStatus(eventId: string): Promise<EventbriteStatus | null> {
  const { data, error } = await supabase.rpc('exos_eventbrite_status', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseEventbriteStatus(data);
}

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

function fnBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-eventbrite-sync` : '';
}

async function call<T>(path: string, init: { method: 'GET' | 'POST'; body?: unknown }): Promise<T> {
  const base = fnBase();
  if (!base) throw new Error('Eventbrite sync is not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  let res: Response;
  try {
    res = await fetch(`${base}${path}`, {
      method: init.method,
      headers: {
        ...(anon ? { apikey: anon } : {}),
        Authorization: `Bearer ${jwt}`,
        ...(init.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(typeof body?.error === 'string' ? body.error : res.status === 404
      ? 'Eventbrite sync is not deployed yet.' : `Request failed (${res.status}).`);
  }
  return body as T;
}

export const connectEventbrite = (orgId: string, token: string) =>
  call<{ connected: boolean; account_name: string | null }>('/connect', { method: 'POST', body: { org: orgId, token } });

export const disconnectEventbrite = (orgId: string) =>
  call<{ connected: boolean }>('/disconnect', { method: 'POST', body: { org: orgId } });

export async function listEventbriteEvents(orgId: string): Promise<EventbriteEventChoice[]> {
  const r = await call<{ events?: EventbriteEventChoice[] }>(`/events?org=${encodeURIComponent(orgId)}`, { method: 'GET' });
  return Array.isArray(r.events) ? r.events : [];
}

export const linkEventbrite = (eventId: string, ebEventId: string) =>
  call<{ linked: boolean; sync: SyncSummary | null }>('/link', { method: 'POST', body: { event: eventId, eb_event: ebEventId } });

export const unlinkEventbrite = (eventId: string) =>
  call<{ linked: boolean }>('/unlink', { method: 'POST', body: { event: eventId } });

export const syncEventbrite = (eventId: string) =>
  call<{ sync: SyncSummary | null }>('/sync', { method: 'POST', body: { event: eventId } });

// ---- Inventory: one shared count (mig 20261014110000) ----------------------

export { mappingLine, parseInventoryStatus, unshareable } from './eventbriteInventoryModel';
export type { EbInventoryStatus, EbMapping, EbTicketClassChoice } from './eventbriteInventoryModel';

/** null when the migration isn't deployed. */
export async function fetchInventoryStatus(eventId: string): Promise<EbInventoryStatus | null> {
  const { data, error } = await supabase.rpc('exos_eventbrite_inventory_status', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseInventoryStatus(data);
}

export async function listEbTicketClasses(eventId: string): Promise<EbTicketClassChoice[]> {
  const r = await call<{ ticket_classes?: EbTicketClassChoice[] }>(`/ticket-classes?event=${encodeURIComponent(eventId)}`, { method: 'GET' });
  return Array.isArray(r.ticket_classes) ? r.ticket_classes : [];
}

export const mapEbTicketClass = (eventId: string, ticketClassId: string, ticketClassName: string | null, tierId: string | null) =>
  call<{ mapped: boolean }>('/map', {
    method: 'POST', body: { event: eventId, ticket_class_id: ticketClassId, ticket_class_name: ticketClassName, tier: tierId },
  });

export const setEbWrites = (orgId: string, on: boolean) =>
  call<{ writes_enabled: boolean; live: boolean }>('/writes', { method: 'POST', body: { org: orgId, on } });

// ---- Connect Eventbrite (OAuth; exos-eventbrite-oauth, mig 20261029140000) ----

export interface EventbriteHistoryRow {
  action: 'connect' | 'disconnect';
  authMethod: EventbriteAuthMethod | null;
  accountName: string | null;
  at: string;
  byYou: boolean;
}

export interface EventbriteOrgStatus {
  canManage: boolean;
  connected: boolean;
  accountName: string | null;
  authMethod: EventbriteAuthMethod | null;
  connectedAt: string | null;
  linkedEvents: number;
  history: EventbriteHistoryRow[];
}

export function parseEventbriteOrgStatus(raw: any): EventbriteOrgStatus {
  const hist: any[] = Array.isArray(raw?.history) ? raw.history : [];
  return {
    canManage: raw?.can_manage === true,
    connected: raw?.connected === true,
    accountName: typeof raw?.account_name === 'string' ? raw.account_name : null,
    authMethod: authMethodOf(raw?.auth_method),
    connectedAt: typeof raw?.connected_at === 'string' ? raw.connected_at : null,
    linkedEvents: Number(raw?.linked_events) || 0,
    history: hist
      .filter((h) => (h?.action === 'connect' || h?.action === 'disconnect') && typeof h?.at === 'string')
      .map((h) => ({
        action: h.action,
        authMethod: authMethodOf(h.auth_method),
        accountName: typeof h.account_name === 'string' ? h.account_name : null,
        at: h.at,
        byYou: h.by_you === true,
      })),
  };
}

/** The org's Eventbrite connection (Integrations). null when the migration isn't deployed. */
export async function fetchEventbriteOrgStatus(orgId: string): Promise<EventbriteOrgStatus | null> {
  const { data, error } = await supabase.rpc('exos_eventbrite_org_status', { p_org_id: orgId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseEventbriteOrgStatus(data);
}

function oauthBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-eventbrite-oauth` : '';
}

/** An error carrying the server's reason code (eventbriteErrorMessage). */
function oauthError(status: number, body: any): Error {
  const reason = status === 503 ? 'not_configured' : status === 403 ? 'forbidden' : status === 401 ? 'auth'
    : status === 429 ? 'rate' : typeof body?.reason === 'string' ? body.reason : 'unknown';
  return Object.assign(new Error(typeof body?.error === 'string' ? body.error : `http ${status}`), { reason });
}

let oauthConfig: Promise<boolean> | null = null;

/** Whether this server connects Eventbrite by OAuth (otherwise: the private-token form). Cached per page load. */
export function eventbriteOAuthAvailable(): Promise<boolean> {
  const base = oauthBase();
  if (!base) return Promise.resolve(false);
  oauthConfig ??= fetch(`${base}/config`)
    .then(async (res) => res.ok && (await res.json().catch(() => null))?.oauth === true)
    .catch(() => false);
  return oauthConfig;
}

async function oauthHeaders(): Promise<Record<string, string>> {
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw Object.assign(new Error('Sign in first.'), { reason: 'auth' });
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  return { ...(anon ? { apikey: anon } : {}), Authorization: `Bearer ${jwt}` };
}

/** Eventbrite's authorize URL for this org (owner / manager). eventId: the door page to come back to. */
export async function startEventbriteConnect(orgId: string, eventId?: string | null): Promise<string> {
  const base = oauthBase();
  if (!base) throw Object.assign(new Error('not configured'), { reason: 'not_configured' });
  const q = new URLSearchParams({ org: orgId });
  if (eventId) q.set('event', eventId);
  const res = await fetch(`${base}/start?${q.toString()}`, { headers: await oauthHeaders() });
  const body = await res.json().catch(() => null);
  if (!res.ok || !isEventbriteAuthorizeUrl(body?.url)) throw oauthError(res.status, body);
  return body.url;
}

/** Finish after Eventbrite sent the browser back (?eventbrite=finish). */
export async function finishEventbriteConnect(state: string): Promise<{ accountName: string | null; eventId: string | null }> {
  const base = oauthBase();
  if (!base) throw Object.assign(new Error('not configured'), { reason: 'not_configured' });
  const res = await fetch(`${base}/finish`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(await oauthHeaders()) },
    body: JSON.stringify({ state }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || body?.connected !== true) throw oauthError(res.status, body);
  return {
    accountName: typeof body.account_name === 'string' ? body.account_name : null,
    eventId: typeof body.event_id === 'string' ? body.event_id : null,
  };
}
