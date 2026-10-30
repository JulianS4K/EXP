// exos-api — org-scoped partner REST API for Exos, plus the public listing feed.
// Reference: docs/api-reference.md and /developers (built from docs/api/*.json).
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to, and the key's scopes. Reads everywhere; writes behind a
// `:write` scope: the sales counts (tickets sold on other platforms, mig
// 20261030120000), whose POST / PUT / DELETE go through service-role RPCs that
// re-check the event / row belongs to the key's org, and booking (venues,
// rooms, holds, show schedule, notes, contacts; mig 20261030100000). Hold
// writes go through the _exos_hold_* SQL functions (levels, promotion and
// convert in one transaction, hold.* webhooks); the rest are plain rows whose
// triggers and checks validate them. Every query names the key's org: this
// function runs with the service role, so RLS does not scope it.
// Artists, lineups and listing-feed shared keys (mig 20261030110000) write
// through service-role SQL functions that take the key's org explicitly.
// Offers, budgets, deals, finance items, settlements and P&L (migs
// 20261031100000 / 100500) are handled in ./finance.ts (handleFinance).
// The core API (events, ticket types, add-ons, promo codes, the door, comps,
// refunds, guest lists, POS; mig 20261031110000, ./core.ts) writes through
// exos_api_write, which runs as the member who created the key and calls the
// dashboard's own SQL, so a write there behaves exactly like the same write in
// the dashboard.
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
// _shared/api/routes.ts. GET /me, /events…, /events/:id/{seats,
// seat-reconciliation, sales-counts, timed-entry, slots}, /orders…,
// /invoices, /refunds, /webhooks, /sales-counts, /eventbrite-events/:id,
// /series, /series/:id, /series/:id/dates, /collections, /collections/:id;
// sales-count writes (POST /sales-counts, PUT + DELETE /sales-counts/:id, POST
// /events/:id/sales-counts/import); booking: /venues, /rooms, /holds,
// /calendar, /events/:id/show-activities, /events/:id/notes,
// /events/:id/contacts, /notes, /event-contacts (GET / POST / PATCH / DELETE
// as listed there).
//   Artists: GET/POST /artists, GET/PATCH /artists/:id, POST
//   /artists/:id/merge, GET /artists/:id/events, GET/PUT /events/:id/lineup;
//   GET/POST /listing-keys, DELETE /listing-keys/:id.
//   offers and finance (./finance.ts, docs/offers-settlements.md): /offers,
//   /offer-templates, /budgets, /budget-lines, /offer-pools, /offer-imports,
//   /deals, /finance-categories, /gl-codes, /events/:id/finance-items,
//   /finance-items, /events/:id/settlement[/finalize|/reopen|/pdf],
//   /events/:id/profit-and-loss, /profit-and-loss, /events/:id/ticket-counts.
//   the core API (./core.ts): event create / update / publish (+ publish
//   blockers), ticket types, add-ons, promo codes, tickets and check-in,
//   offline check-ins, comps, refunds (Idempotency-Key required), guest lists,
//   disputes, payouts, POS items and devices, the write log.
//
// Writes take a JSON body (or form-encoded), at most MAX_BODY_BYTES (2 MB +
// 256 KB for the sales-count CSV import), read capped while streaming; an
// Idempotency-Key header makes a core-API write safe to resend (the first
// answer is replayed). Refunds need STRIPE_SECRET_KEY (optional
// EXOS_REFUND_KEEP_PLATFORM_FEE), like exos-refund.
//
// commerce:read (migs 20261030130000 / 130500): /gift-card-products,
// /gift-cards[/:id], /giving-campaigns[/:id], /donations,
// /membership-products[/:id], /memberships[/:id], /pass-products, /passes,
// /events/:id/member-presale. Never a gift card code (only its last 4) or a
// gift claim token.
//
// Public listing feed (docs/listing-feed.md): GET /public/events[/:id] and the
// Opendate-named alias /public/confirms[/:id], authenticated with a shared key
// (?shared_key=sh_live_… or X-Shared-Key) instead of an API key. Read-only,
// CORS-open, cacheable 60 s with an ETag (If-None-Match → 304), 120 requests a
// minute per key (exos_rate_hit). Optional secret: EXOS_APP_BASE_URL (public
// app base, for ticket_url).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { allowedMethods, API_METHODS, apiPath, isSharedKeyPath, matchRoute, type ApiMethod, type ApiRoute } from "../_shared/api/routes.ts";
import { formBody, MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import { effectiveScopes, hasScope } from "../_shared/api/scopes.ts";
import { pageEnvelope, PagingError, parsePage, type Page } from "../_shared/api/paging.ts";
import { parseCsv } from "../_shared/csvParse.ts";
import {
  isPlatform, MAX_IMPORT_BYTES, planSalesImport, SALES_FIELDS, salesTotals, suggestSalesMapping,
  type SalesCountRow, type SalesField, type SalesMapping,
} from "../_shared/salesCounts.ts";
import {
  ACTIVITY_COLS, bookingDbError, BodyError, clearBody, CONTACT_COLS, convertBody, holdBody, isIsoDate, isUuid,
  NOTE_COLS, parseActivity, parseContact, parseHoldFilters, parseNote, parseRoom, parseVenue, ROOM_COLS, VENUE_COLS,
  venueView,
} from "../_shared/api/booking.ts";
import { parseSpotifyArtist, PARTNER_TYPES, spotifyLinks } from "../_shared/artists.ts";
import {
  buildFeedPage, etagMatches, FEED_MAX_AGE, feedEntry, FeedParamError, parseFeedQuery, SHARED_KEY_RE,
  type FeedSource, type SourceEvent,
} from "../_shared/listingFeed/feed.ts";
import { withPublicTierFees } from "../_shared/feeRulesRead.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { type FinDeps, handleFinance } from "./finance.ts";
import { Answer, CORE_ROUTES, CoreError, handleCore, idempotencyKey, sqlError } from "./core.ts";

const RATE_LIMIT = 120; // requests per key per minute
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;

const EVENT_LIST_COLS = "id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at";
const EVENT_COLS =
  "id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, " +
  "exos_venue_id, exos_room_id, hold_id, tickets_sold, total_tickets, created_at";
// Routes that answer 201 Created.
const CREATED = new Set([
  "create-venue", "create-room", "create-hold", "convert-hold", "create-show-activity", "create-event-note",
  "create-event-contact",
]);
const TIER_COLS =
  "id, name, description, price, capacity, sold, ticket_type, visibility, sales_start, sales_end, sort_order";
// Reserved seating (mig 20261030140000): extra columns, dropped again on a
// database without them (42703) so the API keeps answering.
const TIER_SEAT_COLS = ", seated";
const TICKET_SEAT_COLS = ", seat_id, seat_label, seat_section, seat_row, seat_number";
const SEAT_STATUSES = new Set(["available", "held", "sold", "blocked"]);
const ORDER_COLS =
  "session_id, event_id, status, quantity, amount_cents, tax_cents, currency, buyer_email, created_at, fulfilled_at";

const EVENT_STATUSES = new Set(["draft", "published", "cancelled"]);
const SALES_COLS =
  "id, event_id, kind, platform, label, sold, gross_cents, currency, capacity, tiers, note, file_name, row_count, " +
  "created_at, updated_at";
// The CSV import's body may carry a 2 MB file as a string; every other write
// body is at most MAX_BODY_BYTES (_shared/api/body.ts).
const MAX_IMPORT_BODY_BYTES = MAX_IMPORT_BYTES + 256 * 1024;
const ARTIST_COLS =
  "id, name, permalink, bio, genres, links, image_url, image_thumb_url, spotify_id, canonical_artist_id, created_at, updated_at";
const ARTIST_SORTS: Record<string, [string, boolean]> = {
  "name asc": ["name", true], "name desc": ["name", false],
  "created_at asc": ["created_at", true], "created_at desc": ["created_at", false],
  "updated_at asc": ["updated_at", true], "updated_at desc": ["updated_at", false],
};
const FEED_RATE_LIMIT = 120; // listing-feed requests per shared key (or per network without one) per minute

const GIFT_CARD_COLS =
  "id, last4, currency, initial_cents, balance_cents, status, source, payment_method, product_id, recipient_email, " +
  "issued_by, pos_drawer_id, expires_at, created_at";
const CAMPAIGN_COLS =
  "id, name, slug, description, currency, goal_cents, starts_at, ends_at, active, checkout_add_on, round_up, " +
  "suggested_cents, created_at";
const MEMBERSHIP_PRODUCT_COLS =
  "id, name, price_cents, currency, billing, duration_days, discount_percent, presale, free_tickets_per_period, " +
  "guest_allowance, household_seats, giftable, active, created_at";
const MEMBERSHIP_COLS =
  "id, product_id, product_name, billing, holder_email, status, current_period_start, current_period_end, " +
  "cancel_at_period_end, source, benefits, created_at";
const MEMBERSHIP_STATUSES = new Set(["pending", "active", "past_due", "cancelled", "expired"]);

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
  /** The body of a POST / PUT / PATCH ({} when empty, or for GET / DELETE). */
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const path = apiPath(url.pathname);
  // The listing feed authenticates with a shared key, not an API key.
  if (isSharedKeyPath(path)) return listingFeed(req, url, path);
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

  const match = matchRoute(method, path);
  if (!match || match.route.auth !== "api_key") {
    const allow = allowedMethods(path);
    if (!match && allow.length) return json({ error: "method not allowed" }, 405, { allow: allow.join(", ") });
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
      body: method === "POST" || method === "PUT" || method === "PATCH"
        ? await readBody(req, match.route.id === "import-sales-counts" ? MAX_IMPORT_BODY_BYTES : MAX_BODY_BYTES)
        : {},
      idempotencyKey: method === "GET" ? null : idempotencyKey(req),
    };
    const out = await handle(match.route, ctx);
    if (out instanceof Response) return out; // PDFs and CSV exports
    if (out instanceof Answer) return json(out.body, out.status);
    if (out instanceof Created) return json(out.body, 201);
    return json(out, CREATED.has(match.route.id) ? 201 : 200);
  } catch (e) {
    if (e instanceof PagingError || e instanceof BodyError) return json({ error: e.message }, 400);
    if (e instanceof ApiError) return json({ error: e.message }, e.status);
    if (e instanceof CoreError) return json({ error: e.message, ...e.extra }, e.status);
    // Core-API writes (exos_api_write) map with sqlError; sales-count RPCs
    // prefix their messages "sales counts:"; booking's are "exos_<fn>:" and use
    // more codes; the artist / lineup / key functions raise the codes in
    // RPC_STATUS.
    const db = CORE_ROUTES.has(match.route.id) ? sqlError(e)
      : (match.route.id.includes("sales-count") ? dbError(e) : null) ??
        bookingDbError(e as { code?: string; message?: string }) ?? rpcError(e);
    if (db) return json({ error: db.message }, db.status);
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

/** A 201 answer from handle(). */
class Created {
  constructor(public body: unknown) {}
}

async function handle(route: ApiRoute, c: Ctx): Promise<unknown | Response> {
  const { sb, orgId, page } = c;
  if (CORE_ROUTES.has(route.id)) {
    return await handleCore(route, {
      sb, orgId, keyId: c.key.id, params: c.params, q: c.q, page, body: c.body, idempotencyKey: c.idempotencyKey,
    });
  }
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
      let q = sb.from("exos_vouchers")
        .select("id, code, tier_id, max_uses, used_count, discount_percent, discount_amount, price_override, " +
          "valid_until, link_label, link_channel, link_clicks, created_at", { count: "exact" })
        .eq("event_id", id);
      // ?code=: look one code up by name (any case), as at checkout.
      const code = c.q.get("code");
      if (code !== null) {
        if (!/^[A-Za-z0-9_-]{1,64}$/.test(code)) throw new ApiError(400, "code is invalid.");
        q = q.ilike("code", code.replace(/_/g, "\\_"));
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "list-attendees": {
      const id = await ownEvent(c);
      // Never barcode_secret.
      const status = c.q.get("status");
      if (status !== null && !/^[a-z_]{1,32}$/.test(status)) throw new ApiError(400, "status is invalid.");
      return paged(await withoutMissing(TICKET_SEAT_COLS, (extra) => {
        let q = sb.from("exos_tickets")
          .select("id, tier_id, tier_name, attendee_name, owner_email, status, check_in_at, price_paid, " +
            "order_ref, channel_source, created_at" + extra, { count: "exact" })
          .eq("event_id", id).eq("org_id", orgId);
        if (status !== null) q = q.eq("status", status);
        return q.order("created_at", { ascending: false }).order("id").range(page.from, page.to);
      }), page);
    }

    case "list-seats": {
      // Every seat of the event's map with its status (available / held /
      // sold / blocked), the ticket on a sold seat, and the tier it sells as.
      // An event without a seat map answers an empty list.
      const id = await ownEvent(c);
      const status = c.q.get("status");
      if (status !== null && !SEAT_STATUSES.has(status)) throw new ApiError(400, "status is invalid.");
      const { data, error } = await sb.rpc("exos_event_seat_status", { p_event_id: id });
      if (error) throw error;
      const seats = ((data ?? []) as { status: string }[]).filter((s) => status === null || s.status === status);
      return { data: seats };
    }

    case "get-seat-reconciliation":
      // Sold seats without a live ticket, live seated tickets without their
      // seat, and held seats of dead holds (Opendate's seat_reconciliation).
      return rows(await sb.rpc("exos_seat_reconciliation", { p_event_id: await ownEvent(c) }));

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
        withoutMissing(TICKET_SEAT_COLS, (extra) =>
          sb.from("exos_tickets").select("id, tier_id, tier_name, attendee_name, owner_email, status, price_paid, check_in_at" + extra)
            .eq("org_id", orgId).eq("order_ref", sid).order("created_at")),
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

    // --- Gift cards, giving, memberships, passes (commerce:read) -------------
    case "list-gift-card-products":
      return rows(await sb.from("exos_gift_card_products")
        .select("id, name, description, currency, amount_type, amounts_cents, min_cents, max_cents, image_url, expiry_months, active, created_at")
        .eq("org_id", orgId).order("created_at"));

    case "list-gift-cards":
      // Never code_hash.
      return paged(await sb.from("exos_gift_cards").select(GIFT_CARD_COLS, { count: "exact" })
        .eq("org_id", orgId).order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);

    case "get-gift-card": {
      const id = idParam(c, "gift card not found");
      const { data: card, error } = await sb.from("exos_gift_cards").select(GIFT_CARD_COLS)
        .eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!card) throw new ApiError(404, "gift card not found");
      const ledger = await sb.from("exos_gift_card_ledger").select("kind, amount_cents, balance_after, session_id, created_at")
        .eq("card_id", id).order("id");
      if (ledger.error) throw ledger.error;
      return { data: { ...(card as unknown as Record<string, unknown>), ledger: ledger.data ?? [] } };
    }

    case "list-giving-campaigns":
    case "get-giving-campaign": {
      let q = sb.from("exos_giving_campaigns").select(CAMPAIGN_COLS).eq("org_id", orgId);
      if (route.id === "get-giving-campaign") q = q.eq("id", idParam(c, "campaign not found"));
      const { data, error } = await q.order("created_at");
      if (error) throw error;
      const list = (data ?? []) as unknown as { id: string }[];
      const ids = list.map((x) => x.id);
      const totals = new Map<string, { raised_cents: number; donation_count: number }>();
      if (ids.length > 0) {
        const { data: ds, error: dErr } = await sb.from("exos_donations").select("campaign_id, amount_cents")
          .eq("org_id", orgId).eq("status", "received").in("campaign_id", ids);
        if (dErr) throw dErr;
        for (const d of (ds ?? []) as { campaign_id: string; amount_cents: number }[]) {
          const t = totals.get(d.campaign_id) ?? { raised_cents: 0, donation_count: 0 };
          t.raised_cents += d.amount_cents;
          t.donation_count += 1;
          totals.set(d.campaign_id, t);
        }
      }
      const out = list.map((x) => ({ ...x, ...(totals.get(x.id) ?? { raised_cents: 0, donation_count: 0 }) }));
      if (route.id === "get-giving-campaign") {
        if (out.length === 0) throw new ApiError(404, "campaign not found");
        return { data: out[0] };
      }
      return { data: out };
    }

    case "list-donations": {
      let q = sb.from("exos_donations")
        .select("id, campaign_id, amount_cents, cover_fees_cents, total_cents, currency, method, donor_name, donor_email, " +
          "anonymous, session_id, event_id, status, receipt_number, created_at", { count: "exact" })
        .eq("org_id", orgId);
      const camp = c.q.get("campaign_id");
      if (camp !== null) {
        if (!UUID_RE.test(camp)) throw new ApiError(400, "campaign_id must be a UUID.");
        q = q.eq("campaign_id", camp);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "list-membership-products":
      return rows(await sb.from("exos_membership_products").select(MEMBERSHIP_PRODUCT_COLS).eq("org_id", orgId).order("created_at"));

    case "get-membership-product": {
      const { data, error } = await sb.from("exos_membership_products").select(MEMBERSHIP_PRODUCT_COLS)
        .eq("org_id", orgId).eq("id", idParam(c, "membership product not found")).maybeSingle();
      if (error) throw error;
      if (!data) throw new ApiError(404, "membership product not found");
      return { data };
    }

    case "list-memberships": {
      // Never gift_token_hash or the Stripe ids.
      let q = sb.from("exos_fan_memberships").select(MEMBERSHIP_COLS, { count: "exact" }).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!MEMBERSHIP_STATUSES.has(status)) throw new ApiError(400, "status is invalid.");
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "get-membership": {
      const id = idParam(c, "membership not found");
      const { data, error } = await sb.from("exos_fan_memberships").select(MEMBERSHIP_COLS)
        .eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!data) throw new ApiError(404, "membership not found");
      const hh = await sb.from("exos_membership_household").select("email").eq("membership_id", id).order("email");
      if (hh.error) throw hh.error;
      return { data: { ...(data as unknown as Record<string, unknown>), household: (hh.data ?? []).map((h: { email: string }) => h.email) } };
    }

    case "list-pass-products":
      return rows(await sb.from("exos_pass_products")
        .select("id, kind, name, price_cents, currency, credits, per_event_limit, event_ids, date_from, date_to, tier_ids, " +
          "valid_until, max_sold, sold, active, created_at")
        .eq("org_id", orgId).order("created_at"));

    case "list-passes":
      return paged(await sb.from("exos_passes")
        .select("id, product_id, kind, name, holder_email, credits_total, credits_used, per_event_limit, valid_until, status, created_at",
          { count: "exact" })
        .eq("org_id", orgId).order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);

    case "get-event-member-presale": {
      const id = await ownEvent(c);
      const { data, error } = await sb.from("exos_member_presales").select("event_id, starts_at, ends_at, tier_ids, product_ids")
        .eq("event_id", id).maybeSingle();
      if (error) throw error;
      return { data: data ?? null };
    }

    case "list-webhooks":
      // Never the signing secret.
      return rows(await sb.from("exos_webhooks")
        .select("id, url, event_types, enabled, description, created_at")
        .eq("org_id", orgId).order("created_at", { ascending: true }));

    // -- Sales counts: tickets sold on other platforms (mig 20261030120000) --

    case "list-sales-counts": {
      let q = sb.from("exos_sales_counts").select(SALES_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) {
        if (!UUID_RE.test(ev)) throw new ApiError(400, "event_id must be a UUID.");
        q = q.eq("event_id", ev);
      }
      const kind = c.q.get("kind");
      if (kind !== null) {
        if (kind !== "manual" && kind !== "import") throw new ApiError(400, "kind must be manual or import.");
        q = q.eq("kind", kind);
      }
      const r = await q.order("updated_at", { ascending: false }).order("id").range(page.from, page.to);
      return paged({ ...r, data: r.data ? (r.data as unknown as SalesCountRow[]).map(salesView) : r.data }, page);
    }

    case "get-sales-count":
      return { data: salesView(await salesRow(c)) };

    case "list-event-sales-counts": {
      const id = await ownEvent(c);
      const { data, error } = await sb.from("exos_sales_counts").select(SALES_COLS)
        .eq("org_id", orgId).eq("event_id", id).order("updated_at", { ascending: false });
      if (error) throw error;
      const list = (data ?? []) as unknown as SalesCountRow[];
      return {
        data: list.map(salesView),
        totals: salesTotals(list).map((t) => ({ currency: t.currency, sold: t.sold, gross_cents: t.grossCents })),
        sold: list.reduce((n, r) => n + r.sold, 0),
      };
    }

    case "create-sales-count": {
      const b = c.body;
      const evId = str(b.event_id, "event_id");
      if (!evId || !UUID_RE.test(evId)) throw new ApiError(400, "event_id (a UUID) is required.");
      const { data: ev, error } = await sb.from("exos_events").select("id, currency")
        .eq("org_id", orgId).eq("id", evId).maybeSingle();
      if (error) throw error;
      if (!ev) throw new ApiError(404, "event not found");
      const sold = int(b.sold, "sold");
      if (sold === null) throw new ApiError(400, "sold is required.");
      const out = await put(c, {
        p_event_id: evId, p_id: null, p_kind: "manual", p_label: str(b.label, "label"), p_platform: null,
        p_sold: sold, p_gross_cents: grossOf(b, sold) ?? 0,
        p_currency: str(b.currency, "currency") ?? (ev as { currency: string | null }).currency ?? "USD",
        p_capacity: capacityOf(b, sold), p_tiers: tiersOf(b), p_note: str(b.note, "note") ?? "",
      });
      return json({ data: salesView(out) }, out.status === "created" ? 201 : 200);
    }

    case "update-sales-count": {
      const b = c.body;
      const row = await salesRow(c);
      const tiers = tiersOf(b);
      const sold = int(b.sold, "sold");
      const gross = grossOf(b, sold ?? row.sold);
      if (tiers === null && row.tiers.length > 0 && (sold !== null || gross !== null)) {
        throw new ApiError(409, "This entry has ticket types: send tiers, or import the file again.");
      }
      const out = await put(c, {
        p_event_id: null, p_id: row.id, p_kind: null, p_label: str(b.label, "label"), p_platform: null,
        p_sold: sold, p_gross_cents: gross, p_currency: str(b.currency, "currency"),
        p_capacity: capacityOf(b, sold ?? row.sold), p_tiers: tiers,
        // Left out: kept. null or "": cleared.
        p_note: b.note === null || b.note === "" ? "" : str(b.note, "note"),
      });
      return { data: salesView(out) };
    }

    case "delete-sales-count": {
      const id = c.params.id;
      if (!UUID_RE.test(id)) throw new ApiError(404, "sales count not found");
      const { data, error } = await sb.rpc("exos_api_sales_count_delete", { p_org_id: orgId, p_id: id });
      if (error) throw error;
      if (data !== true) throw new ApiError(404, "sales count not found");
      return { data: { id, deleted: true } };
    }

    case "import-sales-counts": {
      const id = await ownEvent(c);
      const b = c.body;
      const platform = str(b.platform, "platform")?.toLowerCase();
      if (!isPlatform(platform)) throw new ApiError(400, "platform is required (one of the listed platforms).");
      const table = importTable(b);
      const header = table[0] ?? [];
      const mapping = importMapping(b.mapping, header);
      const { data: ev } = await sb.from("exos_events").select("currency").eq("id", id).maybeSingle();
      const plan = planSalesImport(table, mapping, {
        currency: str(b.currency, "currency") ?? (ev as { currency: string | null } | null)?.currency ?? "USD",
        event: str(b.event, "event"),
      });
      const summary = {
        platform, currency: plan.currency, sold: plan.sold, gross_cents: plan.grossCents, capacity: plan.capacity,
        tiers: plan.tiers, rows: plan.rows, other_event_rows: plan.otherEvents, voided_rows: plan.voided,
        mapping: Object.fromEntries(Object.entries(mapping).map(([f, i]) => [f, header[i as number] ?? null])),
        warnings: plan.warnings,
      };
      if (plan.errors.length) {
        return json({ error: "the file has errors; nothing was imported", errors: plan.errors, import: summary }, 422);
      }
      if (b.dry_run === true) return { data: null, import: { ...summary, dry_run: true } };
      const out = await put(c, {
        p_event_id: id, p_id: null, p_kind: "import", p_label: null, p_platform: platform,
        p_sold: plan.sold, p_gross_cents: plan.grossCents, p_currency: plan.currency, p_capacity: plan.capacity,
        p_tiers: plan.tiers, p_note: "", p_file_name: str(b.file_name, "file_name"), p_row_count: plan.rows,
      });
      return json({ data: salesView(out), status: out.status, import: summary }, out.status === "created" ? 201 : 200);
    }

    case "find-eventbrite-event": {
      // Opendate's find_confirm: our event for an Eventbrite event id (the
      // link Exos Door's Eventbrite sync made, mig 20261013100000).
      const ebId = c.params.id;
      if (!/^[0-9]{1,24}$/.test(ebId)) throw new ApiError(404, "no event is linked to that Eventbrite event");
      const { data: link, error } = await sb.from("exos_eventbrite_links")
        .select("event_id, eb_event_id, eb_event_name, linked_at, last_synced_at")
        .eq("org_id", orgId).eq("eb_event_id", ebId).maybeSingle();
      if (error) throw error;
      if (!link) throw new ApiError(404, "no event is linked to that Eventbrite event");
      const l = link as { event_id: string; eb_event_id: string; eb_event_name: string | null; linked_at: string; last_synced_at: string | null };
      const { data: ev, error: evErr } = await sb.from("exos_events").select(EVENT_LIST_COLS)
        .eq("org_id", orgId).eq("id", l.event_id).maybeSingle();
      if (evErr) throw evErr;
      if (!ev) throw new ApiError(404, "no event is linked to that Eventbrite event");
      return {
        data: {
          ...(ev as unknown as Record<string, unknown>),
          eventbrite: { id: l.eb_event_id, name: l.eb_event_name, linked_at: l.linked_at, last_synced_at: l.last_synced_at },
        },
      };
    }
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

    // -- Series, collections, timed entry (mig 20261030150000) --------------
    case "list-series": {
      let q = sb.from("exos_event_series").select(SERIES_COLS, { count: "exact" }).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!SERIES_STATUSES.has(status)) throw new ApiError(400, "status must be active, archived or cancelled.");
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }

    case "get-series": {
      const id = idParam(c, "series not found");
      const { data: s, error } = await sb.from("exos_event_series").select(SERIES_COLS)
        .eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!s) throw new ApiError(404, "series not found");
      const [occ, evs] = await Promise.all([
        sb.from("exos_series_occurrences").select(OCCURRENCE_COLS).eq("series_id", id).order("occ_date").limit(500),
        sb.from("exos_events").select("id, status, tickets_sold, total_tickets").eq("series_id", id).eq("org_id", orgId),
      ]);
      for (const r of [occ, evs]) if (r.error) throw r.error;
      const events = (evs.data ?? []) as { id: string; status: string; tickets_sold: number; total_tickets: number }[];
      const ids = events.map((e) => e.id);
      let gross = 0;
      if (ids.length > 0) {
        const { data: orders, error: oErr } = await sb.from("exos_checkout_sessions").select("amount_cents")
          .eq("org_id", orgId).eq("status", "fulfilled").in("event_id", ids);
        if (oErr) throw oErr;
        gross = (orders ?? []).reduce((n, o) => n + Number((o as { amount_cents: number }).amount_cents ?? 0), 0);
      }
      const capped = events.filter((e) => e.total_tickets > 0);
      return {
        data: {
          ...(s as unknown as Record<string, unknown>),
          summary_stats: {
            events_in_series: events.length,
            events_cancelled: events.filter((e) => e.status === "cancelled").length,
            tickets_sold: events.reduce((n, e) => n + (e.tickets_sold ?? 0), 0),
            gross_cents: gross,
            average_capacity_sold: capped.length
              ? Math.round((capped.reduce((n, e) => n + e.tickets_sold / e.total_tickets, 0) / capped.length) * 1000) / 1000
              : null,
          },
          schedule: occ.data ?? [],
        },
      };
    }

    case "list-series-dates": {
      const id = idParam(c, "series not found");
      const { data: s, error } = await sb.from("exos_event_series").select("id").eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!s) throw new ApiError(404, "series not found");
      return paged(await sb.from("exos_series_occurrences").select(OCCURRENCE_COLS, { count: "exact" })
        .eq("series_id", id).order("occ_date").range(page.from, page.to), page);
    }

    case "list-collections":
      return paged(await sb.from("exos_collections").select(COLLECTION_COLS, { count: "exact" })
        .eq("org_id", orgId).order("sort_order").order("created_at").order("id").range(page.from, page.to), page);

    case "get-collection": {
      const id = idParam(c, "collection not found");
      const { data: col, error } = await sb.from("exos_collections").select(COLLECTION_COLS)
        .eq("org_id", orgId).eq("id", id).maybeSingle();
      if (error) throw error;
      if (!col) throw new ApiError(404, "collection not found");
      // Membership resolved in SQL (manual list or rule), drafts included.
      const { data: memberIds, error: mErr } = await sb.rpc("_exos_collection_event_ids", { p_collection_id: id, p_public: false });
      if (mErr) throw mErr;
      const ids = ((memberIds ?? []) as unknown[]).map((x) => String(typeof x === "object" && x ? Object.values(x)[0] : x));
      const { data: evs, error: eErr } = ids.length
        ? await sb.from("exos_events").select(EVENT_LIST_COLS).eq("org_id", orgId).in("id", ids).order("starts_at")
        : { data: [], error: null };
      if (eErr) throw eErr;
      return { data: { ...(col as unknown as Record<string, unknown>), events: evs ?? [] } };
    }

    case "get-timed-entry": {
      const id = await ownEvent(c);
      const { data: te, error } = await sb.from("exos_timed_entry")
        .select("event_id, tier_ids, slot_minutes, capacity, tier_capacity, entry_window_minutes, early_entry_minutes, " +
          "hours, start_date, end_date, closed_dates, version, updated_at")
        .eq("event_id", id).maybeSingle();
      if (error) throw error;
      if (!te) throw new ApiError(404, "this event has no timed entry");
      return { data: te };
    }

    case "list-slots": {
      const id = await ownEvent(c);
      const from = dateParam(c.q, "from");
      const to = dateParam(c.q, "to");
      const { data, error } = await sb.rpc("_exos_slot_report", { p_event_id: id, p_from: from, p_to: to });
      if (error) throw error;
      return { data: data ?? [] };
    }

    // -- Artists and lineups (mig 20261030110000) ------------------------------
    case "list-artists": {
      let q = sb.from("exos_artists").select(ARTIST_COLS, { count: "exact" }).eq("org_id", orgId);
      const name = (c.q.get("q") ?? c.q.get("q[name_cont]") ?? "").trim();
      if (name) {
        if (name.length > 100) throw new ApiError(400, "q is at most 100 characters.");
        q = q.ilike("name", `%${escapeLike(name)}%`);
      }
      if (c.q.get("include_merged") !== "true") q = q.is("canonical_artist_id", null);
      const sp = c.q.get("spotify_id");
      if (sp !== null) {
        const parsed = parseSpotifyArtist(sp);
        if (!parsed.ok || !parsed.id) throw new ApiError(400, "spotify_id must be a Spotify artist link, URI or id.");
        q = q.eq("spotify_id", parsed.id);
      }
      const sortRaw = (c.q.get("q[s]") ?? c.q.get("sort") ?? "name asc").trim().toLowerCase().replace(/\s+/g, " ");
      const sort = ARTIST_SORTS[sortRaw] ?? ARTIST_SORTS[`${sortRaw} asc`];
      if (!sort) throw new ApiError(400, "sort must be name, created_at or updated_at, then asc or desc.");
      const r = paged(await q.order(sort[0], { ascending: sort[1] }).order("id").range(page.from, page.to), page);
      return { ...r, data: (r.data as Record<string, unknown>[]).map(artistView) };
    }

    case "get-artist":
      return { data: await ownArtist(c) };

    case "create-artist":
      return new Created({
        data: await rpc(sb, "_exos_artist_save", {
          p_org_id: orgId, p_artist_id: null, p_fields: unwrap(c.body, "artist"), p_actor: null,
        }),
      });

    case "update-artist":
      return {
        data: await rpc(sb, "_exos_artist_save", {
          p_org_id: orgId, p_artist_id: artistId(c), p_fields: unwrap(c.body, "artist"), p_actor: null,
        }),
      };

    case "merge-artist": {
      const id = artistId(c);
      const target = String(c.body.target_artist_id ?? c.body.targetArtistId ?? "");
      if (!UUID_RE.test(target)) throw new ApiError(400, "target_artist_id must be an artist id.");
      return { data: await rpc(sb, "_exos_artist_merge", { p_org_id: orgId, p_source: id, p_target: target }) };
    }

    case "list-artist-events": {
      await ownArtist(c);
      const r = await rpc(sb, "exos_api_artist_events", {
        p_org_id: orgId, p_artist_id: c.params.id, p_limit: page.perPage, p_offset: page.from,
      }) as { total?: number; rows?: unknown[] } | null;
      return pageEnvelope(r?.rows ?? [], page, r?.total ?? 0);
    }

    case "get-lineup": {
      const id = await ownEvent(c);
      return { data: await rpc(sb, "_exos_lineup_json", { p_event_id: id }) };
    }

    case "set-lineup": {
      const id = await ownEvent(c);
      const slots = Array.isArray(c.body) ? c.body : (c.body.lineup ?? c.body.performers);
      if (!Array.isArray(slots)) throw new ApiError(400, "lineup must be a list of { artist_id, act_type?, set_time? }.");
      return { data: await rpc(sb, "_exos_lineup_save", { p_org_id: orgId, p_event_id: id, p_slots: slots }) };
    }

    // -- Listing-feed shared keys ---------------------------------------------------
    case "list-listing-keys": {
      const r = rows(await sb.from("exos_listing_keys")
        .select("id, label, partner_type, key_prefix, created_at, last_used_at, revoked_at")
        .eq("org_id", orgId).order("created_at", { ascending: true }));
      return { ...r, partner_types: PARTNER_TYPES };
    }

    case "create-listing-key": {
      const b = unwrap(c.body, "listing_key");
      const label = b.label ?? b.name ?? null;
      if (label !== null && typeof label !== "string") throw new ApiError(400, "label must be a string.");
      const partner = b.partner_type ?? b.partnerType ?? null;
      if (partner !== null && typeof partner !== "string") throw new ApiError(400, "partner_type must be a string.");
      const created = await rpc(sb, "_exos_listing_key_create", {
        p_org_id: orgId, p_label: label, p_partner_type: partner, p_actor: null, p_api_key_id: c.key.id,
      }) as Record<string, unknown>;
      return new Created({ data: { ...created, feed_url: feedUrl(String(created.key)) } });
    }

    case "revoke-listing-key": {
      const id = c.params.id;
      if (!UUID_RE.test(id)) throw new ApiError(404, "shared key not found");
      // The API key's creator must be an owner now, as in the dashboard (SQL checks it).
      await rpc(sb, "_exos_listing_key_revoke", { p_org_id: orgId, p_key_id: id, p_api_key_id: c.key.id });
      return { data: { id, revoked: true } };
    }
  }
  // Offers, budgets, finance, settlements, P&L, ticket counts (./finance.ts).
  const fin = await handleFinance(route.id, c, FIN_DEPS);
  if (fin !== undefined) return fin;
  throw new ApiError(404, "not found");
}

