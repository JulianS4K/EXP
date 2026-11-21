// claude/exos-org-audit (mig 20261109100000): the org audit log
// (docs/security.md "Org audit log", docs/api/audit.json).
//
//   GET /v1/audit   audit:read   newest first, paged; ?event_id, ?actor_id,
//                                ?group (inventory | money | access | data),
//                                ?action, ?from / ?to (ISO, to exclusive)
//
// Read-only: rows are written in SQL (_exos_audit) and the table is
// append-only. The function runs with the service role, so the query names
// the key's org; an event or actor of another org simply matches nothing.
// The credential's scope decides the read (audit:read, owner and finance by
// default; never a role).

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import { enumParam, idParam, isoParam } from "../_shared/api/financeExtras.ts";
import { ACTION_RE, apiAuditRow, AUDIT_COLS, AUDIT_GROUP_NAMES, groupPrefixes } from "../_shared/api/audit.ts";

export const AUDIT_ROUTES = new Set(["list-audit"]);

export class AuditError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export interface AuditCtx {
  sb: SupabaseClient;
  orgId: string;
  q: URLSearchParams;
  page: Page;
}

export async function handleAudit(route: ApiRoute, c: AuditCtx): Promise<unknown> {
  if (route.id !== "list-audit") throw new AuditError(404, "not found");
  let q = c.sb.from("exos_org_audit").select(AUDIT_COLS, { count: "exact" }).eq("org_id", c.orgId);
  const ev = idParam(c.q, "event_id");
  if (ev) q = q.eq("event_id", ev);
  const actor = idParam(c.q, "actor_id");
  if (actor) q = q.eq("actor_uid", actor);
  const group = enumParam(c.q, AUDIT_GROUP_NAMES, "group");
  if (group) q = q.or(groupPrefixes(group).map((p) => `action.like.${p}*`).join(","));
  const action = c.q.get("action");
  if (action !== null && action.trim() !== "") {
    if (!ACTION_RE.test(action.trim())) throw new AuditError(400, "action must look like group.verb (e.g. refund.issue).");
    q = q.eq("action", action.trim());
  }
  const from = isoParam(c.q, "from");
  if (from) q = q.gte("at", from);
  const to = isoParam(c.q, "to");
  if (to) q = q.lt("at", to);
  const r = await q.order("id", { ascending: false }).range(c.page.from, c.page.to);
  if (r.error) {
    if (r.error.code === "PGRST103") return pageEnvelope([], c.page, null); // past the end
    throw r.error;
  }
  return pageEnvelope((r.data ?? []).map(apiAuditRow), c.page, r.count);
}
