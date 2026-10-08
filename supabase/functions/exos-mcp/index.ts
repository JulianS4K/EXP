// exos-mcp — Exos as a remote MCP server for AI assistants (docs/mcp.md).
//
// Streamable HTTP, stateless: POST a JSON-RPC message (or batch), get JSON
// back. Works with Claude (claude.ai / Desktop custom connectors, Claude Code
// `claude mcp add --transport http`, the Messages API MCP connector) and
// ChatGPT (connectors / developer mode, the Responses API `mcp` tool).
//
// Auth:
//   none                          public tools: find events, get a ticket link.
//   Authorization: Bearer <key>   an Exos organizer API key (same keys as
//                                 exos-api): adds read-only tools for that org.
//                                 A key that doesn't check out is refused (401),
//                                 never silently downgraded.
// Everything is read-only; nothing is bought, held or changed.
//
// Limits: 60 calls a minute per network without a key, 120 per key
// (exos_rate_hit / exos_api_rate_hit). If the limiter errors, calls are refused.
//
// Deploy with --no-verify-jwt (assistants don't send a Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), EXOS_APP_BASE_URL
// (public app base, e.g. https://…/bridge), optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleBody, type ToolContext } from "../_shared/mcp/protocol.ts";
import {
  exosMcpServer,
  type AttentionOrder,
  type DoorStatus,
  type EventSales,
  type EventSearch,
  type ExosData,
  type OrgEvent,
  type PublicEvent,
  type PublicTier,
} from "../_shared/mcp/exosTools.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";

const VERSION = "1.0.0";
const MAX_BODY = 64 * 1024;
const PUBLIC_PER_MINUTE = 60;
const KEY_PER_MINUTE = 120;

const EVENT_COLS =
  "id, slug, name, summary, description, starts_at, doors_at, timezone, currency, venue_name, venue_address, " +
  "primary_performer_name, performer_names, genres, category, image_url, total_tickets, tickets_sold";
