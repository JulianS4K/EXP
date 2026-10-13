// exos-eventbrite-sync — Exos Door: keep an Exos door event in step with an
// Eventbrite event's attendees, read only (mig 20261013100000;
// docs/marketplace/eventbrite.md; docs/organizer-guide.md "Tickets sold
// somewhere else").
//
// Eventbrite is only READ (CLAUDE.md: upstream ticketing APIs are
// read-only): every request goes through _shared/eventbrite/client.ts ebGet,
// which sends GET only. No check-ins are written back, no webhooks are
// registered, nothing is bought or held.
//
// Routes (under /functions/v1/exos-eventbrite-sync), JSON in and out:
//   POST /connect    {org, token}   owner / manager. Checks the private token
//        with GET /users/me/, then stores it in Vault (exos_eventbrite_connect).
//        Answers {connected, account_name}.
//   POST /disconnect {org}          owner / manager. Token deleted, links removed.
//   GET  /events?org=<org id>       owner / manager. The account's current and
//        future events (GET /users/me/organizations/ + /organizations/{id}/events/).
//   POST /link       {event, eb_event}  owner / manager. Reads the Eventbrite
//        event with the org's token (GET /events/{id}/), links it, and runs
//        the first sync. Answers {linked, sync}.
//   POST /unlink     {event}        owner / manager.
//   POST /sync       {event}        door staff of the event ("Sync now"; at most
//        every 20 s). Answers {sync}.
//   POST /cron                      X-Cron-Secret. Syncs the links that are due
//        (exos_eventbrite_sync_claim), within a time budget. Scheduled every 2
//        minutes by the migration.
//
// The user routes take the Supabase JWT in Authorization and verify it here;
// the RPCs they call are service role only and re-check the user's role.
// Deploy with --no-verify-jwt (the CORS preflight carries no JWT; /cron is
// gated by the cron secret).
//
// The token never leaves the server: it is not returned, not logged, and is
// sent only to www.eventbriteapi.com in the Authorization header.
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//      CRON_SECRET, EXOS_REDIRECT_ORIGINS (CORS allowlist for the SPA).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import {
  type ApplyRow, type ApplyState, type ClaimedLink, ebErrorMessage, isEbId, isTokenShaped, listUpcomingEvents,
  readEvent, type SyncOutcome, syncLink, whoAmI,
} from "../_shared/eventbrite/client.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Wall-clock budget for one cron run (the platform limit is higher). */
const CRON_BUDGET_MS = 100_000;
/** Pages of 50 attendees per link per run: a big first sync spreads over runs. */
const CRON_PAGES = 10;
const MANUAL_PAGES = 20;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "cron") {
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    return json(await runCron(sb));
  }

  const user = await signedInUser(req);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};

  try {
    if (route === "connect" && req.method === "POST") {
      const org = String(body?.org ?? "");
      const token = typeof body?.token === "string" ? body.token.trim() : "";
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      if (!isTokenShaped(token)) {
        return json({ error: "That doesn't look like an Eventbrite private token.", reason: "bad_token" }, 400, cors);
      }
      // Role first, so a non-manager can't use this to test tokens.
      const role = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
      if (role.error) return rpcError(role.error, cors);
      const me = await whoAmI(fetch, token);
      if (!me.ok || !me.body) {
        return json({ error: ebErrorMessage(me), reason: "eventbrite" }, me.status === 401 ? 400 : 502, cors);
      }
      const r = await sb.rpc("exos_eventbrite_connect", {
        p_org_id: org, p_user_id: user, p_token: token, p_account_name: me.body.name,
      });
      if (r.error) return rpcError(r.error, cors);
      return json(r.data, 200, cors);
    }

    if (route === "disconnect" && req.method === "POST") {
      const org = String(body?.org ?? "");
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const r = await sb.rpc("exos_eventbrite_disconnect", { p_org_id: org, p_user_id: user });
      if (r.error) return rpcError(r.error, cors);
      return json(r.data, 200, cors);
    }

    if (route === "events" && req.method === "GET") {
      const org = url.searchParams.get("org") ?? "";
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const tok = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
      if (tok.error) return rpcError(tok.error, cors);
      if (typeof tok.data !== "string") return json({ error: "Connect Eventbrite first.", reason: "not_connected" }, 409, cors);
      const r = await listUpcomingEvents(fetch, tok.data);
      if (!r.ok) return json({ error: ebErrorMessage(r), reason: "eventbrite" }, 502, cors);
      return json({ events: r.body }, 200, cors);
    }

    if (route === "link" && req.method === "POST") {
      const event = String(body?.event ?? "");
      const ebEvent = String(body?.eb_event ?? "");
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      if (!isEbId(ebEvent)) return json({ error: "Pick an Eventbrite event.", reason: "bad_eb_event" }, 400, cors);
      const org = await eventOrg(sb, event);
      if (!org) return json({ error: "event not found" }, 404, cors);
      const tok = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
      if (tok.error) return rpcError(tok.error, cors);
      if (typeof tok.data !== "string") return json({ error: "Connect Eventbrite first.", reason: "not_connected" }, 409, cors);
      const ev = await readEvent(fetch, tok.data, ebEvent);
      if (!ev.ok || !ev.body) return json({ error: ebErrorMessage(ev), reason: "eventbrite" }, 502, cors);
      const r = await sb.rpc("exos_eventbrite_link", {
        p_event_id: event, p_user_id: user, p_eb_event_id: ev.body.id, p_eb_event_name: ev.body.name,
      });
      if (r.error) return rpcError(r.error, cors);
      const sync = await syncOne(sb, event, user, MANUAL_PAGES);
      return json({ ...(r.data as object), sync }, 200, cors);
    }

    if (route === "unlink" && req.method === "POST") {
      const event = String(body?.event ?? "");
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      const r = await sb.rpc("exos_eventbrite_unlink", { p_event_id: event, p_user_id: user });
      if (r.error) return rpcError(r.error, cors);
      return json(r.data, 200, cors);
    }

    if (route === "sync" && req.method === "POST") {
      const event = String(body?.event ?? "");
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      const sync = await syncOne(sb, event, user, MANUAL_PAGES);
      if (sync && "forbidden" in sync) return json({ error: "door staff only" }, 403, cors);
      return json({ sync }, 200, cors);
    }
  } catch (err) {
    console.error("exos-eventbrite-sync: failed", route, redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
  return json({ error: "not found" }, 404, cors);
});

