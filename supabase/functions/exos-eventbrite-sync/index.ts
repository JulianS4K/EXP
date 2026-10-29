// exos-eventbrite-sync — Exos Door: keep an Exos door event in step with an
// Eventbrite event's attendees, read only (mig 20261013100000;
// docs/marketplace/eventbrite.md; docs/organizer-guide.md "Tickets sold
// somewhere else").
//
// Eventbrite is READ (CLAUDE.md: upstream ticketing APIs are read-only):
// every read goes through _shared/eventbrite/client.ts ebGet, which sends GET
// only. The one exception is the inventory sync's capacity update on an
// organizer's existing, mapped ticket class (_shared/eventbrite/writer.ts,
// dry run unless the org's switch and EXOS_EVENTBRITE_WRITES=on). No
// check-ins are written back, no webhooks are registered, nothing is
// created, bought or held.
//
// Routes (under /functions/v1/exos-eventbrite-sync), JSON in and out:
//   POST /connect    {org, token}   owner / manager. Checks the private token
//        with GET /users/me/, then stores it in Vault (exos_eventbrite_connect).
//        Answers {connected, account_name}. The pasted-token path: it stays
//        for installs without an Eventbrite OAuth app (and for the pilot);
//        "Connect Eventbrite" (exos-eventbrite-oauth, mig 20261029140000)
//        stores its OAuth token in the same Vault secret.
//   POST /disconnect {org}          owner / manager. Token deleted, links removed,
//        imported guests and the connection log kept (mig 20261029140000).
//        Local only: Eventbrite documents no token revocation endpoint, so
//        nothing is sent there (the organizer can also remove the app on
//        Eventbrite; docs/eventbrite-app.md).
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
// Inventory (mig 20261014110000; one shared count across Exos and Eventbrite):
//   GET  /ticket-classes?event=<id> owner / manager. The linked Eventbrite
//        event's ticket classes and the Exos ticket types, for mapping.
//   POST /map  {event, ticket_class_id, ticket_class_name, tier|null}
//        owner / manager. Maps an EXISTING Eventbrite ticket class to an Exos
//        ticket type (null: unmap). Exos never creates ticket classes.
//   POST /writes {org, on}           owner. The org's switch for sending.
//   Every 2 minutes for each link with mappings (exos_eventbrite_inventory_due,
//   apart from the attendee cadence) and after Sync now: read the ticket
//   classes, count Eventbrite sales against Exos (exos_eventbrite_inventory_apply), then set
//   each class's capacity to its target with _shared/eventbrite/writer.ts,
//   the one write Exos makes there. Dry run (plan recorded only) unless the
//   org's switch AND EXOS_EVENTBRITE_WRITES=on.
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
//      CRON_SECRET, EXOS_REDIRECT_ORIGINS (CORS allowlist for the SPA),
//      EXOS_EVENTBRITE_WRITES ("on" lets orgs that switched it on send capacity).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import {
  type ApplyRow, type ApplyState, type ClaimedLink, ebErrorMessage, isEbId, isTokenShaped, listTicketClasses,
  listUpcomingEvents, readEvent, type SyncOutcome, syncLink, unshareableReason, whoAmI,
} from "../_shared/eventbrite/client.ts";
import { planCapacity, planRecord, sendCapacity, writesLive } from "../_shared/eventbrite/writer.ts";

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

    if (route === "ticket-classes" && req.method === "GET") {
      const event = url.searchParams.get("event") ?? "";
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      const org = await eventOrg(sb, event);
      if (!org) return json({ error: "event not found" }, 404, cors);
      const tok = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
      if (tok.error) return rpcError(tok.error, cors);
      if (typeof tok.data !== "string") return json({ error: "Connect Eventbrite first.", reason: "not_connected" }, 409, cors);
      const { data: lk } = await sb.from("exos_eventbrite_links").select("eb_event_id").eq("event_id", event).maybeSingle();
      const ebEvent = (lk as { eb_event_id?: string } | null)?.eb_event_id;
      if (!ebEvent) return json({ error: "Link an Eventbrite event first.", reason: "not_linked" }, 409, cors);
      const r = await listTicketClasses(fetch, tok.data, ebEvent);
      if (!r.ok) return json({ error: ebErrorMessage(r), reason: "eventbrite" }, 502, cors);
      return json({ ticket_classes: r.body }, 200, cors);
    }

    if (route === "map" && req.method === "POST") {
      const event = String(body?.event ?? "");
      const cls = String(body?.ticket_class_id ?? "");
      const tier = body?.tier == null ? null : String(body.tier);
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      if (!isEbId(cls)) return json({ error: "Pick an Eventbrite ticket class.", reason: "bad_class" }, 400, cors);
      if (tier !== null && !UUID.test(tier)) return json({ error: "Pick an Exos ticket type.", reason: "bad_tier" }, 400, cors);
      let name = typeof body?.ticket_class_name === "string" ? body.ticket_class_name.slice(0, 200) : null;
      if (tier !== null) {
        // Only an existing, shareable class of the linked Eventbrite event.
        const org = await eventOrg(sb, event);
        if (!org) return json({ error: "event not found" }, 404, cors);
        const tok = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
        if (tok.error) return rpcError(tok.error, cors);
        if (typeof tok.data !== "string") return json({ error: "Connect Eventbrite first.", reason: "not_connected" }, 409, cors);
        const { data: lk } = await sb.from("exos_eventbrite_links").select("eb_event_id").eq("event_id", event).maybeSingle();
        const ebEvent = (lk as { eb_event_id?: string } | null)?.eb_event_id;
        if (!ebEvent) return json({ error: "Link an Eventbrite event first.", reason: "not_linked" }, 409, cors);
        const list = await listTicketClasses(fetch, tok.data, ebEvent);
        if (!list.ok || !list.body) return json({ error: ebErrorMessage(list), reason: "eventbrite" }, 502, cors);
        const found = list.body.find((c) => c.id === cls);
        if (!found) return json({ error: "That ticket isn't on the linked Eventbrite event.", reason: "bad_class" }, 400, cors);
        const why = unshareableReason(found);
        if (why) return json({ error: why, reason: "unshareable" }, 400, cors);
        name = found.name ?? name;
      }
      const r = await sb.rpc("exos_eventbrite_map_ticket", {
        p_event_id: event, p_user_id: user, p_eb_ticket_class_id: cls, p_eb_ticket_class_name: name, p_tier_id: tier,
      });
      if (r.error) return rpcError(r.error, cors);
      return json(r.data, 200, cors);
    }

    if (route === "writes" && req.method === "POST") {
      const org = String(body?.org ?? "");
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const r = await sb.rpc("exos_eventbrite_set_writes", { p_org_id: org, p_user_id: user, p_on: body?.on === true });
      if (r.error) return rpcError(r.error, cors);
      return json({ writes_enabled: r.data === true, live: writesLive(r.data === true, Deno.env.get("EXOS_EVENTBRITE_WRITES")) }, 200, cors);
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

type ManualSync = (SyncOutcome & { inventory?: InventoryOutcome }) | { skipped: "recent" | "not_linked" } | { forbidden: true } | null;

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
  const out = await syncLink(fetch, link, applier(sb, link), { maxPages: pages, deadline: Date.now() + 40_000 });
  const inventory = await syncInventory(sb, link);
  return inventory ? { ...out, inventory } : out;
}

