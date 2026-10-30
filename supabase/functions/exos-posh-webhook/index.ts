// exos-posh-webhook — Posh "Order Created" / "Pending Order Created" in
// (mig 20261029150000, docs/marketplace/posh.md).
//
// POST /exos-posh-webhook/<token>            the URL an organizer pastes into
//                                            Posh (Organization Settings ->
//                                            API Webhooks)
// POST /exos-posh-webhook/<token>/pending    the same, for an organizer who
//                                            gives "Pending Order Created" its
//                                            own URL (a hint when the payload
//                                            doesn't say which it is)
// POST /exos-posh-webhook/replay/<log id>    operator replay of a logged
//                                            delivery (x-cron-secret)
//
// Auth: the URL itself. <token> is 32 random bytes (64 hex) made by
// exos_posh_connect, stored only as its SHA-256; rotating it stops the old
// URL. Posh documents no request signature, so there is nothing else to
// check (if a signature header turns up, the log keeps header NAMES so it
// can be found and added). Limits: 64 KB per body, 120 deliveries a minute
// per URL (exos_rate_hit). Nothing is ever sent to Posh.
//
// Deploy with --no-verify-jwt (Posh sends no Supabase JWT). Secrets:
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (platform), CRON_SECRET (replay).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { detectKind, extractOrder, parseBody, redact, route, sha256Hex } from "../_shared/posh/payload.ts";

const MAX_BODY = 64 * 1024;
const PER_MINUTE = 120;

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405, { Allow: "POST" });
  const r = route(new URL(req.url).pathname);
  if (!r) return json({ error: "not found" }, 404);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (r.kind === "replay") {
    const authErr = requireCronSecret(req);
    if (authErr) return authErr;
    const { data, error } = await sb.rpc("exos_posh_log_payload", { p_log_id: r.logId });
    const row = Array.isArray(data) ? data[0] : null;
    if (error || !row?.payload) return json({ error: error ? "lookup failed" : "no stored payload" }, error ? 500 : 404);
    const { data: out, error: e2 } = await sb.rpc("exos_posh_ingest", {
      p_token_hash: row.token_hash, p_body_hash: row.body_hash, p_kind: row.kind,
      p_order: extractOrder(row.payload), p_payload: row.payload, p_header_names: [], p_replay: true,
    });
    if (e2) {
      console.error("exos-posh-webhook: replay failed", redactError(e2));
      return json({ error: "replay failed" }, 500);
    }
    return json(out);
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY) return json({ error: "body too large" }, 413);
  const text = await readCapped(req, MAX_BODY);
  if (text === null) return json({ error: "body too large" }, 413);

  const tokenHash = await sha256Hex(r.token);
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `posh:${tokenHash.slice(0, 40)}`, p_limit: PER_MINUTE });
  if (rlErr) {
    console.error("exos-posh-webhook: rate limiter error (refusing)", redactError(rlErr));
    return json({ error: "temporarily unavailable" }, 503, { "Retry-After": "30" });
  }
  if (allowed === false) return json({ error: "rate limit exceeded" }, 429, { "Retry-After": "60" });

  const body = parseBody(text, req.headers.get("content-type"));
  if (!body) return json({ error: "expected a JSON body" }, 400);

  const { data: out, error } = await sb.rpc("exos_posh_ingest", {
    p_token_hash: tokenHash,
    p_body_hash: await sha256Hex(text),
    p_kind: detectKind(body, r.hint),
    p_order: extractOrder(body),
    p_payload: redact(body),
    p_header_names: [...req.headers.keys()].slice(0, 60),
    p_replay: false,
  });
  if (error) {
    console.error("exos-posh-webhook: ingest failed", redactError(error));
    return json({ error: "could not record the order" }, 500);
  }
  if (out?.outcome === "unknown_hook") return json({ error: "not found" }, 404);
  return json({ ok: true, outcome: out?.outcome });
});

/** The body as text, read as a stream and cut off past `max` bytes (null). */
async function readCapped(req: Request, max: number): Promise<string | null> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.byteLength; }
  return new TextDecoder().decode(all);
}