// ---- Sync ------------------------------------------------------------------

type ManualSync = SyncOutcome | { skipped: "recent" | "not_linked" } | { forbidden: true } | null;

/** "Sync now" (or the first sync after linking) for one event. */
async function syncOne(sb: SupabaseClient, event: string, user: string, pages: number): Promise<ManualSync> {
  const c = await sb.rpc("exos_eventbrite_sync_claim", { p_event_id: event, p_user_id: user, p_limit: 1 });
  if (c.error) {
    if (c.error.code === "42501") return { forbidden: true };
    console.error("exos-eventbrite-sync: claim failed", redactError(c.error));
    return null;
  }
  const link = (c.data as ClaimedLink[] | null)?.[0];
  if (!link) {
    const linked = await sb.from("exos_eventbrite_links").select("event_id").eq("event_id", event).maybeSingle();
    return { skipped: linked.data ? "recent" : "not_linked" };
  }
  return await syncLink(fetch, link, applier(sb, link.event_id), { maxPages: pages, deadline: Date.now() + 40_000 });
}

async function runCron(sb: SupabaseClient): Promise<Record<string, unknown>> {
  const deadline = Date.now() + CRON_BUDGET_MS;
  const c = await sb.rpc("exos_eventbrite_sync_claim", { p_limit: 10 });
  if (c.error) {
    console.error("exos-eventbrite-sync: cron claim failed", redactError(c.error));
    return { ok: false };
  }
  const links = (c.data as ClaimedLink[] | null) ?? [];
  const results: Array<{ event: string; state: string; rows: number }> = [];
  for (const link of links) {
    if (Date.now() >= deadline) {
      // Out of time: free the rest for the next run.
      await sb.rpc("exos_eventbrite_apply", {
        p_event_id: link.event_id, p_rows: [], p_state: "pause", p_continuation: link.continuation,
      });
      continue;
    }
    const out = await syncLink(fetch, link, applier(sb, link.event_id), { maxPages: CRON_PAGES, deadline });
    results.push({ event: link.event_id, state: out.state, rows: out.rows });
  }
  return { ok: true, claimed: links.length, results };
}

function applier(sb: SupabaseClient, event: string) {
  return async (rows: ApplyRow[], state: ApplyState, continuation: string | null, error: string | null) => {
    const r = await sb.rpc("exos_eventbrite_apply", {
      p_event_id: event, p_rows: rows, p_state: state, p_continuation: continuation, p_error: error,
    });
    if (r.error) {
      console.error("exos-eventbrite-sync: apply failed", redactError(r.error));
      // Free the link and keep the cursor; the next run retries.
      await sb.rpc("exos_eventbrite_apply", {
        p_event_id: event, p_rows: [], p_state: "error", p_continuation: continuation,
        p_error: "Exos couldn't save the attendees; retrying.",
      });
      return null;
    }
    return r.data as { ok: boolean; added?: number; voided?: number; restored?: number };
  };
}

// ---- Helpers ---------------------------------------------------------------

async function eventOrg(sb: SupabaseClient, event: string): Promise<string | null> {
  const { data } = await sb.from("exos_events").select("org_id").eq("id", event).maybeSingle();
  return (data as { org_id?: string } | null)?.org_id ?? null;
}

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = (error.message ?? "").replace(/^exos_eventbrite_\w+: /, "");
  if (error.code === "42501") return json({ error: "Owners and managers only.", reason: "forbidden" }, 403, cors);
  if (error.code === "23505" || error.code === "22023") return json({ error: msg, reason: "invalid" }, 400, cors);
  console.error("exos-eventbrite-sync: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
}

async function signedInUser(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data } = await sbUser.auth.getUser();
  return data.user?.id ?? null;
}

/** CORS for the SPA's fetch calls: only allow-listed origins are echoed. */
function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}
