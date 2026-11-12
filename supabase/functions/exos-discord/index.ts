// exos-discord — promote Exos events on the organizer's own Discord server
// (mig 20261113130000; docs/discord.md). Two levels, both off until
// EXOS_DISCORD_ENABLED=on, both a dry run unless the org's writes switch AND
// EXOS_DISCORD_WRITES=on:
//
//   1. Announcements through the org's channel webhook (one embed, a "Get
//      tickets" link, never a mention; once per event per kind).
//   2. One EXTERNAL scheduled event per event the organizer shows on
//      Discord, made by the platform's bot in the org's linked server.
//
// Requests to Discord go only through _shared/channels/discord.ts
// (DISCORD_API, its allowlist bound to the org's guild and webhook). The
// webhook token and the bot token are never logged or returned
// (redactDiscord / redactError), and errors carry Discord's numeric code only.
//
// Routes (under /functions/v1/exos-discord):
//   GET  /config                 No auth. { enabled, bot, writes }: what the SPA may show.
//   POST /post {event, kind}     JWT, owner / manager (exos_discord_request_post checks the role,
//                                the once-per-kind rule and the rate limits), then sends it now.
//   POST /sync {event}           JWT, owner / manager: run the event's scheduled-event pass now.
//   GET  /start?org=<id>         JWT, owner / manager: { url } of Discord's bot authorization
//                                (scope bot, CREATE_EVENTS only), with a single-use state.
//   GET  /callback?code&state    Discord sends the browser here: the code is parked with a finish
//                                token's hash; the browser goes back to the org's settings with
//                                the token in the URL fragment (_shared/oauthFinish.ts).
//   POST /finish {state, finish} JWT of the user who started it: the code is exchanged at Discord's
//                                token endpoint and the server named there is linked
//                                (exos_discord_guild_link). The redirect's guild_id is ignored.
//   POST /cron                   X-Cron-Secret: queued posts and due scheduled events (every 2 min).
// Deploy with --no-verify-jwt (CORS preflight, Discord's redirect, the cron).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET,
//      EXOS_APP_URL (the SPA base, in EXOS_REDIRECT_ORIGINS), EXOS_REDIRECT_ORIGINS,
//      EXOS_DISCORD_ENABLED, EXOS_DISCORD_WRITES, and for level 2: DISCORD_APPLICATION_ID,
//      DISCORD_CLIENT_SECRET, DISCORD_BOT_TOKEN, DISCORD_REDIRECT_URI (optional; default
//      <SUPABASE_URL>/functions/v1/exos-discord/callback).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { urlIsBlocked } from "../_shared/ssrf.ts";
import { finishRefusal, withFinishFragment } from "../_shared/oauthFinish.ts";
import { integrationsReturnUrl, isStateShaped, newState, returnAppUrl, stateHash } from "../_shared/eventbrite/oauth.ts";
import { writesLive } from "../_shared/channels/model.ts";
import {
  discordAppConfig, discordEvent, discordHash, type DiscordStep, exchangeInstallCode, imageDataUri, installUrl,
  makeDiscordIo, postAnnouncement, type PostKind, redactDiscord, syncScheduledEvent,
} from "../_shared/channels/discord.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CRON_BUDGET_MS = 90_000;

