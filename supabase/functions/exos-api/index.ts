// exos-api — org-scoped partner REST API for Exos, plus the Opendate partner
// contract for distribution partners.
// Reference: docs/api-reference.md and /developers (built from docs/api/*.json).
//
// Credentials (Authorization: Bearer …), docs/developer-platform.md:
//   sk_live_…    an org API key (mig 20260616200000): its SHA-256 is looked up
//                in exos_api_keys, which yields the org and the key's scopes.
//   exos_pat_…   a personal access token: a user, pinned to one org.
//   exos_oat_…   an OAuth access token: a user in one org, for one app.
// The two user tokens act as their user: every request reads the user's LIVE
// role (exos_api_token_auth, mig 20261031130500), narrows the token's scopes to
// it, and refuses a user who is no longer an active member (403). Every
// request is scoped to the credential's org.
//
// Scopes (mig 20261027090000, _shared/api/scopes.ts): each route needs one
// (_shared/api/routes.ts). Keys made before scopes carry the legacy `read`,
// which covers every `:read` scope. Missing scope → 403 + WWW-Authenticate.
// Writes go through service-role SQL functions that take the org explicitly.
//
// Rate limit: 120 requests per credential per minute; over it → 429 with Retry-After.
//
// Lists are paged: ?page=1&per_page=50 (max 200) → { data, meta }.
//
// The partner contract (docs/partner-sales.md, mig 20261031130000): /public/…
// authenticated with a distribution partner's key (dk_live_…, ?shared_key=,
// X-Shared-Key or Bearer), with Opendate's paths, parameters and shapes.
// Partners call us; nothing here calls a marketplace.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. Optional:
// EXOS_APP_BASE_URL (public app base, e.g. https://…/bridge: live-ticket and
// invitation links).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  API_METHODS, apiPath, isPartnerPath, matchRoute, methodsAt, type ApiMethod, type ApiRoute,
} from "../_shared/api/routes.ts";
import { effectiveScopes, hasScope } from "../_shared/api/scopes.ts";
import { pageEnvelope, PagingError, parsePage, type Page } from "../_shared/api/paging.ts";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import { bearerKind, ORG_ROLES, ROLE_INFO, ROLE_SCOPES, sha256Hex } from "../_shared/api/credentials.ts";
import {
  opendatePage, orderFilters, PARTNER_KEY_RE, ParamError, parseOrderItems, presentedPartnerKey, railsFormBody,
  reservationAttrs, RESERVATION_TOKEN_RE, unwrapParams,
} from "../_shared/partners/sales.ts";

const RATE_LIMIT = 120; // requests per credential per minute
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;

const EVENT_LIST_COLS = "id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at";
const EVENT_COLS =
  "id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, " +
  "tickets_sold, total_tickets, created_at";
const TIER_COLS =
  "id, name, description, price, capacity, sold, ticket_type, visibility, sales_start, sales_end, sort_order";
const ORDER_COLS =
  "session_id, event_id, status, quantity, amount_cents, tax_cents, currency, buyer_email, created_at, fulfilled_at";
const PARTNER_COLS = "id, label, partner_type, key_prefix, scopes, active, created_at, last_used_at, revoked_at";
const RESERVATION_COLS =
  "id, token, status, channel, channel_source, partner_id, quantity, currency, subtotal_cents, fees_cents, tax_cents, " +
  "total_cents, cash_paid_cents, first_name, last_name, email, external_id, expires_at, completed_at, cancelled_at, created_at";
const MEMBER_ROLES = new Set(["manager", "finance", "content", "scanner"]);
const PARTNER_TYPES = ["automatiq", "stubhub", "vivid", "seatgeek", "ticketnetwork", "victorylive", "other"];

const EVENT_STATUSES = new Set(["draft", "published", "cancelled"]);

class ApiError extends Error {
  status: number;
  extra: Record<string, unknown>;
  constructor(status: number, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.extra = extra;
  }
}

/** Who is calling: an org API key, or a user through a personal / OAuth token. */
interface Credential {
  kind: "api_key" | "pat" | "oauth";
  id: string;
  name: string | null;
  key_prefix: string | null;
  /** What the credential may do now (user tokens: narrowed to the live role). */
  scopes: string[];
  userId: string | null;
  role: string | null;
  clientId: string | null;
}

interface Ctx {
  sb: SupabaseClient;
  orgId: string;
  cred: Credential;
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
}

/** A 201 answer from handle(). */
class Created {
  constructor(public body: unknown) {}
}