async function runCron(sb: SupabaseClient): Promise<Record<string, unknown>> {
  const deadline = Date.now() + CRON_BUDGET_MS;
  const c = await sb.rpc("exos_eventbrite_sync_claim", { p_limit: 10 });
  if (c.error) {
    console.error("exos-eventbrite-sync: cron claim failed", redactError(c.error));
    return { ok: false };
  }
  const links = (c.data as ClaimedLink[] | null) ?? [];
  const results: Array<Record<string, unknown>> = [];
  for (const link of links) {
    if (Date.now() >= deadline) {
      // Out of time: free the rest for the next run.
      await sb.rpc("exos_eventbrite_apply", {
        p_event_id: link.event_id, p_lease: link.lease_id, p_rows: [], p_state: "pause", p_continuation: link.continuation,
      });
      continue;
    }
    const out = await syncLink(fetch, link, applier(sb, link), { maxPages: CRON_PAGES, deadline });
    results.push({ event: link.event_id, state: out.state, rows: out.rows });
  }
  // Inventory every 2 minutes for every link with a mapping, apart from the
  // attendee cadence (which is 29 minutes until 2 days out).
  const inventory: Array<Record<string, unknown>> = [];
  if (Date.now() < deadline) {
    const due = await sb.rpc("exos_eventbrite_inventory_due", { p_limit: 20 });
    if (due.error) console.error("exos-eventbrite-sync: inventory due failed", redactError(due.error));
    for (const l of (due.data ?? []) as InventoryLink[]) {
      if (Date.now() >= deadline) break;
      const r = await syncInventory(sb, l);
      if (r) inventory.push({ event: l.event_id, ...r });
    }
  }
  return { ok: true, claimed: links.length, results, inventory };
}

