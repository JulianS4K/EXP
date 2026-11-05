// exos-api — order and ticket edits, receipt resends, whole-order check-out,
// the guest-list import preview and recommendations (mig 20261102140000,
// docs/api-reference.md). Opendate's paths are aliases (routes.ts).
//
// Writes are ONE call to exos_api_order_write(key, action, target, args,
// idempotency key), which runs as the member who created the key, pins the
// order / ticket to the key's org (and to the confirm_id event when the
// Opendate path names one), and calls the dashboard's own SQL
// (exos_order_update, exos_order_send_receipt, exos_order_check_out,
// exos_ticket_update), so the API and the dashboard behave the same and both
// are audited in exos_order_edits. Reads call the service-role
// _exos_rec_* / _exos_guest_list_preview functions with the key's org.
// No business rule lives here: it shapes requests and answers only.

import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope } from "../_shared/api/paging.ts";
import { EditError, orderEditFields, receiptEmail, ticketEditFields, ticketIdFrom } from "../_shared/orderEdits.ts";
import { PreviewError, previewInput } from "../_shared/guestPreview.ts";
import { fanRecReasons, parseRecScope, recReasons, type FanRecSignals, type RecSignals } from "../_shared/recommend.ts";
import { CoreError, type CoreCtx } from "./core.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_RE = /^[A-Za-z0-9_-]{1,255}$/;

/** The route ids this module answers. */
export const ORDER_ROUTES = new Set([
  "update-order", "send-order-receipt", "check-out-order", "update-ticket", "preview-guest-list",
  "list-similar-events", "list-fan-event-recommendations", "list-event-fan-recommendations",
]);

export async function handleOrders(route: ApiRoute, c: CoreCtx): Promise<unknown> {
  const p = c.params;
  try {
    switch (route.id) {
      case "update-order":
        return { data: await write(c, "order.update", sessionOr404(p.id), { fields: orderEditFields(c.body), event_id: eventParam(p.eid) }) };
      case "send-order-receipt":
        return { data: await write(c, "order.send_receipt", sessionOr404(p.id), { email: receiptEmail(c.body), event_id: eventParam(p.eid) }) };
      case "check-out-order": {
        const list = c.body.list_id ?? null;
        if (list !== null && (typeof list !== "string" || !UUID_RE.test(list))) throw new CoreError(400, "list_id must be a UUID.");
        return {
          data: await write(c, "order.check_out", sessionOr404(p.id), {
            list_id: list, reason: str(c.body.reason), device: str(c.body.device), event_id: eventParam(p.eid),
          }),
        };
      }
      case "update-ticket": {
        const id = ticketIdFrom(p.id ?? "");
        if (!id) throw new CoreError(404, "ticket not found");
        return { data: await write(c, "ticket.update", id, { fields: ticketEditFields(c.body), event_id: eventParam(p.eid) }) };
      }
      case "preview-guest-list": {
        const ev = uuidOr404(p.id, "event");
        const list = c.body.list_id ?? c.body.guest_list_id ?? null;
        if (list !== null && (typeof list !== "string" || !UUID_RE.test(list))) throw new CoreError(400, "list_id must be a UUID.");
        const input = previewInput(c.body);
        const out = await rpc(c, "_exos_guest_list_preview", {
          p_org: c.orgId, p_event_id: ev, p_list_id: list, p_rows: input.rows,
        }) as Record<string, unknown>;
        return { data: { ...out, source: input.source, skipped_lines: input.skipped, ...(input.plan ? { file: input.plan } : {}) } };
      }
      case "list-similar-events": {
        const out = await rpc(c, "_exos_rec_similar_events", {
          p_org: c.orgId, p_event_id: uuidOr404(p.id, "event"), p_cross: scope(c, "org") === "all",
          p_limit: c.page.perPage, p_offset: c.page.from,
        }) as { total: number; rows: Array<Record<string, unknown>> };
        return pageEnvelope(out.rows.map(withReasons), c.page, out.total);
      }
      case "list-fan-event-recommendations": {
        const fan = c.q.get("fan_id");
        if (fan === null) throw new CoreError(400, "fan_id is required.");
        if (!UUID_RE.test(fan)) throw new CoreError(400, "fan_id must be a UUID.");
        const out = await rpc(c, "_exos_rec_fan_events", {
          p_org: c.orgId, p_fan_id: fan, p_cross: scope(c, "org") === "all", p_limit: c.page.perPage, p_offset: c.page.from,
        }) as { total: number; rows: Array<Record<string, unknown>> };
        return pageEnvelope(out.rows.map(withReasons), c.page, out.total);
      }
      case "list-event-fan-recommendations": {
        const out = await rpc(c, "_exos_rec_event_fans", {
          p_org: c.orgId, p_event_id: uuidOr404(p.id, "event"), p_limit: c.page.perPage, p_offset: c.page.from,
        }) as { total: number; rows: Array<Record<string, unknown>> };
        return pageEnvelope(out.rows.map((r) => ({ ...r, reasons: fanRecReasons(r.signals as FanRecSignals) })), c.page, out.total);
      }
    }
  } catch (e) {
    if (e instanceof EditError || e instanceof PreviewError) throw new CoreError(400, e.message);
    // Too many receipt resends for one order: 429, like the API's own limit.
    const err = e as { code?: string; message?: string } | null;
    if (err?.code === "54000") {
      throw new CoreError(429, String(err.message ?? "too many requests").replace(/^(exos|_exos)_[a-z_]+: /, ""));
    }
    throw e;
  }
  throw new CoreError(404, "not found");
}

function withReasons(r: Record<string, unknown>): Record<string, unknown> {
  return { ...r, reasons: recReasons(r.signals as RecSignals) };
}

function scope(c: CoreCtx, fallback: "org" | "all"): "org" | "all" {
  try {
    return parseRecScope(c.q.get("scope"), fallback);
  } catch (e) {
    throw new CoreError(400, (e as Error).message);
  }
}

async function write(c: CoreCtx, action: string, target: string, args: Record<string, unknown>): Promise<unknown> {
  return await rpc(c, "exos_api_order_write", {
    p_key_id: c.keyId, p_action: action, p_target: target, p_args: args, p_idempotency_key: c.idempotencyKey,
  });
}

async function rpc(c: CoreCtx, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v.slice(0, 300) : null;
}

/** Opendate's confirm_id in the path: the event the order / ticket must be on. */
function eventParam(v: string | undefined): string | null {
  if (v === undefined) return null;
  if (!UUID_RE.test(v)) throw new CoreError(404, "event not found");
  return v;
}

function uuidOr404(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new CoreError(404, `${what} not found`);
  return v;
}

function sessionOr404(v: string | undefined): string {
  if (!v || !SESSION_RE.test(v)) throw new CoreError(404, "order not found");
  return v;
}
