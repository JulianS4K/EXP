// exos-api: import from DICE (mig 20261106100000, docs/dice-coverage.md,
// docs/api/dice-import.json). Dispatched from index.ts by route id.
//
//   GET  /v1/dice-import          the org's DICE connection and what it imported
//   GET  /v1/dice-import/runs     the import runs, newest first (paged)
//   POST /v1/dice-import/sync     run a sync now ({dry_run: true}: counts only)
//
// org:admin: the connection holds a third-party credential, and a sync
// writes events, door lists and fans at once, so no narrower scope covers it.
// Connecting (pasting the MIO token) stays in the dashboard: a partner key
// never carries the DICE token. The sync runs as the key's creator, who must
// be an owner or manager now (_exos_api_key_actor); the SQL checks it again.
// Behind EXOS_DICE_IMPORT=on like the edge function: 503 otherwise.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { type Page, pageEnvelope } from "../_shared/api/paging.ts";
import type { DiceOptions } from "../_shared/dice/client.ts";
import { dryRunOrg, syncOrg } from "../_shared/dice/run.ts";
import { DICE_DISABLED_MESSAGE, diceImportEnabled, diceSyncBodyProblem } from "../_shared/dice/sync.ts";

/** The route ids this module answers. */
export const DICE_ROUTES = new Set(["get-dice-import", "list-dice-import-runs", "start-dice-import-sync"]);

export interface DiceCtx {
  sb: SupabaseClient;
  orgId: string;
  cred: { kind: "api_key" | "pat" | "oauth"; id: string; userId: string | null };
  page: Page;
  body: Record<string, unknown>;
  env: (k: string) => string | undefined;
  dice?: DiceOptions;
}

/** An answer with a status (index.ts sends it as JSON). */
export class DiceApiError extends Error {
  constructor(public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}

async function rpc(c: DiceCtx, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await c.sb.rpc(fn, args);
  if (error) {
    if (error.code === "42501") throw new DiceApiError(403, String(error.message ?? "forbidden").replace(/^exos_\w+: /, ""));
    throw new DiceApiError(500, "internal error");
  }
  return data;
}

/** Handles one of this module's routes. */
export async function handleDice(route: ApiRoute, c: DiceCtx): Promise<unknown> {
  if (!diceImportEnabled(c.env)) throw new DiceApiError(503, DICE_DISABLED_MESSAGE, { reason: "disabled" });
  switch (route.id) {
    case "get-dice-import":
      return { data: await rpc(c, "_exos_dice_status_json", { p_org_id: c.orgId }) };

    case "list-dice-import-runs": {
      const r = await rpc(c, "_exos_dice_runs", { p_org_id: c.orgId, p_limit: c.page.perPage, p_offset: c.page.from }) as
        { total?: number; rows?: unknown[] } | null;
      return pageEnvelope(r?.rows ?? [], c.page, typeof r?.total === "number" ? r.total : null);
    }

    case "start-dice-import-sync": {
      const problem = diceSyncBodyProblem(c.body);
      if (problem) throw new DiceApiError(400, problem);
      const user = c.cred.kind === "api_key"
        ? await rpc(c, "_exos_api_key_actor", { p_org: c.orgId, p_api_key: c.cred.id, p_roles: ["owner", "manager"] })
        : c.cred.userId;
      if (typeof user !== "string") throw new DiceApiError(403, "only an owner or manager can sync DICE");
      const dice = c.dice ?? { fetch };
      const out = c.body.dry_run === true
        ? await dryRunOrg(c.sb, dice, c.orgId, user, "api")
        : await syncOrg(c.sb, dice, c.orgId, user, "api");
      const { status, ok, error, reason, ...rest } = out;
      if (!ok) throw new DiceApiError(status, error ?? "the sync failed", { reason, ...rest });
      return { data: rest };
    }
  }
  throw new DiceApiError(404, "not found");
}