const service = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const appBase = () => (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "") || null;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const path = apiPath(url.pathname);
  // The partner contract authenticates with a partner key, not a bearer credential.
  if (isPartnerPath(path)) return partnerApi(req, url, path);
  const method = req.method.toUpperCase() as ApiMethod;
  if (!API_METHODS.includes(method)) return json({ error: "method not allowed" }, 405, { allow: API_METHODS.join(", ") });

  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!token) return json({ error: "missing bearer API key" }, 401);

  const sb = service();
  const resolved = await resolveCredential(sb, token);
  if (resolved === "membership") {
    return json({ error: "this token's user is no longer a member of the organization" }, 403);
  }
  if (!resolved) return json({ error: "invalid or revoked API key" }, 401);
  const { cred, orgId } = resolved;

  // Per-credential rate limit: RATE_LIMIT requests per clock minute (fixed
  // window). API keys use exos_api_rate_hit (mig 20260925020000), user tokens
  // exos_rate_hit with their own bucket. If the counter errors the request is
  // refused (503): the API returns attendee PII, so no limiter, no answer.
  const { data: allowed, error: rlErr } = cred.kind === "api_key"
    ? await sb.rpc("exos_api_rate_hit", { p_key_id: cred.id, p_limit: RATE_LIMIT })
    : await sb.rpc("exos_rate_hit", { p_bucket: `api:${cred.kind}:${cred.id}`, p_limit: RATE_LIMIT });
  if (rlErr) {
    console.error("exos-api: rate limiter error (refusing request)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
  }
  if (allowed === false) return rateLimited();

  if (cred.kind === "api_key") {
    // Best-effort last-used stamp — awaited so it actually lands before the
    // serverless invocation returns (don't fail the request if it doesn't write).
    try {
      await sb.from("exos_api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", cred.id);
    } catch { /* best-effort */ }
  }

  const match = matchRoute(method, path);
  if (!match || match.route.auth !== "api_key") {
    const allow = methodsAt(path);
    if (allow.length) return json({ error: "method not allowed" }, 405, { allow: allow.join(", ") });
    return json({ error: "not found", hint: "see /developers for the API reference" }, 404);
  }
  if (match.route.scope && !hasScope(cred.scopes, match.route.scope)) {
    return json({ error: "insufficient scope", required_scope: match.route.scope }, 403, {
      "www-authenticate": `Bearer error="insufficient_scope", scope="${match.route.scope}"`,
    });
  }

  try {
    const ctx: Ctx = {
      sb, orgId, cred,
      params: match.params,
      q: url.searchParams,
      // Only lists read ?page / ?per_page; elsewhere they are ignored.
      page: parsePage(match.route.paged ? url.searchParams : new URLSearchParams()),
      body: method === "POST" || method === "PUT" || method === "PATCH" ? await readBody(req) : {},
    };
    const out = await handle(match.route, ctx);
    return out instanceof Created ? json(out.body, 201) : json(out);
  } catch (e) {
    return errorResponse(e, "exos-api");
  }
});

/** The credential behind a bearer string and its org, "membership" for a user who left, else null. */
async function resolveCredential(
  sb: SupabaseClient, token: string,
): Promise<{ cred: Credential; orgId: string } | "membership" | null> {
  const kind = bearerKind(token);
  if (!kind) return null;
  const hash = await sha256Hex(token);
  if (kind === "api_key") {
    const { data: k } = await sb.from("exos_api_keys")
      .select("id, org_id, name, key_prefix, scopes, revoked_at")
      .eq("key_hash", hash).is("revoked_at", null).maybeSingle();
    if (!k) return null;
    return {
      orgId: k.org_id as string,
      cred: {
        kind, id: k.id as string, name: k.name as string | null, key_prefix: k.key_prefix as string,
        scopes: (k.scopes ?? []) as string[], userId: null, role: null, clientId: null,
      },
    };
  }
  const { data, error } = await sb.rpc("exos_api_token_auth", { p_hash: hash, p_kind: kind });
  if (error) {
    console.error("exos-api: token lookup failed", error.message);
    return null;
  }
  const t = data as Record<string, unknown> | null;
  if (!t) return null;
  if (t.error === "membership") return "membership";
  return {
    orgId: String(t.org_id),
    cred: {
      kind, id: String(t.credential_id), name: (t.name as string | null) ?? null,
      key_prefix: (t.key_prefix as string | null) ?? null, scopes: (t.scopes ?? []) as string[],
      userId: String(t.user_id), role: String(t.role), clientId: (t.client_id as string | null) ?? null,
    },
  };
}