const FIN_DEPS: FinDeps = {
  notFound: (what) => new ApiError(404, `${what} not found`),
  conflict: (msg) => new ApiError(409, msg),
  paged,
  rpc,
  created: (body) => new Created(body),
};

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

const SERIES_COLS = "id, name, kind, status, description, image_url, template_event_id, timezone, rule, " +
  "created_at, updated_at, cancelled_at";
const SERIES_STATUSES = new Set(["active", "archived", "cancelled"]);
const OCCURRENCE_COLS = "occ_date, occ_time, starts_at, event_id, status";
const COLLECTION_COLS = "id, name, slug, description, image_url, mode, event_ids, rule_kind, rule_value, published, " +
  "sort_order, created_at, updated_at";

/** The :id path parameter as a UUID; anything else is simply not found. */
function idParam(c: Ctx, notFound: string): string {
  const id = c.params.id;
  if (!UUID_RE.test(id)) throw new ApiError(404, notFound);
  return id;
}

function dateParam(q: URLSearchParams, name: string): string | null {
  const v = q.get(name);
  if (v === null) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v))) throw new ApiError(400, `${name} must be a date (YYYY-MM-DD).`);
  return v;
}

// -- The listing feed --------------------------------------------------------------

async function listingFeed(req: Request, url: URL, path: string): Promise<Response> {
  const cors = { "access-control-allow-origin": "*" };
  const noStore = { ...cors, "cache-control": "no-store" };
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        ...cors, "access-control-allow-methods": "GET, HEAD, OPTIONS",
        "access-control-allow-headers": "x-shared-key, if-none-match", "access-control-max-age": "86400",
      },
    });
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return json({ error: "method not allowed" }, 405, { ...noStore, allow: "GET, HEAD" });
  }
  const match = matchRoute("GET", path);
  if (!match || match.route.auth !== "shared_key") return json({ error: "not found" }, 404, noStore);

  const key = (url.searchParams.get("shared_key") ?? req.headers.get("x-shared-key") ?? "").trim();
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const hash = SHARED_KEY_RE.test(key) ? await sha256Hex(key) : null;
  // A bucket per key; missing or malformed keys share one per network.
  let bucket = `lfeed:${hash?.slice(0, 24)}`;
  if (!hash) {
    const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    bucket = `lfeed-ip:${(await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown"}`;
  }
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: FEED_RATE_LIMIT });
  if (rlErr) {
    console.error("exos-api feed: rate limiter error (refusing)", rlErr.message);
    return json({ error: "temporarily unavailable" }, 503, { ...noStore, "retry-after": "30" });
  }
  if (allowed === false) {
    return json({ error: "rate limit exceeded", limit_per_minute: FEED_RATE_LIMIT }, 429, {
      ...noStore, "retry-after": String(Math.max(1, 60 - new Date().getUTCSeconds())),
    });
  }
  if (!key) return json({ error: "missing shared_key" }, 401, noStore);
  if (!hash) return json({ error: "invalid or revoked shared_key" }, 401, noStore);

  try {
    const now = new Date();
    const one = match.params.id;
    if (one !== undefined && !UUID_RE.test(one)) return json({ error: "event not found" }, 404, noStore);
    const q = one === undefined ? parseFeedQuery(url.searchParams, now) : null;
    const { data, error } = await sb.rpc("exos_listing_feed_source", {
      p_key_hash: hash, p_event_id: one ?? null, p_since: q ? q.startGte.toISOString() : null,
    });
    if (error) throw error;
    const source = data as FeedSource | null;
    if (!source) return json({ error: "invalid or revoked shared_key" }, 401, noStore);
    const events = await withFees(sb, source.events ?? []);
    const opts = {
      appBase: (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, ""),
      partnerType: source.key.partner_type,
      now,
    };
    let body: unknown;
    if (q) body = buildFeedPage(events, q, opts);
    else if (events.length) body = feedEntry(events[0], opts);
    else return json({ error: "event not found" }, 404, noStore);

    const text = JSON.stringify(body);
    const etag = `"${(await sha256B64(text)).slice(0, 27)}"`;
    const headers = {
      ...cors, "cache-control": `public, max-age=${FEED_MAX_AGE}`, etag, vary: "X-Shared-Key",
      "content-type": "application/json",
    };
    if (etagMatches(req.headers.get("if-none-match"), etag)) return new Response(null, { status: 304, headers });
    return new Response(req.method === "HEAD" ? null : text, { status: 200, headers });
  } catch (e) {
    if (e instanceof FeedParamError) return json({ error: e.message }, 400, noStore);
    console.error("exos-api feed error:", e);
    return json({ error: "internal error" }, 500, noStore);
  }
}

