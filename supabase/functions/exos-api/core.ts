// exos-api — the core partner API (mig 20261031110000, docs/api-reference.md):
// writes over what the dashboard already does (events, ticket types, add-ons,
// promo codes, refunds, comps, check-ins, guest lists, POS items) and the
// reads around them (publish blockers, tickets, refunds, disputes, payouts).
//
// Every write is ONE call to exos_api_write(key, action, target, args,
// idempotency key). That SQL function runs as the member who created the key,
// pins the target to the key's org, re-checks the key's scope, and calls the
// dashboard's own RPC (or checks the dashboard's RLS roles before writing the
// table), so a write here behaves exactly like the same write in the
// dashboard, and logs it in exos_api_writes. No business rule lives in this
// file: it shapes requests and answers only.
//
// Refunds also need Stripe: exos_api_write claims (the dashboard's
// exos_refund_claim, idempotent on the Idempotency-Key), then refundClaim
// (_shared/refundRun.ts, shared with exos-refund) refunds and finalizes.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import { type Claim, refundClaim } from "../_shared/refundRun.ts";
import { createPayPalClient, paypalConfig } from "../_shared/paypal/client.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;
const IDEMPOTENCY_RE = /^[A-Za-z0-9_.:-]{8,100}$/;

// Never barcode_secret.
const TICKET_COLS =
  "id, event_id, tier_id, tier_name, attendee_name, buyer_email, status, check_in_at, price_paid, " +
  "order_ref, channel_source, created_at, updated_at";
const TIER_COLS =
  "id, event_id, name, description, price, capacity, sold, ticket_type, visibility, sales_start, sales_end, sort_order";
const ADDON_COLS = "id, event_id, name, description, price, capacity, sold, max_per_order, visibility, sort_order";
// Never reserved_email: a promo code's holder is not the partner's business.
const PROMO_COLS =
  "id, event_id, code, tier_id, max_uses, used_count, discount_percent, discount_amount, price_override, " +
  "valid_until, comment, link_label, link_channel, link_clicks, created_at";
const GUEST_COLS =
  "id, list_id, event_id, guest_name, email, phone, plus_ones, arrived, arrived_at, note, source, created_at, updated_at";
const DISPUTE_COLS =
  "id, event_id, session_id, dispute_id, amount_cents, fee_cents, currency, reason, status, evidence_due_by, " +
  "evidence_submitted, recovery_status, created_at, updated_at, closed_at";
const POS_ITEM_COLS =
  "id, event_id, category, name, sku, price_cents, tax_rule_id, tier_id, active, is_86d, inventory_count, sort_order, " +
  "created_at, updated_at";

