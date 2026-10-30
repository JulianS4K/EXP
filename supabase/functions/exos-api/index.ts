// exos-api — org-scoped partner REST API for Exos.
// Reference: docs/api-reference.md and /developers (built from docs/api/*.json).
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to, and the key's scopes. Everything is a read except the
// sales counts (tickets sold on other platforms, mig 20261030120000), whose
// POST / PUT / DELETE need finance:write and go through service-role RPCs that
// re-check the event / row belongs to the key's org.
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
//   attendees, check-ins, check-in-lists, guest-lists, waitlist, seats,
//   seat-reconciliation}, /orders,
//   /orders/:id, /invoices, /refunds, /webhooks, /events/:id/sales-counts,
//   /sales-counts, /sales-counts/:id, /eventbrite-events/:id
// Writes: POST /sales-counts, PUT + DELETE /sales-counts/:id,
//   POST /events/:id/sales-counts/import

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { API_METHODS, apiPath, matchRoute, type ApiMethod, type ApiRoute } from "../_shared/api/routes.ts";
import { effectiveScopes, hasScope } from "../_shared/api/scopes.ts";
import { pageEnvelope, PagingError, parsePage, type Page } from "../_shared/api/paging.ts";
import { parseCsv } from "../_shared/csvParse.ts";
import {
  isPlatform, MAX_IMPORT_BYTES, planSalesImport, SALES_FIELDS, salesTotals, suggestSalesMapping,
  type SalesCountRow, type SalesField, type SalesMapping,
} from "../_shared/salesCounts.ts";

const RATE_LIMIT = 120; // requests per key per minute
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;

const EVENT_LIST_COLS = "id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at";
const EVENT_COLS =
  "id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, " +
  "tickets_sold, total_tickets, created_at";
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
// A JSON body: the CSV import may carry a 2 MB file as a string.
const MAX_BODY_BYTES = MAX_IMPORT_BYTES + 256 * 1024;

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
    const body = method === "GET" || method === "DELETE" ? {} : await readJson(req);
    const ctx: Ctx = {
      sb, orgId,
      key: { id: keyRow.id, name: keyRow.name, key_prefix: keyRow.key_prefix, scopes },
      params: match.params,
      q: url.searchParams,
      // Only lists read ?page / ?per_page; elsewhere they are ignored.
      page: parsePage(match.route.paged ? url.searchParams : new URLSearchParams()),
      body,
    };
    const out = await handle(match.route, ctx);
    if (out instanceof Response) return out;
    return json(out);
  } catch (e) {
    if (e instanceof PagingError) return json({ error: e.message }, 400);
    if (e instanceof ApiError) return json({ error: e.message }, e.status);
    const pg = dbError(e);
    if (pg) return json({ error: pg.message }, pg.status);
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

async function handle(route: ApiRoute, c: Ctx): Promise<unknown | Response> {
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
 * The body as text, refused with 413 once it passes `max` bytes. Counts while
 * streaming, so a chunked body without Content-Length can't be read in full.
 */
async function readCapped(req: Request, max: number): Promise<string> {
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
      throw new ApiError(413, "request body too large.");
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

async function readJson(req: Request): Promise<Record<string, unknown>> {
  if (Number(req.headers.get("content-length") ?? "0") > MAX_BODY_BYTES) throw new ApiError(413, "request body too large.");
  const ct = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!ct.startsWith("application/json")) throw new ApiError(415, "send a JSON body (Content-Type: application/json).");
  const text = await readCapped(req, MAX_BODY_BYTES);
  let v: unknown;
  try {
    v = JSON.parse(text || "{}");
  } catch {
    throw new ApiError(400, "the body is not valid JSON.");
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new ApiError(400, "the body must be a JSON object.");
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