/** Public tiers with their passed-on fees, so prices are all-in like every other feed. */
async function withFees(sb: SupabaseClient, events: SourceEvent[]): Promise<SourceEvent[]> {
  const flat = events.flatMap((e) => (e.tiers ?? []).map((t) => ({ ...t, event_id: e.id })));
  if (!flat.length) return events;
  const priced = await withPublicTierFees(sb, flat);
  const byEvent = new Map<string, typeof priced>();
  for (const t of priced) byEvent.set(t.event_id, [...(byEvent.get(t.event_id) ?? []), t]);
  return events.map((e) => ({ ...e, tiers: byEvent.get(e.id) ?? [] }));
}

function feedUrl(key: string): string | null {
  const base = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  return base ? `${base}/functions/v1/exos-api/v1/public/events?shared_key=${encodeURIComponent(key)}` : null;
}

// -- Helpers for the artist / lineup / key routes ------------------------------------

/** An artist row as the API shows it: Spotify URI and URL derived, thumbnail falls back to the photo. */
function artistView(a: Record<string, unknown>): Record<string, unknown> {
  return { ...a, image_thumb_url: a.image_thumb_url ?? a.image_url ?? null, ...spotifyLinks(a.spotify_id) };
}

function artistId(c: Ctx): string {
  const id = c.params.id;
  if (!UUID_RE.test(id)) throw new ApiError(404, "artist not found");
  return id;
}

