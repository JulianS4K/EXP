// exos-event-import — "List an event you sell elsewhere" (mig 20261029170000;
// docs/organizer-guide.md; spec §7.2). Creates LINK-OUT Exos events: listed
// by Exos (event page, org page, discovery, Google / catalog / calendar
// feeds), sold only on the organizer's own checkout. Exos sells nothing for
// them (the SQL enforces it on every sell path).
//
// Upstream is READ ONLY (CLAUDE.md): Eventbrite is read through
// _shared/eventbrite/client.ts ebGet (GET only). Luma and Posh are not
// contacted at all: a pasted Luma / Posh link becomes a draft from the link
// and the organizer's own details (reading their public pages waits for the
// operator: _shared/eventImport/publicPage.ts, not called). No page is
// scraped and no organizer-supplied URL is fetched, so there is nothing for
// the SSRF guard to check; any future page read must go through
// _shared/ssrf.ts first.
//
// Routes (under /functions/v1/exos-event-import), JSON in and out:
//   GET  /eventbrite/events?org=<org>   owner / manager. The connected
//        Eventbrite account's live and upcoming events, each marked with the
//        Exos event it was already imported as.
//   POST /eventbrite/import {org, ids}  owner / manager. Up to 25 Eventbrite
//        event ids; each is read again here by id (the client sends ids only)
//        and imported (published). Re-importing one updates it.
//   POST /link {org, url, details?}     owner / manager. A pasted link, parsed
//        HERE (never a platform the client names). Eventbrite: read through
//        the API by id with the org's token, imported published. Luma / Posh:
//        a draft from `details` (name, starts_at, ends_at, timezone,
//        venue_name, street, city, region, postal, country, online,
//        price_min, price_max, currency, image_url, description).
//   POST /check {event}                 owner / manager. "Check now" (at most
//        once a minute): re-reads the source.
//   POST /cron                          X-Cron-Secret. Re-reads the due imports
//        (exos_link_out_check_claim) within a time budget. Scheduled by the
//        migration as exos-event-import-check-15min, INACTIVE (turn it on with
//        cron.alter_job, see the migration).
//
// The user routes take the Supabase JWT and verify it here; the RPCs are
// service role only and re-check the user's role against the org (or the
// event's own org). Deploy with --no-verify-jwt (CORS preflight; /cron has the
// cron secret).
//
// Token lookup: the org's Eventbrite token comes from exactly two calls,
// exos_eventbrite_token (user routes, role-checked) and the claim's token
// (_exos_eventbrite_org_token, the cron). Eventbrite OAuth (spec §7.1) swaps
// those two SQL bodies; nothing here changes.
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//      CRON_SECRET, EXOS_REDIRECT_ORIGINS (CORS allowlist for the SPA).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { ebErrorMessage, isEbId } from "../_shared/eventbrite/client.ts";
import { listImportChoices, readImportEvent, toCheckResult } from "../_shared/eventImport/eventbrite.ts";
import { parseEventUrl } from "../_shared/eventImport/urls.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Wall-clock budget for one cron run (two Eventbrite reads per event). */
const CRON_BUDGET_MS = 90_000;
const CRON_LIMIT = 40;
const MAX_IMPORT = 25;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const parts = url.pathname.replace(/\/+$/, "").split("/");
  const fnAt = parts.lastIndexOf("exos-event-import");
  const route = (fnAt >= 0 ? parts.slice(fnAt + 1) : parts.slice(-1)).join("/");
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "cron") {
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    return json(await runChecks(sb, null, null));
  }

  const user = await signedInUser(req);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};

  try {
    if (route === "eventbrite/events" && req.method === "GET") {
      const org = url.searchParams.get("org") ?? "";
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const tok = await eventbriteToken(sb, org, user);
      if ("error" in tok) return tok.error(cors);
      const r = await listImportChoices(fetch, tok.token);
      if (!r.ok || !r.body) return json({ error: ebErrorMessage(r), reason: "eventbrite" }, 502, cors);
      const { data: done } = await sb.from("exos_event_imports").select("source_event_id, event_id")
        .eq("org_id", org).eq("platform", "eventbrite").in("source_event_id", r.body.map((c) => c.id).slice(0, 500));
      const imported = new Map(((done ?? []) as Array<{ source_event_id: string; event_id: string }>).map((x) => [x.source_event_id, x.event_id]));
      return json({ events: r.body.map((c) => ({ ...c, imported_event_id: imported.get(c.id) ?? null })) }, 200, cors);
    }

    if (route === "eventbrite/import" && req.method === "POST") {
      const org = String(body?.org ?? "");
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const ids = Array.isArray(body?.ids) ? [...new Set((body.ids as unknown[]).map(String))] : [];
      if (!ids.length || ids.length > MAX_IMPORT || !ids.every(isEbId)) {
        return json({ error: `Pick 1 to ${MAX_IMPORT} Eventbrite events.`, reason: "bad_ids" }, 400, cors);
      }
      const tok = await eventbriteToken(sb, org, user);
      if ("error" in tok) return tok.error(cors);
      const results: Array<Record<string, unknown>> = [];
      for (const id of ids) results.push({ id, ...(await importEventbrite(sb, org, user, tok.token, id, "account")) });
      return json({ results }, 200, cors);
    }

    if (route === "link" && req.method === "POST") {
      const org = String(body?.org ?? "");
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      const parsed = parseEventUrl(body?.url);
      if ("error" in parsed) return json({ error: parsed.error, reason: "bad_url" }, 400, cors);
      if (parsed.platform === "eventbrite") {
        const tok = await eventbriteToken(sb, org, user);
        if ("error" in tok) return tok.error(cors);
        const r = await importEventbrite(sb, org, user, tok.token, parsed.sourceId, "link");
        return json(r, r.ok ? 200 : 400, cors);
      }
      // Luma / Posh: a draft from the link and the organizer's details.
      const d = (body?.details && typeof body.details === "object" ? body.details : {}) as Record<string, unknown>;
      const s = (k: string, max: number) => (typeof d[k] === "string" ? (d[k] as string).trim().slice(0, max) : "");
      const venueAddress = Object.fromEntries(
        (["street", "city", "region", "postal", "country"] as const).map((k) => [k, s(k, 200)]).filter(([, v]) => v),
      );
      const data = {
        source_event_id: parsed.sourceId, source_url: parsed.url, source_status: "unknown",
        name: s("name", 200), description: s("description", 20000) || null,
        starts_at: s("starts_at", 40) || null, ends_at: s("ends_at", 40) || null, timezone: s("timezone", 64) || null,
        venue_name: s("venue_name", 200) || null, venue_address: Object.keys(venueAddress).length ? venueAddress : null,
        online: d.online === true, image_url: s("image_url", 1000) || null, currency: s("currency", 3) || null,
        price_min: typeof d.price_min === "number" ? d.price_min : null,
        price_max: typeof d.price_max === "number" ? d.price_max : null,
        is_free: d.price_max === 0, ticket_types: [], publish: false,
      };
      const r = await sb.rpc("exos_link_out_import", {
        p_org_id: org, p_user_id: user, p_platform: parsed.platform, p_origin: "link", p_data: data,
      });
      if (r.error) return rpcError(r.error, cors);
      return json({ ok: true, ...(r.data as object) }, 200, cors);
    }

    if (route === "check" && req.method === "POST") {
      const event = String(body?.event ?? "");
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      const out = await runChecks(sb, event, user);
      if ("forbidden" in out) return json({ error: "Owners and managers only.", reason: "forbidden" }, 403, cors);
      return json(out, 200, cors);
    }
  } catch (err) {
    console.error("exos-event-import: failed", route, redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
  return json({ error: "not found" }, 404, cors);
});

