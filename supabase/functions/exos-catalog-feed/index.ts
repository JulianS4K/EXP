// exos-catalog-feed — an org's published upcoming events as an ad catalog
// (docs/marketing-catalog.md). A public pull feed that Meta Commerce Manager,
// TikTok Catalog Manager and Google Merchant Center fetch on a schedule;
// nothing is sent anywhere.
//
//   GET /exos-catalog-feed/<org_slug>.csv                 Meta catalog CSV
//   GET /exos-catalog-feed/<org_slug>.xml                 Google Merchant Center RSS (g: namespace)
//   GET /exos-catalog-feed/<org_slug>.csv?format=tiktok   TikTok catalog CSV
//   GET /exos-catalog-feed/<org_slug>.xml?format=meta     Meta catalog RSS
//   GET …?report=1        operator only (Authorization: Bearer <service role
//                         key>): the events left out, with why.
//
// Reads only the public views (exos_public_orgs, exos_public_events,
// exos_public_tiers) with the anon key, so it can only serve what the event
// page already shows. The service role is used for the rate limiter alone.
//
// Limits: 30 calls a minute per network (exos_rate_hit, mig 20260929060000);
// if the limiter errors, calls are refused. Responses are cacheable for 15 min.
//
// Deploy with --no-verify-jwt (the platforms' fetchers send no Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// (platform), EXOS_APP_BASE_URL (public app base, e.g. https://…/bridge),
// optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  buildCatalog,
  parseFeedPath,
  renderCatalog,
  resolvePlatform,
  type CatalogEventRow,
  type CatalogOrg,
  type CatalogTierRow,
} from "../_shared/catalog/feed.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";

const PER_MINUTE = 30;
const MAX_EVENTS = 500;
const TIER_COLS = "id, event_id, price, capacity, sold, sales_start, sales_end, price_schedule, exclusive_tax_percent, sort_order";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET" && req.method !== "HEAD") return json({ error: "use GET" }, 405, { Allow: "GET, HEAD" });
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(appBase)) {
    console.error("exos-catalog-feed: EXOS_APP_BASE_URL is not set to an https URL");
    return json({ error: "feed not configured" }, 503);
  }
  const url = new URL(req.url);
  const path = parseFeedPath(url.pathname);
  if (!path) return json({ error: "use /exos-catalog-feed/<org_slug>.csv or .xml" }, 404);
  const resolved = resolvePlatform(path.fileType, url.searchParams.get("format"));
  if ("error" in resolved) return json({ error: resolved.error }, 400);

  const service = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const net = (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown";
  const { data: allowed, error: rlErr } = await service.rpc("exos_rate_hit", { p_bucket: `catfeed:${net}`, p_limit: PER_MINUTE });
  if (rlErr) {
    console.error("exos-catalog-feed: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) return json({ error: "rate limit exceeded" }, 429, { "Retry-After": "60" });

  // Public reads only: the anon key, through the column-narrowed views.
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const now = new Date();
    const input = await readCatalogInput(anon, path.slug, now);
    if (!input) return json({ error: "organizer not found" }, 404, { "Cache-Control": "public, max-age=300" });
    const { items, skipped } = buildCatalog(input, { appBase, platform: resolved.platform, now });
    if (url.searchParams.get("report") === "1") {
      if (!(await isOperator(req))) return json({ error: "operator only" }, 401, { "WWW-Authenticate": 'Bearer realm="exos"' });
      return json({ generated_at: now.toISOString(), org: input.org.slug, listed: items.length, skipped }, 200, { "Cache-Control": "no-store" });
    }
    const { body, contentType } = renderCatalog(items, resolved.platform, path.fileType, input.org, appBase);
    return new Response(req.method === "HEAD" ? null : body, {
      status: 200,
      headers: {
        "Content-Type": contentType,
        "Cache-Control": "public, max-age=900",
        "Content-Disposition": `inline; filename="${path.slug}-${resolved.platform}.${path.fileType}"`,
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch (e) {
    console.error("exos-catalog-feed: failed", redactError(e));
    return json({ error: "something went wrong" }, 500);
  }
});

async function readCatalogInput(sb: SupabaseClient, slug: string, now: Date) {
  const { data: org, error: oErr } = await sb.from("exos_public_orgs").select("id, name, slug").eq("slug", slug).maybeSingle();
  if (oErr) throw new Error(`org: ${oErr.message}`);
  if (!org) return null;
  // Anything that could still be happening: started within the last day
  // (catalogBlocker drops the ones that are over) or later. The view only has
  // published events.
  const since = new Date(now.getTime() - 24 * 3600_000).toISOString();
  const { data: evs, error: eErr } = await sb.from("exos_public_events").select("*")
    .eq("org_id", (org as CatalogOrg).id).gte("starts_at", since)
    .order("starts_at", { ascending: true }).limit(MAX_EVENTS);
  if (eErr) throw new Error(`events: ${eErr.message}`);
  const events = (evs ?? []) as unknown as CatalogEventRow[];
  const tiers: CatalogTierRow[] = [];
  const ids = events.map((e) => e.id);
  for (let i = 0; i < ids.length; i += 200) {
    const { data: t, error: tErr } = await sb.from("exos_public_tiers").select(TIER_COLS)
      .in("event_id", ids.slice(i, i + 200)).order("sort_order", { ascending: true });
    if (tErr) throw new Error(`tiers: ${tErr.message}`);
    tiers.push(...((t ?? []) as unknown as CatalogTierRow[]));
  }
  return { org: org as CatalogOrg, events, tiers };
}

/** Bearer <service role key>, compared in constant time over the SHA-256 digests. */
async function isOperator(req: Request): Promise<boolean> {
  const auth = req.headers.get("Authorization") ?? "";
  const given = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  const want = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!given || !want) return false;
  const [a, b] = await Promise.all([given, want].map((s) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", ...extra } });
}
