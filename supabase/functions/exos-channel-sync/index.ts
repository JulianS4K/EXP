// exos-channel-sync — one Exos event, mirrored 1-1 on Eventbrite and Luma
// (mig 20261019090000; docs/organizer-guide.md "Selling on Eventbrite and Luma
// too"). Exos is the source.
//
// Each pass, per mirror due (exos_channel_claim):
//   1. Details: create the event there (or keep the linked one) with Exos's
//      name, time, venue, description and ticket types with prices; publish
//      when Exos publishes; on an Exos cancel, cancel on Eventbrite (refused
//      there once it has orders) or close registration on Luma. Skipped when
//      nothing changed (content hash).
//   2. Luma only: the shared count. Read the guest list, count tickets per
//      ticket type, apply them to Exos (exos_luma_inventory_apply), and set
//      each Luma ticket type's capacity to its target. (Eventbrite's count is
//      exos-eventbrite-sync's inventory pass, which picks up the classes this
//      creates.)
//   3. Luma-primary events: add queued comp guests on Luma.
// Writes go only to _shared/channels/{eventbrite,luma}.ts's allowlists, and
// only when the org's switch AND the operator's flag are on
// (EXOS_EVENTBRITE_WRITES / EXOS_LUMA_WRITES = "on"); otherwise the pass
// records the plan (dry run) and nothing leaves Exos.
//
// Routes (POST, under /functions/v1/exos-channel-sync):
//   /push {event}   owner / manager: run the event's mirrors now.
//   /cron           X-Cron-Secret: due mirrors within a time budget (every 2 min).
// Deploy with --no-verify-jwt (CORS preflight; /cron is gated by the secret).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET,
//      EXOS_REDIRECT_ORIGINS, EXOS_EVENTBRITE_WRITES, EXOS_LUMA_WRITES,
//      EXOS_LUMA_ENABLED (Luma is off unless "on": its mirrors wait, no Luma call is made).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { contentHash, lumaEnabled, makeIo, mirrorEvent, type StepRecord, type SyncResult, writesLive } from "../_shared/channels/model.ts";
import { EB_API, EB_WRITES, ebStandIn, syncEventbrite } from "../_shared/channels/eventbrite.ts";
import { capacityUpdate, compBody, LUMA_BASE, LUMA_WRITES, lumaStandIn, lumaTicketCounts, syncLuma } from "../_shared/channels/luma.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CRON_BUDGET_MS = 100_000;

interface Claimed { event_id: string; provider: "eventbrite" | "luma"; org_id: string; lease_id: string; change_seq: number; payload: any }

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "cron") {
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    return json(await run(sb, null, Date.now() + CRON_BUDGET_MS));
  }

  if (route === "push") {
    const auth = req.headers.get("Authorization") ?? "";
    if (!/^Bearer\s+\S+/.test(auth)) return json({ error: "sign in first" }, 401, cors);
    const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: who } = await sbUser.auth.getUser();
    if (!who.user) return json({ error: "sign in first" }, 401, cors);
    const body = await req.json().catch(() => ({}));
    const event = String(body?.event ?? "");
    if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
    // The status RPC checks the caller's role.
    const st = await sbUser.rpc("exos_channel_status", { p_event_id: event });
    if (st.error) return json({ error: "Not allowed." }, 403, cors);
    if ((st.data as { can_manage?: boolean })?.can_manage !== true) return json({ error: "Owner or manager only." }, 403, cors);
    return json(await run(sb, event, Date.now() + 25_000), 200, cors);
  }
  return json({ error: "not found" }, 404, cors);
});

async function run(sb: SupabaseClient, event: string | null, deadline: number) {
  const { data, error } = await sb.rpc("exos_channel_claim", { p_limit: event ? 2 : 20, p_event_id: event });
  if (error) {
    console.error("exos-channel-sync: claim failed", redactError(error));
    return { ok: false };
  }
  const out: unknown[] = [];
  for (const c of (data ?? []) as Claimed[]) {
    if (Date.now() > deadline) {
      await mark(sb, c, { state: "error", error: "out of time; retrying" });
      continue;
    }
    try {
      out.push({ event: c.event_id, provider: c.provider, ...(await pass(sb, c)) });
    } catch (err) {
      const msg = redactError(err).slice(0, 200);
      console.error("exos-channel-sync: pass failed", c.provider, msg);
      await mark(sb, c, { state: "error", error: msg });
      out.push({ event: c.event_id, provider: c.provider, state: "error" });
    }
  }
  return { ok: true, passes: out.length, results: out };
}

function mark(sb: SupabaseClient, c: Claimed, result: SyncResult) {
  return sb.rpc("exos_channel_mark", {
    p_event_id: c.event_id, p_provider: c.provider, p_lease: c.lease_id, p_change_seq: c.change_seq, p_result: result,
  });
}

