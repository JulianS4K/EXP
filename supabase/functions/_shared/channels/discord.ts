// Channels: promote an Exos event on the organizer's own Discord server (mig
// 20261113130000; docs/discord.md). Two levels:
//
//   1. Announcement: one embed through the org's channel webhook
//      (POST /webhooks/{id}/{token}).
//   2. Scheduled event: one EXTERNAL guild scheduled event per Exos event,
//      made by the platform's bot in the org's linked server (POST / PATCH /
//      DELETE /guilds/{guild}/scheduled-events[/{id}]); deleted when the Exos
//      event is deleted (mig 20261114100000).
// Plus "Send a test" through the webhook and the automatic reminder's timing
// (mig 20261114100000).
//
// Every request goes to DISCORD_API (https://discord.com/api/v10) and must be
// in the allowlist below, bound to THIS org's guild id and webhook id; any
// other method, path, server or webhook throws before fetch is called. No
// messages beyond the webhook, no roles, members, channels or DMs. Writes go
// out only when `live` (the org's switch AND EXOS_DISCORD_WRITES=on); a dry
// run records the plan, with the webhook token redacted, and sends nothing.
// The one other call is the OAuth code exchange at DISCORD_TOKEN_URL during
// the bot install (exchangeInstallCode), which writes nothing on Discord.
//
// Pure: no Deno or Node APIs beyond fetch (injected), Intl and Web Crypto, so
// the Deno tests and vitest share it.
import { eventPageUrl } from "../calendar/feed.ts";
import { utc } from "./model.ts";

export const DISCORD_API = "https://discord.com/api/v10";
/** Hosts Exos sends anything to for Discord. */
export const DISCORD_HOSTS: ReadonlySet<string> = new Set(["discord.com"]);
export const DISCORD_AUTHORIZE_URL = "https://discord.com/oauth2/authorize";
export const DISCORD_TOKEN_URL = `${DISCORD_API}/oauth2/token`;
/** CREATE_EVENTS (1 << 44): create scheduled events, and edit / delete the ones the bot made. Nothing else. */
export const DISCORD_BOT_PERMISSIONS = "17592186044416";

const SNOWFLAKE = /^[0-9]{17,20}$/;
const WEBHOOK_TOKEN = /^[A-Za-z0-9_-]{60,100}$/;

// ---- the allowlist ----------------------------------------------------------

export type DiscordMethod = "GET" | "POST" | "PATCH" | "DELETE";
export interface DiscordBound { guildId?: string | null; webhookId?: string | null }

const ALLOWED: { method: DiscordMethod; re: RegExp; kind: "guild" | "webhook" }[] = [
  { method: "POST", re: /^\/guilds\/([0-9]{17,20})\/scheduled-events$/, kind: "guild" },
  { method: "GET", re: /^\/guilds\/([0-9]{17,20})\/scheduled-events\/[0-9]{17,20}$/, kind: "guild" },
  { method: "PATCH", re: /^\/guilds\/([0-9]{17,20})\/scheduled-events\/[0-9]{17,20}$/, kind: "guild" },
  { method: "DELETE", re: /^\/guilds\/([0-9]{17,20})\/scheduled-events\/[0-9]{17,20}$/, kind: "guild" },
  { method: "POST", re: /^\/webhooks\/([0-9]{17,20})\/[A-Za-z0-9_-]{60,100}$/, kind: "webhook" },
];
const WEBHOOK_QUERY = "wait=true&with_components=true";

