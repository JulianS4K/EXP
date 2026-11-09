// exos-tixel-webhook — Tixel's fan-data webhook in (mig 20261105120000,
// docs/fans.md "Tixel waitlist signups"). Opendate's POST /public/tixel/waitlist_signups.
//
// POST /exos-tixel-webhook   X-Secret: <the organizer's secret>
//
// Auth: the secret picks the organization (EXOS_TIXEL_WEBHOOK_SECRETS, a JSON
// object of org id -> secret, kept in the function's env, never in the
// database; _shared/tixel/webhook.ts). Off (404) while that env var is unset.
// A WAITLIST delivery is stored and put on the waitlist of the org's one
// upcoming event with that title (_exos_tixel_ingest, service role); PURCHASE,
// AUTO_PURCHASE and LISTING are acknowledged (200) so Tixel doesn't retry.
// Marketing consent is never changed from here. Limits: 32 KB per body, 120
// deliveries a minute per org (exos_rate_hit). Nothing is ever sent to Tixel.
//
// Deploy with --no-verify-jwt (Tixel sends no Supabase JWT). Secrets:
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), EXOS_TIXEL_WEBHOOK_SECRETS.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { readCapped } from "../_shared/api/body.ts";
import { redactError } from "../_shared/log.ts";
import { MAX_TIXEL_BODY, orgForSecret, parseTixelBody, parseTixelSecrets } from "../_shared/tixel/webhook.ts";

const PER_MINUTE = 120;

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405, { Allow: "POST" });
  const { pairs, dropped } = parseTixelSecrets(Deno.env.get("EXOS_TIXEL_WEBHOOK_SECRETS"));
  if (dropped) console.error(`exos-tixel-webhook: ${dropped} malformed EXOS_TIXEL_WEBHOOK_SECRETS entr${dropped === 1 ? "y" : "ies"} ignored`);
  if (!pairs.length) return json({ error: "not found" }, 404);

  const orgId = orgForSecret(pairs, req.headers.get("x-secret"));
  if (!orgId) return json({ error: "Invalid secret" }, 401);

  const text = await readCapped(req, MAX_TIXEL_BODY);
  if (text === null) return json({ error: "body too large" }, 413);
  const body = parseTixelBody(text);
  if (!body) return json({ error: "expected a JSON object" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `tixel:${orgId}`, p_limit: PER_MINUTE });
  if (rlErr) {
    console.error("exos-tixel-webhook: rate limiter error (refusing)", redactError(rlErr));
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) return json({ error: "rate limit exceeded" }, 429, { "Retry-After": "60" });

  const { data: out, error } = await sb.rpc("_exos_tixel_ingest", { p_org: orgId, p_payload: body });
  if (error) {
    if (error.code === "22023") return json({ error: error.message }, 422);
    console.error("exos-tixel-webhook: ingest failed", redactError(error));
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  const r = out as { recorded?: boolean; id?: string; replay?: boolean };
  if (!r?.recorded) return json({ ok: true, recorded: false });
  return json({ id: r.id, ...(r.replay ? { replay: true } : {}) }, r.replay ? 200 : 201);
});
