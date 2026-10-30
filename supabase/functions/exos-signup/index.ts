// exos-signup — the public endpoint behind an organizer's signup form
// (mig 20261031120000, docs/fans.md).
//
//   POST /exos-signup/<form id>                       (what the embed calls)
//   POST /exos-signup/forms/<form id>/submissions     (Opendate's embed path)
//   POST /exos-signup  { form_id, ... }
//
// Body: JSON or form-encoded, capped at 16 KB while streaming. Fields: email
// (required), first_name, last_name, phone, subscribe_to_marketing_email
// (default yes), subscribe_to_marketing_sms, url (honeypot: filled = a bot,
// answered as usual, nothing written), captcha_token. Opendate's fan[...]
// wrapper is accepted.
//
// Anonymous and CORS-open (any site can embed a form), so:
//   * it never returns fan data: every accepted submission answers
//     { ok: true, status: "check_email" }, whether the address is new, already
//     on the list or held back by a limit;
//   * 10 submissions a minute per network (hashed IP, never stored raw) and
//     120 a minute per form (exos_rate_hit); the SQL adds 20 an hour per
//     network per org and 3 a day per address. Limiter down → 503;
//   * captcha hook: with EXOS_SIGNUP_CAPTCHA_SECRET set (provider
//     EXOS_SIGNUP_CAPTCHA_PROVIDER = turnstile | hcaptcha) a token is required
//     and verified; unset = off;
//   * email is double opt-in: the SQL queues the signup-confirm mail, and only
//     the link in it puts the fan on the list. Texts are confirmed signed in.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. Optional:
// EXOS_GUEST_IP_SALT (salt for the hashed IP), the captcha pair above.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { formBody, readCapped } from "../_shared/api/body.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import {
  captchaConfig, captchaPassed, captchaVerifyRequest, formIdFromPath, parseSignupBody, SignupInputError,
} from "../_shared/signup.ts";

const MAX_BODY = 16 * 1024;
const PER_IP_PER_MIN = 10;
const PER_FORM_PER_MIN = 120;
const ACCEPTED = { ok: true, status: "check_email" };

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type, apikey, x-client-info, authorization",
  "access-control-max-age": "86400",
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST, OPTIONS" });

  const text = await readCapped(req, MAX_BODY);
  if (text === null) return json({ error: "request body is too large" }, 413);

  let raw: Record<string, unknown> = {};
  const type = (req.headers.get("content-type") ?? "").toLowerCase();
  if (type.includes("application/x-www-form-urlencoded")) {
    raw = formBody(text);
    // Captcha widgets post hyphenated names, which formBody leaves out.
    const q = new URLSearchParams(text);
    for (const k of ["cf-turnstile-response", "h-captcha-response"]) if (q.has(k)) raw[k] = q.get(k);
  } else if (text.trim()) {
    try {
      const v = JSON.parse(text);
      if (!v || typeof v !== "object" || Array.isArray(v)) return json({ error: "the body must be a JSON object" }, 400);
      raw = v as Record<string, unknown>;
    } catch {
      return json({ error: "the body must be a JSON object" }, 400);
    }
  }

  let input;
  try {
    input = parseSignupBody(raw, formIdFromPath(new URL(req.url).pathname));
  } catch (e) {
    if (e instanceof SignupInputError) return json({ error: e.message }, 422);
    throw e;
  }

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const ip = clientIp((h) => req.headers.get(h));
  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ipHash = await hashIp(ip, salt);

  // Rate limits before anything else touches the database.
  for (const [bucket, limit] of [[`signup-ip:${ipHash?.slice(0, 32) ?? "unknown"}`, PER_IP_PER_MIN],
                                  [`signup-form:${input.formId}`, PER_FORM_PER_MIN]] as const) {
    const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: limit });
    if (error) {
      console.error("exos-signup: rate limiter error (refusing)", error.message);
      return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
    }
    if (data === false) {
      return json({ error: "too many signups, try again in a minute" }, 429,
        { "retry-after": String(Math.max(1, 60 - new Date().getUTCSeconds())) });
    }
  }

  if (input.bot) return json(ACCEPTED);

  const captcha = captchaConfig((n) => Deno.env.get(n));
  if (captcha) {
    if (!input.captchaToken) return json({ error: "captcha required" }, 400);
    const r = captchaVerifyRequest(captcha, input.captchaToken, ip);
    try {
      const res = await fetch(r.url, {
        method: "POST", body: r.body, headers: { "content-type": "application/x-www-form-urlencoded" },
        signal: AbortSignal.timeout(5000),
      });
      if (!captchaPassed(await res.json().catch(() => null))) return json({ error: "captcha failed, try again" }, 400);
    } catch (e) {
      console.error("exos-signup: captcha verify failed", String(e).slice(0, 200));
      return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
    }
  }

  const { error } = await sb.rpc("_exos_signup_submit", {
    p_form_id: input.formId, p_email: input.email, p_first: input.firstName, p_last: input.lastName,
    p_email_opt_in: input.emailOptIn, p_sms_opt_in: input.smsOptIn, p_phone: input.phone, p_ip_hash: ipHash,
  });
  if (error) {
    if (error.code === "22023") return json({ error: String(error.message).replace(/^exos_signup: /, "").slice(0, 200) }, 422);
    if (error.code === "P0002") return json({ error: "this form isn't taking signups" }, 404);
    console.error("exos-signup: submit failed", error.code, error.message);
    return json({ error: "internal error" }, 500);
  }
  return json(ACCEPTED);
});

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS, ...extra },
  });
}