const env = (k: string) => Deno.env.get(k);
const enabled = () => env("EXOS_DISCORD_ENABLED") === "on";

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const app = returnAppUrl(env("EXOS_APP_URL"), env("EXOS_REDIRECT_ORIGINS"));
  const cfg = discordAppConfig(env);
  if (route === "config" && req.method === "GET") {
    return json({ enabled: enabled() && app !== null, bot: enabled() && app !== null && cfg !== null, writes: env("EXOS_DISCORD_WRITES") === "on" }, 200, cors);
  }
  // Dark until the operator turns it on: no Discord call, no state made.
  if (!enabled()) return json({ error: "Discord is switched off on this Exos server", reason: "off" }, 503, cors);
  if (!app) return json({ error: "Discord is not set up on this Exos server", reason: "not_configured" }, 503, cors);
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "cron" && req.method === "POST") {
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    const deadline = Date.now() + CRON_BUDGET_MS;
    const posts = await drainPosts(sb, app, null, deadline);
    const syncs = await runSyncs(sb, app, cfg?.botToken ?? null, null, deadline);
    return json({ ok: true, posts, syncs });
  }

  if (route === "post" && req.method === "POST") {
    const auth = userClient(req);
    if (!auth) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    const body = await req.json().catch(() => ({}));
    const event = String(body?.event ?? "");
    const kind = String(body?.kind ?? "publish");
    if (!UUID.test(event) || (kind !== "publish" && kind !== "reminder")) return json({ error: "missing or bad event or kind" }, 400, cors);
    // The RPC checks the role, the once-per-kind rule and the rate limits before anything goes to Discord.
    const { data, error } = await auth.rpc("exos_discord_request_post", { p_event_id: event, p_kind: kind });
    if (error) return rpcError(error, cors);
    const r = data as { post_id: string; status: string; already: boolean };
    if (r.already) return json({ status: r.status, already: true }, 200, cors);
    const sent = await drainPosts(sb, app, r.post_id, Date.now() + 20_000);
    return json({ status: sent.results[0]?.state ?? "queued", already: false }, 200, cors);
  }

  if (route === "sync" && req.method === "POST") {
    const auth = userClient(req);
    if (!auth) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    const body = await req.json().catch(() => ({}));
    const event = String(body?.event ?? "");
    if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
    const st = await auth.rpc("exos_discord_event_status", { p_event_id: event });
    if (st.error) return rpcError(st.error, cors);
    if ((st.data as { can_manage?: boolean })?.can_manage !== true) return json({ error: "Owner or manager only." }, 403, cors);
    if (!cfg) return json({ error: "The Exos bot isn't set up on this server yet", reason: "not_configured" }, 503, cors);
    const out = await runSyncs(sb, app, cfg.botToken, event, Date.now() + 20_000);
    return json({ state: out.results[0]?.state ?? "nothing to do" }, 200, cors);
  }

  // ---- "Add Exos bot to your server" ------------------------------------------
  if (route === "start" && req.method === "GET") {
    if (!cfg) return json({ error: "The Exos bot isn't set up on this server yet", reason: "not_configured" }, 503, cors);
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    const org = url.searchParams.get("org") ?? "";
    if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
    const state = newState();
    const { error } = await sb.rpc("exos_discord_install_begin", { p_org_id: org, p_user_id: user, p_state_hash: await stateHash(state) });
    if (error) {
      if (error.code === "42501") return json({ error: "owner or manager only", reason: "forbidden" }, 403, cors);
      if (error.code === "54000") return json({ error: "too many attempts, try again in a few minutes", reason: "rate" }, 429, cors);
      console.error("exos-discord: begin failed", redactError(error));
      return json({ error: "could not start adding the bot", reason: "server" }, 500, cors);
    }
    return json({ url: installUrl(cfg, state) }, 200, cors);
  }

  if (route === "callback" && req.method === "GET") {
    if (!cfg) return redirect(integrationsReturnUrl(app, null, { discord: "error", reason: "not_configured" }));
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    const err = url.searchParams.get("error");
    if (!isStateShaped(state)) return redirect(integrationsReturnUrl(app, null, { discord: "error", reason: "state" }));
    const finish = newState();
    const { data: orgId, error } = await sb.rpc("exos_oauth_state_return", {
      p_state_hash: await stateHash(state), p_code: err ? null : code, p_finish_hash: await stateHash(finish),
    });
    if (error) {
      console.error("exos-discord: callback failed", redactError(error));
      return redirect(integrationsReturnUrl(app, null, { discord: "error", reason: "server" }));
    }
    const org = typeof orgId === "string" ? orgId : null;
    if (!org) return redirect(integrationsReturnUrl(app, null, { discord: "error", reason: "expired" }));
    if (err || !code) return redirect(integrationsReturnUrl(app, org, { discord: "error", reason: err === "access_denied" ? "denied" : "discord" }));
    return redirect(withFinishFragment(integrationsReturnUrl(app, org, { discord: "finish", discord_state: state }), "discord_finish", finish));
  }

  if (route === "finish" && req.method === "POST") {
    if (!cfg) return json({ error: "The Exos bot isn't set up on this server yet", reason: "not_configured" }, 503, cors);
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    let body: { state?: unknown; finish?: unknown };
    try { body = await req.json(); } catch { return json({ error: "invalid JSON", reason: "state" }, 400, cors); }
    if (!isStateShaped(body.state)) return json({ error: "bad state", reason: "state" }, 400, cors);
    const finishHash = isStateShaped(body.finish) ? await stateHash(body.finish) : null;
    const { data, error } = await sb.rpc("exos_discord_install_consume", {
      p_state_hash: await stateHash(body.state), p_user_id: user, p_finish_hash: finishHash,
    });
    if (error) {
      console.error("exos-discord: consume failed", redactError(error));
      return json({ error: "could not finish adding the bot", reason: "server" }, 500, cors);
    }
    const row = (Array.isArray(data) ? data[0] : null) as { org_id: string | null; code: string | null; refused: string | null } | null;
    if (!row?.org_id || !row.code) {
      const refusal = finishRefusal(row?.refused);
      return json({ error: refusal.error, reason: refusal.reason }, refusal.status, cors);
    }
    const tok = await exchangeInstallCode(fetch, cfg, row.code);
    if ("error" in tok) {
      console.error("exos-discord: code exchange failed", tok.error);
      return json({ error: "Discord didn't confirm the server; add the bot again", reason: tok.error === "config" ? "config" : "exchange" }, 502, cors);
    }
    const { data: linked, error: linkErr } = await sb.rpc("exos_discord_guild_link", {
      p_org_id: row.org_id, p_user_id: user, p_guild_id: tok.guildId, p_guild_name: tok.guildName,
    });
    if (linkErr) {
      if (linkErr.code === "42501") return json({ error: "owner or manager only", reason: "forbidden" }, 403, cors);
      if (linkErr.code === "23505") return json({ error: "that Discord server is linked to another Exos organization", reason: "taken" }, 409, cors);
      console.error("exos-discord: link failed", redactError(linkErr));
      return json({ error: "could not save the server", reason: "server" }, 500, cors);
    }
    const l = linked as { guild_name?: string | null } | null;
    return json({ connected: true, org_id: row.org_id, guild_name: l?.guild_name ?? null }, 200, cors);
  }

  return json({ error: "not found" }, 404, cors);
});