// Online / hybrid + noindex (mig 20261005090000): searches leave out events
// the organizer hid from search; without the columns, the old select.
const ONLINE_COLS = ", format, noindex";
const TIER_COLS =
  "id, event_id, name, description, price, capacity, sold, sales_start, sales_end, price_schedule, exclusive_tax_percent, accessible";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version",
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  // No server-to-client stream: GET (and DELETE of a session) aren't offered.
  if (req.method !== "POST") return json({ error: "use POST (MCP Streamable HTTP, stateless)" }, 405, { Allow: "POST, OPTIONS" });

  const body = await req.text();
  if (body.length > MAX_BODY) return json({ error: "request too large" }, 413);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Who's calling: an organizer key, or anyone.
  const ctx: ToolContext = { orgId: null };
  const auth = req.headers.get("Authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  let bucket: { keyId?: string; net?: string };
  if (key) {
    const { data: row } = await sb.from("exos_api_keys").select("id, org_id")
      .eq("key_hash", await sha256Hex(key)).is("revoked_at", null).maybeSingle();
    if (!row) {
      return json({ error: "invalid or revoked Exos API key" }, 401, { "WWW-Authenticate": 'Bearer realm="exos"' });
    }
    ctx.orgId = row.org_id as string;
    bucket = { keyId: row.id as string };
  } else {
    const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    bucket = { net: (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown" };
  }

  const { data: allowed, error: rlErr } = bucket.keyId
    ? await sb.rpc("exos_api_rate_hit", { p_key_id: bucket.keyId, p_limit: KEY_PER_MINUTE })
    : await sb.rpc("exos_rate_hit", { p_bucket: `mcp:${bucket.net}`, p_limit: PUBLIC_PER_MINUTE });
  if (rlErr) {
    console.error("exos-mcp: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) {
    return json({ error: "rate limit exceeded" }, 429, { "Retry-After": String(Math.max(1, 60 - new Date().getUTCSeconds())) });
  }

  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  const server = exosMcpServer(supabaseData(sb), { appBase, version: VERSION });
  const out = await handleBody(server, body, ctx, (e) => console.error("exos-mcp: tool failed", redactError(e)));
  if (out === null) return new Response(null, { status: 202, headers: CORS });
  return json(out, 200);
});

function supabaseData(sb: SupabaseClient): ExosData {
  return {
    async searchEvents(q: EventSearch): Promise<PublicEvent[]> {
      const run = (withOnline: boolean) => {
        let query = sb.from("exos_public_events").select(EVENT_COLS + (withOnline ? ONLINE_COLS : ""))
          .gte("starts_at", q.from).order("starts_at", { ascending: true }).limit(q.limit);
        if (withOnline) query = query.eq("noindex", false);
        if (q.to) query = query.lte("starts_at", q.to);
        const words = clean(q.query);
        if (words) {
          const p = `"*${words}*"`;
          query = query.or(`name.ilike.${p},venue_name.ilike.${p},primary_performer_name.ilike.${p},category.ilike.${p}`);
        }
        const place = clean(q.city);
        if (place) query = query.ilike("venue_address->>city", `%${place}%`);
        return query;
      };
      let { data, error } = await run(true);
      if (error?.code === "42703") ({ data, error } = await run(false)); // undefined_column
      if (error) throw new Error(`search events: ${error.message}`);
      return (data ?? []) as unknown as PublicEvent[];
    },
    async getEvent(ref: string): Promise<PublicEvent | null> {
      // By id or slug: a hidden event still opens for someone who has its link.
      const run = (cols: string) => {
        const query = sb.from("exos_public_events").select(cols);
        return (UUID_RE.test(ref) ? query.eq("id", ref) : query.eq("slug", ref)).maybeSingle();
      };
      let { data, error } = await run(EVENT_COLS + ", format");
      if (error?.code === "42703") ({ data, error } = await run(EVENT_COLS));
      if (error) throw new Error(`get event: ${error.message}`);
      return (data as unknown as PublicEvent | null) ?? null;
    },
    async tiersFor(eventId: string): Promise<PublicTier[]> {
      const { data, error } = await sb.from("exos_public_tiers").select(TIER_COLS)
        .eq("event_id", eventId).order("sort_order", { ascending: true });
      if (error) throw new Error(`tiers: ${error.message}`);
      return (data ?? []) as unknown as PublicTier[];
    },
    async orgEvents(orgId: string, opts: { upcomingOnly: boolean; limit: number }): Promise<OrgEvent[]> {
      let query = sb.from("exos_events").select("id, name, status, starts_at, venue_name, tickets_sold, total_tickets")
        .eq("org_id", orgId).order("starts_at", { ascending: false }).limit(opts.limit);
      if (opts.upcomingOnly) query = query.gte("starts_at", new Date().toISOString());
      const { data, error } = await query;
      if (error) throw new Error(`org events: ${error.message}`);
      return (data ?? []) as unknown as OrgEvent[];
    },
    async eventSales(orgId: string, eventId: string): Promise<EventSales | null> {
      const { data, error } = await sb.rpc("exos_mcp_event_sales", { p_org_id: orgId, p_event_id: eventId });
      if (error) throw new Error(`event sales: ${error.message}`);
      return (data as EventSales | null) ?? null;
    },
    async doorStatus(orgId: string, eventId: string): Promise<DoorStatus | null> {
      const { data, error } = await sb.rpc("exos_mcp_door_status", { p_org_id: orgId, p_event_id: eventId });
      if (error) throw new Error(`door status: ${error.message}`);
      return (data as DoorStatus | null) ?? null;
    },
    async attention(orgId: string, eventId?: string): Promise<AttentionOrder[]> {
      let query = sb.from("exos_marketplace_orders")
        .select("channel, external_order_id, quantity, attention_reason, updated_at, exos_events(name)")
        .eq("org_id", orgId).eq("status", "needs_attention").is("handled_at", null)
        .order("updated_at", { ascending: false }).limit(50);
      if (eventId) query = query.eq("event_id", eventId);
      const { data, error } = await query;
      if (error) throw new Error(`attention: ${error.message}`);
      // No buyer emails: the organizer sees those in Exos itself.
      return ((data ?? []) as unknown as Array<{ channel: string; external_order_id: string; quantity: number;
        attention_reason: string | null; updated_at: string; exos_events: { name: string } | null }>)
        .map((o) => ({ channel: o.channel, external_order_id: o.external_order_id, quantity: o.quantity,
          reason: o.attention_reason, event_name: o.exos_events?.name ?? null, updated_at: o.updated_at }));
    },
  };
}

/** Search words safe inside a PostgREST filter (no , ( ) " * \ and friends). */
function clean(s: string | undefined): string {
  return (s ?? "").normalize("NFKC").replace(/[^\p{L}\p{N} '&.-]/gu, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS, ...extra } });
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}
