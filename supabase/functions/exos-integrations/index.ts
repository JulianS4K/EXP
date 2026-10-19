// exos-integrations — bring-your-own credentials and the pretix / hi.events / Luma
// ticket-backend sync (migs 20261016090000, 20261016100000; docs/self-hosting.md,
// docs/organizer-guide.md "Selling on another platform").
//
// Every call to a provider is a READ (CLAUDE.md: upstream ticketing APIs are
// read-only). pretix: orders + items with the org's API token. hi.events: a
// check-in list's public attendee feed. Luma: guests with the calendar's API
// key. Twilio / Telnyx: an account read to
// check the credentials (sending is the SMS drain's job, with consent).
// Organizer-supplied addresses go through the SSRF guard; redirects are not
// followed. Secrets never leave the server.
//
// Routes (POST JSON, under /functions/v1/exos-integrations):
//   /test  {org, provider}           owner / manager / finance: checks the saved
//          credentials, marks the integration connected / error.
//   /link  {event, provider, ref}    owner / manager: checks the pretix event /
//          hi.events check-in list / Luma event, links it, runs the first sync.
//   /sync  {event}                   door staff / owner / manager: "Sync now".
//   /verify-domain {org, domain}     owner / manager: checks the TXT record
//          _exos-verify.<domain> for the domain's token (mig 20261016130000).
//   /cron                            X-Cron-Secret: due links, within a budget.
// Deploy with --no-verify-jwt (CORS preflight; /cron is gated by the secret).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET,
//      EXOS_REDIRECT_ORIGINS, EXOS_LUMA_ENABLED (Luma is off unless "on": no Luma call is made).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { urlIsBlocked } from "../_shared/ssrf.ts";
import { baseUrl, SLUG } from "../_shared/backends/rows.ts";
import { cursorString, parseCursor, pretixItems, pretixOrdersPage } from "../_shared/backends/pretix.ts";
import { hiEventsAttendeesPage, hiEventsList } from "../_shared/backends/hievents.ts";
import { testProvider } from "../_shared/backends/providers.ts";
import { lumaEvent, lumaGuestsPage } from "../_shared/backends/luma.ts";

// Luma is plugged in but off until the operator sets EXOS_LUMA_ENABLED=on: no Luma API call is made.
const lumaOn = () => Deno.env.get("EXOS_LUMA_ENABLED") === "on";
const LUMA_OFF = "Luma is switched off for now.";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CRON_BUDGET_MS = 100_000;
const PAGES_PER_RUN = 10;
const BACKENDS = ["pretix", "hievents", "luma"];
const PROVIDER_NAME: Record<string, string> = { pretix: "pretix", hievents: "hi.events", luma: "Luma" };

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
    return json(await runCron(sb));
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return json({ error: "sign in first" }, 401, cors);
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: who } = await sbUser.auth.getUser();
  if (!who.user) return json({ error: "sign in first" }, 401, cors);
  const body = await req.json().catch(() => ({}));

  try {
    if (route === "test") {
      const org = String(body?.org ?? "");
      const provider = String(body?.provider ?? "");
      if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
      // The list RPC checks the caller's role (owner / manager / finance).
      const list = await sbUser.rpc("exos_list_integrations", { p_org_id: org });
      if (list.error) return rpcError(list.error, cors);
      if (!(list.data as { provider: string }[]).some((r) => r.provider === provider)) {
        return json({ error: "Save the integration first." }, 404, cors);
      }
      const cfg = await sb.rpc("exos_integration_config", { p_org_id: org, p_provider: provider });
      if (cfg.error || !cfg.data) return json({ error: "Not found." }, 404, cors);
      const c = cfg.data as { config: Record<string, unknown>; secret: string | null };
      if (provider === "luma" && !lumaOn()) return json({ ok: null, account_name: null, error: LUMA_OFF }, 200, cors);
      const res = await testProvider(fetch, provider, c.config ?? {}, c.secret ?? null, (u) => urlIsBlocked(u));
      if (res.ok !== null) {
        await sb.rpc("exos_integration_mark", {
          p_org_id: org, p_provider: provider, p_ok: res.ok, p_error: res.error ?? null, p_account_name: res.name ?? null,
        });
      }
      return json({ ok: res.ok, account_name: res.name ?? null, error: res.error ?? null }, 200, cors);
    }

    if (route === "link") {
      const event = String(body?.event ?? "");
      const provider = String(body?.provider ?? "");
      const ref = typeof body?.ref === "string" ? body.ref.trim() : "";
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      if (!BACKENDS.includes(provider)) return json({ error: "pretix, hievents or luma" }, 400, cors);
      if (provider === "luma" && !lumaOn()) return json({ error: LUMA_OFF }, 400, cors);
      if (!SLUG.test(ref)) return json({ error: "That id doesn't look right." }, 400, cors);
      const org = await eventOrg(sb, event);
      if (!org) return json({ error: "event not found" }, 404, cors);
      const check = await checkRef(sb, org, provider, ref);
      if (!check.ok) return json({ error: check.error }, 400, cors);
      // Luma accepts the public event link too; the link stores the evt- id it resolves to.
      const r = await sbUser.rpc("exos_backend_link", { p_event_id: event, p_provider: provider, p_ref: check.id ?? ref, p_name: check.name ?? null });
      if (r.error) return rpcError(r.error, cors);
      const sync = await syncOne(sb, event);
      return json({ ...(r.data as object), sync }, 200, cors);
    }

    if (route === "sync") {
      const event = String(body?.event ?? "");
      if (!UUID.test(event)) return json({ error: "missing or bad event" }, 400, cors);
      // The status RPC checks the caller is door staff / owner / manager.
      const st = await sbUser.rpc("exos_backend_status", { p_event_id: event });
      if (st.error) return rpcError(st.error, cors);
      return json({ sync: await syncOne(sb, event) }, 200, cors);
    }

    if (route === "verify-domain") {
      const org = String(body?.org ?? "");
      const domain = String(body?.domain ?? "").trim().toLowerCase();
      if (!UUID.test(org) || !/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(domain)) {
        return json({ error: "missing or bad org / domain" }, 400, cors);
      }
      // The list RPC checks owner / manager.
      const list = await sbUser.rpc("exos_list_org_domains", { p_org_id: org });
      if (list.error) return rpcError(list.error, cors);
      const tok = await sb.rpc("exos_org_domain_token", { p_org_id: org, p_domain: domain });
      if (tok.error || typeof tok.data !== "string") return json({ error: "Add the domain first." }, 404, cors);
      const found = await txtRecords(`_exos-verify.${domain}`);
      const ok = found.includes(tok.data);
      const error = ok ? null : found.length ? "The TXT record is there but has a different value." : "No TXT record found yet (DNS can take an hour).";
      await sb.rpc("exos_mark_org_domain", { p_domain: domain, p_ok: ok, p_error: error });
      return json({ ok, error }, 200, cors);
    }

    return json({ error: "not found" }, 404, cors);
  } catch (err) {
    console.error("exos-integrations failed", redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
});

