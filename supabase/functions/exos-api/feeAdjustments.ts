// claude/exos-dice-gaps-6 (mig 20261107110000): the fee-change log (DICE
// Adjustment { reason, processedAt, ticket, feesChange }).
//
//   GET /v1/orders/:id/adjustments       orders:read   one order's changes, oldest
//                                                      first, with the net
//   GET /v1/events/:id/fee-adjustments   finance:read  an event's, newest first,
//                                                      paged
//
// exos_fee_adjustments is append-only. A refund adds the buyer-fee part of the
// money it returned (the order's passed-on fees x refunded / paid; a refund
// that fails later adds the reversal); finance adds manual changes with a note
// in the dashboard. The credential's scope decides the read (never a role).
// Every read is scoped to the key's org: another org's order or event is a
// 404, and nothing of it is echoed.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COLS = "id, session_id, event_id, ticket_id, reason, note, fees_change_cents, currency, refund_id, processed_at";

export const FEE_ADJ_ROUTES = new Set(["get-order-fee-adjustments", "list-event-fee-adjustments"]);

export class FeeAdjError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export interface FeeAdjCtx {
  sb: SupabaseClient;
  orgId: string;
  params: Record<string, string>;
  page: Page;
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
  }
  throw new FeeAdjError(404, "not found");
}
