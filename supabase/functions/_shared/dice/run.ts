// Connect, sync and dry run against the database (mig 20261106100000),
// shared by exos-dice-import (dashboard + cron) and exos-api (POST
// /v1/dice-import/sync). The reads are _shared/dice/client.ts (queries
// only); the writes are service-role RPCs.
//
// ROLE AND LIMIT FIRST, DICE SECOND. Every function here asks the database
// before it sends anything to DICE, and stops on a refusal:
//   connectOrg  exos_dice_connect_begin  owner / manager; 10 attempts an hour
//                                        per org and per user (so nobody can
//                                        use Exos to test DICE tokens)
//   syncOrg     exos_dice_sync_claim     owner / manager; the lease; once a
//                                        minute; no preview running
//   dryRunOrg   exos_dice_dry_run_begin  owner / manager; no sync or other
//                                        preview running; 5 a minute; the run
//                                        row reserved under the connection lock
// src/lib/diceClient.test.ts checks fetch is never called on a refusal.
//
// No Supabase import: `DiceDb` is the one method used (`rpc`), so vitest
// drives these with a fake database and a fake fetch.

import { type DiceEntity, type DiceOptions, diceErrorMessage, isDiceTokenShaped, readViewer } from "./client.ts";
import type { DiceRow } from "./map.ts";
import { type Cursors, DRY_RUN_LIMITS, RUN_LIMITS, runSync, type SyncReport, type SyncStore } from "./sync.ts";

export { DICE_DISABLED_MESSAGE, diceImportEnabled } from "./sync.ts";

export type DbError = { code?: string; message?: string };
export interface DiceDb {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: DbError | null }>;
}

export type Trigger = "dashboard" | "api" | "cron";

export interface RunAnswer {
  ok: boolean;
  /** HTTP status for the caller. */
  status: number;
  error?: string;
  reason?: string;
  dry_run?: boolean;
  kind?: "full" | "incremental";
  run_id?: string | null;
  result?: SyncReport["status"];
  entities?: SyncReport["entities"];
  preview?: SyncReport["preview"];
  warnings?: string[];
  connected?: boolean;
  account_name?: string | null;
  same_account?: boolean;
}

/** The SQL's refusals (role, limit, busy, not connected) as answers. */
export function dbRefusal(e: DbError): RunAnswer {
  const msg = (e.message ?? "").replace(/^exos_\w+: /, "");
  if (e.code === "42501") return { ok: false, status: 403, error: "Owners and managers only.", reason: "forbidden" };
  if (e.code === "54000") return { ok: false, status: 429, error: msg || "Too many requests. Wait a little.", reason: "rate_limited" };
  if (e.code === "55000") return { ok: false, status: 409, error: msg || "A DICE sync is already running.", reason: "busy" };
  if (e.code === "22023") return { ok: false, status: 409, error: msg || "Connect DICE first.", reason: "not_connected" };
  if (e.code === "PGRST202" || e.code === "42883") {
    return { ok: false, status: 503, error: "Import from DICE isn't installed on this database yet.", reason: "not_deployed" };
  }
  return { ok: false, status: 500, error: "something went wrong", reason: "db" };
}
/** Wall-clock budget for one run, under the edge function limit. */
export const RUN_BUDGET_MS = 100_000;

/**
 * Connect: role + attempt limit (exos_dice_connect_begin), THEN the token is
 * checked with DICE (`viewer { id name }`), then stored (exos_dice_connect).
 */
export async function connectOrg(db: DiceDb, dice: DiceOptions, org: string, user: string, token: string): Promise<RunAnswer> {
  if (!isDiceTokenShaped(token)) {
    return { ok: false, status: 400, error: "That doesn't look like a DICE API token. Copy it again from MIO.", reason: "bad_token" };
  }
  const gate = await db.rpc("exos_dice_connect_begin", { p_org_id: org, p_user_id: user });
  if (gate.error) return dbRefusal(gate.error);
  const v = await readViewer(dice, token);
  if (!v.ok || !v.data) return { ok: false, status: v.status === 401 ? 400 : 502, error: diceErrorMessage(v), reason: "dice" };
  const r = await db.rpc("exos_dice_connect", {
    p_org_id: org, p_user_id: user, p_token: token, p_account_id: v.data.id, p_account_name: v.data.name,
  });
  if (r.error) return dbRefusal(r.error);
  const d = (r.data ?? {}) as { connected?: boolean; account_name?: string | null; same_account?: boolean };
  return { ok: true, status: 200, connected: d.connected === true, account_name: d.account_name ?? null, same_account: d.same_account === true };
}

