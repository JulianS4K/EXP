// claude/exos-dice-gaps-6 (mig 20261107110000): the fee-change log (DICE
// Adjustment { reason, processedAt, ticket, feesChange }).
//
//   GET /v1/orders/:id/adjustments       orders:read   one order's changes, oldest
//                                                      first, with the net
//   GET /v1/events/:id/fee-adjustments   finance:read  an event's, newest first,
//                                                      paged
//   POST /v1/orders/:id/adjustments      finance:write a manual change (claude/exos-dice-leftovers,
//                                                      mig 20261108110000)
//
// exos_fee_adjustments is append-only. A refund adds the buyer-fee part of the
// money it returned (the order's passed-on fees x refunded / paid; a refund
// that fails later adds the reversal); finance adds manual changes with a note
// in the dashboard or through the POST. The credential's scope decides the
// read (never a role). The POST needs finance:write AND an organization API
// key whose creator is an owner, manager or finance member now
// (_exos_api_fee_adjustment checks it in SQL with _exos_api_key_actor, the
// dashboard's rule); integer cents, a note, an idempotency key (the
// Idempotency-Key header or the body's idempotency_key): a resend answers the
// first row (duplicate: true). It records the change; it moves no money.
// Every read is scoped to the key's org: another org's order or event is a
// 404, and nothing of it is echoed.

import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COLS = "id, session_id, event_id, ticket_id, reason, note, fees_change_cents, currency, refund_id, processed_at";

export const FEE_ADJ_ROUTES = new Set([
  "get-order-fee-adjustments", "list-event-fee-adjustments",
  "create-order-fee-adjustment", // claude/exos-dice-leftovers
]);
/** The routes that answer 201 Created (a resend answers 201 with the first row too). */
export const FEE_ADJ_CREATED = new Set(["create-order-fee-adjustment"]);

export class FeeAdjError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/** What this module needs of the service-role client (structural, so vitest
 *  loads the module without the Deno-only supabase-js import). */