async function handle(route: ApiRoute, c: Ctx): Promise<unknown> {
  const { sb, orgId, page } = c;
  switch (route.id) {
    case "me": {
      const { data: org } = await sb.from("exos_orgs").select("id, name, slug").eq("id", orgId).maybeSingle();
      return {
        data: {
          org,
          // `key` keeps its first-release shape for API keys; user tokens fill it too.
          key: { id: c.cred.id, name: c.cred.name, key_prefix: c.cred.key_prefix, scopes: c.cred.scopes },
          credential: { kind: c.cred.kind, user_id: c.cred.userId, role: c.cred.role, client_id: c.cred.clientId },
          effective_scopes: effectiveScopes(c.cred.scopes),
        },
      };
    }

    case "list-events": {
      let q = sb.from("exos_events").select(EVENT_LIST_COLS, { count: "exact" }).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!EVENT_STATUSES.has(status)) throw new ApiError(400, "status must be draft, published or cancelled.");
        q = q.eq("status", status);
      }
      const after = isoParam(c.q, "starts_after");
      if (after) q = q.gte("starts_at", after);
      const before = isoParam(c.q, "starts_before");
      if (before) q = q.lt("starts_at", before);
      return paged(await q.order("starts_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "get-event": {
      const id = eventId(c);
      const { data: ev, error } = await sb.from("exos_events").select(EVENT_COLS)
        .eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!ev) throw new ApiError(404, "event not found");
      return { data: { ...(ev as unknown as Record<string, unknown>), tiers: await tiers(sb, id) } };
    }

    case "list-ticket-types": {
      const id = await ownEvent(c);
      return { data: await tiers(sb, id) };
    }

    case "list-add-ons": {
      const id = await ownEvent(c);
      return rows(await sb.from("exos_event_addons")
        .select("id, name, description, price, capacity, sold, max_per_order, visibility, sort_order")
        .eq("event_id", id).order("sort_order", { ascending: true }));
    }

    case "list-promo-codes": {
      const id = await ownEvent(c);
      // Never reserved_email: a promo code's holder is not the partner's business.
      return paged(await sb.from("exos_vouchers")
        .select("id, code, tier_id, max_uses, used_count, discount_percent, discount_amount, price_override, " +
          "valid_until, link_label, link_channel, link_clicks, created_at", { count: "exact" })
        .eq("event_id", id).order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "list-attendees": {
      const id = await ownEvent(c);
      // Never barcode_secret.
      let q = sb.from("exos_tickets")
        .select("id, tier_id, tier_name, attendee_name, owner_email, status, check_in_at, price_paid, " +
          "order_ref, channel_source, created_at", { count: "exact" })
        .eq("event_id", id).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!/^[a-z_]{1,32}$/.test(status)) throw new ApiError(400, "status is invalid.");
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "list-check-ins": {
      const id = await ownEvent(c);
      return paged(await sb.from("exos_event_checkins")
        .select("id, ticket_id, scanned_at, source, verification, direction, list_id, gate, forced, device",
          { count: "exact" })
        .eq("event_id", id).eq("org_id", orgId)
        .order("scanned_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "list-check-in-lists": {
      const id = await ownEvent(c);
      return rows(await sb.from("exos_checkin_lists")
        .select("id, name, tier_ids, allow_reentry, valid_from, valid_until, sort_order")
        .eq("event_id", id).eq("org_id", orgId).order("sort_order", { ascending: true }));
    }

    case "list-guest-lists": {
      const id = await ownEvent(c);
      return rows(await sb.from("exos_guest_lists")
        .select("id, name, promoter_id, cap, max_plus_ones, status, closes_at, created_at")
        .eq("event_id", id).eq("org_id", orgId).order("created_at", { ascending: true }));
    }

    case "list-waitlist": {
      const id = await ownEvent(c);
      return paged(await sb.from("exos_waitlist")
        .select("id, tier_id, email, name, quantity, status, notified_at, offered_at, claim_expires_at, created_at",
          { count: "exact" })
        .eq("event_id", id).order("created_at", { ascending: true }).order("id").range(page.from, page.to), page);
    }

    case "list-orders": {
      let q = sb.from("exos_checkout_sessions").select(ORDER_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) {
        if (!UUID_RE.test(ev)) throw new ApiError(400, "event_id must be a UUID.");
        q = q.eq("event_id", ev);
      }
      const status = c.q.get("status");
      if (status !== null) {
        if (!/^[a-z_]{1,32}$/.test(status)) throw new ApiError(400, "status is invalid.");
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("session_id").range(page.from, page.to), page);
    }

    case "get-order": {
      const sid = c.params.id;
      if (!SESSION_RE.test(sid)) throw new ApiError(404, "order not found");
      const { data: order, error } = await sb.from("exos_checkout_sessions").select(ORDER_COLS)
        .eq("org_id", orgId).eq("session_id", sid).maybeSingle();
      if (error) throw error;
      if (!order) throw new ApiError(404, "order not found");
      const [tickets, addons, refunds] = await Promise.all([
        sb.from("exos_tickets").select("id, tier_id, tier_name, attendee_name, owner_email, status, price_paid, check_in_at")
          .eq("org_id", orgId).eq("order_ref", sid).order("created_at"),
        sb.from("exos_order_addons").select("id, addon_id, addon_name, quantity, unit_price_paid, status")
          .eq("org_id", orgId).eq("order_ref", sid).order("created_at"),
        sb.from("exos_order_refunds").select("id, amount_cents, currency, status, reason, is_partial, created_at")
          .eq("org_id", orgId).eq("session_id", sid).order("created_at"),
      ]);
      for (const r of [tickets, addons, refunds]) if (r.error) throw r.error;
      return { data: { ...(order as unknown as Record<string, unknown>), tickets: tickets.data, add_ons: addons.data, refunds: refunds.data } };
    }

    case "list-invoices":
      // exos_invoice_totals (mig 20261001100000): invoices are immutable and
      // refunds are credit notes; `status` is derived ('issued',
      // 'partially_refunded', 'refunded', 'cancelled'), refunded_cents added.
      return paged(await sb.from("exos_invoice_totals")
        .select("number, event_id, session_id, buyer_email, currency, subtotal_cents, tax_cents, total_cents, " +
          "status, refunded_cents, issued_at", { count: "exact" })
        .eq("org_id", orgId).order("issued_at", { ascending: false }).order("number").range(page.from, page.to), page);

    case "list-refunds":
      return paged(await sb.from("exos_order_refunds")
        .select("id, session_id, amount_cents, currency, status, reason, is_partial, created_at", { count: "exact" })
        .eq("org_id", orgId).order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);

    case "list-webhooks":
      // Never the signing secret.
      return rows(await sb.from("exos_webhooks")
        .select("id, url, event_types, enabled, description, created_at")
        .eq("org_id", orgId).order("created_at", { ascending: true }));

    // -- Distribution partners (mig 20261031130000) -----------------------------
    case "list-distribution-partners": {
      const r = rows(await sb.from("exos_distribution_partners").select(PARTNER_COLS)
        .eq("org_id", orgId).order("created_at", { ascending: true }));
      return { ...r, partner_types: PARTNER_TYPES, scopes: ["inventory", "comps"] };
    }

    case "create-distribution-partner": {
      const b = unwrap(c.body, "distribution_partner");
      const scopes = b.scopes === undefined ? null : stringList(b.scopes, "scopes");
      return new Created({
        data: await rpc(sb, "_exos_dist_partner_create", {
          p_org_id: orgId, p_label: optString(b.label ?? b.name, "label", 80),
          p_partner_type: optString(b.partner_type ?? b.partnerType, "partner_type", 40) ?? "other",
          p_scopes: scopes, p_actor: c.cred.userId, p_api_key_id: apiKeyId(c),
        }),
      });
    }

    case "update-distribution-partner": {
      const id = uuidParam(c.params.id, "partner not found");
      const b = unwrap(c.body, "distribution_partner");
      const patch: Record<string, unknown> = {};
      for (const k of ["label", "active", "scopes"]) if (b[k] !== undefined) patch[k] = b[k];
      if (Object.keys(patch).length === 0) throw new ApiError(400, "send label, active or scopes.");
      return { data: await rpc(sb, "_exos_dist_partner_update", { p_org_id: orgId, p_id: id, p_patch: patch, p_api_key_id: apiKeyId(c) }) };
    }

    case "revoke-distribution-partner": {
      const id = uuidParam(c.params.id, "partner not found");
      return { data: await rpc(sb, "_exos_dist_partner_revoke", { p_org_id: orgId, p_id: id, p_api_key_id: apiKeyId(c) }) };
    }

    case "get-event-distribution": {
      const id = await ownEvent(c);
      return { data: await rpc(sb, "_exos_event_distribution_json", { p_event_id: id }) };
    }

    case "set-event-distribution": {
      const id = await ownEvent(c);
      // A content token may edit events but not partner settings: owners and managers only.
      requireRole(c, ["owner", "manager"]);
      const tiers = Array.isArray(c.body) ? c.body : c.body.tiers;
      if (!Array.isArray(tiers)) throw new ApiError(400, "tiers must be a list of { tier_id, enabled, partner_ids?, paused? }.");
      return {
        data: await rpc(sb, "_exos_tier_distribution_set", {
          p_org_id: orgId, p_event_id: id, p_tiers: tiers, p_actor: c.cred.userId,
        }),
      };
    }

    // -- Reservations of an event; organizer reservations --------------------
    case "list-ticket-reservations": {
      const id = await ownEvent(c);
      let q = sb.from("exos_partner_reservations").select(RESERVATION_COLS, { count: "exact" })
        .eq("org_id", orgId).eq("event_id", id);
      const status = c.q.get("status");
      if (status !== null) {
        if (!["active", "completed", "cancelled", "expired"].includes(status)) {
          throw new ApiError(400, "status must be active, completed, cancelled or expired.");
        }
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "get-ticket-reservation": {
      const id = await ownEvent(c);
      const token = tokenParam(c.params.token);
      const { data, error } = await sb.from("exos_partner_reservations").select(RESERVATION_COLS + ", lines, ticket_ids")
        .eq("org_id", orgId).eq("event_id", id).eq("token", token).maybeSingle();
      if (error) throw error;
      if (!data) throw new ApiError(404, "reservation not found");
      return { data };
    }

    case "build-organizer-reservation": {
      const id = await ownEvent(c);
      const p = unwrapParams(c.body, "ticket_reservation");
      return {
        data: await rpc(sb, "_exos_partner_reserve", {
          p_org_id: orgId, p_event_id: id, p_partner_id: null, p_api_key_id: c.cred.id,
          p_lines: parseOrderItems(p.order_items_attributes ?? p.order_items), p_attrs: {}, p_comp: false, p_dry_run: true,
        }),
      };
    }

    case "create-organizer-reservation": {
      const id = await ownEvent(c);
      const p = unwrapParams(c.body, "ticket_reservation");
      return new Created({
        data: await rpc(sb, "_exos_partner_reserve", {
          p_org_id: orgId, p_event_id: id, p_partner_id: null, p_api_key_id: c.cred.id,
          p_lines: parseOrderItems(p.order_items_attributes ?? p.order_items), p_attrs: reservationAttrs(p),
          p_comp: false, p_dry_run: false,
        }),
      });
    }

    case "update-organizer-reservation": {
      const token = await ownReservation(c, null);
      const r = await rpc(sb, "_exos_partner_reservation_update", {
        p_org_id: orgId, p_partner_id: null, p_token: token,
        p_attrs: reservationAttrs(unwrapParams(c.body, "ticket_reservation")),
      }) as Record<string, unknown>;
      if (r?.status === "expired") throw new ApiError(410, "this reservation expired; reserve again", { reason: "expired" });
      return { data: r };
    }

    case "cancel-organizer-reservation": {
      const token = await ownReservation(c, null);
      return { data: await rpc(sb, "_exos_partner_reservation_cancel", { p_org_id: orgId, p_partner_id: null, p_token: token }) };
    }

    case "complete-organizer-reservation": {
      const token = await ownReservation(c, null);
      const out = await rpc(sb, "_exos_partner_reservation_complete", {
        p_org_id: orgId, p_partner_id: null, p_token: token,
        p_attrs: reservationAttrs(unwrapParams(c.body, "ticket_reservation")), p_app_base: appBase(),
      }) as Record<string, unknown>;
      if (out.status === "expired") throw new ApiError(410, "this reservation expired; nothing was sold", { reason: "expired" });
      return out.fresh ? new Created({ data: out.order }) : { data: out.order };
    }

    // -- The team ----------------------------------------------------------------
    case "get-team": {
      await requireOwner(c);
      const { data, error } = await sb.from("exos_orgs").select("id, name, slug, created_at").eq("id", orgId).maybeSingle();
      if (error) throw error;
      return { data };
    }

    case "update-team": {
      await requireOwner(c);
      const b = unwrap(c.body, "team");
      const name = optString(b.name, "name", 80);
      if (!name) throw new ApiError(400, "send a name (1-80 characters).");
      const { data, error } = await sb.from("exos_orgs").update({ name }).eq("id", orgId)
        .select("id, name, slug, created_at").maybeSingle();
      if (error) throw error;
      return { data };
    }

    case "list-team-members": {
      await requireOwner(c);
      const { data, error } = await sb.from("exos_org_memberships").select("user_id, role, disabled")
        .eq("org_id", orgId).order("role").limit(500);
      if (error) throw error;
      const members = (data ?? []) as { user_id: string; role: string; disabled: boolean }[];
      const emails = await Promise.all(members.slice(0, 200).map(async (m) => {
        const { data: u } = await sb.auth.admin.getUserById(m.user_id);
        return u?.user?.email ?? null;
      }));
      return { data: members.map((m, i) => ({ id: m.user_id, user_id: m.user_id, email: emails[i] ?? null, role: m.role, disabled: m.disabled })) };
    }

    case "update-team-member": {
      await requireOwner(c);
      const uid = uuidParam(c.params.id, "member not found");
      const member = await nonOwnerMember(c, uid);
      const b = unwrap(c.body, "team_membership");
      const patch: Record<string, unknown> = {};
      if (b.role !== undefined) {
        if (typeof b.role !== "string" || !MEMBER_ROLES.has(b.role)) {
          throw new ApiError(400, "role must be manager, finance, content or scanner (ownership is changed in the dashboard).");
        }
        patch.role = b.role;
      }
      if (b.disabled !== undefined) {
        if (typeof b.disabled !== "boolean") throw new ApiError(400, "disabled must be true or false.");
        patch.disabled = b.disabled;
      }
      if (Object.keys(patch).length === 0) throw new ApiError(400, "send role or disabled.");
      // The offboarding trigger revokes the member's keys and tokens on a
      // demotion below manager or when disabled.
      const { data, error } = await sb.from("exos_org_memberships").update(patch)
        .eq("org_id", orgId).eq("user_id", member).select("user_id, role, disabled").maybeSingle();
      if (error) throw error;
      return { data: { id: data?.user_id, ...data } };
    }

    case "remove-team-member": {
      await requireOwner(c);
      const uid = uuidParam(c.params.id, "member not found");
      const member = await nonOwnerMember(c, uid);
      const { error } = await sb.from("exos_org_memberships").delete().eq("org_id", orgId).eq("user_id", member);
      if (error) throw error;
      return { data: { id: member, removed: true } };
    }

    case "list-team-invitations": {
      await requireOwner(c);
      return rowsWithIds(await sb.from("exos_org_invites").select("token, email, role, status, expires_at, created_at")
        .eq("org_id", orgId).order("created_at", { ascending: false }).limit(200));
    }

    case "create-team-invitation": {
      const actor = await requireOwner(c);
      const b = unwrap(c.body, "invitation");
      const email = typeof b.email === "string" ? b.email.trim().toLowerCase() : "";
      if (!EMAIL_RE.test(email) || email.length > 254) throw new ApiError(400, "email is not a valid address.");
      const role = typeof b.role === "string" ? b.role : "";
      if (!MEMBER_ROLES.has(role)) throw new ApiError(400, "role must be manager, finance, content or scanner.");
      const { data, error } = await sb.from("exos_org_invites").insert({
        org_id: orgId, email, role, created_by: actor, status: "pending",
        expires_at: new Date(Date.now() + 14 * 86_400_000).toISOString(),
      }).select("token, email, role, status, expires_at, created_at").single();
      if (error) throw error;
      const base = appBase();
      return new Created({ data: { id: data.token, ...data, invite_url: base ? `${base}/invite/${data.token}` : null } });
    }

    case "cancel-team-invitation": {
      await requireOwner(c);
      const token = uuidParam(c.params.id, "invitation not found");
      const { data, error } = await sb.from("exos_org_invites").update({ status: "cancelled" })
        .eq("org_id", orgId).eq("token", token).eq("status", "pending").select("token").maybeSingle();
      if (error) throw error;
      if (!data) throw new ApiError(404, "invitation not found");
      return { data: { id: token, status: "cancelled" } };
    }

    case "list-team-roles":
      return {
        data: ORG_ROLES.map((r) => ({ id: r, name: r, description: ROLE_INFO[r], token_scopes: ROLE_SCOPES[r] })),
      };

    case "list-my-memberships": {
      if (!c.cred.userId) throw new ApiError(400, "an organization API key belongs to one organization; use GET /v1/me");
      const { data, error } = await sb.from("exos_org_memberships").select("org_id, role, disabled, exos_orgs(name, slug)")
        .eq("user_id", c.cred.userId).eq("disabled", false);
      if (error) throw error;
      // deno-lint-ignore no-explicit-any
      return { data: (data ?? []).map((m: any) => ({
        org_id: m.org_id, name: m.exos_orgs?.name ?? null, slug: m.exos_orgs?.slug ?? null, role: m.role,
        current: m.org_id === orgId,
      })) };
    }

    case "revoke-current-token": {
      if (c.cred.kind !== "pat") {
        throw new ApiError(400, c.cred.kind === "oauth"
          ? "revoke an OAuth token at the authorization server's /revoke"
          : "API keys are revoked in Org settings");
      }
      await rpc(sb, "_exos_pat_revoke_self", { p_id: c.cred.id });
      return { data: { id: c.cred.id, revoked: true } };
    }
  }
  throw new ApiError(404, "not found");
}

/** The credential's own id when it is an org API key (the SQL checks its creator is an owner). */
function apiKeyId(c: Ctx): string | null {
  return c.cred.kind === "api_key" ? c.cred.id : null;
}

/** User tokens: the user's live role must be one of `roles`. API keys pass (their scopes decide). */
function requireRole(c: Ctx, roles: string[]) {
  if (c.cred.role !== null && !roles.includes(c.cred.role)) {
    throw new ApiError(403, `this needs an organization ${roles.join(" or ")}`);
  }
}

/**
 * Team management is the owner's, as in the dashboard: a user token's user is
 * an owner now, or an API key's creator is. Returns the acting user.
 */
async function requireOwner(c: Ctx): Promise<string | null> {
  if (c.cred.kind !== "api_key") {
    if (c.cred.role !== "owner") throw new ApiError(403, "only an organization owner can manage the team");
    return c.cred.userId;
  }
  const ok = await rpc(c.sb, "_exos_api_key_creator_is_owner", { p_org_id: c.orgId, p_api_key_id: c.cred.id });
  if (ok !== true) throw new ApiError(403, "only a key made by an organization owner can manage the team");
  const { data } = await c.sb.from("exos_api_keys").select("created_by").eq("id", c.cred.id).maybeSingle();
  return (data?.created_by as string | null) ?? null;
}

/** A member of the org who isn't an owner (owners are changed in the dashboard). */
async function nonOwnerMember(c: Ctx, uid: string): Promise<string> {
  const { data, error } = await c.sb.from("exos_org_memberships").select("user_id, role")
    .eq("org_id", c.orgId).eq("user_id", uid).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "member not found");
  if (data.role === "owner") throw new ApiError(409, "owners are changed in the dashboard, not through the API");
  return uid;
}

/** An organizer reservation of this event, by its :token (404 otherwise). */
async function ownReservation(c: Ctx, partnerId: string | null): Promise<string> {
  const id = await ownEvent(c);
  const token = tokenParam(c.params.token);
  let q = c.sb.from("exos_partner_reservations").select("id").eq("org_id", c.orgId).eq("event_id", id).eq("token", token);
  q = partnerId ? q.eq("partner_id", partnerId) : q.eq("channel", "organizer");
  const { data, error } = await q.maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "reservation not found");
  return token;
}

// -- The partner contract (/public/…) ------------------------------------------------

async function partnerApi(req: Request, url: URL, path: string): Promise<Response> {
  const noStore = { "cache-control": "no-store" };
  const method = req.method.toUpperCase();
  const match = matchRoute(method, path);
  if (!match || match.route.auth !== "partner_key") {
    const allow = methodsAt(path);
    if (allow.length) return json({ error: "method not allowed" }, 405, { ...noStore, allow: allow.join(", ") });
    return json({ error: "not found", hint: "see /developers for the API reference" }, 404, noStore);
  }
  const key = presentedPartnerKey(url.searchParams, (h) => req.headers.get(h));
  if (!key) return json({ error: "Missing shared_key." }, 401, noStore);
  if (!PARTNER_KEY_RE.test(key)) return json({ error: "Invalid or revoked shared_key." }, 401, noStore);

  const sb = service();
  const { data: partner, error: authErr } = await sb.rpc("exos_dist_partner_auth", { p_key_hash: await sha256Hex(key) });
  if (authErr) {
    console.error("exos-api: partner key lookup failed", authErr.message);
    return json({ error: "temporarily unavailable" }, 503, { ...noStore, "retry-after": "30" });
  }
  if (!partner) return json({ error: "Invalid or revoked shared_key." }, 401, noStore);
  const p = partner as { id: string; org_id: string; partner_type: string; scopes: string[] };

  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `dist:${p.id}`, p_limit: RATE_LIMIT });
  if (rlErr) return json({ error: "temporarily unavailable" }, 503, { ...noStore, "retry-after": "30" });
  if (allowed === false) return rateLimited();

  const needed = match.route.id === "public-create-comp" ? "comps" : "inventory";
  if (!p.scopes.includes(needed)) {
    return json({ error: `This key does not have the "${needed}" scope.` }, 403, noStore);
  }

  try {
    const body = method === "POST" || method === "PUT" ? await readBody(req, true) : {};
    const out = await partnerHandle(match.route.id, sb, p, match.params, url.searchParams, body);
    return out instanceof Created ? json(out.body, 201, noStore) : json(out, 200, noStore);
  } catch (e) {
    return errorResponse(e, "exos-api partner", noStore);
  }
}

async function partnerHandle(
  id: string, sb: SupabaseClient, p: { id: string; org_id: string }, params: Record<string, string>,
  q: URLSearchParams, body: Record<string, unknown>,
): Promise<unknown> {
  const org = p.org_id;
  const eventId = () => uuidParam(params.id, "Event not found.");
  switch (id) {
    case "public-list-ticket-types":
      return await rpc(sb, "_exos_partner_ticket_types", { p_org_id: org, p_partner_id: p.id, p_event_id: eventId() });

    case "public-create-reservation": {
      const r = unwrapParams(body, "ticket_reservation");
      if (r.resale_order_items_attributes !== undefined) {
        throw new ApiError(422, "resale order items are not sold through this API");
      }
      return new Created(await rpc(sb, "_exos_partner_reserve", {
        p_org_id: org, p_event_id: eventId(), p_partner_id: p.id, p_api_key_id: null,
        p_lines: parseOrderItems(r.order_items_attributes ?? r.order_items), p_attrs: reservationAttrs(r),
        p_comp: false, p_dry_run: false,
      }));
    }

    case "public-get-reservation":
      return await rpc(sb, "_exos_partner_reservation_get", {
        p_org_id: org, p_partner_id: p.id, p_token: await partnerReservation(sb, p, eventId(), params.token),
      });

    case "public-update-reservation": {
      const token = await partnerReservation(sb, p, eventId(), params.token);
      const r = await rpc(sb, "_exos_partner_reservation_update", {
        p_org_id: org, p_partner_id: p.id, p_token: token, p_attrs: reservationAttrs(unwrapParams(body, "ticket_reservation")),
      }) as Record<string, unknown>;
      if (r?.status === "expired") throw new ApiError(410, "This reservation expired; reserve again.", { reason: "expired" });
      return r;
    }

    case "public-cancel-reservation": {
      const token = await partnerReservation(sb, p, eventId(), params.token);
      return await rpc(sb, "_exos_partner_reservation_cancel", { p_org_id: org, p_partner_id: p.id, p_token: token });
    }

    case "public-complete-reservation": {
      const token = await partnerReservation(sb, p, eventId(), params.token);
      const r = unwrapParams(body, "ticket_reservation");
      const out = await rpc(sb, "_exos_partner_reservation_complete", {
        p_org_id: org, p_partner_id: p.id, p_token: token, p_attrs: reservationAttrs(r), p_app_base: appBase(),
      }) as Record<string, unknown>;
      if (out.status === "expired") {
        throw new ApiError(410, "This reservation expired; nothing was sold and the seats were released.", { reason: "expired" });
      }
      const order = withLinks(out.order as Record<string, unknown>, q.get("include_ticket_pdfs") ?? r.include_ticket_pdfs);
      return out.fresh ? new Created(order) : order;
    }

    case "public-create-comp": {
      const r = unwrapParams(body, "comp");
      return new Created((await rpc(sb, "_exos_partner_comp", {
        p_org_id: org, p_partner_id: p.id, p_event_id: eventId(),
        p_lines: parseOrderItems(r.order_items_attributes ?? r.order_items), p_attrs: reservationAttrs(r),
        p_app_base: appBase(),
      }) as Record<string, unknown>).order);
    }

    case "public-list-orders": {
      const pg = opendatePage(q);
      return await rpc(sb, "_exos_partner_orders", {
        p_org_id: org, p_partner_id: p.id, p_filters: orderFilters(q), p_page: pg.page, p_per_page: pg.perPage,
        p_app_base: appBase(),
      });
    }

    case "public-get-order":
      return await partnerOrder(sb, p, params.id);

    case "public-list-ticket-links": {
      const o = await partnerOrder(sb, p, params.id);
      return { order_id: o.id, ticket_pdfs: ticketLinks(o) };
    }

    case "public-get-ticket-link": {
      const o = await partnerOrder(sb, p, params.id);
      const t = ticketLinks(o).find((x) => x.ticket_id === params.ticket);
      if (!t) throw new ApiError(404, "Ticket not found.");
      return t;
    }
  }
  throw new ApiError(404, "not found");
}

/** The partner's reservation for this event (404 for any other). */
async function partnerReservation(sb: SupabaseClient, p: { id: string; org_id: string }, eventId: string, raw: string): Promise<string> {
  const token = tokenParam(raw);
  const { data, error } = await sb.from("exos_partner_reservations").select("id")
    .eq("org_id", p.org_id).eq("partner_id", p.id).eq("event_id", eventId).eq("token", token).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "Reservation not found.");
  return token;
}

