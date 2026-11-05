// A DICE sync or dry run against the database (mig 20261106100000), shared
// by exos-dice-import (dashboard + cron) and exos-api (POST
// /v1/dice-import/sync). The reads are _shared/dice/client.ts (queries
// only); the writes are the service-role RPCs: exos_dice_sync_claim (lease,
// run row, token), exos_dice_apply (one page and its cursor),
// exos_dice_sync_finish. A dry run reads with exos_dice_token and writes
// only its log row (exos_dice_log_dry_run).
//
// The feature switch: EXOS_DICE_IMPORT=on. diceImportEnabled() is the one
// check; both functions answer 503 without it.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { type DiceEntity, type DiceOptions, diceErrorMessage } from "./client.ts";
import type { DiceRow } from "./map.ts";
import { type Cursors, DRY_RUN_LIMITS, RUN_LIMITS, runSync, type SyncReport, type SyncStore } from "./sync.ts";

export { DICE_DISABLED_MESSAGE, diceImportEnabled } from "./sync.ts";

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
}

type DbError = { code?: string; message?: string };

/** The SQL's refusals for a claim, as answers. */
export function claimRefusal(e: DbError): RunAnswer {
  const msg = (e.message ?? "").replace(/^exos_\w+: /, "");
  if (e.code === "42501") return { ok: false, status: 403, error: "Owners and managers only.", reason: "forbidden" };
  if (e.code === "55000") return { ok: false, status: 409, error: msg || "A DICE sync is already running.", reason: "busy" };
  if (e.code === "22023") return { ok: false, status: 409, error: msg || "Connect DICE first.", reason: "not_connected" };
  return { ok: false, status: 500, error: "something went wrong", reason: "db" };
}

/** Wall-clock budget for one run, under the edge function limit. */
export const RUN_BUDGET_MS = 100_000;

/** One sync for one claimed org: pages written as they are read, then finish. */
export async function syncClaimed(
  sb: SupabaseClient, dice: DiceOptions,
  claimed: { org_id: string; token: string; cursors: Cursors | null; lease_id: string; run_id: string; kind: string },
  deadline: number,
): Promise<RunAnswer> {
  let leaseLost = false;
  const store: SyncStore = {
    async apply(entity: DiceEntity, rows: DiceRow[], page) {
      const r = await sb.rpc("exos_dice_apply", {
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
    await sb.rpc("exos_dice_sync_finish", {
      p_org_id: claimed.org_id, p_lease: claimed.lease_id, p_status: "error",
      p_error: "Exos couldn't save what it read from DICE.", p_warnings: [message.slice(0, 200)],
    });
    return { ok: false, status: 500, error: "Exos couldn't save what it read from DICE.", reason: "db", run_id: claimed.run_id };
  }
  const authFailed = report.error?.status === 401 || report.error?.status === 403;
  const error = report.error ? diceErrorMessage({ status: report.error.status, error: report.error.error }) : null;
  await sb.rpc("exos_dice_sync_finish", {
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

/** "Sync now" (dashboard) or the API: claim this org, run, finish. */
export async function syncOrg(
  sb: SupabaseClient, dice: DiceOptions, org: string, user: string, trigger: Exclude<Trigger, "cron">,
): Promise<RunAnswer> {
  const c = await sb.rpc("exos_dice_sync_claim", { p_org_id: org, p_user_id: user, p_trigger: trigger, p_limit: 1 });
  if (c.error) return claimRefusal(c.error);
  const row = ((c.data ?? []) as Array<Record<string, unknown>>)[0];
  if (!row) return { ok: false, status: 409, error: "Connect DICE first.", reason: "not_connected" };
  return await syncClaimed(sb, dice, row as never, Date.now() + RUN_BUDGET_MS);
}

/** A dry run: the same reads, nothing written but the log row. */
export async function dryRunOrg(
  sb: SupabaseClient, dice: DiceOptions, org: string, user: string, trigger: Exclude<Trigger, "cron">,
): Promise<RunAnswer> {
  const t = await sb.rpc("exos_dice_token", { p_org_id: org, p_user_id: user });
  if (t.error) return claimRefusal(t.error);
  const row = ((t.data ?? []) as Array<{ token?: string; cursors?: Cursors }>)[0];
  if (!row?.token) return { ok: false, status: 409, error: "Connect DICE first.", reason: "not_connected" };
  const report = await runSync(dice, row.token, row.cursors ?? {}, null, { ...DRY_RUN_LIMITS, deadline: Date.now() + 40_000 });
  const error = report.error ? diceErrorMessage({ status: report.error.status, error: report.error.error }) : null;
  const counts = {
    preview: report.preview ?? {},
    ...Object.fromEntries(Object.entries(report.entities).map(([k, v]) => [k, { read: v?.read ?? 0, total: v?.total ?? null }])),
  };
  const log = await sb.rpc("exos_dice_log_dry_run", {
    p_org_id: org, p_user_id: user, p_trigger: trigger, p_status: report.status, p_counts: counts, p_error: error,
  });
  if (log.error) {
    if (log.error.code === "54000") return { ok: false, status: 429, error: "Too many previews. Wait a minute.", reason: "rate_limited" };
    return claimRefusal(log.error);
  }
  return {
    ok: report.status !== "error", status: report.status === "error" ? 502 : 200,
    ...(error ? { error, reason: "dice" } : {}),
    dry_run: true, kind: report.kind, run_id: typeof log.data === "string" ? log.data : null, result: report.status,
    entities: report.entities, preview: report.preview, warnings: report.warnings,
  };
}
