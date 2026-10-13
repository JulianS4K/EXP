// Exos Door: the Eventbrite sync, client side (mig 20261013100000; the
// exos-eventbrite-sync edge function). Status is an RPC; connect, link and
// sync go through the edge function, which holds the token and only ever
// reads from Eventbrite.

import { supabase } from '../supabase';
import { isMissingRpc } from './net';

export interface EventbriteLink {
  ebEventId: string;
  ebEventName: string | null;
  lastSyncedAt: string | null;
  lastOkAt: string | null;
  lastError: string | null;
  syncing: boolean;
  attendees: number;
  voided: number;
  /** Attendees the last pass couldn't add (e.g. a barcode another guest has); retried each pass. */
  rowErrors: number;
}

export interface EventbriteStatus {
  canManage: boolean;
  connected: boolean;
  accountName: string | null;
  link: EventbriteLink | null;
}

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