/** exos_eventbrite_apply for one claimed link. A failed call returns null;
 *  syncLink then records the error with the page's own continuation. */
function applier(sb: SupabaseClient, link: ClaimedLink) {
  return async (rows: ApplyRow[], state: ApplyState, continuation: string | null, error: string | null) => {
    const r = await sb.rpc("exos_eventbrite_apply", {
      p_event_id: link.event_id, p_lease: link.lease_id, p_rows: rows, p_state: state,
      p_continuation: continuation, p_error: error,
    });
    if (r.error) {
      console.error("exos-eventbrite-sync: apply failed", redactError(r.error));
      return null;
    }
    return r.data as { ok: boolean; reason?: string; added?: number; voided?: number; restored?: number };
  };
}

// ---- Inventory ---------------------------------------------------------------

type InventoryRow = {
  eb_ticket_class_id: string; tier_id: string; eb_capacity: number | null; eb_sold: number | null;
  target_capacity: number | null; oversold: number | null; writes_enabled: boolean; skip_reason: string | null;
};
type InventoryLink = { event_id: string; eb_event_id: string; token: string };
type InventoryOutcome = { classes: number; sent: number; planned: number; failed: number; skipped: number; oversold: number };

/** One inventory pass for a link: read classes, count sales, set capacities. Null: no mappings. */
async function syncInventory(sb: SupabaseClient, link: InventoryLink): Promise<InventoryOutcome | null> {
  const { count } = await sb.from("exos_eventbrite_ticket_links").select("tier_id", { count: "exact", head: true })
    .eq("event_id", link.event_id).eq("eb_event_id", link.eb_event_id).eq("active", true);
  if (!count) return null;
  const readAt = new Date().toISOString();   // a later read wins; an older one is ignored
  const read = await listTicketClasses(fetch, link.token, link.eb_event_id);
  if (!read.ok || !read.body) {
    console.error("exos-eventbrite-sync: ticket classes not read", link.event_id, read.error ?? read.status);
    return { classes: 0, sent: 0, planned: 0, failed: 1, skipped: 0, oversold: 0 };
  }
  const applied = await sb.rpc("exos_eventbrite_inventory_apply", { p_event_id: link.event_id, p_classes: read.body, p_read_at: readAt });
  if (applied.error) {
    console.error("exos-eventbrite-sync: inventory apply failed", redactError(applied.error));
    return { classes: read.body.length, sent: 0, planned: 0, failed: 1, skipped: 0, oversold: 0 };
  }
  const out: InventoryOutcome = { classes: read.body.length, sent: 0, planned: 0, failed: 0, skipped: 0, oversold: 0 };
  const flag = Deno.env.get("EXOS_EVENTBRITE_WRITES");
  for (const row of (applied.data ?? []) as InventoryRow[]) {
    out.oversold += row.oversold ?? 0;
    if (row.skip_reason) {
      out.skipped++;
      continue;
    }
    const plan = planCapacity(link.eb_event_id, row.eb_ticket_class_id, row.eb_capacity, row.target_capacity);
    if (!plan) continue;
    const live = writesLive(row.writes_enabled, flag);
    let error: string | null = null;
    if (live) {
      const r = await sendCapacity(fetch, link.token, plan);
      if (!r.ok) error = `Eventbrite ${r.error ?? r.status}`;
    }
    const ack = await sb.rpc("exos_eventbrite_inventory_ack", {
      p_event_id: link.event_id, p_eb_ticket_class_id: row.eb_ticket_class_id, p_plan: planRecord(plan, live),
      p_sent: live, p_capacity: plan.to, p_error: error,
    });
    if (ack.error) console.error("exos-eventbrite-sync: inventory ack failed", redactError(ack.error));
    if (!live) out.planned++;
    else if (error) out.failed++;
    else out.sent++;
  }
  return out;
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