async function partnerOrder(sb: SupabaseClient, p: { id: string; org_id: string }, raw: string): Promise<Record<string, unknown>> {
  const id = uuidParam(raw, "Order not found.");
  const o = await rpc(sb, "_exos_partner_order", { p_org_id: p.org_id, p_partner_id: p.id, p_order_id: id, p_app_base: appBase() });
  if (!o) throw new ApiError(404, "Order not found.");
  return o as Record<string, unknown>;
}

/**
 * Opendate's ticket_pdfs, Exos-style: each ticket's live link instead of a
 * PDF (the door code is only on the live ticket; a PDF would be a static
 * barcode anyone could copy).
 */
function ticketLinks(o: Record<string, unknown>) {
  const tickets = (o.tickets ?? []) as { id: string; product_name?: string; delivery?: { url?: string | null } | null }[];
  return tickets.map((t) => ({
    ticket_id: t.id, product_name: t.product_name ?? null, url: t.delivery?.url ?? null,
    content_type: null, content_base64: null,
  }));
}

function withLinks(order: Record<string, unknown>, include: unknown): Record<string, unknown> {
  const on = include === true || include === "true" || include === "1";
  return on ? { ...order, ticket_pdfs: ticketLinks(order) } : order;
}

// -- Helpers -------------------------------------------------------------------------

