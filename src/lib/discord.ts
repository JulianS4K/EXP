// Discord promotion (mig 20261113130000; docs/discord.md): an organizer's own
// Discord server. Level 1: a channel webhook for announcements. Level 2: the
// platform's bot keeps a Discord scheduled event per event shown there. The
// whole feature is dark until the operator sets EXOS_DISCORD_ENABLED=on on
// the exos-discord function (its /config says so); nothing is sent to
// Discord unless the org's writes switch AND EXOS_DISCORD_WRITES=on.
//
// Pure helpers first (vitest), then the RPC / edge calls.

import { supabase } from './supabase';

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

/**
 * A channel webhook URL as Discord shows it ("Copy Webhook URL"). The same
 * rule as the SQL (exos_discord_webhook_parts), which decides; this only
 * lets the form say what's wrong before saving.
 */
export const WEBHOOK_URL_RE =
  /^https:\/\/(?:discord\.com|discordapp\.com)\/api(?:\/v[0-9]{1,2})?\/webhooks\/([0-9]{17,20})\/([A-Za-z0-9_-]{60,100})\/?$/;

export function webhookUrlOk(raw: string): boolean {
  const s = (raw ?? '').trim();
  return s.length <= 300 && WEBHOOK_URL_RE.test(s);
}

/** The only place "Add Exos bot" may send the browser. */
export function isDiscordAuthorizeUrl(u: unknown): u is string {
  if (typeof u !== 'string') return false;
  try {
    const x = new URL(u);
    return x.protocol === 'https:' && x.host === 'discord.com' && x.pathname === '/oauth2/authorize' && x.searchParams.get('scope') === 'bot';
  } catch {
    return false;
  }
}

export type PostKind = 'publish' | 'reminder';
export interface DiscordConfig { enabled: boolean; bot: boolean; writes: boolean }
export interface DiscordStatus {
  canManage: boolean;
  isOwner: boolean;
  webhook: { set: boolean; hint: string | null; setAt: string | null; broken: boolean };
  guild: { linked: boolean; name: string | null; broken: boolean };
  /** The platform's circuit breaker stopped Discord calls (an operator clears it). */
  paused: boolean;
  writesEnabled: boolean;
  autoPost: boolean;
  shownEvents: number;
}
export interface DiscordPost { kind: PostKind; status: string; sentAt: string | null; lastError: string | null }
export interface DiscordEventStatus {
  canManage: boolean;
  eventStatus: string;
  hasWebhook: boolean;
  guildLinked: boolean;
  guildName: string | null;
  guildBroken: boolean;
  webhookBroken: boolean;
  writesEnabled: boolean;
  show: boolean;
  sync: { status: string; onDiscord: boolean; pending: boolean; lastError: string | null } | null;
  posts: DiscordPost[];
}

const bool = (v: unknown) => v === true;
const strOrNull = (v: unknown) => (typeof v === 'string' && v ? v : null);

export function parseDiscordStatus(d: any): DiscordStatus {
  return {
    canManage: bool(d?.can_manage),
    isOwner: bool(d?.is_owner),
    webhook: { set: bool(d?.webhook?.set), hint: strOrNull(d?.webhook?.hint), setAt: strOrNull(d?.webhook?.set_at), broken: bool(d?.webhook?.broken) },
    guild: { linked: bool(d?.guild?.linked), name: strOrNull(d?.guild?.name), broken: bool(d?.guild?.broken) },
    paused: bool(d?.paused),
    writesEnabled: bool(d?.writes_enabled),
    autoPost: bool(d?.auto_post),
    shownEvents: Number(d?.shown_events) || 0,
  };
}

export function parseDiscordEventStatus(d: any): DiscordEventStatus {
  const s = d?.sync;
  return {
    canManage: bool(d?.can_manage),
    eventStatus: String(d?.event_status ?? 'draft'),
    hasWebhook: bool(d?.has_webhook),
    guildLinked: bool(d?.guild_linked),
    guildName: strOrNull(d?.guild_name),
    guildBroken: bool(d?.guild_broken),
    webhookBroken: bool(d?.webhook_broken),
    writesEnabled: bool(d?.writes_enabled),
    show: bool(d?.show),
    sync: s && typeof s === 'object'
      ? { status: String(s.status ?? 'pending'), onDiscord: bool(s.on_discord), pending: bool(s.pending), lastError: strOrNull(s.last_error) }
      : null,
    posts: (Array.isArray(d?.posts) ? d.posts : []).filter((p: any) => p?.kind === 'publish' || p?.kind === 'reminder')
      .map((p: any) => ({ kind: p.kind, status: String(p.status ?? ''), sentAt: strOrNull(p.sent_at), lastError: strOrNull(p.last_error) })),
  };
}

/** One line for a post's state, for the event panel. */
export function postLine(p: DiscordPost | undefined): string {
  if (!p) return 'Not posted yet.';
  switch (p.status) {
    case 'sent': return 'Posted.';
    case 'queued': case 'sending': return 'Posting…';
    case 'dry_run': return 'Dry run: Exos recorded the post but didn’t send it (Discord writes are off).';
    case 'error': return `Not posted: ${p.lastError ?? 'Discord refused it'}.`;
    default: return '';
  }
}

