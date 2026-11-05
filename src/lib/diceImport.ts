// Org settings → Integrations → Import from DICE (mig 20261106100000;
// docs/dice-coverage.md). The card reads the connection with the
// exos_dice_org_status RPC (owner / manager; never the token) and acts
// through the exos-dice-import edge function: connect (the MIO token,
// checked with DICE, stored in Vault), disconnect, sync (dry run first).
//
// Pure helpers (parse, summaries) are tested in src/lib/diceImport.test.ts.

import { supabase } from './supabase';
import { isMissingRpc } from './door/net';

export type DiceConnStatus = 'not_connected' | 'connected' | 'error' | 'disconnected';
export type DiceEntity = 'events' | 'tickets' | 'orders' | 'returns' | 'transfers';
export const DICE_ENTITIES: readonly DiceEntity[] = ['events', 'tickets', 'orders', 'returns', 'transfers'];

export interface DiceRun {
  id: string;
  kind: 'full' | 'incremental';
  trigger: 'dashboard' | 'api' | 'cron';
  dryRun: boolean;
  status: 'running' | 'ok' | 'partial' | 'error';
  startedAt: string;
  finishedAt: string | null;
  counts: Record<string, Record<string, number>>;
  error: string | null;
}

export interface DiceImported {
  events: number; eventsPast: number; ticketTypes: number; tickets: number; doorEntries: number;
  returns: number; orders: number; fans: number; fansMarketingConsent: number;
}

export interface DiceStatus {
  canManage: boolean;
  connected: boolean;
  status: DiceConnStatus;
  accountName: string | null;
  connectedAt: string | null;
  syncing: boolean;
  lastSyncAt: string | null;
  lastOkAt: string | null;
  lastError: string | null;
  fullSyncDoneAt: string | null;
  /** An entity's pass that a cap stopped part way (the next sync resumes it). */
  resuming: DiceEntity[];
  imported: DiceImported;
  runs: DiceRun[];
}

export interface DicePreview {
  eventsUpcoming: number; eventsPast: number; ticketTypes: number; tickets: number; fans: number;
  fansMarketingConsent: number; orders: number; returns: number; transfers: number;
}

export interface DiceSyncResult {
  dryRun: boolean;
  result: 'ok' | 'partial' | 'error' | null;
  kind: 'full' | 'incremental' | null;
  preview: DicePreview | null;
  /** DICE's totalCount per entity (everything there, not only what this run read). */
  totals: Partial<Record<DiceEntity, number>>;
  counts: Partial<Record<DiceEntity, Record<string, number>>>;
  error: string | null;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);
const n = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {});
const counts = (v: unknown): Record<string, number> =>
  Object.fromEntries(Object.entries(obj(v)).filter(([, x]) => typeof x === 'number' && Number.isFinite(x))) as Record<string, number>;
const STATUSES: readonly DiceConnStatus[] = ['not_connected', 'connected', 'error', 'disconnected'];

function parseRun(raw: unknown): DiceRun | null {
  const r = obj(raw);
  if (typeof r.id !== 'string') return null;
  const c = obj(r.counts);
  return {
    id: r.id,
    kind: r.kind === 'incremental' ? 'incremental' : 'full',
    trigger: r.trigger === 'api' || r.trigger === 'cron' ? r.trigger : 'dashboard',
    dryRun: r.dry_run === true,
    status: r.status === 'ok' || r.status === 'partial' || r.status === 'error' ? r.status : 'running',
    startedAt: str(r.started_at) ?? '',
    finishedAt: str(r.finished_at),
    counts: Object.fromEntries(Object.keys(c).map((k) => [k, counts(c[k])])),
    error: str(r.error),
  };
}

/** exos_dice_org_status's answer; null when it isn't usable. */
export function parseDiceStatus(raw: unknown): DiceStatus | null {
  const r = obj(raw);
  if (typeof r.connected !== 'boolean') return null;
  const im = obj(r.imported);
  const cur = obj(r.cursors);
  return {
    canManage: r.can_manage === true,
    connected: r.connected,
    status: STATUSES.includes(r.status as DiceConnStatus) ? r.status as DiceConnStatus : 'not_connected',
    accountName: str(r.account_name),
    connectedAt: str(r.connected_at),
    syncing: r.syncing === true,
    lastSyncAt: str(r.last_sync_at),
    lastOkAt: str(r.last_ok_at),
    lastError: str(r.last_error),
    fullSyncDoneAt: str(r.full_sync_done_at),
    resuming: DICE_ENTITIES.filter((e) => obj(cur[e]).resuming === true),
    imported: {
      events: n(im.events), eventsPast: n(im.events_past), ticketTypes: n(im.ticket_types), tickets: n(im.tickets),
      doorEntries: n(im.door_entries), returns: n(im.returns), orders: n(im.orders), fans: n(im.fans),
      fansMarketingConsent: n(im.fans_marketing_consent),
    },
    runs: (Array.isArray(r.runs) ? r.runs : []).map(parseRun).filter((x): x is DiceRun => !!x),
  };
}

