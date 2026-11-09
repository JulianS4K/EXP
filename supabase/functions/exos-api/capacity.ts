// exos-api: shared capacity pools (DICE TicketPool; "Shared limits" in the
// event editor; mig 20261106120000) and price steps (DICE PriceTier; mig
// 20261106130000). docs/api/capacity.json. Dispatched from index.ts by route id.
//
// The function runs with the service role: every call names the key's org
// (c.orgId) and the SQL cores take it, so another org's event, pool or ticket
// type is a 404. The SQL is the authority on every rule (no unlimited pool, 0
// closes, never below what's sold; an end on every step but the last).
//
// Who may write: an organization API key (personal and OAuth tokens only read
// these routes, _shared/api/request.ts), acting as the member who created it
// (mig 20261104180000). Pool and price writes are inventory / ticket-type
// edits, so the creator must be an owner or manager now: the SQL cores take
// the key (p_api_key) and refuse anyone else with 42501, as exos_api_write
// does for ticket types. Reads follow events:read like GET ticket-type.

import type { ApiRoute } from "../_shared/api/routes.ts";

/** The route ids this module answers. */
export const CAPACITY_ROUTES = new Set([
  "list-capacity-pools", "create-capacity-pool", "get-capacity-pool", "update-capacity-pool", "delete-capacity-pool",
  "get-price-steps", "set-price-steps",
]);
/** Routes answering 201. */
export const CAPACITY_CREATED = new Set(["create-capacity-pool"]);

/** What this module needs of the service-role client (kept narrow so vitest can load it). */
export interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

export interface CapacityCtx {
  sb: RpcClient;
  orgId: string;
  /** The credential (index.ts): writes need an org API key, passed to SQL as the actor. */
  cred: { kind: "api_key" | "pat" | "oauth"; id: string; userId: string | null; role: string | null };
  params: Record<string, string>;
  body: Record<string, unknown>;
}

/** The API key a write acts as (its creator's role is checked in SQL). */
export function writerKey(c: CapacityCtx): string {
  if (c.cred.kind !== "api_key") {
    throw new CapacityError(403, "this write needs an organization API key (sk_live_…) created by an owner or manager");
  }
  return c.cred.id;
}

/** An answer with a status (index.ts sends it as JSON). */
export class CapacityError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const POOL_FIELDS = ["name", "allocation", "closed", "ticket_type_ids"] as const;

/** The body, or its one wrapped object ({ capacity_pool: {...} } / { price_steps: {...} }). */
export function unwrapBody(b: Record<string, unknown>, key: string): Record<string, unknown> {
  const inner = b[key];
  if (inner && typeof inner === "object" && !Array.isArray(inner) && Object.keys(b).length === 1) {
    return inner as Record<string, unknown>;
  }
  return b;
}

/** A first-pass check of a pool body (the SQL checks again); null when fine. */
export function poolBodyProblem(b: Record<string, unknown>, create: boolean): string | null {
  const extra = Object.keys(b).find((k) => !(POOL_FIELDS as readonly string[]).includes(k));
  if (extra) return `unknown field ${extra.slice(0, 60)}`;
  if (create && !("name" in b)) return "name is required";
  if (create && !("allocation" in b)) return "allocation is required (0 closes sales; there is no unlimited)";
  if ("allocation" in b && (!Number.isInteger(b.allocation) || (b.allocation as number) < 0)) {
    return "allocation must be a whole number, 0 or more (0 closes sales; there is no unlimited)";
  }
  if (!create && Object.keys(b).length === 0) return "send at least one field";
  return null;
}

/** A price-steps body: { steps: [...] } and / or door_price_cents; a bare array is the steps. */
export function stepsBody(b: unknown): Record<string, unknown> {
  if (Array.isArray(b)) return { steps: b };
  return unwrapBody((b ?? {}) as Record<string, unknown>, "price_steps");
}

/** The SQL's refusals as HTTP answers. */
export function capacityDbError(e: unknown): CapacityError {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  const message = String(err?.message ?? "request refused").slice(0, 400);
  if (code === "P0002") return new CapacityError(404, message);
  if (code === "42501") return new CapacityError(403, message);
  if (code === "23514") return new CapacityError(409, message);
  if (code === "22023" || code === "22P02" || code === "22007" || code === "22008") return new CapacityError(400, message);
  return new CapacityError(500, "internal error");
}

// deno-lint-ignore no-explicit-any
async function rpc(c: CapacityCtx, fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw capacityDbError(error);
  return data;
}

function id(v: string | undefined, what: string): string {
  if (!v || !UUID_RE.test(v)) throw new CapacityError(404, `${what} not found`);
  return v;
}

/** Handles one of this module's routes. */
export async function handleCapacity(route: ApiRoute, c: CapacityCtx): Promise<unknown> {
  const ev = () => id(c.params.id, "event");
  switch (route.id) {
    case "list-capacity-pools":
      return { data: await rpc(c, "_exos_api_capacity_pools", { p_org: c.orgId, p_event: ev() }) };

    case "get-capacity-pool": {
      const pools = await rpc(c, "_exos_api_capacity_pools", { p_org: c.orgId, p_event: ev() }) as Array<{ id: string }>;
      const pool = pools.find((p) => p.id === id(c.params.pool, "shared limit"));
      if (!pool) throw new CapacityError(404, "shared limit not found");
      return { data: pool };
    }

    case "create-capacity-pool":
    case "update-capacity-pool": {
      const create = route.id === "create-capacity-pool";
      const body = unwrapBody(c.body, "capacity_pool");
      const problem = poolBodyProblem(body, create);
      if (problem) throw new CapacityError(400, problem);
      return {
        data: await rpc(c, "_exos_api_capacity_pool_write", {
          p_org: c.orgId, p_api_key: writerKey(c), p_event: ev(), p_pool: create ? null : id(c.params.pool, "shared limit"),
          p: body, p_delete: false,
        }),
      };
    }

    case "delete-capacity-pool":
      return {
        data: await rpc(c, "_exos_api_capacity_pool_write", {
          p_org: c.orgId, p_api_key: writerKey(c), p_event: ev(), p_pool: id(c.params.pool, "shared limit"), p: null, p_delete: true,
        }),
      };

    case "get-price-steps":
      return { data: await rpc(c, "_exos_api_price_steps", { p_org: c.orgId, p_event: ev(), p_tier: id(c.params.tier, "ticket type") }) };

    case "set-price-steps": {
      const body = stepsBody(c.body);
      if (!("steps" in body) && !("door_price_cents" in body)) throw new CapacityError(400, "send steps and/or door_price_cents");
      return {
        data: await rpc(c, "_exos_api_price_steps_set", {
          p_org: c.orgId, p_api_key: writerKey(c), p_event: ev(), p_tier: id(c.params.tier, "ticket type"), p: body,
        }),
      };
    }
  }
  throw new CapacityError(404, "not found");
}
