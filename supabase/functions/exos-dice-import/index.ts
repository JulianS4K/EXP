// exos-dice-import — "Import from DICE" (mig 20261106100000;
// docs/dice-coverage.md). A promoter moving from DICE pastes the API token
// they generated in MIO (DICE's partner dashboard); Exos imports their DICE
// events (as draft link-out events: Exos never sells what DICE sells),
// ticket holders (onto each event's 'DICE' door list, keyed by the DICE
// code, so a DICE barcode scans at the Exos door) and fans (marketing
// consent ONLY when DICE's optInPartners is true).
//
// Upstream is READ ONLY (CLAUDE.md): DICE is read through
// _shared/dice/client.ts, which sends GraphQL QUERIES only to DICE's one
// endpoint and refuses any mutation or subscription before sending.
//
// Routes (under /functions/v1/exos-dice-import), JSON in and out:
//   POST /status     {org}               owner / manager: the connection, what
//        was imported, the last runs (exos_dice_org_status, as the user).
//   POST /connect    {org, token}        owner / manager: checks the token
//        with `viewer { id name }`, then stores it in Vault.
//   POST /disconnect {org}               owner / manager: deletes the token;
//        what was imported stays.
//   POST /sync       {org, dry_run?}     owner / manager: a full first run,
//        then incremental. dry_run: the same reads, counts only, nothing
//        written but the run's log row.
//   POST /cron                           X-Cron-Secret. Syncs the orgs that
//        are due (exos_dice_sync_claim) within a time budget. Scheduled by
//        the migration as exos-dice-import-sync-hourly, INACTIVE.
//
// Behind EXOS_DICE_IMPORT=on: anything else answers 503 on every route.
//
// The user routes take the Supabase JWT and verify it here; the RPCs are
// service role only and re-check the user's role against the org. Deploy
// with --no-verify-jwt (CORS preflight; /cron has the cron secret).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//      CRON_SECRET, EXOS_REDIRECT_ORIGINS (CORS allowlist for the SPA),
//      EXOS_DICE_IMPORT (on / off).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { readCapped } from "../_shared/api/body.ts";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { diceErrorMessage, isDiceTokenShaped, readViewer, type DiceOptions } from "../_shared/dice/client.ts";
import {
  DICE_DISABLED_MESSAGE, diceImportEnabled, dryRunOrg, RUN_BUDGET_MS, syncClaimed, syncOrg,
} from "../_shared/dice/run.ts";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY = 16 * 1024;
const CRON_ORGS = 5;
const dice: DiceOptions = { fetch };

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const parts = url.pathname.replace(/\/+$/, "").split("/");
  const fnAt = parts.lastIndexOf("exos-dice-import");
  const route = (fnAt >= 0 ? parts.slice(fnAt + 1) : parts.slice(-1)).join("/");
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (!diceImportEnabled((k) => Deno.env.get(k))) {
    return json({ error: DICE_DISABLED_MESSAGE, reason: "disabled" }, 503, cors);
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "cron") {
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    return json(await runCron(sb));
  }

  const auth = req.headers.get("Authorization") ?? "";
  const user = await signedInUser(auth);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  const text = await readCapped(req, MAX_BODY);
  if (text === null) return json({ error: "request too large" }, 413, cors);
  let body: Record<string, unknown> = {};
  try {
    const parsed = text ? JSON.parse(text) : {};
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed as Record<string, unknown>;
  } catch {
    return json({ error: "send JSON" }, 400, cors);
  }
  const org = String(body.org ?? "");
  if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);

  try {
    if (route === "status") {
      // As the user: the SQL checks owner / manager and never returns the token.
      const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: auth } },
      });
      const r = await sbUser.rpc("exos_dice_org_status", { p_org_id: org });
      if (r.error) return rpcError(r.error, cors);
      return json(r.data, 200, cors);
    }

    if (route === "connect") {
      const token = typeof body.token === "string" ? body.token.trim() : "";
      if (!isDiceTokenShaped(token)) {
        return json({ error: "That doesn't look like a DICE API token. Copy it again from MIO.", reason: "bad_token" }, 400, cors);
      }
      const v = await readViewer(dice, token);
      if (!v.ok || !v.data) return json({ error: diceErrorMessage(v), reason: "dice" }, v.status === 401 ? 400 : 502, cors);
      const r = await sb.rpc("exos_dice_connect", {
        p_org_id: org, p_user_id: user, p_token: token, p_account_id: v.data.id, p_account_name: v.data.name,
      });
      if (r.error) return rpcError(r.error, cors);
      return json({ ok: true, ...(r.data as object) }, 200, cors);
    }

    if (route === "disconnect") {
      const r = await sb.rpc("exos_dice_disconnect", { p_org_id: org, p_user_id: user });
      if (r.error) return rpcError(r.error, cors);
      return json({ ok: true, ...(r.data as object) }, 200, cors);
    }

    if (route === "sync") {
      const out = body.dry_run === true
        ? await dryRunOrg(sb, dice, org, user, "dashboard")
        : await syncOrg(sb, dice, org, user, "dashboard");
      const { status, ...rest } = out;
      return json(rest, status, cors);
    }
  } catch (err) {
    console.error("exos-dice-import: failed", route, redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
  return json({ error: "not found" }, 404, cors);
});

/** The cron: every due org, one after another, within the time budget. */
async function runCron(sb: SupabaseClient): Promise<Record<string, unknown>> {
  const deadline = Date.now() + RUN_BUDGET_MS;
  const c = await sb.rpc("exos_dice_sync_claim", { p_org_id: null, p_user_id: null, p_trigger: "cron", p_limit: CRON_ORGS });
  if (c.error) {
    console.error("exos-dice-import: claim failed", redactError(c.error));
    return { ok: false };
  }
  const rows = (c.data ?? []) as Array<Record<string, unknown>>;
  const results: Array<Record<string, unknown>> = [];
  for (const row of rows) {
    // Each claimed org gets an equal share of what is left.
    const share = Math.max(5_000, Math.floor((deadline - Date.now()) / Math.max(1, rows.length - results.length)));
    const r = await syncClaimed(sb, dice, row as never, Math.min(deadline, Date.now() + share));
    results.push({ org: row.org_id, ok: r.ok, result: r.result ?? null, reason: r.reason ?? null });
  }
  return { ok: true, synced: rows.length, results };
}

function cleanMsg(m: string | undefined): string {
  return (m ?? "").replace(/^exos_\w+: /, "");
}

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  if (error.code === "42501") return json({ error: "Owners and managers only.", reason: "forbidden" }, 403, cors);
  if (error.code === "22023") return json({ error: cleanMsg(error.message), reason: "invalid" }, 400, cors);
  if (error.code === "PGRST202" || error.code === "42883") {
    return json({ error: "Import from DICE isn't installed on this database yet.", reason: "not_deployed" }, 503, cors);
  }
  console.error("exos-dice-import: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
}

async function signedInUser(auth: string): Promise<string | null> {
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data } = await sbUser.auth.getUser();
  return data.user?.id ?? null;
}

/** CORS for the SPA's fetch calls: only allow-listed origins are echoed. */
function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}
