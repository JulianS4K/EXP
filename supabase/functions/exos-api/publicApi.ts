// exos-api: the no-credential /v1/public/… routes (auth `public` in
// _shared/api/routes.ts; claude/exos-fan-api, mig 20261105110000):
//
//   GET  /public/discovery/events[/:id]   published events (Opendate fan_app
//                                         /public/discovery/confirms)
//   GET  /public/venues[/:id]             organizers with upcoming events
//   GET  /public/search?q=                events and organizers
//   GET  /public/event-series[/:id]       an organizer's public series
//                                         (Opendate /public/website_event_series)
//   POST /public/fans                     a signup to a form (form_id in the body)
//   POST /public/forms/:id/submissions    a signup form's embed path
//
// Reads are one _exos_api_public call (service role, with this caller's
// network bucket: the salted hash of the client IP, never the IP), which
// returns only what the storefront already shows anyone and limits each
// network to 60 requests a minute. Ticket types are priced all-in here, the
// way every Exos price a buyer sees is (fees and exclusive tax included, no
// fee line). Signups run exactly as exos-signup does: 10 a minute per
// network and 120 per form, the optional captcha, double opt-in, and the
// same answer whatever happened, so the route never tells whether an address
// is on a list.
//
// CORS-open (a venue's own site can call it). Optional secrets:
// EXOS_GUEST_IP_SALT, EXOS_SIGNUP_CAPTCHA_SECRET / _PROVIDER.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, PagingError, parsePage } from "../_shared/api/paging.ts";
import {
  PUBLIC_READS, PUBLIC_WRITES, PublicParamError, pricePublicEvent, publicReadArgs, publicTicketType,
  type PublicTierRow, SIGNUP_MAX_BODY, SIGNUP_PER_FORM_PER_MIN, SIGNUP_PER_IP_PER_MIN,
} from "../_shared/api/publicDiscovery.ts";
import { formBody, readCapped } from "../_shared/api/body.ts";
import { captchaConfig, captchaPassed, captchaVerifyRequest, parseSignupBody, SignupInputError } from "../_shared/signup.ts";
import { withPublicTierFees } from "../_shared/feeRulesRead.ts";
import { allInCents, effectiveTierPrice } from "../_shared/pricing.ts";
import { parseUnitFees } from "../_shared/fees.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
};
const ACCEPTED = { ok: true, status: "check_email" };
const PRICING = { scheduled: effectiveTierPrice, allIn: allInCents, fees: parseUnitFees };

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS, ...extra },
  });
}

const retryAfter = () => String(Math.max(1, 60 - new Date().getUTCSeconds()));

/** Answers one public route (`route.auth === "public"`). */
export async function publicApi(
  req: Request, url: URL, route: ApiRoute, params: Record<string, string>, sb: SupabaseClient,
): Promise<Response> {
  const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ip = clientIp((h) => req.headers.get(h));
  const net = (await hashIp(ip, salt)) ?? "unknown";
  try {
    if (PUBLIC_WRITES.has(route.id)) return await signup(req, route, params, sb, net, ip);
    const spec = PUBLIC_READS[route.id];
    if (!spec) return json({ error: "not found" }, 404);
    const args = publicReadArgs(route.id, url.searchParams);
    const page = route.paged ? parsePage(url.searchParams) : null;
    if (page) {
      args.limit = page.perPage;
      args.offset = page.from;
    }
    // A series answers its next 100 upcoming dates (not a paged route).
    if (route.id === "public-event-series") args.per_page = 100;
    const { data, error } = await sb.rpc("_exos_api_public", {
      p_action: spec.action, p_target: spec.target ? params[spec.target] ?? null : null, p_args: args,
      p_bucket: `net:${net.slice(0, 32)}`,
    });
    if (error) throw error;
    const out = await priced(sb, spec.action, data);
    if (page) {
      const o = out as { rows?: unknown[]; total?: number };
      return json(pageEnvelope(o.rows ?? [], page, o.total ?? null));
    }
    return json({ data: out });
  } catch (e) {
    if (e instanceof PublicParamError || e instanceof PagingError) return json({ error: e.message }, 400);
    const err = e as { code?: string; message?: string };
    const msg = String(err?.message ?? "").replace(/^exos_api_public: /, "").slice(0, 200);
    if (err?.code === "54000") return json({ error: msg || "rate limit exceeded" }, 429, { "retry-after": retryAfter() });
    if (err?.code === "P0002") return json({ error: msg || "not found" }, 404);
    if (err?.code === "22023" || err?.code === "22P02") return json({ error: msg || "invalid request" }, 400);
    console.error("exos-api public error:", e);
    return json({ error: "internal error" }, 500);
  }
}

