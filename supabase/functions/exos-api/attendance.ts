// claude/exos-attendance-report (mig 20261113120000, docs/api/attendance.json):
// an event's attendance report for the organization's credential.
//
//   GET /v1/events/:id/attendance   orders:read   ?compare=<event id>
//
// Aggregate only: live tickets by billing postal area (an area with fewer
// than 5 buyers folded into "Other (fewer than 5)" in SQL, never named),
// and daily sales pacing, optionally against another event of the org
// lined up by days before the event. No per-buyer row.
//
// The scope (orders:read) is checked at the edge; the role in SQL
// (_exos_api_attendance): an org API key acts as its creator, who must be an
// owner, manager or finance member now, and a personal / OAuth token's user
// must hold one of those roles in the org now. 20 a minute per credential
// (429). The event and the comparison are the key's org's or 404.

import type { ApiRoute } from "../_shared/api/routes.ts";

/** The route ids this module answers. */
export const ATTENDANCE_ROUTES = new Set(["get-event-attendance"]);

/** What this module needs of the service-role client (kept narrow so vitest can load it). */
export interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

export interface AttendanceCtx {
  sb: RpcClient;
  orgId: string;
  cred: { kind: "api_key" | "pat" | "oauth"; id: string; userId: string | null };
  params: Record<string, string>;
  q: URLSearchParams;
}

/** An answer with a status (index.ts sends it as JSON). */
export class AttendanceError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The SQL codes this read raises, as HTTP. */
const STATUS: Record<string, number> = { "42501": 403, P0002: 404, "22023": 400, "54000": 429 };

export async function handleAttendance(route: ApiRoute, c: AttendanceCtx): Promise<unknown> {
  if (route.id !== "get-event-attendance") throw new AttendanceError(404, "not found");
  const id = c.params.id ?? "";
  if (!UUID_RE.test(id)) throw new AttendanceError(404, "event not found");
  const compareRaw = c.q.get("compare") ?? c.q.get("compare_event_id");
  if (compareRaw !== null && compareRaw !== "" && !UUID_RE.test(compareRaw)) {
    throw new AttendanceError(400, "compare must be an event id");
  }
  const { data, error } = await c.sb.rpc("_exos_api_attendance", {
    p_org: c.orgId,
    p_event: id,
    p_compare: compareRaw ? compareRaw : null,
    p_cred_kind: c.cred.kind,
    p_cred_id: c.cred.id,
    p_user: c.cred.userId,
  });
  if (error) {
    const status = STATUS[error.code ?? ""];
    if (status) throw new AttendanceError(status, String(error.message ?? "invalid request").slice(0, 300));
    throw error;
  }
  return { data };
}
