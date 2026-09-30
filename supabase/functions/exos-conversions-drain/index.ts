// exos-conversions-drain — send queued server-side ad conversions (Meta CAPI,
// TikTok Events API, GA4 Measurement Protocol, Reddit, Snap; Google Ads is
// planned only) from exos_marketing_conversions (mig 20260930100000).
//
// Cron-invoked (requireCronSecret), e.g. every 5 minutes; not scheduled yet
// (docs/marketing-conversions.md has the cron.schedule call for the operator).
// CLAIMS due rows via exos_conversions_claim_batch (FOR UPDATE SKIP LOCKED +
// a lease: status 'sending', attempts+1, a claim_token), so overlapping runs
// never send the same row twice; a run that dies leaves a lease that is
// reclaimed after LEASE_MINUTES. Every result goes through
// exos_conversions_mark with the row's claim_token, so a run whose lease was
// taken over can't overwrite the newer attempt.
//
// DRY-RUN BY DEFAULT. Nothing leaves the building unless
// EXOS_CONVERSIONS_LIVE === "true". In dry-run each row's request is built,
// its secret redacted, stored in payload_planned, and the row is marked
// 'skipped' with last_error "dry-run: …" (so it isn't re-claimed every run).
// To send dry-run rows after going live, requeue the recent ones (SQL in the
// doc); the platforms refuse events older than their window anyway.
// Google Ads rows are always planned only (OAuth exchange + API verification
// pending, see _shared/conversions/googleAds.ts).
//
// Secrets: each org's token comes from Supabase Vault through the claim RPC
// (service role only). It is sent only to the platform's pinned host
// (_shared/conversions/common.ts ALLOWED_HOSTS), redacted from
// payload_planned and from error text, and never logged.
//
// Env: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//      EXOS_CONVERSIONS_LIVE ("true" to send), EXOS_APP_BASE_URL (https://…,
//      for event_source_url; optional).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import type { ConversionRow, Credential, Platform } from "../_shared/conversions/common.ts";
import { buildConversionRequest, plannedOnly, redactRequest, sendConversion } from "../_shared/conversions/send.ts";

const MAX_ATTEMPTS = 6;
const BATCH = 25;
const TIMEOUT_MS = 8000;
// BATCH x TIMEOUT_MS is ~200 s at worst; the run stops starting sends after
// RUN_BUDGET_MS and hands the rest back, well inside the lease.
const LEASE_MINUTES = 10;
const RUN_BUDGET_MS = 100_000;

type Claimed = {
  id: string; org_id: string; platform: Platform; event_name: "Purchase" | "Refund";
  event_id_dedupe: string; occurred_at: string; value_cents: number; currency: string;
  payload: ConversionRow["payload"]; attempts: number; claim_token: string;
  enabled: boolean; config: Record<string, string> | null; test_event_code: string | null;
  secret: string | null;
};

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const live = Deno.env.get("EXOS_CONVERSIONS_LIVE") === "true";
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const started = Date.now();

  const { data, error } = await sb.rpc("exos_conversions_claim_batch", {
    p_limit: BATCH, p_max_attempts: MAX_ATTEMPTS, p_lease_minutes: LEASE_MINUTES,
  });
  if (error) {
    console.error("exos-conversions-drain: claim failed", redactError(error));
    return json({ error: "claim failed" }, 500);
  }
  const claimed = (data ?? []) as Claimed[];
  const counts = { sent: 0, failed: 0, retry: 0, skipped: 0, dry_run: 0, released: 0, mark_errors: 0 };

  const mark = async (row: Claimed, result: string, extra: {
    error?: string | null; status?: number | null; planned?: unknown;
  } = {}) => {
    const { error: e } = await sb.rpc("exos_conversions_mark", {
      p_id: row.id, p_claim_token: row.claim_token, p_result: result,
      p_error: extra.error ?? null, p_status_code: extra.status ?? null,
      p_planned: extra.planned ?? null, p_max_attempts: MAX_ATTEMPTS,
    });
    if (e) {
      counts.mark_errors++;
      console.error(`exos-conversions-drain: mark ${row.id} failed`, redactError(e));
    }
  };

  for (const row of claimed) {
    if (Date.now() - started > RUN_BUDGET_MS) {
      await mark(row, "release");
      counts.released++;
      continue;
    }
    if (!row.enabled || !row.secret) {
      await mark(row, "skipped", { error: "platform disabled or no token" });
      counts.skipped++;
      continue;
    }

    const cred: Credential = { config: row.config ?? {}, secret: row.secret, test_event_code: row.test_event_code };
    const built = buildConversionRequest(row, cred, { appBase, now: new Date() });
    if (!built.ok) {
      await mark(row, "skipped", { error: built.skip });
      counts.skipped++;
      continue;
    }
    const planned = redactRequest(built.request, row.secret);

    if (!live || plannedOnly(row.platform)) {
      const why = !live ? "dry-run: EXOS_CONVERSIONS_LIVE is not true" : `planned only: ${row.platform} sender not enabled`;
      await mark(row, "skipped", { error: why, planned });
      counts.dry_run++;
      continue;
    }

    const out = await sendConversion(built.request, row.secret, (u, i) => fetch(u, i), TIMEOUT_MS);
    if (out.result === "sent") {
      await mark(row, "sent", { status: out.status, planned });
      counts.sent++;
    } else {
      await mark(row, out.result, { error: out.error, status: out.status, planned });
      counts[out.result]++;
    }
  }

  return json({ live, processed: claimed.length, ...counts });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