function rateLimited(): Response {
  const retryAfter = Math.max(1, 60 - new Date().getUTCSeconds());
  return json({ error: "rate limit exceeded", limit_per_minute: RATE_LIMIT }, 429, { "retry-after": String(retryAfter) });
}

/** The SQLSTATEs the write functions raise, as HTTP answers. */
const RPC_STATUS: Record<string, number> = {
  "22023": 400, "42501": 403, "P0002": 404, "23505": 409, "55000": 409, "54000": 409,
  EX409: 409, EX422: 422, EXSLD: 409,
};

function errorResponse(e: unknown, where: string, extra: Record<string, string> = {}): Response {
  if (e instanceof PagingError || e instanceof ParamError) return json({ error: e.message }, 400, extra);
  if (e instanceof ApiError) return json({ error: e.message, ...e.extra }, e.status, extra);
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  if (code in RPC_STATUS) {
    const body: Record<string, unknown> = { error: String(err?.message ?? "invalid request").slice(0, 300) };
    if (code === "EXSLD") body.reason = "sold_out";
    if (code === "EX422") body.reason = "not_available";
    return json(body, RPC_STATUS[code], extra);
  }
  console.error(`${where} error:`, e);
  return json({ error: "internal error" }, 500, extra);
}

async function rpc(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/**
 * A write body: JSON, or form-encoded (Rails-style nesting for the partner
 * contract). Read with a running byte cap (_shared/api/body.ts).
 */
async function readBody(req: Request, rails = false): Promise<Record<string, unknown>> {
  const text = await readCapped(req, MAX_BODY_BYTES);
  if (text === null) throw new ApiError(413, "request body is too large");
  if (!text.trim()) return {};
  if ((req.headers.get("content-type") ?? "").toLowerCase().includes("application/x-www-form-urlencoded")) {
    return railsFormBody(text);
  }
  try {
    const v = JSON.parse(text);
    if (v && typeof v === "object") return v as Record<string, unknown>;
  } catch { /* fall through */ }
  if (rails) throw new ApiError(400, "the body must be JSON or form-encoded");
  throw new ApiError(400, "the body must be a JSON object");
}

/** `{ wrapper: {...} }` or the body itself. */
function unwrap(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const w = body[wrapper];
  return w && typeof w === "object" && !Array.isArray(w) ? w as Record<string, unknown> : body;
}

function optString(v: unknown, name: string, max: number): string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string" || v.trim().length > max) throw new ApiError(400, `${name} must be at most ${max} characters.`);
  return v.trim();
}