async function pass(sb: SupabaseClient, c: Claimed) {
  const p = c.payload ?? {};
  if (c.provider === "luma" && !lumaEnabled(Deno.env.get("EXOS_LUMA_ENABLED"))) {
    await mark(sb, c, { state: "error", error: "Luma is switched off for now" });
    return { state: "off" };
  }
  const ev = mirrorEvent(p);
  if (!ev) {
    await mark(sb, c, { state: "error", error: "the event needs a name and a start time" });
    return { state: "error" };
  }
  const secret = typeof p.secret === "string" ? p.secret : "";
  if (!secret) {
    await mark(sb, c, { state: "error", error: c.provider === "eventbrite" ? "connect Eventbrite first" : "connect Luma first" });
    return { state: "error" };
  }
  const flag = Deno.env.get(c.provider === "eventbrite" ? "EXOS_EVENTBRITE_WRITES" : "EXOS_LUMA_WRITES");
  const live = writesLive(p.writes_enabled, flag);
  const steps: StepRecord[] = [];
  const io = c.provider === "eventbrite"
    ? makeIo({ fetch, base: EB_API, headers: { Authorization: `Bearer ${secret}` }, live, allowed: EB_WRITES, steps, standIn: ebStandIn })
    : makeIo({ fetch, base: LUMA_BASE, headers: { "x-luma-api-key": secret }, live, allowed: LUMA_WRITES, steps, standIn: lumaStandIn });
  const hash = await contentHash(ev);
  const m = p.mirror ?? {};

  // 1. Details (skipped when Exos has nothing new for this platform).
  let result: SyncResult;
  if (m.external_id && m.status === "synced" && m.last_hash === hash) {
    result = { state: "synced", hash };
  } else {
    result = c.provider === "eventbrite" ? await syncEventbrite(io, ev, p, steps, hash) : await syncLuma(io, ev, p, steps, hash);
  }
  const marked = await mark(sb, c, result);
  if (marked.error) throw marked.error;
  if (c.provider !== "luma") return { state: result.state };

  // 2. Luma's shared count, and 3. comps (the event must exist there).
  const lumaId = result.external_id ?? m.external_id;
  if (!lumaId || result.state === "error") return { state: result.state };
  const inv = await lumaInventory(sb, io, c.event_id, lumaId, live);
  const comps = p.event?.primary_source === "luma" ? await lumaComps(sb, io, c.event_id, lumaId, live) : 0;
  return { state: result.state, inventory: inv, comps };
}

async function lumaInventory(sb: SupabaseClient, io: ReturnType<typeof makeIo>, eventId: string, lumaId: string, live: boolean) {
  const readAt = new Date().toISOString();
  const { counts, complete, error } = await lumaTicketCounts(io, lumaId);
  if (!complete) return { ok: false, error };
  const { data: links } = await sb.from("exos_luma_ticket_links")
    .select("luma_ticket_type_id, luma_capacity").eq("event_id", eventId).eq("luma_event_id", lumaId).eq("active", true);
  const current = new Map<string, number | null>(((links ?? []) as any[]).map((l) => [l.luma_ticket_type_id, l.luma_capacity]));
  const rows = [...current.keys()].map((id) => ({ id, sold: counts.get(id) ?? 0 }));
  const { data, error: e2 } = await sb.rpc("exos_luma_inventory_apply", { p_event_id: eventId, p_counts: rows, p_read_at: readAt });
  if (e2) return { ok: false, error: "apply failed" };
  let sent = 0;
  for (const r of (data ?? []) as any[]) {
    if (r.skip_reason) continue;
    const body = capacityUpdate(r.luma_ticket_type_id, r.target_capacity, current.get(r.luma_ticket_type_id) ?? null);
    if (!body) continue;
    const steps: StepRecord[] = [];
    const res = await io.req("POST", "/v1/events/ticket-types/update", body);
    await sb.rpc("exos_luma_inventory_ack", {
      p_event_id: eventId, p_ticket_type_id: r.luma_ticket_type_id,
      p_plan: { dry_run: !live, path: "/v1/events/ticket-types/update", body, steps },
      p_sent: live, p_capacity: r.target_capacity, p_error: res.ok ? null : `Luma: ${res.error ?? "failed"}`,
    });
    if (live && res.ok) sent++;
  }
  return { ok: true, sent };
}

async function lumaComps(sb: SupabaseClient, io: ReturnType<typeof makeIo>, eventId: string, lumaId: string, live: boolean) {
  const { data } = await sb.rpc("exos_luma_comp_claim", { p_event_id: eventId, p_limit: 50 });
  const rows = (data ?? []) as { id: string; email: string; name: string | null; send_email: boolean; luma_ticket_type_id: string | null }[];
  let added = 0;
  for (const r of rows) {
    if (!r.luma_ticket_type_id) {
      await sb.rpc("exos_luma_comp_mark", { p_id: r.id, p_status: "retry", p_error: "that ticket type isn't on Luma yet" });
      continue;
    }
    const res = await io.req("POST", "/v1/events/guests/add", compBody(lumaId, r.luma_ticket_type_id, [{ email: r.email, name: r.name }], r.send_email));
    const skipped = Array.isArray(res.body?.skipped) && res.body.skipped.some((s: any) => String(s?.email ?? "").toLowerCase() === r.email);
    const status = !live ? "planned" : !res.ok ? "retry" : skipped ? "skipped" : "added";
    await sb.rpc("exos_luma_comp_mark", {
      p_id: r.id, p_status: status,
      p_error: !res.ok ? `Luma: ${res.error ?? "failed"}` : skipped ? "Luma skipped this guest (unsubscribed or blocked)" : null,
    });
    if (status === "added") added++;
  }
  return added;
}

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } });
}