/** One line for the scheduled event's state. */
export function syncLine(s: DiscordEventStatus): string {
  if (!s.guildLinked) return 'Add the Exos bot to your Discord server in Org settings first.';
  if (s.guildBroken) return 'The Exos bot lost access to your server. Reconnect the bot in Org settings → Discord.';
  if (!s.show) return 'Not on Discord.';
  if (!s.sync || s.sync.pending) return 'Updating Discord…';
  if (s.sync.status === 'dry_run') return 'Dry run: Exos recorded the Discord event but didn’t create it (Discord writes are off).';
  if (s.sync.status === 'error') return `Discord: ${s.sync.lastError ?? 'the last update failed'}; Exos tries again.`;
  if (s.sync.onDiscord) return `On ${s.guildName ?? 'your server'}'s events list.`;
  return s.eventStatus === 'published' ? 'Waiting to go up.' : 'It goes up when the event is published.';
}

/** An RPC error's own words, without the function name. */
export function rpcMessage(e: { message?: string } | null | undefined, fallback = 'Something went wrong.'): string {
  const m = String(e?.message ?? '').replace(/^exos_discord_[a-z_]+: /, '').trim();
  return m || fallback;
}

// ---- calls -----------------------------------------------------------------------

function fnBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-discord` : '';
}

let configP: Promise<DiscordConfig> | null = null;
const OFF: DiscordConfig = { enabled: false, bot: false, writes: false };

/** What this Exos server turned on (cached per page load). Off on any failure. */
export function fetchDiscordConfig(): Promise<DiscordConfig> {
  const base = fnBase();
  if (!base) return Promise.resolve(OFF);
  configP ??= fetch(`${base}/config`)
    .then(async (res) => {
      const b = res.ok ? await res.json().catch(() => null) : null;
      return b?.enabled === true ? { enabled: true, bot: b.bot === true, writes: b.writes === true } : OFF;
    })
    .catch(() => OFF);
  return configP;
}

async function headers(): Promise<Record<string, string>> {
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  return { ...(anon ? { apikey: anon } : {}), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' };
}

async function call<T>(path: string, init: RequestInit): Promise<T> {
  const base = fnBase();
  if (!base) throw new Error('Discord isn’t set up on this Exos server.');
  let res: Response;
  try {
    res = await fetch(`${base}${path}`, { ...init, headers: { ...(await headers()), ...(init.headers ?? {}) } });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) throw Object.assign(new Error(typeof out?.error === 'string' ? out.error : `Request failed (${res.status}).`),
    { reason: typeof out?.reason === 'string' ? out.reason : 'unknown' });
  return out as T;
}

export async function fetchDiscordStatus(orgId: string): Promise<DiscordStatus> {
  const { data, error } = await supabase.rpc('exos_discord_status', { p_org_id: orgId });
  if (error) throw new Error(rpcMessage(error));
  return parseDiscordStatus(data);
}

export async function saveDiscordWebhook(orgId: string, url: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('exos_discord_set_webhook', { p_org_id: orgId, p_url: url.trim() });
  if (error) throw new Error(rpcMessage(error));
  return strOrNull((data as any)?.hint);
}

export async function removeDiscordWebhook(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_discord_remove_webhook', { p_org_id: orgId });
  if (error) throw new Error(rpcMessage(error));
}

export async function setDiscordOptions(orgId: string, o: { writes?: boolean; autoPost?: boolean }): Promise<void> {
  const { error } = await supabase.rpc('exos_discord_set_options', {
    p_org_id: orgId, p_writes: o.writes ?? null, p_auto_post: o.autoPost ?? null,
  });
  if (error) throw new Error(rpcMessage(error));
}

export async function unlinkDiscordServer(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_discord_unlink_guild', { p_org_id: orgId });
  if (error) throw new Error(rpcMessage(error));
}

/** Discord's bot authorization page for this org (owner / manager). */
export async function startDiscordInstall(orgId: string): Promise<string> {
  const r = await call<{ url?: unknown }>(`/start?${new URLSearchParams({ org: orgId })}`, { method: 'GET' });
  if (!isDiscordAuthorizeUrl(r.url)) throw new Error('Exos returned an unexpected link; nothing was opened.');
  return r.url;
}

/** After Confirm on the return screen (OAuthFinish). */
export async function finishDiscordInstall(state: string, finish: string): Promise<{ guildName: string | null }> {
  const r = await call<{ connected?: boolean; guild_name?: unknown }>('/finish', { method: 'POST', body: JSON.stringify({ state, finish }) });
  if (r.connected !== true) throw Object.assign(new Error('Nothing was linked.'), { reason: 'unknown' });
  return { guildName: strOrNull(r.guild_name) };
}

export async function fetchDiscordEventStatus(eventId: string): Promise<DiscordEventStatus> {
  const { data, error } = await supabase.rpc('exos_discord_event_status', { p_event_id: eventId });
  if (error) throw new Error(rpcMessage(error));
  return parseDiscordEventStatus(data);
}

/** Show on Discord on / off, then run the event's pass now (best effort). */
export async function setDiscordShow(eventId: string, show: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_discord_set_show', { p_event_id: eventId, p_show: show });
  if (error) throw new Error(rpcMessage(error));
  await call('/sync', { method: 'POST', body: JSON.stringify({ event: eventId }) }).catch(() => undefined);
}

/** "Post to Discord" / "Post a reminder": once per event per kind. */
export async function postToDiscord(eventId: string, kind: PostKind): Promise<{ status: string; already: boolean }> {
  const r = await call<{ status?: string; already?: boolean }>('/post', { method: 'POST', body: JSON.stringify({ event: eventId, kind }) });
  return { status: String(r.status ?? 'queued'), already: r.already === true };
}