async function ownArtist(c: Ctx): Promise<Record<string, unknown>> {
  const id = artistId(c);
  const { data, error } = await c.sb.from("exos_artists").select(ARTIST_COLS)
    .eq("org_id", c.orgId).eq("id", id).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "artist not found");
  return artistView(data as unknown as Record<string, unknown>);
}

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

/** Opendate-style bodies wrap the fields ({ artist: { name } }); both forms work. */
function unwrap(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const inner = body[wrapper];
  return inner && typeof inner === "object" && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

/** The SQLSTATEs the artist, lineup and key functions raise, as HTTP answers. */
const RPC_STATUS: Record<string, number> = {
  "22023": 400, "42501": 403, "P0002": 404, "23505": 409, "55000": 409, "54000": 409,
};

function rpcError(e: unknown): { status: number; message: string } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  if (!(code in RPC_STATUS)) return null;
  return { status: RPC_STATUS[code], message: String(err?.message ?? "invalid request").slice(0, 300) };
}

async function sha256B64(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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

// -- Sales counts helpers ------------------------------------------------------

type SalesWrite = SalesCountRow & { status: "created" | "updated" | "unchanged" };

/** The row as the API shows it: `available` = capacity − sold when a capacity is known. */
function salesView(r: SalesCountRow): Record<string, unknown> {
  const { status: _status, ...rest } = r as SalesWrite;
  return { ...rest, available: r.capacity === null || r.capacity === undefined ? null : Math.max(0, r.capacity - r.sold) };
}

async function salesRow(c: Ctx): Promise<SalesCountRow> {
  const id = c.params.id;
  if (!UUID_RE.test(id)) throw new ApiError(404, "sales count not found");
  const { data, error } = await c.sb.from("exos_sales_counts").select(SALES_COLS)
    .eq("org_id", c.orgId).eq("id", id).maybeSingle();
  if (error) throw error;
  if (!data) throw new ApiError(404, "sales count not found");
  return data as unknown as SalesCountRow;
}

/** The one writer (exos_api_sales_count_put re-checks the event / row is the key's org's). */
async function put(c: Ctx, args: Record<string, unknown>): Promise<SalesWrite> {
  const { data, error } = await c.sb.rpc("exos_api_sales_count_put", {
    p_file_name: null, p_row_count: null, ...args, p_org_id: c.orgId,
  });
  if (error) throw error;
  return data as SalesWrite;
}

function str(v: unknown, name: string): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new ApiError(400, `${name} must be a string.`);
  const t = v.trim();
  return t === "" ? null : t;
}

