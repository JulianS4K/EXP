// exos-match — matched seats (mig 20261031210000, docs/matched-seats.md).
//
// Groups the holders of a "matched" ticket type into tables / crews, then the
// database reveals each group's spot at reveal time. The grouping itself is
// _shared/matching.ts (a byte-for-byte copy of src/lib/matching.ts); every
// hard rule is checked again in SQL by exos_match_apply before anything is
// stored, and the config row is locked there, so the cron and a staff "Match
// now" can't both write.
//
// Routes (POST):
//   /cron   X-Cron-Secret. Matches every tier past its cutoff, reveals the
//           ones past their reveal time, sweeps quiz answers past retention.
//   /run    The caller's Supabase JWT; body { tier_id, reshuffle? }. Owner /
//           manager of the tier's org (checked in SQL with the verified user
//           id). Matches now (or re-runs while every group is still a draft).
//           reshuffle: true picks a new seed; otherwise the stored seed, or
//           one derived from the tier id, so a re-run is reproducible.
//
// Nothing here moves money: refund leftovers go through exos-refund from the
// staff panel. Nothing is sent from here either: reveal mail goes through
// exos_mail / exos-mail-drain and texts through exos_sms_outbox /
// exos-sms-drain (dry run unless EXOS_SMS_LIVE=on).
//
// Deploy with --no-verify-jwt (the cron path has no JWT; /run checks it).
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { matchGroups, type MatchMember, type MatchSpot, type UndersubscribedPolicy } from "../_shared/matching.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY = 4096;
const BUDGET_MS = 50_000;

interface Inputs {
  tier_id: string;
  status: string;
  settings: { min: number; target: number; max: number; groupCount: number | null; policy: string; seed: number | null };
  spots: MatchSpot[];
  members: MatchMember[];
  blocks: [string, string][];
}

/** A stable 31-bit seed from the tier id, when none is stored. */
export function seedFromId(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 1) || 1;
}

async function matchTier(sb: SupabaseClient, tierId: string, actor: string | null, reshuffle: boolean) {
  const { data, error } = await sb.rpc("exos_match_inputs", { p_tier_id: tierId, p_actor: actor });
  if (error) throw error;
  const inp = data as Inputs;
  const seed = reshuffle
    ? (crypto.getRandomValues(new Uint32Array(1))[0] >>> 1) || 1
    : Number(inp.settings.seed ?? seedFromId(tierId));
  const result = matchGroups({
    members: inp.members,
    spots: inp.spots,
    settings: {
      min: inp.settings.min, target: inp.settings.target, max: inp.settings.max,
      groupCount: inp.settings.groupCount, seed,
    },
    blocks: inp.blocks,
    policy: (inp.settings.policy === "refund" ? "refund" : "merge") as UndersubscribedPolicy,
  });
  const { data: applied, error: applyErr } = await sb.rpc("exos_match_apply", {
    p_tier_id: tierId, p_actor: actor, p_seed: seed, p_result: result,
  });
  if (applyErr) throw applyErr;
  return { tier_id: tierId, seed, ...(applied as Record<string, unknown>), warnings: result.warnings };
}

async function cron(sb: SupabaseClient) {
  const t0 = Date.now();
  const out: { matched: unknown[]; failed: { tier_id: string; error: string }[]; revealed: number; swept: number } =
    { matched: [], failed: [], revealed: 0, swept: 0 };
  const { data: due, error } = await sb.rpc("exos_match_due");
  if (error) throw error;
  for (const row of (due ?? []) as (string | { exos_match_due: string })[]) {
    if (Date.now() - t0 > BUDGET_MS) break;
    const tierId = typeof row === "string" ? row : row.exos_match_due;
    try {
      out.matched.push(await matchTier(sb, tierId, null, false));
    } catch (e) {
      out.failed.push({ tier_id: tierId, error: redactError(e).slice(0, 200) });
    }
  }
  const { data: revealed, error: rErr } = await sb.rpc("exos_match_reveal_due");
  if (rErr) throw rErr;
  out.revealed = Number(revealed) || 0;
  const { data: swept, error: sErr } = await sb.rpc("exos_match_sweep");
  if (sErr) throw sErr;
  out.swept = Number(swept) || 0;
  return out;
}

async function readBody(req: Request): Promise<string | null> {
  const reader = req.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > MAX_BODY) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const buf = new Uint8Array(n);
  let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.byteLength; }
  return new TextDecoder().decode(buf);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors() });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const route = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    if (route === "cron") {
      const authErr = requireCronSecret(req);
      if (authErr) return authErr;
      return json(await cron(sb));
    }
    if (route === "run" || route === "exos-match") {
      const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
      });
      const { data: { user } } = await sbUser.auth.getUser();
      if (!user) return json({ error: "unauthorized" }, 401);
      const raw = await readBody(req);
      if (raw === null) return json({ error: "body too large" }, 413);
      // deno-lint-ignore no-explicit-any
      let p: any;
      try { p = JSON.parse(raw || "{}"); } catch { return json({ error: "invalid JSON" }, 400); }
      const tierId = typeof p?.tier_id === "string" ? p.tier_id : "";
      if (!UUID.test(tierId)) return json({ error: "tier_id required" }, 400);
      try {
        return json(await matchTier(sb, tierId, user.id, p?.reshuffle === true));
      } catch (e) {
        // deno-lint-ignore no-explicit-any
        const code = String((e as any)?.code ?? "");
        // deno-lint-ignore no-explicit-any
        const msg = String((e as any)?.message ?? "matching failed").replace(/^exos_match_\w+: /, "");
        if (code === "42501") return json({ error: msg }, 403);
        if (code === "55000" || code === "22023") return json({ error: msg }, 409);
        throw e;
      }
    }
    return json({ error: "not found" }, 404);
  } catch (e) {
    console.error("exos-match:", redactError(e));
    return json({ error: "matching failed" }, 500);
  }
});

function cors(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors() } });
}