function stringList(v: unknown, name: string): string[] {
  if (!Array.isArray(v) || v.length > 20 || !v.every((x) => typeof x === "string")) {
    throw new ApiError(400, `${name} must be a list of strings.`);
  }
  return v as string[];
}

function uuidParam(raw: string | undefined, notFound: string): string {
  if (!raw || !UUID_RE.test(raw)) throw new ApiError(404, notFound);
  return raw.toLowerCase();
}

function tokenParam(raw: string | undefined): string {
  if (!raw || !RESERVATION_TOKEN_RE.test(raw)) throw new ApiError(404, "Reservation not found.");
  return raw;
}

// deno-lint-ignore no-explicit-any
function rowsWithIds(r: { data: any; error: unknown }): { data: unknown[] } {
  if (r.error) throw r.error;
  return { data: ((r.data ?? []) as Record<string, unknown>[]).map((x) => ({ id: x.token, ...x })) };
}

/** The :id path parameter as an event id; anything but a UUID is simply not found. */
function eventId(c: Ctx): string {
  const id = c.params.id;
  if (!UUID_RE.test(id)) throw new ApiError(404, "event not found");
  return id;
}

/** Confirm the event belongs to the key's org before exposing anything under it. */
async function ownEvent(c: Ctx): Promise<string> {
  const id = eventId(c);
  const { data, error } = await c.sb.from("exos_events").select("id").eq("org_id", c.orgId).eq("id", id).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "event not found");
  return id;
}