/** An error answer: status, message and (optionally) more fields. */
export class CoreError extends Error {
  constructor(public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}

/** An answer with its own status (201 Created, 409 with blockers, ...). */
export class Answer {
  constructor(public status: number, public body: unknown) {}
}

export interface CoreCtx {
  sb: SupabaseClient;
  orgId: string;
  keyId: string;
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

/** The route ids this module answers. */
export const CORE_ROUTES = new Set([
  "create-event", "update-event", "get-publish-blockers", "publish-event", "unpublish-event",
  "get-ticketing-configuration", "list-event-fee-rules",
  "get-ticket-type", "create-ticket-type", "update-ticket-type", "delete-ticket-type",
  "get-add-on", "create-add-on", "update-add-on", "delete-add-on",
  "get-promo-code", "create-promo-code", "update-promo-code", "delete-promo-code",
  "list-tickets", "get-ticket", "scan-lookup", "check-in-ticket", "check-out-ticket", "undo-check-in",
  "check-in-order", "submit-offline-check-ins", "issue-comps",
  "get-refund-preview", "create-refund", "get-refund", "get-refund-request",
  "list-disputes", "get-dispute", "list-payouts", "get-payout",
  "create-guest-list", "update-guest-list", "delete-guest-list", "list-guests", "add-guests",
  "update-guest", "remove-guest", "check-in-guest",
  "list-pos-items", "get-pos-item", "create-pos-item", "update-pos-item", "list-pos-devices",
  "list-api-writes",
]);

export async function handleCore(route: ApiRoute, c: CoreCtx): Promise<unknown> {
  const { sb, orgId, page, params: p } = c;
  switch (route.id) {
    // -- Events -------------------------------------------------------------------
    case "create-event": {
      const ev = { ...unwrap(c.body, "event") };
      const types = c.body.ticket_types ?? ev.ticket_types;
      delete ev.ticket_types;
      const args: Record<string, unknown> = { event: ev };
      if (types !== undefined) args.ticket_types = types;
      return new Answer(201, { data: await write(c, "event.create", null, args) });
    }
    case "update-event":
      return { data: await write(c, "event.update", uuidOr404(p.id, "event"), { event: unwrap(c.body, "event") }) };
    case "get-publish-blockers": {
      const id = await ownEvent(c, p.id);
      const blockers = await rpc(sb, "_exos_event_publish_blockers", { p_event_id: id }) as unknown[];
      return { data: { event_id: id, publishable: blockers.length === 0, blockers } };
    }
    case "publish-event": {
      const out = await write(c, "event.publish", uuidOr404(p.id, "event"), {}) as { published?: boolean; blockers?: unknown };
      if (!out?.published) {
        throw new CoreError(409, "the event can't be published yet", { blockers: out?.blockers ?? [], data: out });
      }
      return { data: out };
    }
    case "unpublish-event":
      return { data: await write(c, "event.unpublish", uuidOr404(p.id, "event"), {}) };
    case "get-ticketing-configuration": {
      const id = await ownEvent(c, p.id);
      const [ev, fees, lists] = await Promise.all([
        sb.from("exos_events").select(
          "id, status, currency, timezone, total_tickets, tickets_sold, purchase_limits, allow_holder_release, " +
            "release_cutoff_hours, door_name_checkin, ticket_backend, external_ticket_url",
        ).eq("id", id).maybeSingle(),
        sb.from("exos_event_fee_settings").select("inherit_org_rules, skipped_org_rule_ids").eq("event_id", id).maybeSingle(),
        sb.from("exos_checkin_lists").select("id, name, tier_ids, allow_reentry, valid_from, valid_until")
          .eq("event_id", id).eq("org_id", orgId).order("sort_order", { ascending: true }),
      ]);
      for (const r of [ev, fees, lists]) if (r.error) throw r.error;
      return {
        data: {
          ...(ev.data as unknown as Record<string, unknown>),
          fee_settings: fees.data ?? { inherit_org_rules: true, skipped_org_rule_ids: [] },
          check_in_lists: lists.data ?? [],
        },
      };
    }
    case "list-event-fee-rules": {
      const id = await ownEvent(c, p.id);
      return rows(await sb.from("exos_effective_fee_rules")
        .select("rule_id, rule_event_id, name, recipient, kind, calc, percent, amount_cents, cap_cents, per, " +
          "taxable, applies_to_addons, tier_ids, rank")
        .eq("event_id", id).eq("org_id", orgId).order("rank", { ascending: true }));
    }

    // -- Ticket types, add-ons, promo codes --------------------------------------------
    case "get-ticket-type":
      return { data: await ownChild(c, "exos_ticket_tiers", TIER_COLS, p.id, p.tier, "ticket type") };
    case "create-ticket-type":
      return new Answer(201, {
        data: await write(c, "ticket_type.create", uuidOr404(p.id, "event"), { ticket_type: unwrap(c.body, "ticket_type") }),
      });
    case "update-ticket-type":
      await ownChild(c, "exos_ticket_tiers", "id", p.id, p.tier, "ticket type");
      return { data: await write(c, "ticket_type.update", p.tier, { ticket_type: unwrap(c.body, "ticket_type") }) };
    case "delete-ticket-type":
      await ownChild(c, "exos_ticket_tiers", "id", p.id, p.tier, "ticket type");
      return { data: await write(c, "ticket_type.delete", p.tier, {}) };

    case "get-add-on":
      return { data: await ownChild(c, "exos_event_addons", ADDON_COLS, p.id, p.addon, "add-on") };
    case "create-add-on":
      return new Answer(201, {
        data: await write(c, "add_on.create", uuidOr404(p.id, "event"), { add_on: unwrap(c.body, "add_on") }),
      });
    case "update-add-on":
      await ownChild(c, "exos_event_addons", "id", p.id, p.addon, "add-on");
      return { data: await write(c, "add_on.update", p.addon, { add_on: unwrap(c.body, "add_on") }) };
    case "delete-add-on":
      await ownChild(c, "exos_event_addons", "id", p.id, p.addon, "add-on");
      return { data: await write(c, "add_on.delete", p.addon, {}) };

    case "get-promo-code":
      return { data: await ownChild(c, "exos_vouchers", PROMO_COLS, p.id, p.code, "promo code") };
    case "create-promo-code":
      return new Answer(201, {
        data: await write(c, "promo_code.create", uuidOr404(p.id, "event"), { promo_code: unwrap(c.body, "promo_code") }),
      });
    case "update-promo-code":
      await ownChild(c, "exos_vouchers", "id", p.id, p.code, "promo code");
      return { data: await write(c, "promo_code.update", p.code, { promo_code: unwrap(c.body, "promo_code") }) };
    case "delete-promo-code":
      await ownChild(c, "exos_vouchers", "id", p.id, p.code, "promo code");
      return { data: await write(c, "promo_code.delete", p.code, {}) };

    // -- Tickets and the door -------------------------------------------------------------
    case "list-tickets": {
      let q = sb.from("exos_tickets").select(TICKET_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) q = q.eq("event_id", uuidOr400(ev, "event_id"));
      const status = c.q.get("status");
      if (status !== null) {
        if (!/^[a-z_]{1,32}$/.test(status)) throw new CoreError(400, "status is invalid.");
        q = q.eq("status", status);
      }
      const order = c.q.get("order_id");
      if (order !== null) {
        if (!SESSION_RE.test(order)) throw new CoreError(400, "order_id is invalid.");
        q = q.eq("order_ref", order);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
    case "get-ticket":
      return { data: await ticketWithScans(c, uuidOr404(p.id, "ticket")) };
    case "scan-lookup": {
      // A ticket id, or the ticket id inside a rotating door code (T-<ticket>:<owner>:<window>:<mac>).
      // This only finds the ticket; check-in with the code is what verifies it.
      const code = p.code.trim();
      const m = /^T-([0-9a-f-]{36}):/i.exec(code);
      const id = UUID_RE.test(code) ? code : m && UUID_RE.test(m[1]) ? m[1] : null;
      if (!id) throw new CoreError(404, "no ticket for this code");
      return { data: { code_type: m ? "door_code" : "ticket_id", ticket: await ticketWithScans(c, id) } };
    }
    case "check-in-ticket":
    case "check-out-ticket":
      return {
        data: await write(c, "ticket.check_in", uuidOr404(p.id, "ticket"), {
          barcode: str(c.body.barcode), reason: str(c.body.reason), list_id: c.body.list_id ?? null,
          device: str(c.body.device), direction: route.id === "check-out-ticket" ? "exit" : "entry",
        }),
      };
    case "undo-check-in":
      return { data: await write(c, "ticket.undo_check_in", uuidOr404(p.id, "ticket"), { reason: str(c.body.reason) }) };
    case "check-in-order":
      return {
        data: await write(c, "order.check_in", sessionOr404(p.id), {
          reason: str(c.body.reason), list_id: c.body.list_id ?? null, device: str(c.body.device),
          direction: c.body.direction === "exit" ? "exit" : "entry",
        }),
      };
    case "submit-offline-check-ins": {
      const scans = c.body.scans ?? c.body.offline_check_in_activities;
      if (!Array.isArray(scans)) throw new CoreError(400, "scans must be a list of { client_ref, ticket_id, scanned_at, ... }.");
      return { data: await write(c, "event.offline_check_ins", uuidOr404(p.id, "event"), { scans }) };
    }

    // -- Comps -------------------------------------------------------------------------------
    case "issue-comps": {
      const b = unwrap(c.body, "comps");
      return new Answer(201, {
        data: await write(c, "comp.issue", uuidOr404(p.id, "event"), {
          tier_id: b.tier_id ?? b.ticket_type_id ?? null, emails: b.emails, quantity_each: b.quantity_each ?? 1,
        }),
      });
    }

    // -- Refunds ----------------------------------------------------------------------------
    case "get-refund-preview":
      return { data: await write(c, "refund.preview", sessionOr404(p.id), {}) };
    case "create-refund":
      return await createRefund(c, sessionOr404(p.id));
    case "get-refund":
      return { data: await one(sb.from("exos_order_refunds")
        .select("id, session_id, amount_cents, currency, status, reason, is_partial, created_at, updated_at")
        .eq("org_id", orgId).eq("id", uuidOr404(p.id, "refund")).maybeSingle(), "refund") };
    case "get-refund-request": {
      const r = await one(sb.from("exos_refund_requests")
        .select("id, session_id, event_id, scope, amount_cents, currency, reason, status, stripe_refund_id, error, " +
          "created_at, updated_at, exos_refund_request_items(ticket_id, amount_cents, covers_full)")
        .eq("org_id", orgId).eq("id", uuidOr404(p.id, "refund request")).maybeSingle(), "refund request");
      const { exos_refund_request_items: items, ...rest } = r as Record<string, unknown>;
      return { data: { ...rest, items: items ?? [] } };
    }
    case "list-disputes": {
      let q = sb.from("exos_disputes").select(DISPUTE_COLS, { count: "exact" }).eq("org_id", orgId);
      const status = c.q.get("status");
      if (status !== null) {
        if (!/^[a-z_]{1,40}$/.test(status)) throw new CoreError(400, "status is invalid.");
        q = q.eq("status", status);
      }
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
    case "get-dispute":
      return { data: await one(sb.from("exos_disputes").select(DISPUTE_COLS)
        .eq("org_id", orgId).eq("id", uuidOr404(p.id, "dispute")).maybeSingle(), "dispute") };
    case "list-payouts":
      return paged(await sb.from("exos_org_payouts")
        .select("id, currency, amount, status, stripe_transfer_id, error, created_at, sent_at", { count: "exact" })
        .eq("org_id", orgId).order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    case "get-payout": {
      const id = uuidOr404(p.id, "payout");
      const payout = await one(sb.from("exos_org_payouts")
        .select("id, currency, amount, status, stripe_transfer_id, error, created_at, updated_at, sent_at")
        .eq("org_id", orgId).eq("id", id).maybeSingle(), "payout");
      const lines = rows(await sb.from("exos_org_payout_lines").select("id, order_id, kind, amount, created_at")
        .eq("org_id", orgId).eq("payout_id", id).order("created_at"));
      return { data: { ...(payout as Record<string, unknown>), lines: lines.data } };
    }

    // -- Guest lists ---------------------------------------------------------------------------
    case "create-guest-list":
      return new Answer(201, {
        data: await write(c, "guest_list.create", uuidOr404(p.id, "event"), { guest_list: unwrap(c.body, "guest_list") }),
      });
    case "update-guest-list":
      return { data: await write(c, "guest_list.update", uuidOr404(p.id, "guest list"), { guest_list: unwrap(c.body, "guest_list") }) };
    case "delete-guest-list":
      return { data: await write(c, "guest_list.delete", uuidOr404(p.id, "guest list"), {}) };
    case "list-guests": {
      const id = uuidOr404(p.id, "guest list");
      await one(sb.from("exos_guest_lists").select("id").eq("org_id", orgId).eq("id", id).maybeSingle(), "guest list");
      return paged(await sb.from("exos_guest_list_entries").select(GUEST_COLS, { count: "exact" })
        .eq("org_id", orgId).eq("list_id", id).is("voided_at", null)
        .order("created_at", { ascending: true }).order("id").range(page.from, page.to), page);
    }
    case "add-guests": {
      const guests = Array.isArray(c.body.guests) ? c.body.guests : null;
      const out = await write(c, "guest.add", uuidOr404(p.id, "guest list"), guests ? { guests } : unwrap(c.body, "guest"));
      return new Answer(201, out);
    }
    case "update-guest":
      return { data: await write(c, "guest.update", uuidOr404(p.id, "guest"), unwrap(c.body, "guest")) };
    case "remove-guest":
      return { data: await write(c, "guest.remove", uuidOr404(p.id, "guest"), {}) };
    case "check-in-guest":
      return {
        data: await write(c, "guest.check_in", uuidOr404(p.id, "guest"), {
          count: c.body.count ?? 1, client_ref: c.body.client_ref ?? null,
        }),
      };

    // -- POS catalog and devices ---------------------------------------------------------------
    case "list-pos-items": {
      let q = sb.from("exos_pos_items").select(POS_ITEM_COLS, { count: "exact" }).eq("org_id", orgId);
      const ev = c.q.get("event_id");
      if (ev !== null) q = q.eq("event_id", uuidOr400(ev, "event_id"));
      const cat = c.q.get("category");
      if (cat !== null) {
        if (!/^[a-z_]{1,20}$/.test(cat)) throw new CoreError(400, "category is invalid.");
        q = q.eq("category", cat);
      }
      return paged(await q.order("sort_order", { ascending: true }).order("id").range(page.from, page.to), page);
    }
    case "get-pos-item":
      return { data: await one(sb.from("exos_pos_items").select(POS_ITEM_COLS)
        .eq("org_id", orgId).eq("id", uuidOr404(p.id, "item")).maybeSingle(), "item") };
    case "create-pos-item":
      return new Answer(201, { data: await write(c, "pos_item.create", null, { item: unwrap(c.body, "item") }) });
    case "update-pos-item":
      return { data: await write(c, "pos_item.update", uuidOr404(p.id, "item"), { item: unwrap(c.body, "item") }) };
    case "list-pos-devices":
      return rows(await sb.from("exos_pos_devices")
        .select("id, event_id, name, kind, status, last_seen_at, created_at")
        .eq("org_id", orgId).order("created_at", { ascending: true }));

    // -- The write log -------------------------------------------------------------------------
    case "list-api-writes": {
      let q = sb.from("exos_api_writes")
        .select("id, api_key_id, actor, action, target, idempotency_key, money_moving, created_at", { count: "exact" })
        .eq("org_id", orgId);
      const action = c.q.get("action");
      if (action !== null) {
        if (!/^[a-z_]{2,40}\.[a-z_]{2,40}$/.test(action)) throw new CoreError(400, "action is invalid.");
        q = q.eq("action", action);
      }
      if (c.q.get("money_moving") === "true") q = q.eq("money_moving", true);
      return paged(await q.order("created_at", { ascending: false }).order("id").range(page.from, page.to), page);
    }
  }
  throw new CoreError(404, "not found");
}

// -- Refunds ---------------------------------------------------------------------------------

async function createRefund(c: CoreCtx, sessionId: string): Promise<Answer> {
  if (!c.idempotencyKey) {
    throw new CoreError(400, "refunds need an Idempotency-Key header (8-100 letters, digits, _ . : or -)");
  }
  // Stripe and PayPal (mig 20261031220000), each only when its keys are set,
  // as in exos-refund: an order paid with PayPal / Venmo refunds at PayPal.
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  const ppCfg = paypalConfig((k) => Deno.env.get(k));
  if (!stripeKey && !ppCfg) throw new CoreError(503, "payments are switched off");
  const b = unwrap(c.body, "refund");
  const items = b.items ?? null;
  if (items !== null && (!Array.isArray(items) || items.length > 100)) {
    throw new CoreError(400, "items must be a list of at most 100 { ticket_id, amount_cents? }");
  }
  const amount = b.amount_cents == null ? null : Number(b.amount_cents);
  if (amount !== null && (!Number.isInteger(amount) || amount <= 0)) {
    throw new CoreError(400, "amount_cents must be a positive whole number");
  }
  const claim = await write(c, "refund.claim", sessionId, {
    items, amount_cents: amount, whole_order: b.whole_order === true, reason: str(b.reason),
  }) as Claim;
  const procs = {
    stripe: stripeKey ? new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" }) : null,
    pp: ppCfg ? createPayPalClient(ppCfg) : null,
  };
  const out = await refundClaim(c.sb, procs, claim, Deno.env.get("EXOS_REFUND_KEEP_PLATFORM_FEE") === "true");
  // Same answers as exos-refund: 'claimed' = Stripe / PayPal didn't answer
  // (retry with the same key, it won't refund twice); 'failed' = it refused.
  const status = out.status === "claimed" ? 502 : out.status === "failed" ? 402 : claim.existing ? 200 : 201;
  return new Answer(status, { data: { ...out, idempotent_replay: claim.existing } });
}

// -- Helpers -------------------------------------------------------------------------------------

/** One exos_api_write call. */
async function write(c: CoreCtx, action: string, target: string | null, args: Record<string, unknown>): Promise<unknown> {
  return await rpc(c.sb, "exos_api_write", {
    p_key_id: c.keyId, p_action: action, p_target: target, p_args: args, p_idempotency_key: c.idempotencyKey,
  });
}

async function rpc(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/** The Idempotency-Key header: null when absent; 400 when malformed. */
export function idempotencyKey(req: Request): string | null {
  const v = req.headers.get("idempotency-key");
  if (v === null) return null;
  if (!IDEMPOTENCY_RE.test(v)) {
    throw new CoreError(400, "Idempotency-Key must be 8-100 letters, digits, _ . : or -");
  }
  return v;
}

/** Opendate-style bodies wrap the fields ({ event: { name } }); both forms work. */
function unwrap(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const inner = body[wrapper];
  return inner && typeof inner === "object" && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v : null;
}

function uuidOr404(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new CoreError(404, `${what} not found`);
  return v;
}

function uuidOr400(v: string, name: string): string {
  if (!UUID_RE.test(v)) throw new CoreError(400, `${name} must be a UUID.`);
  return v;
}

function sessionOr404(v: string | undefined): string {
  if (!v || !SESSION_RE.test(v)) throw new CoreError(404, "order not found");
  return v;
}

async function ownEvent(c: CoreCtx, id: string | undefined): Promise<string> {
  const ev = uuidOr404(id, "event");
  await one(c.sb.from("exos_events").select("id").eq("org_id", c.orgId).eq("id", ev).maybeSingle(), "event");
  return ev;
}

/** A row of `table` under the key's event `eventId` (else 404). */
async function ownChild(
  c: CoreCtx, table: string, cols: string, eventId: string | undefined, id: string | undefined, what: string,
): Promise<Record<string, unknown>> {
  const ev = await ownEvent(c, eventId);
  return await one(c.sb.from(table).select(cols).eq("event_id", ev).eq("id", uuidOr404(id, what)).maybeSingle(), what);
}

async function ticketWithScans(c: CoreCtx, id: string): Promise<Record<string, unknown>> {
  const t = await one(c.sb.from("exos_tickets").select(TICKET_COLS).eq("org_id", c.orgId).eq("id", id).maybeSingle(), "ticket");
  const scans = rows(await c.sb.from("exos_event_checkins")
    .select("id, scanned_at, source, verification, direction, list_id, gate, device")
    .eq("org_id", c.orgId).eq("ticket_id", id).order("scanned_at", { ascending: false }).limit(50));
  return { ...t, check_ins: scans.data };
}

// deno-lint-ignore no-explicit-any
async function one(p: PromiseLike<{ data: any; error: unknown }>, what: string): Promise<Record<string, unknown>> {
  const { data, error } = await p;
  if (error) throw error;
  if (!data) throw new CoreError(404, `${what} not found`);
  return data as Record<string, unknown>;
}

// deno-lint-ignore no-explicit-any
function rows(r: { data: any; error: unknown }): { data: unknown[] } {
  if (r.error) throw r.error;
  return { data: r.data ?? [] };
}

// deno-lint-ignore no-explicit-any
function paged(r: { data: any; error: any; count: number | null }, page: Page) {
  if (r.error) {
    // A page past the end: PostgREST answers 416 (PGRST103); give an empty page.
    if (r.error.code === "PGRST103") {
      const m = /only (\d+) rows?/.exec(String(r.error.details ?? ""));
      return pageEnvelope([], page, m ? Number(m[1]) : null);
    }
    throw r.error;
  }
  return pageEnvelope(r.data ?? [], page, r.count);
}

/**
 * The SQLSTATEs exos_api_write (and the RPCs it calls) raise, as HTTP
 * answers; anything else is a 500.
 */
const SQL_STATUS: Record<string, number> = {
  "22023": 400, "22P02": 400, "22007": 400, "22008": 400, "22001": 400, "22003": 400, "23502": 400,
  "42501": 403, "P0002": 404,
  "23505": 409, "23503": 409, "23514": 409, "55000": 409, "54000": 409,
};

export function sqlError(e: unknown): { status: number; message: string } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  if (!(code in SQL_STATUS)) return null;
  const message = String(err?.message ?? "invalid request").replace(/^(exos|_exos)_[a-z_]+: /, "").slice(0, 300);
  return { status: SQL_STATUS[code], message };
}