export interface FeeAdjClient {
  // deno-lint-ignore no-explicit-any
  from(table: string): any;
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

export interface FeeAdjCtx {
  sb: FeeAdjClient;
  orgId: string;
  params: Record<string, string>;
  page: Page;
  /** POST only: the credential, the body, the Idempotency-Key header. */
  cred?: { kind: "api_key" | "pat" | "oauth"; id: string };
  body?: Record<string, unknown>;
  idempotencyKey?: string | null;
}

/** The SQL core's limits (mig 20261107110000 _exos_fee_adjustment_add). */
export const MAX_ADJUSTMENT_CENTS = 10_000_000;
const KEY_RE = /^[A-Za-z0-9:_.-]{8,200}$/;

export interface AdjustmentInput {
  fees_change_cents: number;
  note: string;
  ticket_id: string | null;
  idempotency_key: string;
}

/**
 * The POST body: { fees_change_cents, note, ticket_id?, idempotency_key? },
 * flat or wrapped as { adjustment: { … } }. The key is the Idempotency-Key
 * header or idempotency_key (both: they must match).
 */
export function adjustmentBody(body: Record<string, unknown>, headerKey: string | null | undefined): AdjustmentInput {
  const inner = body.adjustment && typeof body.adjustment === "object" && !Array.isArray(body.adjustment)
    ? body.adjustment as Record<string, unknown> : body;
  const cents = inner.fees_change_cents;
  if (typeof cents !== "number" || !Number.isInteger(cents) || cents === 0 || Math.abs(cents) > MAX_ADJUSTMENT_CENTS) {
    throw new FeeAdjError(400, `fees_change_cents is a whole number of cents, not 0, at most ${MAX_ADJUSTMENT_CENTS} either way`);
  }
  const note = typeof inner.note === "string" ? inner.note.trim().replace(/\s+/g, " ") : "";
  if (note.length < 3 || note.length > 500) throw new FeeAdjError(400, "note is required (3 to 500 characters): say why");
  const t = inner.ticket_id;
  if (t !== undefined && t !== null && t !== "" && (typeof t !== "string" || !UUID_RE.test(t))) {
    throw new FeeAdjError(400, "ticket_id must be a UUID");
  }
  const bodyKey = typeof inner.idempotency_key === "string" && inner.idempotency_key.trim()
    ? inner.idempotency_key.trim()
    : typeof body.idempotency_key === "string" && body.idempotency_key.trim() ? body.idempotency_key.trim() : null;
  if (headerKey && bodyKey && headerKey !== bodyKey) {
    throw new FeeAdjError(400, "the Idempotency-Key header and idempotency_key differ");
  }
  const key = headerKey || bodyKey;
  if (!key) throw new FeeAdjError(400, "an idempotency key is required (the Idempotency-Key header or idempotency_key)");
  if (!KEY_RE.test(key)) throw new FeeAdjError(400, "the idempotency key is 8 to 200 letters, digits or :_.-");
  return { fees_change_cents: cents, note, ticket_id: typeof t === "string" && t ? t.toLowerCase() : null, idempotency_key: key };
}

/** A Postgres error from the core, as an answer (never another org's data: the core says "order not found"). */
function sqlError(e: { code?: string; message?: string }): never {
  const m = e.message ?? "request failed";
  if (e.code === "P0002") throw new FeeAdjError(404, "order not found");
  if (e.code === "42501") throw new FeeAdjError(403, m);
  if (e.code === "22023") throw new FeeAdjError(400, m);
  if (e.code === "55000") throw new FeeAdjError(409, m);
  throw e;
}

/** A log row as the API shows it: DICE's names alongside ours. */
// deno-lint-ignore no-explicit-any
export function apiAdjustment(r: any): Record<string, unknown> {
  return {
    id: r.id,
    order_id: r.session_id,
    event_id: r.event_id,
    ticket_id: r.ticket_id ?? null,
    reason: r.reason,
    note: r.note ?? null,
    fees_change_cents: Number(r.fees_change_cents),
    currency: r.currency,
    refund_id: r.refund_id ?? null,
    processed_at: r.processed_at,
  };
}

export async function handleFeeAdjustments(route: ApiRoute, c: FeeAdjCtx): Promise<unknown> {
  switch (route.id) {
    case "get-order-fee-adjustments": {
      const sid = (c.params.id ?? "").slice(0, 255);
      if (!sid) throw new FeeAdjError(404, "order not found");
      const { data: order, error: oErr } = await c.sb.from("exos_checkout_sessions").select("session_id, currency")
        .eq("org_id", c.orgId).eq("session_id", sid).maybeSingle();
      if (oErr) throw oErr;
      if (!order) throw new FeeAdjError(404, "order not found");
      const { data, error } = await c.sb.from("exos_fee_adjustments").select(COLS)
        .eq("org_id", c.orgId).eq("session_id", sid)
        .order("processed_at", { ascending: true }).order("id").limit(1000);
      if (error) throw error;
      const rows = (data ?? []).map(apiAdjustment);
      return {
        data: rows,
        net_fees_change_cents: rows.reduce((s, r) => s + (r.fees_change_cents as number), 0),
        currency: (order as { currency?: string }).currency ?? "usd",
      };
    }
    case "list-event-fee-adjustments": {
      const id = c.params.id ?? "";
      if (!UUID_RE.test(id)) throw new FeeAdjError(404, "event not found");
      const { data: ev, error: evErr } = await c.sb.from("exos_events").select("id")
        .eq("org_id", c.orgId).eq("id", id).maybeSingle();
      if (evErr) throw evErr;
      if (!ev) throw new FeeAdjError(404, "event not found");
      const r = await c.sb.from("exos_fee_adjustments").select(COLS, { count: "exact" })
        .eq("org_id", c.orgId).eq("event_id", id)
        .order("processed_at", { ascending: false }).order("id").range(c.page.from, c.page.to);
      if (r.error) {
        // Past the end: an empty page.
        if (r.error.code === "PGRST103") return pageEnvelope([], c.page, null);
        throw r.error;
      }
      return pageEnvelope((r.data ?? []).map(apiAdjustment), c.page, r.count);
    }
    case "create-order-fee-adjustment": {
      // A user token never writes here (request.ts userTokenMayCall); say so plainly anyway.
      if (!c.cred || c.cred.kind !== "api_key") {
        throw new FeeAdjError(403, "a fee adjustment needs an organization API key (sk_live_…) created by an owner, manager or finance member");
      }
      const sid = (c.params.id ?? "").slice(0, 255);
      if (!sid) throw new FeeAdjError(404, "order not found");
      const b = adjustmentBody(c.body ?? {}, c.idempotencyKey);
      const { data, error } = await c.sb.rpc("_exos_api_fee_adjustment", {
        p_org: c.orgId, p_api_key: c.cred.id, p_session_id: sid, p_cents: b.fees_change_cents, p_note: b.note,
        p_ticket_id: b.ticket_id, p_idem: b.idempotency_key,
      });
      if (error) sqlError(error);
      // deno-lint-ignore no-explicit-any
      const row = data as any;
      return { data: apiAdjustment(row), duplicate: row?.duplicate === true };
    }
  }
  throw new FeeAdjError(404, "not found");
}
