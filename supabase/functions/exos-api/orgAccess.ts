// exos-api: per-role API permissions, venue booking requests, event-scoped
// grants (co-hosted events) and the partner presale setting
// (mig 20261104180000, docs/org-access.md). Dispatched from index.ts by
// route id.
//
// The function runs with the service role: every call names the key's org
// (c.orgId) and the SQL cores take it, so another org's id is a 404. Writes
// need an org API key (as booking's do) and act as its creator, who must hold
// the role the dashboard asks for right now (_exos_api_key_actor). A route on
// a co-hosted event needs its scope in the caller's credential (routes.ts)
// AND in the venue's grant (the SQL checks the grant).

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import {
  cleanGrantScopes, COHOST_EVENT_FIELDS, isConfigurableRole, isPartnerPresaleMode, roleScopesProblem,
  VENUE_REQUEST_STATUSES, venueApprovalVenue, venueRequestBody,
} from "../_shared/api/orgAccess.ts";

/** The route ids this module answers. */
export const ORG_ACCESS_ROUTES = new Set([
  "get-role-api-scopes", "update-role-api-scopes",
  "list-venue-directory", "list-venue-requests", "create-venue-request", "get-venue-request",
  "approve-venue-request", "decline-venue-request", "withdraw-venue-request",
  "list-partner-grants", "update-partner-grant", "revoke-partner-grant",
  "list-cohosted-events", "get-cohosted-event", "update-cohosted-event", "get-cohosted-event-sales",
  "get-partner-presale", "update-partner-presale", "get-event-partner-presale", "update-event-partner-presale",
]);

/** The 201 answers. */
export const ORG_ACCESS_CREATED = new Set(["create-venue-request"]);