function int(v: unknown, name: string): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) throw new ApiError(400, `${name} must be a whole number, 0 or more.`);
  return v;
}

/** gross_cents, else price_cents × sold (a unit price, as Opendate sends). */
function grossOf(b: Record<string, unknown>, sold: number | null): number | null {
  const g = int(b.gross_cents, "gross_cents");
  if (g !== null) return g;
  const p = int(b.price_cents, "price_cents");
  return p !== null && sold !== null ? p * sold : null;
}

/** capacity, else sold + available. */
function capacityOf(b: Record<string, unknown>, sold: number | null): number | null {
  const cap = int(b.capacity, "capacity");
  if (cap !== null) return cap;
  const avail = int(b.available, "available");
  return avail !== null && sold !== null ? sold + avail : null;
}

function tiersOf(b: Record<string, unknown>): unknown[] | null {
  if (b.tiers === undefined || b.tiers === null) return null;
  if (!Array.isArray(b.tiers) || b.tiers.length > 50) throw new ApiError(400, "tiers must be an array of at most 50 ticket types.");
  return b.tiers;
}

/** The file as rows: `csv` (text), or `rows` (objects keyed by column, or arrays with the header first). */
function importTable(b: Record<string, unknown>): string[][] {
  if (typeof b.csv === "string") {
    if (new TextEncoder().encode(b.csv).length > MAX_IMPORT_BYTES) throw new ApiError(413, "the CSV is larger than 2 MB.");
    return parseCsv(b.csv);
  }
  if (Array.isArray(b.rows) && b.rows.length > 0) {
    if (b.rows.length > 2001) throw new ApiError(400, "at most 2000 rows; split the file.");
    const cellOf = (v: unknown) => (v === null || v === undefined || typeof v === "object" ? "" : String(v));
    if (Array.isArray(b.rows[0])) return (b.rows as unknown[]).map((r) => (Array.isArray(r) ? r.map(cellOf) : []));
    const header: string[] = [];
    for (const r of b.rows) {
      if (!r || typeof r !== "object" || Array.isArray(r)) throw new ApiError(400, "rows must all be objects, or all arrays.");
      for (const k of Object.keys(r)) if (!header.includes(k)) header.push(k);
      if (header.length > 100) throw new ApiError(400, "at most 100 columns.");
    }
    return [header, ...(b.rows as Record<string, unknown>[]).map((r) => header.map((k) => cellOf(r[k])))];
  }
  throw new ApiError(400, "send the file as csv (text) or rows.");
}