/** exos-dice-import /sync's answer (a sync or a dry run). */
export function parseSyncResult(raw: unknown): DiceSyncResult {
  const r = obj(raw);
  const p = r.preview ? obj(r.preview) : null;
  const ents = obj(r.entities);
  return {
    dryRun: r.dry_run === true,
    result: r.result === 'ok' || r.result === 'partial' || r.result === 'error' ? r.result : null,
    kind: r.kind === 'full' || r.kind === 'incremental' ? r.kind : null,
    preview: p ? {
      eventsUpcoming: n(p.events_upcoming), eventsPast: n(p.events_past), ticketTypes: n(p.ticket_types), tickets: n(p.tickets),
      fans: n(p.fans), fansMarketingConsent: n(p.fans_marketing_consent), orders: n(p.orders), returns: n(p.returns),
      transfers: n(p.transfers),
    } : null,
    totals: Object.fromEntries(DICE_ENTITIES.flatMap((e) => {
      const t = obj(ents[e]).total;
      return typeof t === 'number' ? [[e, t]] : [];
    })),
    counts: Object.fromEntries(DICE_ENTITIES.map((e) => [e, counts(obj(ents[e]).counts)])),
    error: str(r.error),
  };
}

const plural = (k: number, one: string, many = `${one}s`) => `${k.toLocaleString()} ${k === 1 ? one : many}`;

/** The dry run, in one or two sentences. */
export function previewText(r: DiceSyncResult): string {
  if (!r.preview) return r.error ?? 'Nothing to preview.';
  const p = r.preview;
  const capped = r.result === 'partial' ? ' (a first look: the import reads everything)' : '';
  const total = (e: DiceEntity) => (r.totals[e] !== undefined ? ` of ${r.totals[e]!.toLocaleString()}` : '');
  return `Read ${plural(p.eventsUpcoming, 'upcoming event')} and ${plural(p.eventsPast, 'past event')}${total('events')}, `
    + `${plural(p.tickets, 'ticket')}${total('tickets')} and ${plural(p.orders, 'order')}${total('orders')}${capped}. `
    + `${plural(p.fans, 'fan')}, of whom ${p.fansMarketingConsent.toLocaleString()} opted in to partner marketing on DICE `
    + `and would join your email list; the rest come in as ticket holders without marketing consent.`;
}

/** The status line under the card. */
export function syncStatusText(s: DiceStatus, now: Date = new Date()): string {
  if (!s.connected) return s.status === 'disconnected' ? 'Disconnected. What was imported stays.' : 'Not connected.';
  if (s.status === 'error') return s.lastError ?? 'DICE refused the token. Connect again with a new token from MIO.';
  if (s.syncing) return 'Syncing from DICE now…';
  if (!s.lastSyncAt) return 'Connected. Run a preview, then import.';
  const ago = relative(s.lastSyncAt, now);
  const i = s.imported;
  const what = `${plural(i.events, 'event')} (drafts), ${plural(i.doorEntries, 'ticket holder')} on the door, ${plural(i.fans, 'fan')} `
    + `(${i.fansMarketingConsent.toLocaleString()} with marketing consent)`;
  if (s.lastError) return `Last sync ${ago} failed: ${s.lastError} Imported so far: ${what}.`;
  const more = s.resuming.length ? ' More to read: the next sync continues.' : !s.fullSyncDoneAt ? ' The first import is still going.' : '';
  return `Last synced ${ago}. Imported: ${what}.${more}`;
}

function relative(iso: string, now: Date): string {
  const s = Math.max(0, Math.round((now.getTime() - Date.parse(iso)) / 1000));
  if (!Number.isFinite(s)) return 'recently';
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86_400)} d ago`;
}

/** A pasted MIO token, trimmed; null when it can't be one (the server checks again). */
export function cleanDiceToken(v: string): string | null {
  const t = v.trim().replace(/^Bearer\s+/i, '');
  return t.length >= 16 && t.length <= 2048 && /^[A-Za-z0-9._~+/=-]+$/.test(t) ? t : null;
}

// ---- Calls ----------------------------------------------------------------------

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

function fnBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-dice-import` : '';
}

async function call<T>(path: string, body: unknown): Promise<T> {
  const base = fnBase();
  if (!base) throw new Error('Import from DICE is not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  let res: Response;
  try {
    res = await fetch(`${base}${path}`, {
      method: 'POST',
      headers: { ...(anon ? { apikey: anon } : {}), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(typeof out?.error === 'string' ? out.error : res.status === 404
      ? 'Import from DICE is not deployed yet.' : `Request failed (${res.status}).`);
  }
  return out as T;
}

/** null when the migration isn't deployed or this user can't manage the org's integrations. */
export async function fetchDiceStatus(orgId: string): Promise<DiceStatus | null> {
  const { data, error } = await supabase.rpc('exos_dice_org_status', { p_org_id: orgId });
  if (error) {
    if (isMissingRpc(error) || error.code === '42501') return null;
    throw error;
  }
  return parseDiceStatus(data);
}

export const connectDice = (orgId: string, token: string) =>
  call<{ connected: boolean; account_name: string | null }>('/connect', { org: orgId, token });

export const disconnectDice = (orgId: string) => call<{ connected: boolean }>('/disconnect', { org: orgId });

export async function syncDice(orgId: string, dryRun: boolean): Promise<DiceSyncResult> {
  return parseSyncResult(await call<unknown>('/sync', { org: orgId, dry_run: dryRun }));
}
