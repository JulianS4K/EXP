// exos-google-feed — the Exos events feed for Google Search / Maps "Tickets"
// (docs/google-events.md). Read-only: it only reads Exos's own public event
// data and serves it; nothing is sent anywhere.
//
//   GET                 the feed: { feed_metadata, events: [schema.org Event …] }
//   GET ?report=1       operator only (Authorization: Bearer <service role
//                       key>): counts and the events left out, with why. It
//                       can name events that never went public, so it isn't
//                       public.
//
// Every field is already public on the event page. Published events, plus
// cancelled ones that were on sale and haven't started (as EventCancelled).
// The feed is a snapshot: an event missing from it is removed.
//
// Limits: 30 calls a minute per network (exos_rate_hit, mig 20260929060000);
// if the limiter errors, calls are refused. Responses are cacheable for 15 min.
//
// Deploy with --no-verify-jwt (Google's fetcher sends no Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), EXOS_APP_BASE_URL
// (public app base, e.g. https://…/bridge), optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  buildGoogleFeed,
  type FeedEventRow,
  type FeedGeo,
  type FeedOrg,
  type FeedTierRow,
} from "../_shared/googleEvents/feed.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";

const PER_MINUTE = 30;
const MAX_EVENTS = 2000;
const EVENT_COLS =
  "id, slug, org_id, name, description, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_address, " +
  "primary_performer_name, performer_names, category, genres, image_url, tickets_sold";
// Store page content (mig 20260929120000). Until the migration is on the
// database the select fails on the missing columns, so the feed retries
// without them rather than going dark.
const STORE_COLS = ", summary, description_md, lineup, min_age";
// Online / hybrid + noindex (mig 20261005090000), with the same fallback.
const ONLINE_COLS = ", format, noindex";
const TIER_COLS = "id, event_id, name, description, price, capacity, sold, sales_start, sales_end, price_schedule, exclusive_tax_percent";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET" && req.method !== "HEAD") return json({ error: "use GET" }, 405, { Allow: "GET, HEAD" });
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(appBase)) {
    console.error("exos-google-feed: EXOS_APP_BASE_URL is not set to an https URL");
    return json({ error: "feed not configured" }, 503);
  }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const net = (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown";
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `gfeed:${net}`, p_limit: PER_MINUTE });
  if (rlErr) {
    console.error("exos-google-feed: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) return json({ error: "rate limit exceeded" }, 429, { "Retry-After": "60" });

  try {
    const now = new Date();
    const input = await readFeedInput(sb, now);
    const { feed, skipped } = buildGoogleFeed(input, { appBase, now });
    if (new URL(req.url).searchParams.get("report") === "1") {
      if (!(await isOperator(req))) return json({ error: "operator only" }, 401, { "WWW-Authenticate": 'Bearer realm="exos"' });
      return json({ generated_at: feed.feed_metadata.generated_at, listed: feed.events.length, skipped }, 200, { "Cache-Control": "no-store" });
    }
    return json(feed, 200, { "Cache-Control": "public, max-age=900" });
  } catch (e) {
    console.error("exos-google-feed: failed", redactError(e));
    return json({ error: "something went wrong" }, 500);
  }
});

async function readFeedInput(sb: SupabaseClient, now: Date) {
  // Anything that could still be happening: started within the last day (long
  // shows; feedBlocker drops the ones that are over) or later.
  const since = new Date(now.getTime() - 24 * 3600_000).toISOString();
  const readEvents = (cols: string) => sb.from("exos_events").select(cols)
    .in("status", ["published", "cancelled"]).gte("starts_at", since)
    .order("starts_at", { ascending: true }).limit(MAX_EVENTS);
  let { data: evs, error } = await readEvents(EVENT_COLS + STORE_COLS + ONLINE_COLS);
  if (error?.code === "42703") ({ data: evs, error } = await readEvents(EVENT_COLS + STORE_COLS)); // undefined_column
  if (error?.code === "42703") ({ data: evs, error } = await readEvents(EVENT_COLS));
  if (error) throw new Error(`events: ${error.message}`);
  const events = (evs ?? []) as unknown as FeedEventRow[];
  const ids = events.map((e) => e.id);
  if (!ids.length) return { events, tiers: [], geo: new Map(), orgs: new Map() };

  const tiers: FeedTierRow[] = [];
  const geo = new Map<string, FeedGeo>();
  const orgIds = [...new Set(events.map((e) => e.org_id))];
  const orgs = new Map<string, FeedOrg>();
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    // Public ticket types only (hidden ones are unlocked by codes; never listed).
    // exos_public_tiers covers published events; a cancelled event's tiers come
    // from the table with the same filter.
    const { data: t, error: tErr } = await sb.from("exos_ticket_tiers").select(TIER_COLS)
      .in("event_id", chunk).eq("visibility", "public").order("sort_order", { ascending: true });
    if (tErr) throw new Error(`tiers: ${tErr.message}`);
    tiers.push(...((t ?? []) as unknown as FeedTierRow[]));
    const { data: g, error: gErr } = await sb.from("exos_event_geo").select("event_id, lat, lng, place_id")
      .in("event_id", chunk).eq("status", "ok").not("lat", "is", null);
    if (gErr) throw new Error(`geo: ${gErr.message}`);
    for (const r of (g ?? []) as Array<{ event_id: string; lat: number; lng: number; place_id: string | null }>) {
      geo.set(r.event_id, { lat: Number(r.lat), lng: Number(r.lng), place_id: r.place_id });
    }
  }
  for (let i = 0; i < orgIds.length; i += 200) {
    const { data: o, error: oErr } = await sb.from("exos_public_orgs").select("id, name, slug").in("id", orgIds.slice(i, i + 200));
    if (oErr) throw new Error(`orgs: ${oErr.message}`);
    for (const r of (o ?? []) as FeedOrg[]) orgs.set(r.id, r);
  }
  return { events, tiers, geo, orgs };
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