// ---- level 1: queued announcements --------------------------------------------
interface ClaimedPost { post_id: string; org_id: string; event_id: string; kind: PostKind; lease_id: string; payload: any }

async function drainPosts(sb: SupabaseClient, app: string, postId: string | null, deadline: number) {
  const { data, error } = await sb.rpc("exos_discord_post_claim", { p_limit: postId ? 1 : 20, p_post_id: postId });
  if (error) {
    console.error("exos-discord: post claim failed", redactError(error));
    return { ok: false, results: [] as { state: string }[] };
  }
  const results: { state: string }[] = [];
  for (const c of (data ?? []) as ClaimedPost[]) {
    const token = String(c.payload?.webhook?.token ?? "");
    if (Date.now() > deadline) {
      await sb.rpc("exos_discord_post_mark", { p_post_id: c.post_id, p_lease: c.lease_id, p_state: "retry", p_error: "out of time; retrying", p_retry_seconds: 30 });
      continue;
    }
    try {
      const ev = discordEvent(c.payload?.event, app);
      if (!ev || !token) {
        await sb.rpc("exos_discord_post_mark", { p_post_id: c.post_id, p_lease: c.lease_id, p_state: "error",
          p_error: !token ? "add a Discord webhook first" : "the event needs a name and a start time" });
        results.push({ state: "error" });
        continue;
      }
      const live = writesLive(c.payload?.writes_enabled, env("EXOS_DISCORD_WRITES"));
      const steps: DiscordStep[] = [];
      const io = makeDiscordIo({ fetch, live, bound: { webhookId: c.payload.webhook.id }, steps, userAgent: `DiscordBot (${app}, 1.0)` });
      const out = await postAnnouncement(io, ev, c.kind, c.payload.webhook.id, token, steps);
      await sb.rpc("exos_discord_post_mark", {
        p_post_id: c.post_id, p_lease: c.lease_id, p_state: out.state, p_message_id: out.messageId ?? null,
        p_error: out.error ? redactDiscord(out.error, [token]) : null, p_plan: safePlan(out.plan, [token]), p_retry_seconds: out.retrySeconds ?? null,
      });
      results.push({ state: out.state });
    } catch (err) {
      const msg = redactDiscord(redactError(err), [token]).slice(0, 200);
      console.error("exos-discord: post failed", msg);
      await sb.rpc("exos_discord_post_mark", { p_post_id: c.post_id, p_lease: c.lease_id, p_state: "error", p_error: msg });
      results.push({ state: "error" });
    }
  }
  return { ok: true, results };
}

