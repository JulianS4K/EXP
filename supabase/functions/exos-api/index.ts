// exos-api — org-scoped partner REST API for Exos.
// Reference: docs/api-reference.md and /developers (built from docs/api/*.json).
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to, and the key's scopes. Reads everywhere; the writes are fan
// contacts and tags (mig 20261031120000), each through a service-role SQL
// function that takes the key's org explicitly and never touches consent.
//
// Scopes (mig 20261027090000, _shared/api/scopes.ts): each route needs one
// (_shared/api/routes.ts). Keys made before scopes carry the legacy `read`,
// which covers every `:read` scope. Missing scope → 403 + WWW-Authenticate.
//
// Rate limit: 120 requests per key per minute; over it → 429 with Retry-After.
//
// Lists are paged: ?page=1&per_page=50 (max 200) → { data, meta }.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Endpoints (all GET, all scoped to the key's org; each also under /v1):
//   /me, /events, /events/:id, /events/:id/{ticket-types, add-ons, promo-codes,
//   attendees, check-ins, check-in-lists, guest-lists, waitlist}, /orders,
//   /orders/:id, /invoices, /refunds, /webhooks;
//   GET/POST /fans, GET /fans/lookup, GET/PATCH/DELETE /fans/:id,
//   GET /signup-forms, GET/POST /tags, GET/PATCH/DELETE /tags/:id,
//   GET/POST /tagged-items, GET/DELETE /tagged-items/:id, GET /canonical-tags,
//   GET /refund-requests (docs/fans.md). A fan's tags also need fans:read /
//   fans:write on top of the route's events:* scope.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { API_METHODS, apiPath, matchRoute, type ApiMethod, type ApiRoute } from "../_shared/api/routes.ts";
import { effectiveScopes, hasScope, type Scope } from "../_shared/api/scopes.ts";
import { pageEnvelope, PagingError, parsePage, type Page } from "../_shared/api/paging.ts";
import { formBody, MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";

const RATE_LIMIT = 120; // requests per key per minute
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;

const EVENT_LIST_COLS = "id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at";
const EVENT_COLS =
  "id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, " +
  "tickets_sold, total_tickets, created_at";
const TIER_COLS =
  "id, name, description, price, capacity, sold, ticket_type, visibility, sales_start, sales_end, sort_order";
const ORDER_COLS =
  "session_id, event_id, status, quantity, amount_cents, tax_cents, currency, buyer_email, created_at, fulfilled_at";

const EVENT_STATUSES = new Set(["draft", "published", "cancelled"]);
const TAG_COLS = "id, name, scope, color, canonical_tag_id, created_at, updated_at";
const TAGGED_COLS = "id, tag_id, taggable_type, taggable_id, created_at";
const TAGGABLE = new Set(["event", "fan", "artist"]);
const FAN_SORTS = new Set(["created_at", "updated_at", "last_order_at", "email"]);
const ASK_STATUSES = new Set(["open", "refunded", "declined", "withdrawn"]);

class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface Ctx {
  sb: SupabaseClient;
  orgId: string;
  key: { id: string; name: string | null; key_prefix: string; scopes: string[] };
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const method = req.method.toUpperCase() as ApiMethod;
  if (!API_METHODS.includes(method)) return json({ error: "method not allowed" }, 405, { allow: API_METHODS.join(", ") });

  const auth = req.headers.get("Authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!key) return json({ error: "missing bearer API key" }, 401);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const keyHash = await sha256Hex(key);
  const { data: keyRow } = await sb
    .from("exos_api_keys")
    .select("id, org_id, name, key_prefix, scopes, revoked_at")
    .eq("key_hash", keyHash)
    .is("revoked_at", null)
    .maybeSingle();
  if (!keyRow) return json({ error: "invalid or revoked API key" }, 401);
  const orgId = keyRow.org_id as string;

  // Per-key rate limit: RATE_LIMIT requests per clock minute (fixed window,
  // exos_api_rate_hit, mig 20260925020000). Over the limit → 429 + Retry-After
  // (seconds to the next window). If the counter itself errors the request is
  // refused (503): the API returns attendee PII, so no limiter, no answer.
  const { data: allowed, error: rlErr } = await sb.rpc("exos_api_rate_hit", {
    p_key_id: keyRow.id, p_limit: RATE_LIMIT,
  });
  if (rlErr) {
    console.error("exos-api: rate limiter error (refusing request)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
  }
  if (allowed === false) {
    const retryAfter = Math.max(1, 60 - new Date().getUTCSeconds());
    return json({ error: "rate limit exceeded", limit_per_minute: RATE_LIMIT }, 429, {
      "retry-after": String(retryAfter),
    });
  }

  // Best-effort last-used stamp — awaited so it actually lands before the
  // serverless invocation returns (don't fail the request if it doesn't write).
  try {
    await sb.from("exos_api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", keyRow.id);
  } catch { /* best-effort */ }

  const url = new URL(req.url);
  const match = matchRoute(method, apiPath(url.pathname));
  if (!match) {
    return json({ error: "not found", hint: "see /developers for the API reference" }, 404);
  }
  const scopes = (keyRow.scopes ?? []) as string[];
  if (match.route.scope && !hasScope(scopes, match.route.scope)) {
    return json({ error: "insufficient scope", required_scope: match.route.scope }, 403, {
      "www-authenticate": `Bearer error="insufficient_scope", scope="${match.route.scope}"`,
    });
  }

  try {
    const ctx: Ctx = {
      sb, orgId,
      key: { id: keyRow.id, name: keyRow.name, key_prefix: keyRow.key_prefix, scopes },
      params: match.params,
      q: url.searchParams,
      // Only lists read ?page / ?per_page; elsewhere they are ignored.
      page: parsePage(match.route.paged ? url.searchParams : new URLSearchParams()),
      body: method === "POST" || method === "PUT" || method === "PATCH" ? await readBody(req) : {},
    };
    const out = await handle(match.route, ctx);
    return out instanceof Created ? json(out.body, 201) : json(out);
  } catch (e) {
    if (e instanceof PagingError) return json({ error: e.message }, 400);
    if (e instanceof ScopeError) {
      return json({ error: "insufficient scope", required_scope: e.scope }, 403, {
        "www-authenticate": `Bearer error="insufficient_scope", scope="${e.scope}"`,
      });
    }
    if (e instanceof ApiError) return json({ error: e.message }, e.status);
    const mapped = rpcError(e);
    if (mapped) return json({ error: mapped.message }, mapped.status);
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

/** A 201 answer from handle(). */
class Created {
  constructor(public body: unknown) {}
}

/** A request that needs a second scope (a fan's tags need fans:*). */
class ScopeError extends Error {
  constructor(public scope: Scope) {
    super("insufficient scope");
  }
}

async function handle(route: ApiRoute, c: Ctx): Promise<unknown> {
  const { sb, orgId, page } = c;
  switch (route.id) {
    case "me": {
      const { data: org } = await sb.from("exos_orgs").select("id, name, slug").eq("id", orgId).maybeSingle();
      return {
        data: {
          org,
          key: { id: c.key.id, name: c.key.name, key_prefix: c.key.key_prefix, scopes: c.key.scopes },
          effective_scopes: effectiveScopes(c.key.scopes),
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
      const tagId = c.q.get("tag_id");
      if (tagId !== null) q = q.in("id", await taggedIds(c, "event", tagId));
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

    // -- Fans (mig 20261031120000). Consent is shown, never set. ---------------
    case "list-fans": {
      const sortRaw = (c.q.get("order_by") ?? "created_at").trim().toLowerCase();
      if (!FAN_SORTS.has(sortRaw)) throw new ApiError(400, "order_by must be created_at, updated_at, last_order_at or email.");
      const dir = (c.q.get("order") ?? "desc").trim().toLowerCase();
      if (dir !== "asc" && dir !== "desc") throw new ApiError(400, "order must be asc or desc.");
      const search = (c.q.get("q") ?? c.q.get("q[email_cont]") ?? c.q.get("q[first_name_cont]") ?? "").trim();
      if (search.length > 100) throw new ApiError(400, "q is at most 100 characters.");
      const email = c.q.get("email");
      const tag = c.q.get("tag_id");
      if (tag !== null && !UUID_RE.test(tag)) throw new ApiError(400, "tag_id must be a UUID.");
      const r = await rpc(sb, "_exos_fans_page", {
        p_org_id: orgId, p_search: search || null, p_email: email, p_tag_ids: tag ? [tag] : null,
        p_updated_after: isoParam(c.q, "updated_after"), p_sort: `${sortRaw} ${dir}`,
        p_limit: page.perPage, p_offset: page.from,
      }) as { total?: number; rows?: unknown[] } | null;
      return pageEnvelope(r?.rows ?? [], page, r?.total ?? 0);
    }

    case "lookup-fans": {
      // Narrow and fixed: each given field matches partially (AND), at most 3, by id.
      const fields: [string, string][] = [];
      for (const f of ["first_name", "last_name", "email"]) {
        const v = (c.q.get(f) ?? "").trim();
        if (v.length > 100) throw new ApiError(400, `${f} is at most 100 characters.`);
        if (v) fields.push([f, v]);
      }
      if (fields.length === 0) throw new ApiError(400, "give first_name, last_name or email.");
      let q = sb.from("exos_fans").select("id, email, first_name, last_name")
        .eq("org_id", orgId).is("discarded_at", null);
      for (const [f, v] of fields) q = q.ilike(f, `%${escapeLike(v)}%`);
      return rows(await q.order("id").limit(3));
    }

    case "get-fan": {
      const d = await rpc(sb, "_exos_fan_detail", { p_org_id: orgId, p_fan_id: fanId(c) });
      if (!d) throw new ApiError(404, "fan not found");
      return { data: d };
    }

    case "create-fan":
      return new Created({
        data: await rpc(sb, "_exos_fan_save", { p_org_id: orgId, p_fan_id: null, p_fields: unwrap(c.body, "fan"), p_source: "api" }),
      });

    case "update-fan":
      return { data: await rpc(sb, "_exos_fan_save", { p_org_id: orgId, p_fan_id: fanId(c), p_fields: unwrap(c.body, "fan"), p_source: "api" }) };

    case "discard-fan": {
      const id = fanId(c);
      await rpc(sb, "_exos_fan_discard", { p_org_id: orgId, p_fan_id: id });
      return { data: { id, discarded: true } };
    }

    case "list-signup-forms":
      return rows(await sb.from("exos_signup_forms")
        .select("id, name, title, intro, button_label, ask_name, offer_sms, default_tag_ids, status, created_at, updated_at")
        .eq("org_id", orgId).neq("status", "archived").order("created_at", { ascending: false }));

    // -- Tags ----------------------------------------------------------------------
    case "list-tags": {
      let q = sb.from("exos_tags").select(TAG_COLS).eq("org_id", orgId);
      const scope = c.q.get("scope");
      if (scope !== null) {
        const s = normTaggable(scope);
        if (!s) throw new ApiError(400, "scope must be event, fan or artist.");
        q = q.or(`scope.is.null,scope.eq.${s}`);
      }
      return rows(await q.order("name").order("id"));
    }

    case "get-tag": {
      const { data, error } = await sb.from("exos_tags").select(TAG_COLS).eq("org_id", orgId).eq("id", tagId(c)).maybeSingle();
      if (error) throw error;
      if (!data) throw new ApiError(404, "tag not found");
      return { data };
    }

    case "create-tag":
      return new Created({ data: await rpc(sb, "_exos_tag_save", { p_org_id: orgId, p_tag_id: null, p_fields: tagFields(c.body), p_actor: null }) });

    case "update-tag":
      return { data: await rpc(sb, "_exos_tag_save", { p_org_id: orgId, p_tag_id: tagId(c), p_fields: tagFields(c.body), p_actor: null }) };

    case "delete-tag": {
      const id = tagId(c);
      await rpc(sb, "_exos_tag_delete", { p_org_id: orgId, p_tag_id: id });
      return { data: { id, deleted: true } };
    }

    case "list-tagged-items": {
      let q = sb.from("exos_tagged_items").select(TAGGED_COLS, { count: "exact" }).eq("org_id", orgId);
      const typeRaw = c.q.get("taggable_type");
      const type = typeRaw === null ? null : normTaggable(typeRaw);
      if (typeRaw !== null && !type) throw new ApiError(400, "taggable_type must be event, fan or artist.");
      // Without fans:read a fan's tags are left out (asking for fans is refused).
      if (!hasScope(c.key.scopes, "fans:read")) {
        if (type === "fan") throw new ScopeError("fans:read");
        q = q.neq("taggable_type", "fan");
      }
      if (type) q = q.eq("taggable_type", type);
      const tid = c.q.get("taggable_id");
      if (tid !== null) {
        if (!UUID_RE.test(tid)) throw new ApiError(400, "taggable_id must be a UUID.");
        q = q.eq("taggable_id", tid);
      }
      const tag = c.q.get("tag_id");
      if (tag !== null) {
        if (!UUID_RE.test(tag)) throw new ApiError(400, "tag_id must be a UUID.");
        q = q.eq("tag_id", tag);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "get-tagged-item": {
      const item = await ownTaggedItem(c);
      if (item.taggable_type === "fan") needScope(c, "fans:read");
      return { data: item };
    }

    case "create-tagged-item": {
      const b = unwrap(c.body, "tagged_item");
      const type = normTaggable(String(b.taggable_type ?? ""));
      if (!type) throw new ApiError(400, "taggable_type must be event, fan or artist.");
      if (type === "fan") needScope(c, "fans:write");
      const id = String(b.taggable_id ?? "");
      if (!UUID_RE.test(id)) throw new ApiError(400, "taggable_id must be a UUID.");
      const attrs = b.tag_attributes && typeof b.tag_attributes === "object" ? b.tag_attributes as Record<string, unknown> : {};
      const tag = b.tag_id ?? null;
      const name = attrs.name ?? b.tag_name ?? null;
      if (tag !== null && (typeof tag !== "string" || !UUID_RE.test(tag))) throw new ApiError(400, "tag_id must be a UUID.");
      if (name !== null && typeof name !== "string") throw new ApiError(400, "tag_attributes[name] must be text.");
      if (tag === null && !name) throw new ApiError(400, "give tag_id or tag_attributes[name].");
      const out = await rpc(sb, "_exos_tag_apply", {
        p_org_id: orgId, p_tag_id: tag, p_tag_name: name, p_type: type, p_id: id, p_actor: null,
      }) as Record<string, unknown>;
      return out.created ? new Created({ data: out }) : { data: out };
    }

    case "delete-tagged-item": {
      const item = await ownTaggedItem(c);
      if (item.taggable_type === "fan") needScope(c, "fans:write");
      await rpc(sb, "_exos_tagged_item_delete", { p_org_id: orgId, p_item_id: item.id });
      return { data: { id: item.id, deleted: true } };
    }

    case "list-canonical-tags": {
      let q = sb.from("exos_canonical_tags").select("id, category, name");
      const name = (c.q.get("q") ?? c.q.get("q[name_cont]") ?? "").trim();
      if (name.length > 40) throw new ApiError(400, "q is at most 40 characters.");
      if (name) q = q.ilike("name", `%${escapeLike(name)}%`);
      const cat = c.q.get("category");
      if (cat !== null) q = q.eq("category", cat);
      return rows(await q.order("category").order("sort_order").order("id"));
    }

    // -- Refund requests (the buyer asks; the dashboard decides) -------------------
    case "list-refund-requests": {
      const status = c.q.get("status");
      if (status !== null && !ASK_STATUSES.has(status)) throw new ApiError(400, "status must be open, refunded, declined or withdrawn.");
      const ev = c.q.get("event_id");
      if (ev !== null && !UUID_RE.test(ev)) throw new ApiError(400, "event_id must be a UUID.");
      const r = await rpc(sb, "exos_api_refund_asks", {
        p_org_id: orgId, p_status: status, p_event_id: ev, p_limit: page.perPage, p_offset: page.from,
      }) as { total?: number; rows?: unknown[] } | null;
      return pageEnvelope(r?.rows ?? [], page, r?.total ?? 0);
    }
  }
  throw new ApiError(404, "not found");
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

function fanId(c: Ctx): string {
  if (!UUID_RE.test(c.params.id)) throw new ApiError(404, "fan not found");
  return c.params.id;
}

function tagId(c: Ctx): string {
  if (!UUID_RE.test(c.params.id)) throw new ApiError(404, "tag not found");
  return c.params.id;
}

function needScope(c: Ctx, scope: Scope): void {
  if (!hasScope(c.key.scopes, scope)) throw new ScopeError(scope);
}

/** "event" / "Event" / Opendate's "CalendarEvent" / "Fan" / "Artist" → our type. */
function normTaggable(raw: string): "event" | "fan" | "artist" | null {
  const t = raw.trim().toLowerCase();
  const alias: Record<string, string> = { calendarevent: "event", confirm: "event" };
  const v = alias[t] ?? t;
  return TAGGABLE.has(v) ? v as "event" | "fan" | "artist" : null;
}

function tagFields(body: Record<string, unknown>): Record<string, unknown> {
  const b = unwrap(body, "tag");
  const out: Record<string, unknown> = {};
  for (const k of ["name", "color", "canonical_tag_id"]) if (k in b) out[k] = b[k];
  if ("scope" in b) out.scope = b.scope === null || b.scope === "" ? null : normTaggable(String(b.scope)) ?? String(b.scope);
  return out;
}

async function ownTaggedItem(c: Ctx): Promise<{ id: string; taggable_type: string } & Record<string, unknown>> {
  if (!UUID_RE.test(c.params.id)) throw new ApiError(404, "tagged item not found");
  const { data, error } = await c.sb.from("exos_tagged_items").select(TAGGED_COLS)
    .eq("org_id", c.orgId).eq("id", c.params.id).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "tagged item not found");
  return data as unknown as { id: string; taggable_type: string } & Record<string, unknown>;
}

/** Ids of this type carrying the tag (an unknown tag matches nothing). */
async function taggedIds(c: Ctx, type: string, tag: string): Promise<string[]> {
  if (!UUID_RE.test(tag)) throw new ApiError(400, "tag_id must be a UUID.");
  const { data, error } = await c.sb.from("exos_tagged_items").select("taggable_id")
    .eq("org_id", c.orgId).eq("taggable_type", type).eq("tag_id", tag).limit(10000);
  if (error) throw error;
  const ids = ((data ?? []) as { taggable_id: string }[]).map((r) => r.taggable_id);
  // PostgREST needs a non-empty list; the nil UUID matches nothing.
  return ids.length ? ids : ["00000000-0000-0000-0000-000000000000"];
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

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

function unwrap(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const inner = body[wrapper];
  return inner && typeof inner === "object" && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const text = await readCapped(req, MAX_BODY_BYTES);
  if (text === null) throw new ApiError(413, "request body is too large");
  if (!text.trim()) return {};
  if ((req.headers.get("content-type") ?? "").toLowerCase().includes("application/x-www-form-urlencoded")) {
    return formBody(text);
  }
  try {
    const v = JSON.parse(text);
    if (v && typeof v === "object") return v as Record<string, unknown>;
  } catch { /* fall through */ }
  throw new ApiError(400, "the body must be a JSON object");
}

async function rpc(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

const RPC_STATUS: Record<string, number> = {
  "22023": 400, "42501": 403, "P0002": 404, "23505": 409, "55000": 409, "54000": 409,
};

function rpcError(e: unknown): { status: number; message: string } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  if (!(code in RPC_STATUS)) return null;
  return { status: RPC_STATUS[code], message: String(err?.message ?? "invalid request").slice(0, 300) };
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}