/** One sync for one claimed org: pages written as they are read, then finish. */
export async function syncClaimed(
  db: DiceDb, dice: DiceOptions,
  claimed: { org_id: string; token: string; cursors: Cursors | null; lease_id: string; run_id: string; kind: string },
  deadline: number,
): Promise<RunAnswer> {
  let leaseLost = false;
  const store: SyncStore = {
    async apply(entity: DiceEntity, rows: DiceRow[], page) {
      const r = await db.rpc("exos_dice_apply", {
        p_org_id: claimed.org_id, p_lease: claimed.lease_id, p_entity: entity, p_rows: rows, p_page: page,
      });
      if (r.error) throw new Error(`apply ${entity}: ${r.error.code ?? ""}`);
      const out = (r.data ?? {}) as Record<string, unknown>;
      if (out.reason === "lease-lost") {
        leaseLost = true;
        throw new Error("lease-lost");
      }
      return Object.fromEntries(Object.entries(out).filter(([, v]) => typeof v === "number")) as Record<string, number>;
    },
  };
  let report: SyncReport;
  try {
    report = await runSync(dice, claimed.token, claimed.cursors ?? {}, store, { ...RUN_LIMITS, deadline });
  } catch (err) {
    if (leaseLost) return { ok: false, status: 409, error: "The DICE connection changed during the sync.", reason: "lease_lost" };
    const message = (err as Error)?.message ?? "";
    await db.rpc("exos_dice_sync_finish", {
      p_org_id: claimed.org_id, p_lease: claimed.lease_id, p_status: "error",
      p_error: "Exos couldn't save what it read from DICE.", p_warnings: [message.slice(0, 200)],
    });
    return { ok: false, status: 500, error: "Exos couldn't save what it read from DICE.", reason: "db", run_id: claimed.run_id };
  }
  const authFailed = report.error?.status === 401 || report.error?.status === 403;
  const error = report.error ? diceErrorMessage({ status: report.error.status, error: report.error.error }) : null;
  await db.rpc("exos_dice_sync_finish", {
    p_org_id: claimed.org_id, p_lease: claimed.lease_id, p_status: report.status, p_error: error,
    p_warnings: report.warnings, p_auth_failed: authFailed,
  });
  return {
    ok: report.status !== "error", status: report.status === "error" ? 502 : 200,
    ...(error ? { error, reason: authFailed ? "dice_auth" : "dice" } : {}),
    dry_run: false, kind: report.kind, run_id: claimed.run_id, result: report.status,
    entities: report.entities, warnings: report.warnings,
  };
}

/** "Sync now" (dashboard) or the API: claim this org (role, lease, spacing), THEN read DICE, then finish. */
export async function syncOrg(
  db: DiceDb, dice: DiceOptions, org: string, user: string, trigger: Exclude<Trigger, "cron">,
): Promise<RunAnswer> {
  const c = await db.rpc("exos_dice_sync_claim", { p_org_id: org, p_user_id: user, p_trigger: trigger, p_limit: 1 });
  if (c.error) return dbRefusal(c.error);
  const row = ((c.data ?? []) as Array<Record<string, unknown>>)[0];
  if (!row) return { ok: false, status: 409, error: "Connect DICE first.", reason: "not_connected" };
  return await syncClaimed(db, dice, row as never, Date.now() + RUN_BUDGET_MS);
}

/**
 * A dry run: reserve the slot (exos_dice_dry_run_begin: role, no sync or
 * preview running, 5 a minute), THEN the same reads as a sync with nothing
 * written, then the report on the reserved row.
 */
export async function dryRunOrg(
  db: DiceDb, dice: DiceOptions, org: string, user: string, trigger: Exclude<Trigger, "cron">,
): Promise<RunAnswer> {
  const b = await db.rpc("exos_dice_dry_run_begin", { p_org_id: org, p_user_id: user, p_trigger: trigger });
  if (b.error) return dbRefusal(b.error);
  const row = ((b.data ?? []) as Array<{ run_id?: string; token?: string; cursors?: Cursors }>)[0];
  if (!row?.token || !row.run_id) return { ok: false, status: 409, error: "Connect DICE first.", reason: "not_connected" };
  let report: SyncReport;
  try {
    report = await runSync(dice, row.token, row.cursors ?? {}, null, { ...DRY_RUN_LIMITS, deadline: Date.now() + 40_000 });
  } catch {
    await db.rpc("exos_dice_dry_run_finish", { p_org_id: org, p_run_id: row.run_id, p_status: "error", p_counts: {}, p_error: "the preview failed" });
    return { ok: false, status: 500, error: "The preview failed.", reason: "dice", run_id: row.run_id };
  }
  const error = report.error ? diceErrorMessage({ status: report.error.status, error: report.error.error }) : null;
  const counts = {
    preview: report.preview ?? {},
    ...Object.fromEntries(Object.entries(report.entities).map(([k, v]) => [k, { read: v?.read ?? 0, total: v?.total ?? null }])),
  };
  await db.rpc("exos_dice_dry_run_finish", {
    p_org_id: org, p_run_id: row.run_id, p_status: report.status, p_counts: counts, p_error: error,
  });
  return {
    ok: report.status !== "error", status: report.status === "error" ? 502 : 200,
    ...(error ? { error, reason: "dice" } : {}),
    dry_run: true, kind: report.kind, run_id: row.run_id, result: report.status,
    entities: report.entities, preview: report.preview, warnings: report.warnings,
  };
}