async function txtRecords(name: string): Promise<string[]> {
  try {
    const recs = await Deno.resolveDns(name, "TXT");
    return recs.map((chunks) => chunks.join("").trim());
  } catch {
    return [];
  }
}

interface Claimed { event_id: string; org_id: string; provider: string; external_ref: string; sync_cursor: string | null; lease_id: string }

async function providerConfig(sb: SupabaseClient, org: string, provider: string) {
  const { data } = await sb.rpc("exos_integration_config", { p_org_id: org, p_provider: provider });
  return data as { config: Record<string, unknown>; secret: string | null } | null;
}

async function checkRef(sb: SupabaseClient, org: string, provider: string, ref: string): Promise<{ ok: boolean; id?: string; name?: string; error?: string }> {
  const c = await providerConfig(sb, org, provider);
  if (!c) return { ok: false, error: `Connect ${PROVIDER_NAME[provider]} in Integrations first.` };
  if (provider === "luma") {
    if (!c.secret) return { ok: false, error: "Paste the Luma API key in Integrations first." };
    return lumaEvent(fetch, c.secret, ref);
  }
  if (provider === "pretix") {
    const base = baseUrl(c.config.base_url ?? "https://pretix.eu");
    if (!base || await urlIsBlocked(base)) return { ok: false, error: "The pretix address isn't usable." };
    const r = await fetch(`${base}/api/v1/organizers/${encodeURIComponent(String(c.config.organizer ?? ""))}/events/${encodeURIComponent(ref)}/`,
      { method: "GET", headers: { Authorization: `Token ${c.secret ?? ""}`, Accept: "application/json" }, redirect: "manual" });
    if (r.status === 404) return { ok: false, error: "pretix has no event with that short name." };
    if (!r.ok) return { ok: false, error: `pretix answered ${r.status}.` };
    const b = await r.json().catch(() => ({}));
    const name = typeof b?.name === "object" ? (b.name.en ?? Object.values(b.name)[0]) : b?.name;
    return { ok: true, name: typeof name === "string" ? name : ref };
  }
  const base = baseUrl(c.config.base_url);
  if (!base || await urlIsBlocked(base)) return { ok: false, error: "The hi.events address isn't usable." };
  return hiEventsList(fetch, base, ref);
}

async function syncOne(sb: SupabaseClient, event: string) {
  const { data, error } = await sb.rpc("exos_backend_sync_claim", { p_limit: 1, p_event_id: event });
  if (error) return { ok: false, error: "claim failed" };
  const rows = (data ?? []) as Claimed[];
  if (!rows.length) return { ok: true, skipped: "synced moments ago" };
  return syncClaimed(sb, rows[0], Date.now() + 25_000);
}