/** mapping: { field: "Column header" }; fields left out are guessed from the headers, null unmaps one. */
function importMapping(raw: unknown, header: string[]): SalesMapping {
  const out = suggestSalesMapping(header);
  if (raw === undefined || raw === null) return out;
  if (typeof raw !== "object" || Array.isArray(raw)) throw new ApiError(400, "mapping must be an object of field: column header.");
  for (const [field, col] of Object.entries(raw as Record<string, unknown>)) {
    if (!(SALES_FIELDS as readonly string[]).includes(field)) throw new ApiError(400, `mapping: unknown field "${field}".`);
    if (col === null || col === "") {
      delete out[field as SalesField];
      continue;
    }
    if (typeof col !== "string") throw new ApiError(400, `mapping.${field} must be a column header.`);
    const i = header.findIndex((h) => h.trim().toLowerCase() === col.trim().toLowerCase());
    if (i < 0) throw new ApiError(400, `mapping.${field}: column "${col}" is not in the file.`);
    out[field as SalesField] = i;
  }
  return out;
}

/**
 * A JSON body, or a form-encoded one (artist[name]=…&artist[genres][]=…), at
 * most `max` bytes, counted while streaming (_shared/api/body.ts). Form bodies
 * are decoded from the capped text (never req.formData(), which reads without
 * a cap). Any other declared Content-Type is a 415.
 */