// ---- Import ------------------------------------------------------------------

async function importEventbrite(
  sb: SupabaseClient, org: string, user: string, token: string, id: string, origin: "account" | "link",
): Promise<Record<string, unknown> & { ok: boolean }> {
  const ev = await readImportEvent(fetch, token, id, new Date(), { owned: true });
  if (ev.error === "NOT_YOUR_EVENT") {
    return { ok: false, error: "That event isn't on the connected Eventbrite account. Only your own events can be imported." };
  }
  if (!ev.ok || !ev.body) return { ok: false, error: ebErrorMessage(ev) };
  const r = await sb.rpc("exos_link_out_import", {
    p_org_id: org, p_user_id: user, p_platform: "eventbrite", p_origin: origin, p_data: { ...ev.body, publish: true },
  });
  if (r.error) {
    if (r.error.code === "42501") return { ok: false, error: "Owners and managers only." };
    if (r.error.code === "22023" || r.error.code === "23505") return { ok: false, error: cleanMsg(r.error.message) };
    console.error("exos-event-import: import failed", redactError(r.error));
    return { ok: false, error: "Exos couldn't save the event." };
  }
  return { ok: true, ...(r.data as object) };
}

// ---- Re-check ------------------------------------------------------------------

type Claimed = { event_id: string; platform: string; source_event_id: string; token: string; lease_id: string };