/** Which allowlist entry a request matches for this org, or null. */
export function allowedRequest(method: string, path: string, bound: DiscordBound): "guild" | "webhook" | null {
  if (typeof path !== "string" || !path.startsWith("/") || path.includes("..") || path.includes("//") || /[\s%#\\]/.test(path)) return null;
  const [p, q, extra] = path.split("?");
  if (extra !== undefined) return null;
  for (const a of ALLOWED) {
    if (a.method !== method) continue;
    const m = a.re.exec(p);
    if (!m) continue;
    if (a.kind === "guild") {
      if (q !== undefined || !bound.guildId || m[1] !== bound.guildId) return null;
    } else {
      if ((q !== undefined && q !== WEBHOOK_QUERY) || !bound.webhookId || m[1] !== bound.webhookId) return null;
    }
    return a.kind;
  }
  return null;
}

/** A path safe to record or log: the webhook token replaced. */
export function redactPath(path: string): string {
  return String(path).replace(/\/webhooks\/([0-9]{17,20})\/[^/?#]+/g, "/webhooks/$1/***");
}

/** Any text with webhook URLs / tokens and bot tokens taken out. */
export function redactDiscord(text: string, secrets: (string | null | undefined)[] = []): string {
  let s = redactPath(String(text ?? "")).replace(/\bBot\s+[A-Za-z0-9._-]{20,}/g, "Bot ***");
  for (const v of secrets) if (v && v.length >= 6) s = s.split(v).join("***");
  return s;
}

// ---- the io -----------------------------------------------------------------

export interface DiscordStep { op: "planned" | "sent"; method: DiscordMethod; path: string; body?: unknown; ok?: boolean; error?: string }
export interface DiscordResult {
  ok: boolean;
  status: number;
  body: any;
  error?: string;
  /** Discord's numeric error code (50013, 10004, ...), when it sent one. */
  code?: number;
  retryAfter?: number;
  /** A 429 that applies to every route (X-RateLimit-Global, or scope global). */
  global?: boolean;
  /** X-RateLimit-Scope of a 429: user, global or shared. */
  scope?: string;
  /** Nothing reached Discord (the gate refused it, or the connection never opened): safe to retry. */
  notSent?: boolean;
}

/** Which credential a call uses: the bot token (guild routes) or the webhook's own. */
export type CallKind = "bot" | "webhook";
export interface GateAnswer { ok: boolean; reason?: string; retryAfter?: number }
export interface CallHooks {
  /** Before each real request (exos_discord_call_gate: breaker, global pause, platform cap). */
  gate?: (kind: CallKind) => Promise<GateAnswer>;
  /** After each refused answer (exos_discord_call_result: invalid count, 401 breaker, global 429 pause). */
  report?: (kind: CallKind, r: DiscordResult) => Promise<void>;
}
export interface DiscordIo {
  live: boolean;
  req(method: DiscordMethod, path: string, body?: unknown): Promise<DiscordResult>;
}

/** Stand-in answers for a dry run (no request is made). */
export function discordStandIn(method: DiscordMethod, kind: "guild" | "webhook"): any {
  if (kind === "webhook") return { id: "0", planned: true };
  if (method === "POST") return { id: "0", planned: true };
  return {};
}

export function makeDiscordIo(opts: {
  fetch: typeof fetch;
  live: boolean;
  bound: DiscordBound;
  botToken?: string | null;
  steps: DiscordStep[];
  userAgent?: string;
  timeoutMs?: number;
  hooks?: CallHooks;
}): DiscordIo {
  return {
    live: opts.live,
    async req(method, path, body) {
      const kind = allowedRequest(method, path, opts.bound);
      if (!kind) throw new Error(`discord: ${method} ${redactPath(path.split("?")[0])} is not an allowed request`);
      const shown = redactPath(path);
      if (method !== "GET" && !opts.live) {
        opts.steps.push({ op: "planned", method, path: shown, ...(body !== undefined ? { body } : {}) });
        return { ok: true, status: 200, body: discordStandIn(method, kind) };
      }
      if (kind === "guild" && !opts.botToken) return { ok: false, status: 0, body: null, error: "NO_BOT_TOKEN", notSent: true };
      const callKind: CallKind = kind === "guild" ? "bot" : "webhook";
      if (opts.hooks?.gate) {
        const g = await opts.hooks.gate(callKind).catch((): GateAnswer => ({ ok: false, reason: "gate", retryAfter: 60 }));
        if (!g.ok) {
          const e = g.reason === "breaker" ? "DISCORD_PAUSED" : g.reason === "org_paused" ? "ORG_PAUSED"
            : g.reason === "paused" ? "RATE_LIMITED_GLOBAL" : "PLATFORM_LIMIT";
          if (method !== "GET") opts.steps.push({ op: "planned", method, path: shown, ok: false, error: e });
          return { ok: false, status: 0, body: null, error: e, retryAfter: g.retryAfter ?? 60, notSent: true };
        }
      }
      const headers: Record<string, string> = {
        Accept: "application/json",
        "User-Agent": opts.userAgent ?? "DiscordBot (https://exos.invalid, 1.0)",
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        // The bot token goes only to guild routes; a webhook carries its own token in the path.
        ...(kind === "guild" ? { Authorization: `Bot ${opts.botToken}` } : {}),
      };
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 10_000);
      try {
        const res = await opts.fetch(DISCORD_API + path, {
          method, headers, body: body !== undefined ? JSON.stringify(body) : undefined, signal: ctrl.signal, redirect: "error",
        });
        const out = res.status === 204 ? null : await res.json().catch(() => null);
        if (res.ok) {
          if (method !== "GET") opts.steps.push({ op: "sent", method, path: shown, ok: true });
          return { ok: true, status: res.status, body: out };
        }
        // Discord's numeric error code only (its message text is never passed on).
        const code = typeof out?.code === "number" && out.code > 0 ? out.code : undefined;
        const r: DiscordResult = { ok: false, status: res.status, body: out, error: code ? `DISCORD_${code}` : `HTTP_${res.status}`,
                                   ...(code ? { code } : {}) };
        if (res.status === 429) {
          const ra = Number(out?.retry_after ?? res.headers.get("retry-after"));
          r.retryAfter = Number.isFinite(ra) && ra > 0 ? Math.ceil(ra) : 30;
          r.scope = (res.headers.get("x-ratelimit-scope") ?? "").toLowerCase() || undefined;
          r.global = out?.global === true || (res.headers.get("x-ratelimit-global") ?? "").toLowerCase() === "true" || r.scope === "global";
          r.error = r.global ? "RATE_LIMITED_GLOBAL" : "RATE_LIMITED";
        }
        if (method !== "GET") opts.steps.push({ op: "sent", method, path: shown, ok: false, error: r.error });
        await opts.hooks?.report?.(callKind, r).catch(() => undefined);
        return r;
      } catch (err) {
        const e = errorKind(err);
        if (method !== "GET") opts.steps.push({ op: "sent", method, path: shown, ok: false, error: e });
        return { ok: false, status: 0, body: null, error: e, ...(e === "CONNECT" ? { notSent: true } : {}) };
      } finally {
        clearTimeout(timer);
      }
    },
  };
}

/**
 * TIMEOUT (may have reached Discord), CONNECT (the connection never opened:
 * DNS, refused, TLS; nothing was sent) or NETWORK (dropped mid-way: unknown).
 */
export function errorKind(err: unknown): "TIMEOUT" | "CONNECT" | "NETWORK" {
  if ((err as Error)?.name === "AbortError") return "TIMEOUT";
  const m = String((err as Error)?.message ?? "");
  return /error trying to connect|tcp connect error|dns error|failed to lookup|connection refused|certificate|invalid peer/i.test(m)
    ? "CONNECT" : "NETWORK";
}

// ---- the event as Discord shows it -------------------------------------------

export interface DiscordEvent {
  id: string;
  name: string;
  status: string;
  startUtc: string;
  endUtc: string;
  timezone: string;
  url: string;
  shortUrl: string;
  description: string;
  imageUrl: string | null;
  venueLine: string | null;
  orgName: string | null;
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

/** The event row from _exos_discord_event_json, with its public page under appBase. */
export function discordEvent(e: any, appBase: string): DiscordEvent | null {
  if (!e || typeof e.id !== "string" || !str(e.name) || !e.starts_at) return null;
  const base = appBase.replace(/\/+$/, "");
  if (!/^https:\/\/[^/]+/.test(base)) return null;
  const start = utc(e.starts_at);
  if (!start) return null;
  const end = utc(e.ends_at ?? "") || utc(new Date(Date.parse(start) + 3 * 3600_000).toISOString());
  const venue = [str(e.venue_name), str(e.venue_location), str(e.city)].filter(Boolean)
    .filter((v, i, a) => a.indexOf(v) === i).join(", ");
  const img = str(e.image_url);
  return {
    id: e.id,
    name: str(e.name),
    status: str(e.status) || "draft",
    startUtc: start,
    endUtc: Date.parse(end) > Date.parse(start) ? end : utc(new Date(Date.parse(start) + 3600_000).toISOString()),
    timezone: str(e.timezone) || "America/New_York",
    url: eventPageUrl(base, { id: e.id, slug: str(e.slug) || null }),
    shortUrl: `${base}/event/${e.id}`,
    description: str(e.description),
    imageUrl: /^https:\/\/[^\s]+$/.test(img) && img.length <= 2000 ? img : null,
    venueLine: e.location_mode === "tba" ? null : venue || null,
    orgName: str(e.org_name) || null,
  };
}

/** "Sat, Nov 21, 2026, 8:00 PM EST" in the event's zone (UTC if the zone is unknown). */
export function formatWhen(startUtc: string, timezone: string): string {
  const d = new Date(startUtc);
  const opts: Intl.DateTimeFormatOptions = {
    weekday: "short", month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short",
  };
  try {
    return new Intl.DateTimeFormat("en-US", { ...opts, timeZone: timezone }).format(d);
  } catch {
    return new Intl.DateTimeFormat("en-US", { ...opts, timeZone: "UTC" }).format(d);
  }
}

/** Text that Discord shows as written: markdown, mentions and masked links escaped. */
export function escapeMarkdown(s: string): string {
  return s.replace(/([\\*_~`|>#\[\]()<@])/g, "\\$1");
}

// ---- level 1: the announcement ------------------------------------------------

export type PostKind = "publish" | "reminder";

/** The webhook body: one embed, a "Get tickets" link button, and never a mention. */
export function announcementBody(ev: DiscordEvent, kind: PostKind) {
  const unix = Math.floor(Date.parse(ev.startUtc) / 1000);
  const lines = [
    kind === "reminder" ? "**Coming up soon.**" : null,
    `**When:** ${formatWhen(ev.startUtc, ev.timezone)} (<t:${unix}:R>)`,
    ev.venueLine ? `**Where:** ${escapeMarkdown(ev.venueLine)}` : null,
  ].filter(Boolean) as string[];
  const embed: Record<string, unknown> = {
    title: clip(ev.name, 256),
    url: ev.url,
    description: lines.join("\n"),
    ...(ev.imageUrl ? { image: { url: ev.imageUrl } } : {}),
    ...(ev.orgName ? { footer: { text: clip(ev.orgName, 100) } } : {}),
  };
  return {
    allowed_mentions: { parse: [] as string[] },
    embeds: [embed],
    components: [{ type: 1, components: [{ type: 2, style: 5, label: "Get tickets", url: ev.url }] }],
  };
}

export function webhookPath(webhookId: string, token: string): string {
  if (!SNOWFLAKE.test(webhookId) || !WEBHOOK_TOKEN.test(token)) throw new Error("discord: bad webhook");
  return `/webhooks/${webhookId}/${token}?${WEBHOOK_QUERY}`;
}

export interface PostOutcome {
  state: "sent" | "dry_run" | "retry" | "error";
  messageId?: string;
  error?: string;
  retrySeconds?: number;
  /** Discord refused the webhook itself: skip it until a new URL is saved. */
  webhookBroken?: boolean;
  plan: { steps: DiscordStep[] };
}

/**
 * Post one announcement through the org's webhook (or plan it, in a dry run).
 * Retried only when nothing can have been posted: a 429, or a request that
 * never left (the gate, a connection that never opened). A 5xx, a timeout or
 * a dropped connection may have posted: an error that says to check the channel.
 */
export async function postAnnouncement(io: DiscordIo, ev: DiscordEvent, kind: PostKind, webhookId: string, token: string,
                                       steps: DiscordStep[]): Promise<PostOutcome> {
  const r = await io.req("POST", webhookPath(webhookId, token), announcementBody(ev, kind));
  return webhookOutcome(io, r, steps);
}

/** What a webhook post's answer means (shared by the announcement and the test message). */
function webhookOutcome(io: DiscordIo, r: DiscordResult, steps: DiscordStep[]): PostOutcome {
  if (!io.live) return { state: "dry_run", plan: { steps } };
  if (r.ok) {
    const id = typeof r.body?.id === "string" && SNOWFLAKE.test(r.body.id) ? r.body.id : undefined;
    return { state: "sent", ...(id ? { messageId: id } : {}), plan: { steps } };
  }
  if (r.status === 429 || r.notSent) {
    return { state: "retry", error: `Discord: ${r.error ?? "not sent"}`, retrySeconds: r.retryAfter ?? 60, plan: { steps } };
  }
  if (r.status === 401 || r.status === 403 || r.status === 404 || r.code === 10015) {
    return { state: "error", webhookBroken: true, error: "Discord: the webhook was deleted or its URL is wrong; paste a new one", plan: { steps } };
  }
  if (r.status === 0 || r.status >= 500) {
    return { state: "error", error: `Discord: ${r.error ?? "no answer"}; it may have posted, so check the channel before posting again`, plan: { steps } };
  }
  return { state: "error", error: `Discord: ${r.error ?? "refused"}`, plan: { steps } };
}

// ---- "Send a test" ---------------------------------------------------------------

/**
 * The test message (Org settings → Discord → Send a test): one embed saying
 * Exos is connected, no content, no link, never a mention.
 */
export function testMessageBody(orgName: string | null) {
  const org = str(orgName);
  return {
    allowed_mentions: { parse: [] as string[] },
    embeds: [{
      title: "Exos is connected",
      description: `Exos is connected to this channel. ${org ? `Announcements for ${escapeMarkdown(clip(org, 100))}'s events` : "Event announcements"} will be posted here.`,
    }],
  };
}

/** Send the test through the org's webhook (or plan it, in a dry run); answers as an announcement does. */
export async function sendTestMessage(io: DiscordIo, webhookId: string, token: string, orgName: string | null,
                                      steps: DiscordStep[]): Promise<PostOutcome> {
  const r = await io.req("POST", webhookPath(webhookId, token), testMessageBody(orgName));
  return webhookOutcome(io, r, steps);
}

// ---- the automatic reminder -----------------------------------------------------

/** What an org may pick for the automatic reminder (exos_discord_links.reminder_hours); null is off. */
export const REMINDER_HOURS: readonly number[] = [24, 48];

/** When the automatic reminder is due: `hours` before the start, or null (off, or a bad start). */
export function reminderAt(startUtc: string, hours: number | null | undefined): string | null {
  const start = Date.parse(startUtc);
  if (!hours || !REMINDER_HOURS.includes(hours) || !Number.isFinite(start)) return null;
  return new Date(start - hours * 3600_000).toISOString();
}

/**
 * Whether the cron pass queues the reminder now; the same rule as
 * exos_discord_reminder_queue, which decides: a published event, within
 * `hours` of its start and not started, no reminder asked for yet, and no
 * publish announcement asked for inside that window.
 */
export function reminderDue(o: {
  status: string; startUtc: string; hours: number | null; now: number;
  reminderAsked?: boolean; publishAskedAt?: string | null;
}): boolean {
  const at = reminderAt(o.startUtc, o.hours);
  if (!at || o.status !== "published" || o.reminderAsked) return false;
  const start = Date.parse(o.startUtc);
  if (!(o.now >= Date.parse(at) && o.now < start)) return false;
  const pub = o.publishAskedAt ? Date.parse(o.publishAskedAt) : NaN;
  return !(Number.isFinite(pub) && pub >= Date.parse(at));
}

// ---- level 2: the scheduled event ----------------------------------------------

/** Discord's location is 1-100 characters: the event page, or its short form. */
export function eventLocation(ev: DiscordEvent): string {
  if (ev.url.length <= 100) return ev.url;
  if (ev.shortUrl.length <= 100) return ev.shortUrl;
  return clip(ev.venueLine ?? ev.name, 100);
}

export function scheduledEventBody(ev: DiscordEvent, image?: string | null) {
  const desc = [`Get tickets: ${ev.url}`, ev.venueLine, ev.description].filter(Boolean).join("\n\n");
  return {
    name: clip(ev.name, 100),
    privacy_level: 2,           // GUILD_ONLY
    entity_type: 3,             // EXTERNAL
    channel_id: null,
    entity_metadata: { location: eventLocation(ev) },
    scheduled_start_time: ev.startUtc,
    scheduled_end_time: ev.endUtc,   // required for EXTERNAL
    description: clip(desc, 1000),
    ...(image ? { image } : {}),
  };
}

/** What a pass would send, so an unchanged event costs no request. */
export async function discordHash(ev: DiscordEvent): Promise<string> {
  const basis = JSON.stringify([ev.name, ev.startUtc, ev.endUtc, ev.url, ev.venueLine, ev.description, ev.imageUrl, ev.status]);
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(basis));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

export interface SyncState { show: boolean; external_id: string | null; last_hash: string | null; status?: string }
export interface DiscordSyncResult {
  state: "synced" | "dry_run" | "error" | "retry";
  guild_id?: string;
  external_id?: string | null;
  hash?: string;
  gone?: boolean;
  /** The server refused the bot (403 missing access / permissions, unknown guild). */
  link_broken?: boolean;
  error?: string;
  retry_seconds?: number;
  plan: { steps: DiscordStep[] };
}

/** 403 missing access (50001) / missing permissions (50013), or unknown guild (10004). */
export function linkBroken(r: DiscordResult): boolean {
  return r.code === 10004 || (r.status === 403 && (r.code === 50001 || r.code === 50013));
}

/**
 * One pass for one Exos event. Shown + published + not over: create, or
 * update when it changed. Cancelled: cancel it on Discord (status 4).
 * Unticked or back to draft: delete it. Deleted in Discord by someone
 * (404 on update): gone, and Exos doesn't put it back.
 */
export async function syncScheduledEvent(io: DiscordIo, ev: DiscordEvent, guildId: string, s: SyncState,
                                         hash: string, steps: DiscordStep[], image: () => Promise<string | null>,
                                         now = Date.now()): Promise<DiscordSyncResult> {
  const base = `/guilds/${guildId}/scheduled-events`;
  const ext = s.external_id && SNOWFLAKE.test(s.external_id) ? s.external_id : null;
  const want = s.show && ev.status === "published" && Date.parse(ev.endUtc) > now;
  const fail = (r: DiscordResult, what: string): DiscordSyncResult => {
    if (r.status === 429 || r.notSent) {
      return { state: "retry", error: `Discord: ${what} (${r.error ?? "not sent"})`, retry_seconds: r.retryAfter ?? 60, plan: { steps } };
    }
    if (linkBroken(r)) {
      return { state: "error", link_broken: true, guild_id: guildId,
               error: "Discord: the Exos bot lost access to the server; reconnect the bot", plan: { steps } };
    }
    if (r.status === 401) return { state: "error", error: "Discord: the Exos bot's token was refused; Discord is paused", plan: { steps } };
    return { state: "error", error: `Discord: ${what} (${r.error ?? "refused"})`, plan: { steps } };
  };
  const done = (external: string | null): DiscordSyncResult =>
    io.live ? { state: "synced", guild_id: guildId, external_id: external, hash, plan: { steps } } : { state: "dry_run", plan: { steps } };

  if (ext && ev.status === "cancelled") {
    const r = await io.req("PATCH", `${base}/${ext}`, { status: 4 });
    if (!r.ok && (r.status !== 404 || linkBroken(r))) {
      // Already started (ACTIVE can't be cancelled): take it down instead.
      const d = await io.req("DELETE", `${base}/${ext}`);
      if (!d.ok && (d.status !== 404 || linkBroken(d))) return fail(d, "couldn't cancel the event");
    }
    return done(null);
  }
  if (!want) {
    if (ext) {
      const r = await io.req("DELETE", `${base}/${ext}`);
      if (!r.ok && (r.status !== 404 || linkBroken(r))) return fail(r, "couldn't remove the event");
    }
    return done(null);
  }
  if (!ext) {
    // The cover is read only when the event really goes out (never in a dry run).
    const cover = io.live ? await image().catch(() => null) : null;
    const r = await io.req("POST", base, scheduledEventBody(ev, cover));
    if (!r.ok) return fail(r, "couldn't create the event");
    const id = typeof r.body?.id === "string" ? r.body.id : "";
    if (io.live && !SNOWFLAKE.test(id)) return { state: "error", error: "Discord: no event id came back", plan: { steps } };
    return done(io.live ? id : null);
  }
  if (s.last_hash === hash && s.status === "synced") return done(ext);
  const r = await io.req("PATCH", `${base}/${ext}`, scheduledEventBody(ev));
  if (r.status === 404 && !linkBroken(r)) {
    return { state: "error", gone: true, external_id: null,
             error: "the event was deleted in Discord; tick Show on Discord again to put it back", plan: { steps } };
  }
  if (!r.ok) return fail(r, "couldn't update the event");
  return done(ext);
}

export interface DeleteOutcome {
  state: "done" | "dry_run" | "retry" | "error";
  link_broken?: boolean;
  error?: string;
  retry_seconds?: number;
  plan: { steps: DiscordStep[] };
}

/**
 * The Exos event was deleted: delete its scheduled event (the allowlisted
 * DELETE, bound to the org's server). Already gone (404) is done. A 429, a
 * request that never left, a 5xx, a timeout or a 401 (the breaker) is tried
 * again later: a DELETE is safe to repeat. A server that refused the bot is
 * an error that marks the link.
 */
export async function deleteScheduledEvent(io: DiscordIo, guildId: string, externalId: string,
                                           steps: DiscordStep[]): Promise<DeleteOutcome> {
  if (!SNOWFLAKE.test(guildId) || !SNOWFLAKE.test(externalId)) return { state: "error", error: "bad Discord ids", plan: { steps } };
  const r = await io.req("DELETE", `/guilds/${guildId}/scheduled-events/${externalId}`);
  if (!io.live) return { state: "dry_run", plan: { steps } };
  if (linkBroken(r)) {
    return { state: "error", link_broken: true, error: "Discord: the Exos bot lost access to the server; delete the event in Discord", plan: { steps } };
  }
  if (r.ok || r.status === 404) return { state: "done", plan: { steps } };
  if (r.status === 429 || r.notSent || r.status === 0 || r.status >= 500 || r.status === 401) {
    return { state: "retry", error: `Discord: couldn't delete the event (${r.error ?? "no answer"})`,
             retry_seconds: r.retryAfter ?? (r.status === 401 ? 600 : 60), plan: { steps } };
  }
  return { state: "error", error: `Discord: couldn't delete the event (${r.error ?? "refused"})`, plan: { steps } };
}

// ---- the cover image ------------------------------------------------------------

export const IMAGE_MAX_BYTES = 4 * 1024 * 1024;
/** Where the SPA uploads event covers (src/lib/storage.ts uploadEventImage). */
export const COVER_BUCKET = "exos-media";
const COVER_PATH = /^event-images\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.[a-z0-9]{1,5}$/;

/**
 * The storage object an event's image_url names, or null. Only a cover on
 * this project's own public storage (<SUPABASE_URL>/storage/v1/object/public/
 * exos-media/event-images/<uid>/<uuid>.<ext>, as uploadEventImage makes it);
 * any other URL gets no image. Exos never fetches an image URL over HTTP:
 * the object is read with the service client, so there is no SSRF.
 */
export function coverObject(imageUrl: string | null, supabaseUrl: string): { bucket: string; path: string } | null {
  if (!imageUrl || imageUrl.length > 2000 || /[\s%\\]/.test(imageUrl)) return null;
  let u: URL, base: URL;
  try { u = new URL(imageUrl); base = new URL(supabaseUrl); } catch { return null; }
  if (u.protocol !== "https:" || base.protocol !== "https:" || u.origin !== base.origin || u.username || u.password || u.search || u.hash) return null;
  const prefix = `/storage/v1/object/public/${COVER_BUCKET}/`;
  if (!u.pathname.startsWith(prefix)) return null;
  const path = u.pathname.slice(prefix.length);
  return COVER_PATH.test(path) && !path.includes("..") ? { bucket: COVER_BUCKET, path } : null;
}

/** The type Discord takes, from the file's own first bytes (not its name or headers). */
export function sniffImage(b: Uint8Array): "image/png" | "image/jpeg" | "image/gif" | null {
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return "image/gif";
  return null;
}

/**
 * Reads one storage object, at most maxBytes (null when larger, missing or
 * unreadable). exos-discord passes the service client's storage here.
 */
export type CoverLoader = (bucket: string, path: string, maxBytes: number) => Promise<Uint8Array | null>;

/** The event's cover as the data URI Discord takes (JPG, PNG or GIF, at most 4 MB), or null. */
export async function coverDataUri(load: CoverLoader, imageUrl: string | null, supabaseUrl: string): Promise<string | null> {
  const obj = coverObject(imageUrl, supabaseUrl);
  if (!obj) return null;
  const buf = await load(obj.bucket, obj.path, IMAGE_MAX_BYTES).catch(() => null);
  if (!buf || buf.byteLength === 0 || buf.byteLength > IMAGE_MAX_BYTES) return null;
  const type = sniffImage(buf);
  if (!type) return null;
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return `data:${type};base64,${btoa(bin)}`;
}

// ---- the bot install (OAuth2, scope bot) -------------------------------------------

export interface DiscordAppConfig { applicationId: string; clientSecret: string; botToken: string; redirectUri: string }

export function discordAppConfig(env: (k: string) => string | undefined): DiscordAppConfig | null {
  const applicationId = (env("DISCORD_APPLICATION_ID") ?? "").trim();
  const clientSecret = (env("DISCORD_CLIENT_SECRET") ?? "").trim();
  const botToken = (env("DISCORD_BOT_TOKEN") ?? "").trim();
  const base = (env("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  const redirectUri = (env("DISCORD_REDIRECT_URI") ?? "").trim() || (base ? `${base}/functions/v1/exos-discord/callback` : "");
  if (!SNOWFLAKE.test(applicationId) || !clientSecret || !botToken || !/^https:\/\//.test(redirectUri)) return null;
  return { applicationId, clientSecret, botToken, redirectUri };
}

/** "Add Exos bot to your server": Discord's bot authorization with a code (so the server comes from the token response). */
export function installUrl(cfg: DiscordAppConfig, state: string): string {
  const q = new URLSearchParams({
    client_id: cfg.applicationId,
    scope: "bot",
    permissions: DISCORD_BOT_PERMISSIONS,
    response_type: "code",
    redirect_uri: cfg.redirectUri,
    integration_type: "0",
    state,
  });
  return `${DISCORD_AUTHORIZE_URL}?${q}`;
}

export type InstallResult = { guildId: string; guildName: string | null } | { error: string };

/**
 * Exchange the install code at DISCORD_TOKEN_URL and read the server Discord
 * added the bot to (`guild` in the token response). The redirect's guild_id
 * is only a hint (Discord's docs), so it is never used. The user's access
 * token in the answer is dropped.
 */
export async function exchangeInstallCode(fetchFn: typeof fetch, cfg: DiscordAppConfig, code: string, timeoutMs = 8000): Promise<InstallResult> {
  if (typeof code !== "string" || code.length < 8 || code.length > 2048 || /\s/.test(code)) return { error: "code" };
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetchFn(DISCORD_TOKEN_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
        Authorization: `Basic ${btoa(`${cfg.applicationId}:${cfg.clientSecret}`)}`,
      },
      body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: cfg.redirectUri }).toString(),
      signal: ctrl.signal,
      redirect: "error",
    });
    const out = await res.json().catch(() => null);
    if (!res.ok) return { error: res.status === 401 ? "config" : "exchange" };
    const g = out?.guild;
    if (!g || typeof g.id !== "string" || !SNOWFLAKE.test(g.id)) return { error: "no_guild" };
    return { guildId: g.id, guildName: typeof g.name === "string" ? g.name.slice(0, 100) : null };
  } catch {
    return { error: "exchange" };
  } finally {
    clearTimeout(timer);
  }
}

/** The pasted URL's two parts, as the SQL (exos_discord_webhook_parts) reads them. For hints only: the SQL decides. */
export function webhookUrlParts(raw: string): { webhookId: string; token: string } | null {
  const m = /^https:\/\/(?:discord\.com|discordapp\.com)\/api(?:\/v[0-9]{1,2})?\/webhooks\/([0-9]{17,20})\/([A-Za-z0-9_-]{60,100})\/?$/
    .exec(String(raw ?? "").trim());
  return m && String(raw).trim().length <= 300 ? { webhookId: m[1], token: m[2] } : null;
}