/** Ticket types priced all-in; lists keep only the "from" price. */
async function priced(sb: SupabaseClient, action: string, data: unknown): Promise<unknown> {
  // deno-lint-ignore no-explicit-any
  const events: any[] = action === "events.list" ? ((data as { rows?: unknown[] })?.rows ?? [])
    : action === "event.get" && data ? [data] : [];
  if (!events.length) return data;
  const tiers = events.flatMap((e) => (Array.isArray(e.ticket_types) ? e.ticket_types : []) as PublicTierRow[]);
  const withFees = await withPublicTierFees(sb, tiers, { serviceRole: true });
  const now = new Date();
  const byEvent = new Map<string, ReturnType<typeof publicTicketType>[]>();
  for (const t of withFees) {
    const k = String(t.event_id);
    byEvent.set(k, [...(byEvent.get(k) ?? []), publicTicketType(t, now, PRICING)]);
  }
  const out = events.map((e) => pricePublicEvent(e, byEvent.get(String(e.id)) ?? [], action === "event.get"));
  return action === "event.get" ? out[0] : { ...(data as object), rows: out };
}

/** POST /public/fans and /public/forms/:id/submissions: as exos-signup. */
async function signup(
  req: Request, route: ApiRoute, params: Record<string, string>, sb: SupabaseClient, net: string, ip: string,
): Promise<Response> {
  const text = await readCapped(req, SIGNUP_MAX_BODY);
  if (text === null) return json({ error: "request body is too large" }, 413);
  let raw: Record<string, unknown> = {};
  const type = (req.headers.get("content-type") ?? "").toLowerCase();
  if (type.includes("application/x-www-form-urlencoded")) {
    raw = formBody(text);
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
    input = parseSignupBody(raw, route.id === "public-create-form-submission" ? (params.id ?? "").toLowerCase() || null : null);
  } catch (e) {
    if (e instanceof SignupInputError) return json({ error: e.message }, 422);
    throw e;
  }
  for (const [bucket, limit] of [[`signup-ip:${net.slice(0, 32)}`, SIGNUP_PER_IP_PER_MIN],
                                  [`signup-form:${input.formId}`, SIGNUP_PER_FORM_PER_MIN]] as const) {
    const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: limit });
    if (error) {
      console.error("exos-api public signup: rate limiter error (refusing)", error.message);
      return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
    }
    if (data === false) return json({ error: "too many signups, try again in a minute" }, 429, { "retry-after": retryAfter() });
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
      console.error("exos-api public signup: captcha verify failed", String(e).slice(0, 200));
      return json({ error: "temporarily unavailable" }, 503, { "retry-after": "30" });
    }
  }
  const { error } = await sb.rpc("_exos_signup_submit", {
    p_form_id: input.formId, p_email: input.email, p_first: input.firstName, p_last: input.lastName,
    p_email_opt_in: input.emailOptIn, p_sms_opt_in: input.smsOptIn, p_phone: input.phone, p_ip_hash: net,
  });
  if (error) {
    if (error.code === "22023") return json({ error: String(error.message).replace(/^exos_signup: /, "").slice(0, 200) }, 422);
    if (error.code === "P0002") return json({ error: "this form isn't taking signups" }, 404);
    if (error.code === "54000") return json(ACCEPTED);
    console.error("exos-api public signup: submit failed", error.code, error.message);
    return json({ error: "internal error" }, 500);
  }
  return json(ACCEPTED);
}

/** CORS preflight for the public routes. */
export function publicPreflight(): Response {
  return new Response(null, { status: 204, headers: CORS });
}