/** The cron (event null) or "Check now" for one event. */
async function runChecks(sb: SupabaseClient, event: string | null, user: string | null): Promise<Record<string, unknown>> {
  const deadline = Date.now() + (event ? 30_000 : CRON_BUDGET_MS);
  const c = await sb.rpc("exos_link_out_check_claim", { p_limit: event ? 1 : CRON_LIMIT, p_event_id: event, p_user_id: user });
  if (c.error) {
    if (c.error.code === "42501") return { forbidden: true };
    console.error("exos-event-import: claim failed", redactError(c.error));
    return { ok: false };
  }
  const rows = (c.data ?? []) as Claimed[];
  const results: Array<Record<string, unknown>> = [];
  for (const row of rows) {
    if (Date.now() >= deadline) {
      // Out of time: the lease lapses in 2 minutes and the next run takes it.
      results.push({ event: row.event_id, skipped: "budget" });
      continue;
    }
    const ev = row.platform === "eventbrite" ? await readImportEvent(fetch, row.token, row.source_event_id) : null;
    const ok = !!ev?.ok && !!ev.body;
    const a = await sb.rpc("exos_link_out_check_apply", {
      p_event_id: row.event_id, p_lease: row.lease_id,
      p_result: ok ? toCheckResult(ev!.body!) : null,
      p_error: ok ? null : ev ? ebErrorMessage(ev) : "This platform can't be re-checked yet.",
    });
    if (a.error) console.error("exos-event-import: apply failed", redactError(a.error));
    results.push({ event: row.event_id, ...((a.data ?? {}) as object), read: ok });
  }
  if (event && !rows.length) return { ok: true, skipped: "recent" };
  return { ok: true, checked: rows.length, results };
}

// ---- Helpers -------------------------------------------------------------------

type TokenResult = { token: string } | { error: (cors: Record<string, string>) => Response };

/** The org's Eventbrite token for a signed-in owner / manager (the user-route half of the one token lookup). */
async function eventbriteToken(sb: SupabaseClient, org: string, user: string): Promise<TokenResult> {
  const tok = await sb.rpc("exos_eventbrite_token", { p_org_id: org, p_user_id: user });
  if (tok.error) return { error: (cors) => rpcError(tok.error!, cors) };
  if (typeof tok.data !== "string") {
    return { error: (cors) => json({ error: "Connect Eventbrite first (Integrations).", reason: "not_connected" }, 409, cors) };
  }
  return { token: tok.data };
}

function cleanMsg(m: string | undefined): string {
  return (m ?? "").replace(/^exos_\w+: /, "");
}

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  if (error.code === "42501") return json({ error: "Owners and managers only.", reason: "forbidden" }, 403, cors);
  if (error.code === "23505" || error.code === "22023") return json({ error: cleanMsg(error.message), reason: "invalid" }, 400, cors);
  console.error("exos-event-import: rpc failed", redactError(error));
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