async function readBody(req: Request, max: number): Promise<Record<string, unknown>> {
  const ct = (req.headers.get("content-type") ?? "").toLowerCase();
  const form = ct.includes("application/x-www-form-urlencoded");
  if (ct && !form && !ct.includes("json")) {
    throw new ApiError(415, "send a JSON body (Content-Type: application/json) or a form-encoded one.");
  }
  const text = await readCapped(req, max);
  if (text === null) throw new ApiError(413, "request body too large.");
  if (!text.trim()) return {};
  if (form) return formBody(text);
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    throw new ApiError(400, "the body is not valid JSON.");
  }
  // An array passes too: PUT /events/:id/lineup takes a bare list of slots.
  if (!v || typeof v !== "object") throw new ApiError(400, "the body must be a JSON object.");
  return v as Record<string, unknown>;
}

/** A Postgres error raised by a sales-count RPC as an HTTP answer with its own message. */
function dbError(e: unknown): { status: number; message: string } | null {
  if (!e || typeof e !== "object") return null;
  const { code, message } = e as { code?: string; message?: string };
  const msg = String(message ?? "").replace(/^sales counts:\s*/i, "");
  if (code === "22023") return { status: 400, message: msg };
  if (code === "P0002") return { status: 404, message: msg };
  if (code === "23505") return { status: 409, message: msg };
  return null;
}

async function tiers(sb: SupabaseClient, eventId: string): Promise<unknown[]> {
  const { data, error } = await withoutMissing(TIER_SEAT_COLS, (extra) =>
    sb.from("exos_ticket_tiers").select(TIER_COLS + extra)
      .eq("event_id", eventId).order("sort_order", { ascending: true }));
  if (error) throw error;
  return data ?? [];
}

/** Runs a query with optional extra columns, and again without them when the
 *  database doesn't have them yet (undefined column). */
// deno-lint-ignore no-explicit-any
async function withoutMissing<R extends { error: any }>(extra: string, run: (extra: string) => PromiseLike<R>): Promise<R> {
  const r = await run(extra);
  if (r.error && (r.error.code === "42703" || r.error.code === "PGRST204")) return await run("");
  return r;
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
