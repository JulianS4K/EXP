// exos-wroom-join (mig 20261118120000): a new anonymous place in a waiting
// room whose organizer turned Cloudflare Turnstile on. The browser's anon join
// answers { state: 'challenge' } there and mints nothing; this checks the
// Turnstile token with Cloudflare's siteverify (one verification POST, no
// upstream write) and then calls exos_wroom_join_verified (service role).
//
// The client address is never read here: the platform headers
// (cf-connecting-ip, x-forwarded-for) go to SQL, which applies
// _exos_request_ip()'s trusted-source rule (request_ip_source: Cloudflare's
// header, else the last X-Forwarded-For hop; never x-real-ip or a
// client-written first hop), buckets IPv6 by /64 for the 30-a-minute limit,
// and answers 'no_ip' without one (503 here: never a place in 'unknown').
//
// Order: method, body, ids, the secret, the address + rate limit (SQL, before
// the external call), the token, siteverify (success, action 'wroom', the
// app's hostname or one of the org's verified custom domains; none
// configured: refused), then the join. Every outside call comes in through deps.

import { readCapped } from "./api/body.ts";
import { captchaPassed, captchaVerifyRequest } from "./signup.ts";
import { parseRedirectOrigins } from "./redirects.ts";
import type { StripeEnd } from "./wroomCheckout.ts";

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
  log?: (msg: string) => void;
  /** The verified custom domains (exos_public_org_domains) of the event's org. */
  orgDomains?: (eventId: string) => Promise<string[]>;
  /** end_checkout: the signed-in user's id from their access token, or null. */
  userId?: (jwt: string) => Promise<string | null>;
  /** end_checkout: expire our own Stripe session (wroomStripe.ts). */
  expireStripe?: (sessionId: string) => Promise<StripeEnd>;
  /** end_checkout: mark our session row expired (pending only). */
  markExpired?: (sessionId: string) => Promise<void>;
}

/** The app's hostnames, from EXOS_APP_BASE_URL, EXOS_APP_URL and EXOS_REDIRECT_ORIGINS. */
export function allowedHosts(env: (name: string) => string | undefined): string[] {
  const out = new Set<string>();
  for (const raw of [env("EXOS_APP_BASE_URL"), env("EXOS_APP_URL"), ...parseRedirectOrigins(env("EXOS_REDIRECT_ORIGINS"))]) {
    if (!raw) continue;
    try { out.add(new URL(raw.trim()).hostname.toLowerCase()); } catch { /* not a URL */ }
  }
  return [...out];
}

let warnedNoHosts = false;

/** Does siteverify's answer pass for this room: success, our action, one of
 *  our hosts (the app's, or the org's verified custom domains)? No host
 *  configured at all: refused (fail closed), logged once. */
export function verifyAnswer(answer: unknown, hosts: string[], log: (m: string) => void = console.warn): boolean {
  if (!captchaPassed(answer)) return false;
  const a = answer as { action?: unknown; hostname?: unknown };
  if (a.action !== WROOM_TURNSTILE_ACTION) return false;
  if (hosts.length === 0) {
    if (!warnedNoHosts) {
      warnedNoHosts = true;
      log("exos-wroom-join: no app hostnames configured (EXOS_APP_BASE_URL / EXOS_APP_URL / EXOS_REDIRECT_ORIGINS); refusing every check");
    }
    return false;
  }
  return typeof a.hostname === "string" && hosts.includes(a.hostname.toLowerCase());
}

