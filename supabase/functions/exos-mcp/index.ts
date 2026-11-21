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
//                                 exos-api), a personal access token
//                                 (exos_pat_…) or an OAuth access token
//                                 (exos_oat_…, docs/developer-platform.md):
//                                 adds the organizer tools for that org, held to the
//                                 same scopes exos-api applies (user tokens:
//                                 narrowed to the user's live role).
//                                 A key that doesn't check out is refused (401,
//                                 with the protected-resource metadata URL),
//                                 never silently downgraded.
//   GET /.well-known/oauth-protected-resource  RFC 9728: where to get a token.
//   POST …/exos-mcp/organizer      the same server, but sign-in is required:
//                                 no token answers 401 with the metadata URL,
//                                 which is what starts the OAuth sign-in in
//                                 claude.ai / ChatGPT connectors (docs/mcp.md).
// Writes (create_event_draft, add_ticket_type, publish_event; mig
// 20261119130000): events:write, two calls each (a preview and a server-issued
// confirm_token), an hourly cap per org, audited with source mcp. They run
// exos_api_write, the REST API's own SQL. Nothing is bought or held.
// An OAuth token issued for another resource (RFC 8707 `resource`) is refused.
//
// Limits: 60 calls a minute per network without a key, 120 per key
// (exos_rate_hit / exos_api_rate_hit). If the limiter errors, calls are refused.
//
// Deploy with --no-verify-jwt (assistants don't send a Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), EXOS_APP_BASE_URL
// (public app base, e.g. https://…/bridge), optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleBody, ToolError, type ToolContext } from "../_shared/mcp/protocol.ts";
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
import { withPublicTierFees } from "../_shared/feeRulesRead.ts";
import { bearerKind } from "../_shared/api/credentials.ts";
import { actorHeaders } from "../_shared/api/audit.ts";
import { challenge, isOrganizerPath, newConfirmToken, protectedResource, tokenResourceOk } from "../_shared/mcp/discovery.ts";
import {
  CONFIRM_TOKEN_RE, type EventState, type FeeOutcome, type McpWriteData, type OrgVenue, type WriteExec,
  type WriteOutcome, type WriteToolName,
} from "../_shared/mcp/exosWriteTools.ts";

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
  const pathname = new URL(req.url).pathname;
  // …/exos-mcp/organizer: sign-in required (the OAuth connector URL).
  const organizer = isOrganizerPath(pathname);
  const sbUrl = Deno.env.get("SUPABASE_URL") ?? "";
  if (req.method === "GET" && /\/\.well-known\/oauth-protected-resource$/.test(pathname)) {
    return json(protectedResource(sbUrl, Deno.env.get("EXOS_OAUTH_ISSUER"), organizer), 200);
  }
  // No server-to-client stream: GET (and DELETE of a session) aren't offered.
  if (req.method !== "POST") return json({ error: "use POST (MCP Streamable HTTP, stateless)" }, 405, { Allow: "POST, OPTIONS" });

  const body = await req.text();
  if (body.length > MAX_BODY) return json({ error: "request too large" }, 413);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Who's calling: an organizer key, or anyone.
  const ctx: ToolContext = { orgId: null };
  const auth = req.headers.get("Authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!key && organizer) {
    return json({ error: "sign in to Exos to use the organizer tools" }, 401, { "WWW-Authenticate": challenge(sbUrl, true) });
  }
  let bucket: { keyId?: string; net?: string; token?: string };
  const kind = key ? bearerKind(key) : null;
  let userId: string | null = null;
  let clientId: string | null = null;
  if (key && (kind === "pat" || kind === "oauth")) {
    // A user token: the same check exos-api makes (live role, scopes narrowed to it).
    const hash = await sha256Hex(key);
    const { data: t, error: tErr } = await sb.rpc("exos_api_token_auth", { p_hash: hash, p_kind: kind });
    if (tErr) {
      console.error("exos-mcp: token lookup failed", tErr.message);
      return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
    }
    if (!t) return json({ error: "invalid, expired or revoked token" }, 401, { "WWW-Authenticate": challenge(sbUrl, organizer) });
    if ((t as { error?: string }).error === "membership") {
      return json({ error: "this token's user is no longer a member of the organization" }, 403);
    }
    const tok = t as {
      org_id: string; scopes: string[]; credential_id: string; user_id: string; client_id?: string | null; resource?: string | null;
    };
    // RFC 8707 / the MCP auth spec: a token made for another resource isn't ours.
    if (kind === "oauth" && !tokenResourceOk(tok.resource, sbUrl)) {
      return json({ error: "this token was issued for another resource" }, 401, {
        "WWW-Authenticate": challenge(sbUrl, organizer, "invalid_token"),
      });
    }
    ctx.orgId = tok.org_id;
    ctx.scopes = tok.scopes ?? [];
    ctx.credKind = kind;
    ctx.credId = tok.credential_id;
    ctx.bearerHash = hash;
    userId = tok.user_id ?? null;
    clientId = tok.client_id ?? null;
    bucket = { token: `${kind}:${tok.credential_id}` };
  } else if (key) {
    // Scopes as of now: narrowed to the key creator's role's set (mig 20261104180000).
    const { data: row, error: kErr } = await sb.rpc("exos_api_key_auth", { p_hash: await sha256Hex(key) });
    if (kErr) {
      console.error("exos-mcp: key lookup failed", kErr.message);
      return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
    }
    if (!row) {
      return json({ error: "invalid or revoked Exos API key" }, 401, { "WWW-Authenticate": challenge(sbUrl, organizer) });
    }
    ctx.orgId = row.org_id as string;
    ctx.scopes = (row.scopes ?? []) as string[];
    ctx.credKind = "api_key";
    ctx.credId = row.id as string;
    ctx.bearerHash = null;
    bucket = { keyId: row.id as string };
  } else {
    const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    bucket = { net: (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown" };
  }

  const { data: allowed, error: rlErr } = bucket.keyId
    ? await sb.rpc("exos_api_rate_hit", { p_key_id: bucket.keyId, p_limit: KEY_PER_MINUTE })
    : bucket.token
    ? await sb.rpc("exos_rate_hit", { p_bucket: `mcp:${bucket.token}`, p_limit: KEY_PER_MINUTE })
    : await sb.rpc("exos_rate_hit", { p_bucket: `mcp:${bucket.net}`, p_limit: PUBLIC_PER_MINUTE });
  if (rlErr) {
    console.error("exos-mcp: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) {
    return json({ error: "rate limit exceeded" }, 429, { "Retry-After": String(Math.max(1, 60 - new Date().getUTCSeconds())) });
  }

  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  // Writes carry the credential and source mcp to the database's audit log
  // (believed on service-role requests only; _exos_audit_actor).
  const writes = ctx.credKind && ctx.credId
    ? writeData(createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      global: {
        headers: {
          ...actorHeaders({ kind: ctx.credKind, id: ctx.credId, userId, clientId }, crypto.randomUUID()),
          "x-exos-source": "mcp",
        },
      },
    }))
    : undefined;
  const server = exosMcpServer(supabaseData(sb), { appBase, version: VERSION, writes });
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
      // `available` (mig 20261014160000): what Exos can sell; missing before it.
      const run = (cols: string) => sb.from("exos_public_tiers").select(cols)
        .eq("event_id", eventId).order("sort_order", { ascending: true });
      let { data, error } = await run(TIER_COLS + ", available");
      if (error?.code === "42703") ({ data, error } = await run(TIER_COLS));
      if (error) throw new Error(`tiers: ${error.message}`);
      // All-in like the storefront: the organizer's passed-on fees are in the price.
      return await withPublicTierFees(sb, (data ?? []) as unknown as PublicTier[]);
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

/** The write tools' database calls (all service-role SQL held to ctx's org; mig 20261119130000). */
function writeData(sb: SupabaseClient): McpWriteData {
  const cred = (ctx: ToolContext) => ({
    p_org: ctx.orgId, p_cred_kind: ctx.credKind, p_cred: ctx.credId, p_bearer_hash: ctx.bearerHash ?? null,
  });
  return {
    async issueConfirm(ctx: ToolContext, tool: WriteToolName, exec: WriteExec) {
      const token = newConfirmToken();
      const { data, error } = await sb.rpc("exos_mcp_confirm_issue", {
        ...cred(ctx), p_tool: tool, p_action: exec.action, p_target: exec.target, p_args: exec.args,
        p_confirm_hash: await sha256Hex(token),
      });
      if (error) {
        if (error.code === "54000" || error.code === "42501") throw new ToolError(String(error.message).replace(/^exos_mcp_confirm_issue: /, ""));
        throw new Error(`confirm issue: ${error.message}`);
      }
      return { token, expires_at: String((data as { expires_at?: string })?.expires_at ?? "") };
    },
    async runWrite(ctx: ToolContext, tool: WriteToolName, confirmToken: string, exec: WriteExec): Promise<WriteOutcome> {
      if (!CONFIRM_TOKEN_RE.test(confirmToken)) throw new ToolError("confirm_token is not one this server issued");
      const { data, error } = await sb.rpc("exos_mcp_write", {
        p_confirm_hash: await sha256Hex(confirmToken), ...cred(ctx), p_tool: tool, p_action: exec.action,
        p_target: exec.target, p_args: exec.args,
      });
      if (error) throw new Error(`mcp write: ${error.message}`);
      return data as WriteOutcome;
    },
    async orgVenue(orgId: string, venueId: string): Promise<OrgVenue | null> {
      const { data, error } = await sb.from("exos_venues").select("id, name, address, timezone")
        .eq("org_id", orgId).eq("id", venueId).maybeSingle();
      if (error) throw new Error(`venue: ${error.message}`);
      return (data as OrgVenue | null) ?? null;
    },
    async eventState(orgId: string, eventId: string): Promise<EventState | null> {
      const { data, error } = await sb.rpc("exos_mcp_event_state", { p_org: orgId, p_event: eventId });
      if (error) throw new Error(`event state: ${error.message}`);
      return (data as EventState | null) ?? null;
    },
    async feeOutcome(orgId: string, eventId: string): Promise<FeeOutcome | null> {
      const { data, error } = await sb.rpc("exos_mcp_fee_outcome", { p_org: orgId, p_event: eventId });
      if (error) throw new Error(`fee outcome: ${error.message}`);
      return (data as FeeOutcome | null) ?? null;
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
