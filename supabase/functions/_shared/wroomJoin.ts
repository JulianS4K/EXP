// exos-wroom-join (mig 20261118120000): a new place in a waiting room whose
// organizer turned Cloudflare Turnstile on. The browser's anon join answers
// { state: 'challenge' } there and mints nothing; this checks the Turnstile
// token with Cloudflare's siteverify (one verification POST, no upstream
// write) and then calls exos_wroom_join_verified with the service role,
// passing the platform's client-address headers so the SQL network limits
// read the same trusted address as for a browser call.
//
// Order: method, body size, ids, the per-network rate limit (before the
// external call), the secret, the token, siteverify, then SQL.
// Pure enough to test: every outside call comes in through deps.

import { readCapped } from "./api/body.ts";
import { captchaPassed, captchaVerifyRequest } from "./signup.ts";
import { clientIp, hashIp } from "./guest.ts";

export const WROOM_JOIN_MAX_BODY = 4 * 1024;
export const WROOM_TURNSTILE_ACTION = "wroom";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN_RE = /^[0-9a-f]{64}$/;

export const WROOM_CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type, apikey, x-client-info, authorization",
  "access-control-max-age": "86400",
};

export interface WroomJoinDeps {
  env: (name: string) => string | undefined;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  /** service-role RPC */
  rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...WROOM_CORS, ...extra },
  });
}

export async function handleWroomJoin(req: Request, deps: WroomJoinDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: WROOM_CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST, OPTIONS" });
  const text = await readCapped(req, WROOM_JOIN_MAX_BODY);
  if (text === null) return json({ error: "request body is too large" }, 413);
  let b: { event_id?: unknown; token?: unknown; turnstile_token?: unknown };
  try {
    b = JSON.parse(text || "{}");
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  if (!b || typeof b !== "object") return json({ error: "invalid JSON" }, 400);
  const eventId = typeof b.event_id === "string" ? b.event_id : "";
  if (!UUID_RE.test(eventId)) return json({ error: "invalid event_id" }, 400);
  const token = typeof b.token === "string" && TOKEN_RE.test(b.token) ? b.token : null;
  const challenge = typeof b.turnstile_token === "string" ? b.turnstile_token.trim() : "";

  const ip = clientIp((h) => req.headers.get(h));
  const salt = deps.env("EXOS_GUEST_IP_SALT") ?? deps.env("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const ipHash = await hashIp(ip, salt);
  // Before the external call: 30 verifications a minute per network.
  const rl = await deps.rpc("exos_rate_hit", { p_bucket: `wroom-tv:${ipHash?.slice(0, 32) ?? "unknown"}`, p_limit: 30 });
  if (rl.error) return json({ error: "temporarily unavailable" }, 503, { "retry-after": "10" });
  if (rl.data === false) return json({ state: "busy", retry_after_ms: 10000 }, 429, { "retry-after": "10" });

  const secret = (deps.env("TURNSTILE_SECRET_KEY") ?? "").trim();
  if (!secret) return json({ error: "the waiting room's check isn't set up", reason: "challenge_unavailable" }, 503);
  if (!challenge || challenge.length > 2048) return json({ error: "complete the check first", reason: "challenge_required" }, 400);

  const r = captchaVerifyRequest({ provider: "turnstile", secret }, challenge, ip);
  let answer: unknown;
  try {
    const res = await deps.fetch(r.url, {
      method: "POST", body: r.body, headers: { "content-type": "application/x-www-form-urlencoded" },
      signal: AbortSignal.timeout(5000),
    });
    answer = await res.json().catch(() => null);
  } catch {
    return json({ error: "temporarily unavailable" }, 503, { "retry-after": "10" });
  }
  const action = (answer as { action?: unknown } | null)?.action;
  if (!captchaPassed(answer) || (action !== undefined && action !== WROOM_TURNSTILE_ACTION)) {
    return json({ error: "the check didn't pass, try again", reason: "challenge_failed" }, 403);
  }

  const { data, error } = await deps.rpc("exos_wroom_join_verified", {
    p_event_id: eventId, p_token: token,
    p_headers: {
      "cf-connecting-ip": req.headers.get("cf-connecting-ip"),
      "x-forwarded-for": req.headers.get("x-forwarded-for"),
    },
  });
  if (error) return json({ error: "could not join the line, try again" }, 503);
  return json(data ?? { state: "off" });
}
