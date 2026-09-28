// exos-calendar — iCalendar (.ics) feeds a calendar app subscribes to
// (docs/calendar.md). Read-only; GET / HEAD only.
//
//   /org/<slug>.ics        an organizer's (promoter's / venue org's) events
//   /venue/<key>.ics       every organizer's events at one venue
//                          (key = venueKey() in _shared/calendar/feed.ts, or
//                          place-<Google Place ID>)
//   /event/<uuid>.ics      one event ("add to calendar" download)
//   /me/<token>.ics        the subscriber's followed organizers + the events
//                          they hold tickets for. The token (exc_…) is made in
//                          the app (exos_calendar_feed_token_create); only its
//                          SHA-256 is stored, and rotating / revoking kills it.
//
// Calendar apps can't send headers, so there's no JWT: the org / venue /
// event feeds are public data only (what the event page shows), and the /me
// feed is keyed by the unguessable token in its URL. The token never reaches
// a log line.
//
// Feeds cover events from 30 days ago onward (max 500). Cancelled events that
// were on sale stay in, as STATUS:CANCELLED, so subscribers see the change.
//
// Limits: 120 calls a minute per network, and 30 a minute per /me token
// (exos_rate_hit, mig 20260929060000). If the limiter errors, calls are
// refused. Responses carry Cache-Control and an ETag (304 on If-None-Match).
//
// Deploy with --no-verify-jwt (calendar apps send no Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), EXOS_APP_BASE_URL
// (public app base, e.g. https://…/bridge), optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildEventsCalendar, parseCalendarPath, type CalendarEventRow, type CalendarRoute as Route } from "../_shared/calendar/feed.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";

const NET_PER_MINUTE = 120;
const TOKEN_PER_MINUTE = 30;
const REFRESH_MINUTES = 360;

interface FeedPayload {
  kind: string;
  name: string;
  slug?: string;
  key?: string;
  timezone?: string | null;
  events: CalendarEventRow[];
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return plain("use GET", 405, { Allow: "GET, HEAD" });
  }
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(appBase)) {
    console.error("exos-calendar: EXOS_APP_BASE_URL is not set to an https URL");
    return plain("calendar not configured", 503);
  }
  const route = parseCalendarPath(new URL(req.url).pathname);
  if (!route) return plain("not found", 404);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const net = (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown";
  const tokenHash = route.kind === "me" ? await sha256Hex(route.token) : null;

  const limited = await rateLimited(sb, `cal:${net}`, NET_PER_MINUTE) ||
    (tokenHash ? await rateLimited(sb, `calme:${tokenHash.slice(0, 32)}`, TOKEN_PER_MINUTE) : false);
  if (limited === "error") return plain("temporarily unavailable", 503, { "Retry-After": "30" });
  if (limited) return plain("rate limit exceeded", 429, { "Retry-After": String(Math.max(1, 60 - new Date().getUTCSeconds())) });

  try {
    const { data, error } = route.kind === "me"
      ? await sb.rpc("exos_calendar_my_feed", { p_token_hash: tokenHash })
      : await sb.rpc("exos_calendar_public_feed", { p_kind: route.kind, p_ref: route.ref });
    if (error) throw new Error(`feed: ${error.message}`);
    // Unknown org / venue / event, or a revoked / unknown token: the same 404.
    if (!data) return plain("not found", 404, { "Cache-Control": "no-store" });
    const feed = data as FeedPayload;

    const oneEvent = route.kind === "event";
    const name = route.kind === "me" ? feed.name
      : route.kind === "venue" ? `${feed.name} · Exos`
      : oneEvent ? feed.name
      : `${feed.name} · Exos`;
    const pageUrl = route.kind === "org" && feed.slug ? `${appBase}/o/${encodeURIComponent(feed.slug)}` : undefined;
    const body = buildEventsCalendar(feed.events ?? [], {
      name,
      description: route.kind === "me"
        ? "Events from organizers you follow on Exos, and events you have tickets for."
        : route.kind === "org" ? `Upcoming events from ${feed.name} on Exos.`
        : route.kind === "venue" ? `Upcoming events at ${feed.name} on Exos.`
        : undefined,
      timezone: feed.timezone ?? null,
      url: pageUrl,
      refreshMinutes: oneEvent ? undefined : REFRESH_MINUTES,
    }, { appBase });

    const etag = `"${(await sha256Hex(body)).slice(0, 32)}"`;
    const headers: Record<string, string> = {
      "Content-Type": "text/calendar; charset=utf-8",
      "Cache-Control": route.kind === "me" ? "private, max-age=900" : "public, max-age=900",
      ETag: etag,
      "Content-Disposition": `${oneEvent ? "attachment" : "inline"}; filename="${fileName(route, feed)}"`,
      "X-Content-Type-Options": "nosniff",
      "Access-Control-Allow-Origin": "*",
    };
    if (route.kind === "me") headers["Referrer-Policy"] = "no-referrer";
    if (req.headers.get("If-None-Match") === etag) return new Response(null, { status: 304, headers });
    return new Response(req.method === "HEAD" ? null : body, { status: 200, headers });
  } catch (e) {
    // Never the URL: a /me path holds the token.
    console.error(`exos-calendar: ${route.kind} feed failed`, redactError(e));
    return plain("something went wrong", 500);
  }
});

async function rateLimited(sb: SupabaseClient, bucket: string, limit: number): Promise<boolean | "error"> {
  const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: limit });
  if (error) {
    console.error("exos-calendar: rate limiter error (refusing)", error.message);
    return "error";
  }
  return data === false;
}

function fileName(route: Route, feed: FeedPayload): string {
  const base = route.kind === "me" ? "my-exos-events"
    : (feed.name || route.kind).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
  return `${base || "exos"}.ics`;
}

function plain(body: string, status: number, extra: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...extra } });
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}