async function syncClaimed(sb: SupabaseClient, c: Claimed, deadline: number) {
  const apply = (rows: unknown[], state: "more" | "done" | "error", cursor: string | null, err?: string) =>
    sb.rpc("exos_backend_apply", {
      p_event_id: c.event_id, p_lease: c.lease_id, p_rows: rows, p_state: state, p_cursor: cursor, p_error: err ?? null,
    });
  const cfg = await providerConfig(sb, c.org_id, c.provider);
  if (!cfg) {
    await apply([], "error", c.sync_cursor, "integration removed");
    return { ok: false, error: "integration removed" };
  }
  let added = 0;
  try {
    if (c.provider === "pretix") {
      const base = baseUrl(cfg.config.base_url ?? "https://pretix.eu");
      if (!base || await urlIsBlocked(base)) throw new Error("pretix address blocked");
      const pcfg = { base, organizer: String(cfg.config.organizer ?? ""), token: cfg.secret ?? "" };
      const passStart = new Date().toISOString();
      const cur = parseCursor(c.sync_cursor);
      const items = await pretixItems(fetch, pcfg, c.external_ref);
      let page = cur.page;
      for (let i = 0; i < PAGES_PER_RUN && Date.now() < deadline; i++) {
        const p = await pretixOrdersPage(fetch, pcfg, c.external_ref, cur.since, page, items);
        if (p.status >= 400) throw new Error(`pretix answered ${p.status}`);
        const more = p.next;
        // Done: the next pass reads what changed since this pass began.
        const r = await apply(p.rows, more ? "more" : "done", more ? cursorString(cur.since, page + 1) : cursorString(passStart));
        added += Number((r.data as { added?: number } | null)?.added ?? 0);
        if (!more) return { ok: true, added };
        page += 1;
      }
      return { ok: true, added, more: true };
    }
    if (c.provider === "luma") {
      if (!lumaOn()) throw new Error(LUMA_OFF);
      const key = cfg.secret ?? "";
      let cursor = c.sync_cursor || null;
      for (let i = 0; i < PAGES_PER_RUN && Date.now() < deadline; i++) {
        const p = await lumaGuestsPage(fetch, key, c.external_ref, cursor);
        if (p.status >= 400) throw new Error(`Luma answered ${p.status}`);
        if (p.next && p.next.length > 200) throw new Error("Luma page cursor too long to store");
        // No "changed since" either: each pass reads every page; done starts over.
        const r = await apply(p.rows, p.next ? "more" : "done", p.next);
        added += Number((r.data as { added?: number } | null)?.added ?? 0);
        if (!p.next) return { ok: true, added };
        cursor = p.next;
      }
      return { ok: true, added, more: true };
    }
    const base = baseUrl(cfg.config.base_url);
    if (!base || await urlIsBlocked(base)) throw new Error("hi.events address blocked");
    let page = Math.max(1, Number(c.sync_cursor ?? "1") || 1);
    for (let i = 0; i < PAGES_PER_RUN && Date.now() < deadline; i++) {
      const p = await hiEventsAttendeesPage(fetch, base, c.external_ref, page);
      if (p.status >= 400) throw new Error(`hi.events answered ${p.status}`);
      // hi.events has no "changed since": each pass reads every page; done starts over at 1.
      const r = await apply(p.rows, p.next ? "more" : "done", p.next ? String(page + 1) : "1");
      added += Number((r.data as { added?: number } | null)?.added ?? 0);
      if (!p.next) return { ok: true, added };
      page += 1;
    }
    return { ok: true, added, more: true };
  } catch (err) {
    const msg = redactError(err).slice(0, 180);
    await apply([], "error", c.sync_cursor, msg);
    return { ok: false, error: msg };
  }
}

async function runCron(sb: SupabaseClient) {
  const deadline = Date.now() + CRON_BUDGET_MS;
  const { data, error } = await sb.rpc("exos_backend_sync_claim", { p_limit: 20 });
  if (error) {
    console.error("exos-integrations: claim failed", redactError(error));
    return { ok: false };
  }
  const out: unknown[] = [];
  for (const c of (data ?? []) as Claimed[]) {
    if (Date.now() > deadline) break;
    out.push({ event: c.event_id, ...(await syncClaimed(sb, c, deadline)) });
  }
  return { ok: true, synced: out.length, results: out };
}

async function eventOrg(sb: SupabaseClient, event: string): Promise<string | null> {
  const { data } = await sb.from("exos_events").select("org_id").eq("id", event).maybeSingle();
  return (data as { org_id?: string } | null)?.org_id ?? null;
}

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = (error.message ?? "").replace(/^exos_\w+: /, "");
  if (error.code === "42501") return json({ error: msg || "Not allowed.", reason: "forbidden" }, 403, cors);
  if (error.code === "23505" || error.code === "22023") return json({ error: msg, reason: "invalid" }, 400, cors);
  console.error("exos-integrations: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
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
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}