export interface OrgAccessCtx {
  sb: SupabaseClient;
  orgId: string;
  cred: { kind: "api_key" | "pat" | "oauth"; id: string; userId: string | null; role: string | null };
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

/** An answer with a status and body (index.ts sends it as JSON). */
export class OrgAccessError extends Error {
  constructor(public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function idParam(c: OrgAccessCtx, what: string, name = "id"): string {
  const v = c.params[name];
  if (!v || !UUID_RE.test(v)) throw new OrgAccessError(404, `${what} not found`);
  return v;
}

/** The body, or its one wrapped object ({ venue_request: {...} }). */
function unwrap(b: Record<string, unknown>, key: string): Record<string, unknown> {
  const inner = b[key];
  if (inner && typeof inner === "object" && !Array.isArray(inner) && Object.keys(b).length === 1) {
    return inner as Record<string, unknown>;
  }
  return b;
}

// deno-lint-ignore no-explicit-any
async function rpc(c: OrgAccessCtx, fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/** The acting member: an API key's creator holding one of `roles` now (SQL checks it). */
async function actor(c: OrgAccessCtx, roles: string[]): Promise<string> {
  if (c.cred.kind !== "api_key") throw new OrgAccessError(403, "this write needs an organization API key (sk_live_…)");
  return await rpc(c, "_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.cred.id, p_roles: roles }) as string;
}

/** Handles one of this module's routes; undefined = not ours. */
export async function handleOrgAccess(route: ApiRoute, c: OrgAccessCtx): Promise<unknown> {
  if (!ORG_ACCESS_ROUTES.has(route.id)) return undefined;
  const { orgId } = c;
  switch (route.id) {
    // ---- Per-role API permissions -------------------------------------------------------
    case "get-role-api-scopes":
      return { data: await rpc(c, "_exos_org_role_scopes_view", { p_org_id: orgId }) };

    case "update-role-api-scopes": {
      const role = c.params.role;
      if (!isConfigurableRole(role)) {
        throw new OrgAccessError(400, "role must be manager, finance, content or scanner (the owner always has every scope).");
      }
      const uid = await actor(c, ["owner"]);
      const raw = c.body.scopes;
      let scopes: string[] | null;
      if (raw === null || c.body.reset === true) scopes = null;
      else if (Array.isArray(raw) && raw.every((s) => typeof s === "string")) {
        scopes = raw as string[];
        const problem = roleScopesProblem(role, scopes);
        if (problem) throw new OrgAccessError(problem.includes("never") ? 403 : 400, problem);
      } else throw new OrgAccessError(400, "scopes must be a list of scope names, or null to go back to the default.");
      return {
        data: await rpc(c, "_exos_org_role_scopes_set", { p_org_id: orgId, p_actor: uid, p_role: role, p_scopes: scopes }),
      };
    }

    // ---- Venue requests -----------------------------------------------------------------
    case "list-venue-directory":
      return { data: await rpc(c, "_exos_venue_directory", { p_org: orgId, p_q: c.q.get("q") ?? "", p_limit: 25 }) };

    case "list-venue-requests": {
      const dir = c.q.get("direction") ?? "received";
      if (dir !== "received" && dir !== "sent") throw new OrgAccessError(400, "direction must be received or sent.");
      const status = c.q.get("status");
      if (status !== null && !(VENUE_REQUEST_STATUSES as readonly string[]).includes(status)) {
        throw new OrgAccessError(400, `status must be one of ${VENUE_REQUEST_STATUSES.join(", ")}.`);
      }
      const out = await rpc(c, "_exos_venue_requests_page", {
        p_org: orgId, p_direction: dir, p_status: status, p_limit: c.page.perPage, p_offset: c.page.from,
      }) as { data: unknown[]; total: number };
      return pageEnvelope(out.data ?? [], c.page, Number(out.total ?? 0));
    }

    case "create-venue-request": {
      const parsed = venueRequestBody(unwrap(c.body, "venue_request"));
      if ("error" in parsed) throw new OrgAccessError(400, parsed.error);
      const uid = await actor(c, ["owner", "manager"]);
      return {
        data: await rpc(c, "_exos_venue_request_create", {
          p_org: orgId, p_actor: uid, p_via: "api", p_api_key: c.cred.id,
          p: { ...parsed.body, ...(c.idempotencyKey ? { idempotency_key: c.idempotencyKey } : {}) },
        }),
      };
    }

    case "get-venue-request":
      return { data: await rpc(c, "_exos_venue_request_get", { p_org: orgId, p_id: idParam(c, "request") }) };

    case "approve-venue-request": {
      const id = idParam(c, "request");
      const b = unwrap(c.body, "approval");
      const extra = Object.keys(b).find((k) => !["create", "scopes", "time", "capacity", "level"].includes(k));
      if (extra) throw new OrgAccessError(400, `unknown field ${extra}`);
      if (b.create !== undefined && b.create !== "hold" && b.create !== "event") {
        throw new OrgAccessError(400, "create must be hold or event.");
      }
      const scopes = cleanGrantScopes(b.scopes);
      if ("error" in scopes) throw new OrgAccessError(400, scopes.error);
      const uid = await actor(c, ["owner", "manager"]);
      return {
        data: await rpc(c, "_exos_venue_request_decide", {
          p_org: orgId, p_actor: uid, p_via: "api", p_api_key: c.cred.id, p_id: id, p_action: "approve",
          p: { ...b, scopes: scopes.scopes },
        }),
      };
    }

    case "decline-venue-request": {
      const id = idParam(c, "request");
      const reason = c.body.reason ?? null;
      if (reason !== null && (typeof reason !== "string" || reason.length > 500)) {
        throw new OrgAccessError(400, "reason must be at most 500 characters.");
      }
      const uid = await actor(c, ["owner", "manager"]);
      return {
        data: await rpc(c, "_exos_venue_request_decide", {
          p_org: orgId, p_actor: uid, p_via: "api", p_api_key: c.cred.id, p_id: id, p_action: "decline", p: { reason },
        }),
      };
    }

    case "withdraw-venue-request": {
      const id = idParam(c, "request");
      await actor(c, ["owner", "manager"]);
      return { data: await rpc(c, "_exos_venue_request_withdraw", { p_org: orgId, p_id: id }) };
    }

    // ---- Grants (the venue's side) ------------------------------------------------------
    case "list-partner-grants": {
      const ev = c.q.get("event_id");
      if (ev !== null && !UUID_RE.test(ev)) throw new OrgAccessError(400, "event_id must be a UUID.");
      const all = c.q.get("include_revoked") === "true";
      return { data: await rpc(c, "_exos_partner_grants_list", { p_org: orgId, p_event: ev, p_live_only: !all }) };
    }

    case "update-partner-grant": {
      const id = idParam(c, "grant");
      const scopes = cleanGrantScopes(c.body.scopes ?? []);
      if ("error" in scopes) throw new OrgAccessError(400, scopes.error);
      const uid = await actor(c, ["owner", "manager"]);
      return { data: await rpc(c, "_exos_partner_grant_set", { p_org: orgId, p_actor: uid, p_id: id, p_scopes: scopes.scopes }) };
    }

    case "revoke-partner-grant": {
      const id = idParam(c, "grant");
      const uid = await actor(c, ["owner", "manager"]);
      return { data: await rpc(c, "_exos_partner_grant_revoke", { p_org: orgId, p_actor: uid, p_id: id }) };
    }

    // ---- Co-hosted events (the promoter's side) -----------------------------------------
    case "list-cohosted-events":
      return { data: await rpc(c, "_exos_cohost_events", { p_org: orgId }) };

    case "get-cohosted-event":
      return { data: await rpc(c, "_exos_cohost_event", { p_org: orgId, p_event: idParam(c, "event") }) };

    case "update-cohosted-event": {
      const id = idParam(c, "event");
      const b = unwrap(c.body, "event");
      const extra = Object.keys(b).find((k) => !(COHOST_EVENT_FIELDS as readonly string[]).includes(k));
      if (extra) throw new OrgAccessError(400, `a co-host can change ${COHOST_EVENT_FIELDS.join(", ")}, not ${extra}.`);
      if (!Object.keys(b).length) throw new OrgAccessError(400, "Nothing to update.");
      return { data: await rpc(c, "_exos_cohost_event_update", { p_org: orgId, p_event: id, p: b }) };
    }

    case "get-cohosted-event-sales":
      return { data: await rpc(c, "_exos_cohost_event_sales", { p_org: orgId, p_event: idParam(c, "event") }) };

    // ---- Partner presale ----------------------------------------------------------------
    case "get-partner-presale":
      return { data: await rpc(c, "_exos_partner_presale_get", { p_org: orgId, p_event: null }) };

    case "update-partner-presale": {
      const mode = c.body.partner_presale ?? c.body.mode;
      if (!isPartnerPresaleMode(mode)) throw new OrgAccessError(400, "partner_presale must be block or allow.");
      const uid = await actor(c, ["owner"]);
      return { data: await rpc(c, "_exos_partner_presale_set", { p_org: orgId, p_actor: uid, p_event: null, p_mode: mode }) };
    }

    case "get-event-partner-presale":
      return { data: await rpc(c, "_exos_partner_presale_get", { p_org: orgId, p_event: idParam(c, "event") }) };

    case "update-event-partner-presale": {
      const id = idParam(c, "event");
      const mode = c.body.partner_presale ?? c.body.mode ?? null;
      if (mode !== null && mode !== "inherit" && !isPartnerPresaleMode(mode)) {
        throw new OrgAccessError(400, "partner_presale must be block, allow or inherit (null).");
      }
      const uid = await actor(c, ["owner", "manager"]);
      return { data: await rpc(c, "_exos_partner_presale_set", { p_org: orgId, p_actor: uid, p_event: id, p_mode: mode }) };
    }
  }
  return undefined;
}

/**
 * The venue gate's refusal, anywhere in exos-api (events from templates,
 * holds, these routes): 403 venue_approval_required naming the endpoint to
 * ask through. null for any other error.
 */
export function venueApprovalAnswer(e: unknown): Record<string, unknown> | null {
  const msg = (e as { message?: unknown } | null)?.message;
  const venue = venueApprovalVenue(msg);
  if (venue === null) return null;
  return {
    error: "venue_approval_required",
    message: "This venue is run by another organization on Exos. Send it a booking request; once approved, it shares the event with you.",
    venue_id: venue || null,
    request_endpoint: "POST /v1/venue-requests",
  };
}

/** The SQL's errors on this module's routes. */
export function orgAccessDbError(e: unknown): { status: number; body: Record<string, unknown> } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === "string" ? err.code : "";
  const message = String(err?.message ?? "request refused").slice(0, 300);
  if (message.startsWith("grant_scope_required")) {
    return { status: 403, body: { error: "grant_scope_required", message: message.replace(/^grant_scope_required:\s*/, "") } };
  }
  switch (code) {
    case "22023": case "22P02": case "22007": case "22008": case "23514":
      return { status: 400, body: { error: message } };
    case "P0002":
      return { status: 404, body: { error: message } };
    case "42501":
      return { status: 403, body: { error: message } };
    case "23505": case "55000": case "54000":
      return { status: 409, body: { error: message } };
    default:
      return null;
  }
}