async function tiers(sb: SupabaseClient, eventId: string): Promise<unknown[]> {
  const { data, error } = await sb.from("exos_ticket_tiers").select(TIER_COLS)
    .eq("event_id", eventId).order("sort_order", { ascending: true });
  if (error) throw error;
  return data ?? [];
}

function isoParam(q: URLSearchParams, name: string): string | null {
  const v = q.get(name);
  if (v === null) return null;
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v) || Number.isNaN(Date.parse(v))) {
    throw new ApiError(400, `${name} must be an ISO 8601 date or time.`);
  }
  return new Date(v).toISOString();
}

// deno-lint-ignore no-explicit-any
function rows(r: { data: any; error: unknown }): { data: unknown[] } {
  if (r.error) throw r.error;
  return { data: r.data ?? [] };
}

// deno-lint-ignore no-explicit-any
function paged(r: { data: any; error: any; count: number | null }, page: Page) {
  if (r.error) {
    // A page past the end: PostgREST answers 416 (PGRST103) with "…there are
    // only N rows" instead of an empty list. Give the client an empty page.
    if (r.error.code === "PGRST103") {
      const m = /only (\d+) rows?/.exec(String(r.error.details ?? ""));
      return pageEnvelope([], page, m ? Number(m[1]) : null);
    }
    throw r.error;
  }
  return pageEnvelope(r.data ?? [], page, r.count);
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}