/** The org's verified domains, as hostnames (bad rows and errors: none). */
async function orgHosts(deps: WroomJoinDeps, eventId: string): Promise<string[]> {
  if (!deps.orgDomains) return [];
  try {
    return (await deps.orgDomains(eventId))
      .map((d) => (typeof d === "string" ? d.trim().toLowerCase() : ""))
      .filter((d) => /^[a-z0-9.-]{3,253}$/.test(d));
  } catch {
    return [];
  }
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
  let b: { event_id?: unknown; token?: unknown; turnstile_token?: unknown; action?: unknown };
  try {
    b = JSON.parse(text || "{}");
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  if (!b || typeof b !== "object") return json({ error: "invalid JSON" }, 400);
  const eventId = typeof b.event_id === "string" ? b.event_id : "";
  if (!UUID_RE.test(eventId)) return json({ error: "invalid event_id" }, 400);
  if (b.action === "end_checkout") return await endCheckout(req, eventId, deps);
  const token = typeof b.token === "string" && TOKEN_RE.test(b.token) ? b.token : null;
  const challenge = typeof b.turnstile_token === "string" ? b.turnstile_token.trim() : "";

  const secret = (deps.env("TURNSTILE_SECRET_KEY") ?? "").trim();
  if (!secret) return json({ error: "the waiting room's check isn't set up", reason: "challenge_unavailable" }, 503);

  // The platform's address headers only; SQL resolves and rate-limits.
  const headers = {
    "cf-connecting-ip": req.headers.get("cf-connecting-ip"),
    "x-forwarded-for": req.headers.get("x-forwarded-for"),
  };
  const g = await deps.rpc("exos_wroom_verify_gate", { p_headers: headers });
  if (g.error) return json({ error: "temporarily unavailable" }, 503, { "retry-after": "10" });
  const gate = (g.data ?? {}) as { ok?: boolean; reason?: string; ip?: string };
  if (gate.reason === "busy") return json({ state: "busy", retry_after_ms: 10000 }, 429, { "retry-after": "10" });
  if (!gate.ok || typeof gate.ip !== "string") return json({ error: "temporarily unavailable" }, 503, { "retry-after": "10" });

  if (!challenge || challenge.length > 2048) return json({ error: "complete the check first", reason: "challenge_required" }, 400);

  const r = captchaVerifyRequest({ provider: "turnstile", secret }, challenge, gate.ip);
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
  const passed = captchaPassed(answer);
  const hosts = passed ? [...allowedHosts(deps.env), ...(await orgHosts(deps, eventId))] : [];
  if (!passed || !verifyAnswer(answer, hosts, deps.log)) {
    return json({ error: "the check didn't pass, try again", reason: "challenge_failed" }, 403);
  }

  const { data, error } = await deps.rpc("exos_wroom_join_verified", { p_event_id: eventId, p_token: token, p_headers: headers });
  if (error) return json({ error: "could not join the line, try again" }, 503);
  return json(data ?? { state: "off" });
}

/**
 * end_checkout: a signed-in buyer whose turn lapsed while a payment page of
 * theirs was still open (the join answered `checking_out`) ends that page so
 * the place can be re-placed. The session is the one SQL finds for THIS
 * account's lapsed place (exos_wroom_open_checkout), never one named by the
 * client; it is expired on our own Stripe account and marked expired. Stripe
 * refuses a session that isn't open (paid, or paying with an async method):
 * then the place is kept (409).
 */
async function endCheckout(req: Request, eventId: string, deps: WroomJoinDeps): Promise<Response> {
  if (!deps.userId || !deps.expireStripe || !deps.markExpired) return json({ error: "not available" }, 503);
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const uid = jwt ? await deps.userId(jwt).catch(() => null) : null;
  if (!uid) return json({ error: "sign in first" }, 401);
  const headers = {
    "cf-connecting-ip": req.headers.get("cf-connecting-ip"),
    "x-forwarded-for": req.headers.get("x-forwarded-for"),
  };
  const g = await deps.rpc("exos_wroom_verify_gate", { p_headers: headers });
  const gate = (g.data ?? {}) as { ok?: boolean; reason?: string };
  if (gate.reason === "busy") return json({ state: "busy", retry_after_ms: 10000 }, 429, { "retry-after": "10" });
  if (g.error || !gate.ok) return json({ error: "temporarily unavailable" }, 503, { "retry-after": "10" });
  const o = await deps.rpc("exos_wroom_open_checkout", { p_event_id: eventId, p_uid: uid });
  if (o.error) return json({ error: "temporarily unavailable" }, 503);
  const sid = typeof o.data === "string" ? o.data : null;
  if (!sid) return json({ ended: false, reason: "none" });
  const end = await deps.expireStripe(sid);
  if (end !== "expired") {
    return json({ error: "that payment page is still in use: finish paying there", reason: "checkout_in_progress" }, 409);
  }
  await deps.markExpired(sid);
  return json({ ended: true });
}
