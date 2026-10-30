// exos-api — org-scoped partner REST API for Exos.
// Reference: docs/api-reference.md and /developers (built from docs/api/*.json).
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to, and the key's scopes. Reads everywhere; writes only for
// booking (venues, rooms, holds, show schedule, notes, contacts; mig
// 20261030100000), each behind a `:write` scope. Hold writes go through the
// _exos_hold_* SQL functions (levels, promotion and convert in one
// transaction, hold.* webhooks); the rest are plain rows whose triggers and
// checks validate them. Every query names the key's org: this function runs
// with the service role, so RLS does not scope it.
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
// Endpoints (all scoped to the key's org; each also under /v1): the table in
// _shared/api/routes.ts. GET /me, /events…, /orders…, /invoices, /refunds,
// /webhooks; booking: /venues, /rooms, /holds, /calendar,
// /events/:id/show-activities, /events/:id/notes, /events/:id/contacts,
// /notes, /event-contacts (GET / POST / PATCH / DELETE as listed there).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { allowedMethods, API_METHODS, apiPath, matchRoute, type ApiRoute } from "../_shared/api/routes.ts";
import { effectiveScopes, hasScope } from "../_shared/api/scopes.ts";
import { pageEnvelope, PagingError, parsePage, type Page } from "../_shared/api/paging.ts";
import {
  ACTIVITY_COLS, bookingDbError, BodyError, clearBody, CONTACT_COLS, convertBody, holdBody, isIsoDate, isUuid,
  NOTE_COLS, parseActivity, parseContact, parseHoldFilters, parseNote, parseRoom, parseVenue, ROOM_COLS, VENUE_COLS,
  venueView,
} from "../_shared/api/booking.ts";

const RATE_LIMIT = 120; // requests per key per minute
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;

const EVENT_LIST_COLS = "id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at";
const EVENT_COLS =
  "id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, " +
  "exos_venue_id, exos_room_id, hold_id, tickets_sold, total_tickets, created_at";
const MAX_BODY_BYTES = 64 * 1024;
// Routes that answer 201 Created.
const CREATED = new Set([
  "create-venue", "create-room", "create-hold", "convert-hold", "create-show-activity", "create-event-note",
  "create-event-contact",
]);
const TIER_COLS =
  "id, name, description, price, capacity, sold, ticket_type, visibility, sales_start, sales_end, sort_order";
const ORDER_COLS =
  "session_id, event_id, status, quantity, amount_cents, tax_cents, currency, buyer_email, created_at, fulfilled_at";

const EVENT_STATUSES = new Set(["draft", "published", "cancelled"]);

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
  /** The parsed JSON body of a POST / PATCH (undefined when empty). */
  body: unknown;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (!(API_METHODS as readonly string[]).includes(req.method)) {
    return json({ error: "method not allowed" }, 405, { allow: API_METHODS.join(", ") });
  }

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
  const path = apiPath(url.pathname);
  const match = matchRoute(req.method, path);
  if (!match) {
    const allow = allowedMethods(path);
    if (allow.length) return json({ error: "method not allowed" }, 405, { allow: allow.join(", ") });
    return json({ error: "not found", hint: "see /developers for the API reference" }, 404);
  }
  const scopes = (keyRow.scopes ?? []) as string[];
  if (match.route.scope && !hasScope(scopes, match.route.scope)) {
    return json({ error: "insufficient scope", required_scope: match.route.scope }, 403, {
      "www-authenticate": `Bearer error="insufficient_scope", scope="${match.route.scope}"`,
    });
  }

  let body: unknown = undefined;
  if (req.method === "POST" || req.method === "PATCH") {
    const raw = await readCapped(req, MAX_BODY_BYTES);
    if (raw === null) return json({ error: "request body too large" }, 413);
    if (raw.trim()) {
      try { body = JSON.parse(raw); }
      catch { return json({ error: "the body must be JSON" }, 400); }
    }
  }

  try {
    const ctx: Ctx = {
      sb, orgId,
      key: { id: keyRow.id, name: keyRow.name, key_prefix: keyRow.key_prefix, scopes },
      params: match.params,
      q: url.searchParams,
      // Only lists read ?page / ?per_page; elsewhere they are ignored.
      page: parsePage(match.route.paged ? url.searchParams : new URLSearchParams()),
      body,
    };
    return json(await handle(match.route, ctx), CREATED.has(match.route.id) ? 201 : 200);
  } catch (e) {
    if (e instanceof PagingError || e instanceof BodyError) return json({ error: e.message }, 400);
    if (e instanceof ApiError) return json({ error: e.message }, e.status);
    const db = bookingDbError(e as { code?: string; message?: string });
    if (db) return json({ error: db.message }, db.status);
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

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
  }
  return await handleBooking(route, c);
}