// ---- level 2: scheduled events -----------------------------------------------------
interface ClaimedSync { event_id: string; org_id: string; lease_id: string; change_seq: number; payload: any }

async function runSyncs(sb: SupabaseClient, app: string, botToken: string | null, event: string | null, deadline: number) {
  const { data, error } = await sb.rpc("exos_discord_sync_claim", { p_limit: event ? 1 : 20, p_event_id: event });
  if (error) {
    console.error("exos-discord: sync claim failed", redactError(error));
    return { ok: false, results: [] as { state: string }[] };
  }
  const results: { state: string }[] = [];
  for (const c of (data ?? []) as ClaimedSync[]) {
    const mark = (result: Record<string, unknown>) =>
      sb.rpc("exos_discord_sync_mark", { p_event_id: c.event_id, p_lease: c.lease_id, p_change_seq: c.change_seq, p_result: result });
    if (Date.now() > deadline) {
      await mark({ state: "retry", error: "out of time; retrying", retry_seconds: 30 });
      continue;
    }
    try {
      const ev = discordEvent(c.payload?.event, app);
      const guild = String(c.payload?.guild_id ?? "");
      if (!ev) {
        await mark({ state: "error", error: "the event needs a name and a start time" });
        results.push({ state: "error" });
        continue;
      }
      if (!botToken) {
        await mark({ state: "error", error: "the Exos bot isn't set up on this server yet" });
        results.push({ state: "error" });
        continue;
      }
      const live = writesLive(c.payload?.writes_enabled, env("EXOS_DISCORD_WRITES"));
      const steps: DiscordStep[] = [];
      const io = makeDiscordIo({ fetch, live, bound: { guildId: guild }, botToken, steps, userAgent: `DiscordBot (${app}, 1.0)` });
      const hash = await discordHash(ev);
      const out = await syncScheduledEvent(io, ev, guild, c.payload?.sync ?? { show: false, external_id: null, last_hash: null }, hash, steps,
        () => imageDataUri(fetch, ev.imageUrl, (u) => urlIsBlocked(u)));
      await mark({ ...out, plan: safePlan(out.plan, [botToken]), ...(out.error ? { error: redactDiscord(out.error, [botToken]) } : {}) });
      results.push({ state: out.state });
    } catch (err) {
      const msg = redactDiscord(redactError(err), [botToken]).slice(0, 200);
      console.error("exos-discord: sync failed", msg);
      await mark({ state: "error", error: msg });
      results.push({ state: "error" });
    }
  }
  return { ok: true, results };
}

/** The plan as stored: tokens redacted, a cover image's data left out. */
function safePlan(plan: { steps: DiscordStep[] }, secrets: (string | null)[]) {
  const text = JSON.stringify(plan, (k, v) => (k === "image" && typeof v === "string" && v.startsWith("data:") ? "[image]" : v));
  return JSON.parse(redactDiscord(text, secrets));
}

// ---- plumbing -------------------------------------------------------------------------
function userClient(req: Request): SupabaseClient | null {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  return createClient(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
}

async function signedInUser(req: Request): Promise<string | null> {
  const c = userClient(req);
  if (!c) return null;
  const { data } = await c.auth.getUser();
  return data.user?.id ?? null;
}

/** An RPC refusal as the SPA shows it: the SQL's own words (they never carry a URL or token). */
function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = String(error.message ?? "").replace(/^exos_discord_[a-z_]+: /, "").slice(0, 200);
  if (error.code === "42501") return json({ error: msg || "Owner or manager only.", reason: "forbidden" }, 403, cors);
  if (error.code === "54000") return json({ error: msg || "Too many requests.", reason: "rate" }, 429, cors);
  if (error.code === "22023") return json({ error: msg || "Not allowed.", reason: "invalid" }, 400, cors);
  console.error("exos-discord: rpc failed", redactError(error));
  return json({ error: "Something went wrong.", reason: "server" }, 500, cors);
}

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(env("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

function redirect(to: string): Response {
  return new Response(null, { status: 302, headers: { location: to, "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } });
}
