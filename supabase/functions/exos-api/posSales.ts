// claude/exos-pos-walkup (mig 20261107100000, docs/api/pos-sales.json): the
// door's walk-up sales, for an organization's credential.
//
//   GET  /v1/events/:id/pos-orders                 orders:read    paged, newest first
//   POST /v1/events/:id/pos-orders/:order/void     refunds:write  same night, before a scan
//
// Both run through SQL cores scoped to the key's org (c.orgId) and the event in
// the path, so another org's event or order is a 404 that says nothing about
// it. A void moves money (the cash goes back out of a drawer), so it takes
// refunds:write (nothing else grants it) and an organization API key whose
// creator is an owner or manager now (_exos_api_key_actor, in SQL), the rule
// the door app applies to a void by someone other than the seller. Personal
// and OAuth tokens only read (request.ts userTokenMayCall). Refunds after a
// scan stay in the door app (an owner / manager override at the door).
// Selling is not an API route: it needs a cash drawer at the door.

import type { ApiRoute } from "../_shared/api/routes.ts";
import { type Page, pageEnvelope } from "../_shared/api/paging.ts";

/** The route ids this module answers. */
export const POS_SALES_ROUTES = new Set(["list-event-pos-orders", "void-event-pos-order"]);

/** What this module needs of the service-role client (kept narrow so vitest can load it). */
export interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

export interface PosSalesCtx {
  sb: RpcClient;
  orgId: string;
  cred: { kind: "api_key" | "pat" | "oauth"; id: string };
  params: Record<string, string>;
  page: Page;
  body: Record<string, unknown>;
}

export class PosSalesError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function id(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new PosSalesError(404, `${what} not found`);
  return v.toLowerCase();
}

/** { reason, drawer_id? }, flat or wrapped as { pos_order: { … } }. */
export function voidBody(body: Record<string, unknown>): { reason: string; drawer_id: string | null } {
  const inner = body.pos_order && typeof body.pos_order === "object" && !Array.isArray(body.pos_order)
    ? body.pos_order as Record<string, unknown> : body;
  const reason = typeof inner.reason === "string" ? inner.reason.trim() : "";
  if (reason.length < 3 || reason.length > 300) throw new PosSalesError(400, "reason is required (3 to 300 characters).");
  const d = inner.drawer_id;
  if (d !== undefined && d !== null && d !== "" && (typeof d !== "string" || !UUID_RE.test(d))) {
    throw new PosSalesError(400, "drawer_id must be a UUID.");
  }
  return { reason, drawer_id: typeof d === "string" && d ? d.toLowerCase() : null };
}

/** A Postgres error from the cores, as an answer. */
function sqlError(e: { code?: string; message?: string }): never {
  const m = e.message ?? "request failed";
  if (e.code === "P0002") throw new PosSalesError(404, m);
  if (e.code === "42501") throw new PosSalesError(403, m);
  if (e.code === "54000") throw new PosSalesError(429, m);
  if (e.code === "0A000") throw new PosSalesError(501, m);
  if (e.code === "22023") throw new PosSalesError(400, m);
  if (e.code === "55000" || e.code === "23514" || e.code === "23505") throw new PosSalesError(409, m);
  throw e;
}

export async function handlePosSales(route: ApiRoute, c: PosSalesCtx): Promise<unknown> {
  const eventId = id(c.params.id, "event");
  switch (route.id) {
    case "list-event-pos-orders": {
      const { data, error } = await c.sb.rpc("_exos_api_pos_orders", {
        p_org: c.orgId, p_event: eventId, p_limit: c.page.perPage, p_offset: c.page.from,
      });
      if (error) sqlError(error);
      const d = (data ?? {}) as { total?: number; data?: unknown[] };
      return pageEnvelope(d.data ?? [], c.page, d.total ?? 0);
    }
    case "void-event-pos-order": {
      if (c.cred.kind !== "api_key") {
        throw new PosSalesError(403, "a void needs an organization API key (sk_live_…) created by an owner or manager");
      }
      const orderId = id(c.params.order, "order");
      const b = voidBody(c.body);
      const { data, error } = await c.sb.rpc("_exos_api_pos_void", {
        p_org: c.orgId, p_api_key: c.cred.id, p_event: eventId, p_order: orderId, p_reason: b.reason, p_drawer: b.drawer_id,
      });
      if (error) sqlError(error);
      return { data };
    }
  }
  throw new PosSalesError(404, "not found");
}