// -- Booking (mig 20261030100000, docs/booking.md) ------------------------------------

async function handleBooking(route: ApiRoute, c: Ctx): Promise<unknown> {
  const { sb, orgId, page } = c;
  switch (route.id) {
    // Venues ------------------------------------------------------------------
    case "list-venues": {
      let q = sb.from("exos_venues").select(VENUE_COLS, { count: "exact" }).eq("org_id", orgId);
      const name = search(c.q, "q", "q[name_cont]");
      if (name) q = q.ilike("name", `%${name}%`);
      const rel = c.q.get("relationship");
      if (rel !== null) {
        if (!["owned", "rented", "partner"].includes(rel)) throw new ApiError(400, "relationship must be owned, rented or partner.");
        q = q.eq("relationship", rel);
      }
      return pagedMap(await q.order("name").order("id").range(page.from, page.to), page, venueView);
    }
    case "create-venue": {
      const row = parseVenue(c.body, false);
      return { data: venueView(await single(sb.from("exos_venues").insert({ ...row, org_id: orgId }).select(VENUE_COLS).single())) };
    }
    case "get-venue":
      return {
        data: venueView(await found(sb.from("exos_venues").select(VENUE_COLS).eq("org_id", orgId)
          .eq("id", uuidParam(c, "id", "venue")).maybeSingle(), "venue")),
      };
    case "update-venue": {
      const id = uuidParam(c, "id", "venue");
      const row = parseVenue(c.body, true);
      return {
        data: venueView(await found(sb.from("exos_venues").update(row).eq("org_id", orgId).eq("id", id)
          .select(VENUE_COLS).maybeSingle(), "venue")),
      };
    }
    case "delete-venue": {
      const id = uuidParam(c, "id", "venue");
      await found(sb.from("exos_venues").delete().eq("org_id", orgId).eq("id", id).select("id").maybeSingle(), "venue");
      return { data: { id, deleted: true } };
    }

    // Rooms -------------------------------------------------------------------
    case "list-venue-rooms": {
      const venue = await ownVenue(c);
      return rows(await sb.from("exos_venue_rooms").select(ROOM_COLS).eq("org_id", orgId).eq("venue_id", venue)
        .order("sort_order").order("name").order("id"));
    }
    case "create-room": {
      const venue = await ownVenue(c);
      const row = parseRoom(c.body, false);
      return {
        data: await single(sb.from("exos_venue_rooms").insert({ ...row, venue_id: venue, org_id: orgId })
          .select(ROOM_COLS).single()),
      };
    }
    case "list-rooms": {
      let q = sb.from("exos_venue_rooms").select(ROOM_COLS, { count: "exact" }).eq("org_id", orgId);
      const venue = c.q.get("venue_id") ?? c.q.get("q[venue_ownership_id_eq]");
      if (venue !== null) {
        if (!isUuid(venue)) throw new ApiError(400, "venue_id must be a UUID.");
        q = q.eq("venue_id", venue);
      }
      const name = search(c.q, "q", "q[name_cont]");
      if (name) q = q.ilike("name", `%${name}%`);
      return paged(await q.order("venue_id").order("sort_order").order("name").order("id").range(page.from, page.to), page);
    }
    case "get-room":
      return {
        data: await found(roomOfVenue(c, sb.from("exos_venue_rooms").select(ROOM_COLS).eq("org_id", orgId)
          .eq("id", uuidParam(c, "id", "room"))).maybeSingle(), "room"),
      };
    case "update-room": {
      const id = uuidParam(c, "id", "room");
      const row = parseRoom(c.body, true);
      return {
        data: await found(roomOfVenue(c, sb.from("exos_venue_rooms").update(row).eq("org_id", orgId).eq("id", id))
          .select(ROOM_COLS).maybeSingle(), "room"),
      };
    }
    case "delete-room": {
      const id = uuidParam(c, "id", "room");
      await found(roomOfVenue(c, sb.from("exos_venue_rooms").delete().eq("org_id", orgId).eq("id", id))
        .select("id").maybeSingle(), "room");
      return { data: { id, deleted: true } };
    }

    // Holds (every write through the SQL functions) -------------------------------
    case "list-holds": {
      const f = parseHoldFilters(c.q);
      const out = await rpc(sb, "_exos_holds_page", {
        p_org: orgId, p_from: f.from, p_to: f.to, p_venue: f.venueId, p_room: f.roomId, p_status: f.status, p_q: f.q,
        p_limit: page.perPage, p_offset: page.from,
      }) as { total: number; data: unknown[] };
      return pageEnvelope(out.data ?? [], page, out.total ?? 0);
    }
    case "create-hold":
      return {
        data: await rpc(sb, "_exos_hold_create", {
          p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p: holdBody(c.body, false),
        }),
      };
    case "get-hold": {
      const id = await ownHold(c);
      return { data: await rpc(sb, "_exos_hold_json", { p_hold_id: id }) };
    }
    case "update-hold": {
      const id = holdParam(c);
      return { data: await rpc(sb, "_exos_hold_update", { p_org: orgId, p_hold_id: id, p: holdBody(c.body, true) }) };
    }
    case "clear-hold": {
      const id = holdParam(c);
      return { data: await rpc(sb, "_exos_hold_clear", { p_org: orgId, p_hold_id: id, p_position_ids: clearBody(c.body) }) };
    }
    case "convert-hold": {
      const id = holdParam(c);
      const out = await rpc(sb, "_exos_hold_convert", {
        p_org: orgId, p_actor: null, p_via: "api", p_api_key: c.key.id, p_hold_id: id, p: convertBody(c.body),
      }) as { hold: unknown; position_id: string; event_id: string };
      const event = await single(sb.from("exos_events").select(EVENT_COLS).eq("org_id", orgId).eq("id", out.event_id).single());
      return {
        data: {
          hold: out.hold,
          position_id: out.position_id,
          event: { ...(event as Record<string, unknown>), tiers: await tiers(sb, out.event_id) },
        },
      };
    }
    case "get-calendar": {
      const from = c.q.get("from");
      const to = c.q.get("to");
      if (!isIsoDate(from) || !isIsoDate(to)) throw new ApiError(400, "from and to are required, written YYYY-MM-DD.");
      const venue = c.q.get("venue_id");
      if (venue !== null && !isUuid(venue)) throw new ApiError(400, "venue_id must be a UUID.");
      return { data: await rpc(sb, "_exos_booking_calendar", { p_org: orgId, p_from: from, p_to: to, p_venue: venue }) };
    }

    // Show schedule -------------------------------------------------------------------
    case "list-show-activities": {
      const ev = await ownEvent(c);
      return paged(await sb.from("exos_show_activities").select(ACTIVITY_COLS, { count: "exact" })
        .eq("org_id", orgId).eq("event_id", ev).order("starts_at").order("id").range(page.from, page.to), page);
    }
    case "create-show-activity": {
      const ev = await ownEvent(c);
      const row = parseActivity(c.body, false);
      return {
        data: await single(sb.from("exos_show_activities").insert({ ...row, event_id: ev, org_id: orgId })
          .select(ACTIVITY_COLS).single()),
      };
    }
    case "get-show-activity": {
      const ev = await ownEvent(c);
      return {
        data: await found(sb.from("exos_show_activities").select(ACTIVITY_COLS).eq("org_id", orgId).eq("event_id", ev)
          .eq("id", uuidParam(c, "aid", "show activity")).maybeSingle(), "show activity"),
      };
    }
    case "update-show-activity": {
      const ev = await ownEvent(c);
      const id = uuidParam(c, "aid", "show activity");
      const row = parseActivity(c.body, true);
      return {
        data: await found(sb.from("exos_show_activities").update(row).eq("org_id", orgId).eq("event_id", ev).eq("id", id)
          .select(ACTIVITY_COLS).maybeSingle(), "show activity"),
      };
    }
    case "delete-show-activity": {
      const ev = await ownEvent(c);
      const id = uuidParam(c, "aid", "show activity");
      await found(sb.from("exos_show_activities").delete().eq("org_id", orgId).eq("event_id", ev).eq("id", id)
        .select("id").maybeSingle(), "show activity");
      return { data: { id, deleted: true } };
    }

    // Notes -----------------------------------------------------------------------------
    case "list-event-notes": {
      const ev = await ownEvent(c);
      return paged(await sb.from("exos_event_notes").select(NOTE_COLS, { count: "exact" })
        .eq("org_id", orgId).eq("event_id", ev).order("created_at").order("id").range(page.from, page.to), page);
    }
    case "create-event-note": {
      const ev = await ownEvent(c);
      const row = parseNote(c.body, false);
      return {
        data: await single(sb.from("exos_event_notes").insert({ ...row, event_id: ev, org_id: orgId })
          .select(NOTE_COLS).single()),
      };
    }
    case "list-notes": {
      let q = sb.from("exos_event_notes").select(NOTE_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) {
        if (!isUuid(ev)) throw new ApiError(400, "event_id must be a UUID.");
        q = q.eq("event_id", ev);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
    case "get-note":
      return {
        data: await found(sb.from("exos_event_notes").select(NOTE_COLS).eq("org_id", orgId)
          .eq("id", uuidParam(c, "id", "note")).maybeSingle(), "note"),
      };
    case "update-note": {
      const id = uuidParam(c, "id", "note");
      const row = parseNote(c.body, true);
      return {
        data: await found(sb.from("exos_event_notes").update(row).eq("org_id", orgId).eq("id", id)
          .select(NOTE_COLS).maybeSingle(), "note"),
      };
    }
    case "delete-note": {
      const id = uuidParam(c, "id", "note");
      await found(sb.from("exos_event_notes").delete().eq("org_id", orgId).eq("id", id).select("id").maybeSingle(), "note");
      return { data: { id, deleted: true } };
    }

    // Contacts --------------------------------------------------------------------------
    case "list-event-contacts": {
      const ev = await ownEvent(c);
      return paged(await sb.from("exos_event_contacts").select(CONTACT_COLS, { count: "exact" })
        .eq("org_id", orgId).eq("event_id", ev).order("role").order("name").order("id").range(page.from, page.to), page);
    }
    case "create-event-contact": {
      const ev = await ownEvent(c);
      const row = parseContact(c.body, false);
      return {
        data: await single(sb.from("exos_event_contacts").insert({ ...row, event_id: ev, org_id: orgId })
          .select(CONTACT_COLS).single()),
      };
    }
    case "list-contacts": {
      let q = sb.from("exos_event_contacts").select(CONTACT_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) {
        if (!isUuid(ev)) throw new ApiError(400, "event_id must be a UUID.");
        q = q.eq("event_id", ev);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
    case "get-contact":
      return {
        data: await found(sb.from("exos_event_contacts").select(CONTACT_COLS).eq("org_id", orgId)
          .eq("id", uuidParam(c, "id", "contact")).maybeSingle(), "contact"),
      };
    case "update-contact": {
      const id = uuidParam(c, "id", "contact");
      const row = parseContact(c.body, true);
      return {
        data: await found(sb.from("exos_event_contacts").update(row).eq("org_id", orgId).eq("id", id)
          .select(CONTACT_COLS).maybeSingle(), "contact"),
      };
    }
    case "delete-contact": {
      const id = uuidParam(c, "id", "contact");
      await found(sb.from("exos_event_contacts").delete().eq("org_id", orgId).eq("id", id).select("id").maybeSingle(), "contact");
      return { data: { id, deleted: true } };
    }
  }
  throw new ApiError(404, "not found");
}

/** A path parameter as a UUID; anything else is simply not found. */
function uuidParam(c: Ctx, name: string, what: string): string {
  const v = c.params[name];
  if (!isUuid(v)) throw new ApiError(404, `${what} not found`);
  return v;
}

/** Under /venues/:vid/rooms/:id the room must also be that venue's. */
// deno-lint-ignore no-explicit-any
function roomOfVenue(c: Ctx, q: any): any {
  if (c.params.vid === undefined) return q;
  return q.eq("venue_id", uuidParam(c, "vid", "room"));
}

function holdParam(c: Ctx): string {
  return uuidParam(c, "id", "hold");
}

async function ownVenue(c: Ctx): Promise<string> {
  const id = uuidParam(c, "id", "venue");
  await found(c.sb.from("exos_venues").select("id").eq("org_id", c.orgId).eq("id", id).maybeSingle(), "venue");
  return id;
}

async function ownHold(c: Ctx): Promise<string> {
  const id = holdParam(c);
  await found(c.sb.from("exos_holds").select("id").eq("org_id", c.orgId).eq("id", id).maybeSingle(), "hold");
  return id;
}

/** ?q= (or an Opendate-style alias), trimmed, with LIKE wildcards escaped. */
function search(q: URLSearchParams, ...names: string[]): string | null {
  for (const n of names) {
    const v = q.get(n);
    if (v === null || !v.trim()) continue;
    if (v.length > 100) throw new ApiError(400, `${n} must be at most 100 characters.`);
    return v.trim().replace(/[\\%_,()]/g, (ch) => `\\${ch}`);
  }
  return null;
}

// deno-lint-ignore no-explicit-any
async function rpc(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

// deno-lint-ignore no-explicit-any
async function single(p: PromiseLike<{ data: any; error: unknown }>): Promise<any> {
  const { data, error } = await p;
  if (error) throw error;
  return data;
}

// deno-lint-ignore no-explicit-any
async function found(p: PromiseLike<{ data: any; error: unknown }>, what: string): Promise<any> {
  const { data, error } = await p;
  if (error) throw error;
  if (!data) throw new ApiError(404, `${what} not found`);
  return data;
}

// deno-lint-ignore no-explicit-any
function pagedMap(r: { data: any; error: any; count: number | null }, page: Page, fn: (row: any) => unknown) {
  const out = paged(r, page);
  return { ...out, data: (out.data as unknown[]).map(fn) };
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

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}

/**
 * The body as text, or null once it passes `max` bytes. Counts while
 * streaming, so a chunked body without Content-Length can't be read in full.
 */
async function readCapped(req: Request, max: number): Promise<string | null> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    buf.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder().decode(buf);
}
