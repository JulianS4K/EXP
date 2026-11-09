// exos-rsvp — phone-number RSVP for free events (mig 20261102150000,
// docs/organizer-guide.md "Phone RSVP"). No app, no account.
//
//   POST { action: "info",   event_id }                         -> is it open, texts or email
//   POST { action: "start",  event_id, name, phone, email?, plus_ones?, promoter?, website }
//                                                               -> { ok, rsvp_id, channel, to }
//   POST { action: "verify", rsvp_id, code }                    -> { ok, tickets: [{ id, url }] }
//
// The code goes out as a text from the org's own Twilio / Telnyx number when
// it has one connected and EXOS_SMS_LIVE=on (the existing SMS switch);
// otherwise by email when the guest gave one; otherwise the page says phone
// RSVP isn't available. After the code, the guest gets their ticket link(s)
// the same way (/t/<id>#k=<key>: the rotating door code, no account).
//
// Anonymous and CORS-open like exos-signup, so: body capped at 8 KB while
// streaming; 20 requests a minute per network (hashed IP, never stored raw,
// exos_rate_hit); the SQL adds per-phone / per-network / per-event limits, a
// 10-minute code with 5 tries, and one RSVP per phone per event. A filled
// "website" field (honeypot) gets a believable answer and nothing is written.
// Answers never say whether a number already RSVP'd.
//
// Checkout questions (mig 20261106110000, docs/checkout-questions.md): "info"
// also answers the questions asked of this RSVP's ticket type, and "start"
// takes `answers` ({ order, tickets: one per guest incl. plus-ones }), checked
// and stored before the code goes out (a refusal expires the RSVP); the
// tickets "verify" mints take them.
//
// Deploy with --no-verify-jwt. Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
// EXOS_APP_URL (ticket links), EXOS_GUEST_IP_SALT, EXOS_SMS_LIVE.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { readCapped } from "../_shared/api/body.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";
import { normalizeAppUrl } from "../_shared/mail-render.ts";
import { sendSms, type SmsConfig } from "../_shared/sms/providers.ts";
import { drainRsvpSms } from "../_shared/sms/rsvpOutbox.ts";
import {
  codeText, honeypotAnswer, MAX_RSVP_BODY, maskPhone, parseRsvpRequest, RsvpInputError, smsAvailable, ticketsText,
} from "../_shared/rsvp.ts";

const PER_IP_PER_MIN = 20;
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type, apikey, x-client-info, authorization",
  "access-control-max-age": "86400",
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const text = await readCapped(req, MAX_RSVP_BODY);
  if (text === null) return json({ error: "request body is too large" }, 413);
  let parsed;
  let rawBody: Record<string, unknown> = {};
  try {
    const j = JSON.parse(text || "{}");
    if (j && typeof j === "object" && !Array.isArray(j)) rawBody = j as Record<string, unknown>;
    parsed = parseRsvpRequest(j);
  } catch (e) {
    return json({ ok: false, error: "bad_request", message: e instanceof RsvpInputError ? e.message : "invalid JSON" }, 400);
  }
  if (parsed.honeypot) return json(honeypotAnswer(parsed.action));

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const ipHash = await hashIp(clientIp((h) => req.headers.get(h)), Deno.env.get("EXOS_GUEST_IP_SALT") ?? "");
  const { data: allowed, error: limErr } = await sb.rpc("exos_rate_hit", { p_bucket: `rsvp:ip:${ipHash}`, p_limit: PER_IP_PER_MIN });
  if (limErr) return json({ ok: false, error: "unavailable" }, 503);
  if (allowed === false) return json({ ok: false, error: "rate_limited" }, 429);

  try {
    if (parsed.action === "info") {
      const { data: info } = await sb.rpc("exos_phone_rsvp_info", { p_event_id: parsed.eventId });
      const i = (info ?? {}) as { ok?: boolean; reason?: string; org_id?: string; tier_name?: string; max_plus_ones?: number };
      const sms = i.ok && i.org_id ? smsAvailable(live(), await smsConfig(sb, i.org_id)) : false;
      // Checkout questions of the RSVP ticket type (none before the migration).
      const { data: rq } = i.ok ? await sb.rpc("exos_rsvp_questions", { p_event_id: parsed.eventId }) : { data: null };
      const qs = (rq ?? {}) as { questions?: unknown; tier_id?: string | null };
      return json({ ok: !!i.ok, reason: i.reason ?? "off", tier_name: i.tier_name ?? null,
                    max_plus_ones: i.max_plus_ones ?? 0, sms, email_fallback: true,
                    tier_id: qs.tier_id ?? null, questions: Array.isArray(qs.questions) ? qs.questions : [] });
    }

    if (parsed.action === "start") {
      const { data: info } = await sb.rpc("exos_phone_rsvp_info", { p_event_id: parsed.eventId });
      const orgId = (info as { org_id?: string } | null)?.org_id ?? null;
      const cfg = orgId ? await smsConfig(sb, orgId) : null;
      const canText = smsAvailable(live(), cfg);
      const { data, error } = await sb.rpc("exos_phone_rsvp_start", {
        p_event_id: parsed.eventId, p_name: parsed.name, p_phone: parsed.phone, p_email: parsed.email,
        p_plus_ones: parsed.plusOnes ?? 0, p_ip_hash: ipHash, p_sms_ok: canText, p_promoter: parsed.promoter,
        p_app_base: normalizeAppUrl(Deno.env.get("EXOS_APP_URL")),
      });
      if (error) throw error;
      const r = data as { ok: boolean; error?: string; rsvp_id?: string; channel?: string; to?: string; code?: string;
                          event_name?: string; max_plus_ones?: number; seats_left?: number };
      // Every start schedules the resend drain the same way and never waits
      // for it: a re-text for a number that already RSVP'd (queued by the
      // SQL when the event is full) goes out off the request path.
      background(drainRsvpSms(sb, live(), (org) => smsConfig(sb, org)).catch((e) => console.error("exos-rsvp: drain", redactError(e))));
      // not_enough_seats carries seats_left (mig 20261105100000, SIM-BUYER-31).
      if (!r.ok) return json({ ok: false, error: r.error, max_plus_ones: r.max_plus_ones, seats_left: r.seats_left });
      // Checkout questions: stored with the RSVP before the code goes out.
      if (r.rsvp_id) {
        const { data: ra, error: raErr } = await sb.rpc("exos_rsvp_record_answers", {
          p_rsvp_id: r.rsvp_id, p_answers: rawBody.answers ?? null,
        });
        if (raErr && !["PGRST202", "42883"].includes(String(raErr.code))) throw raErr;
        const a = (ra ?? { ok: true }) as { ok?: boolean; error?: string; problems?: unknown };
        if (a.ok === false && a.error === "answers") return json({ ok: false, error: "answers", problems: a.problems ?? [] }, 400);
      }
      if (r.channel === "sms") {
        const sent = cfg ? await sendSms(fetch, cfg, r.to!, codeText(r.event_name, r.code!)) : null;
        if (!sent || !("id" in sent)) {
          console.error("exos-rsvp: code text failed", sent && "error" in sent ? sent.error : "no provider");
          return json({ ok: false, error: "no_channel" }, 502);
        }
        return json({ ok: true, rsvp_id: r.rsvp_id, channel: "sms", to: maskPhone(r.to) });
      }
      return json({ ok: true, rsvp_id: r.rsvp_id, channel: "email", to: maskEmail(r.to) });
    }

    // verify
    const appBase = normalizeAppUrl(Deno.env.get("EXOS_APP_URL"));
    if (!appBase) return json({ ok: false, error: "unavailable" }, 503);
    const { data, error } = await sb.rpc("exos_phone_rsvp_verify", { p_rsvp_id: parsed.rsvpId, p_code: parsed.code, p_app_base: appBase });
    if (error) throw error;
    const v = data as { ok: boolean; error?: string; attempts_left?: number; event_id?: string; tickets?: { id: string; url: string | null }[];
                        channel?: string; to?: string; org_id?: string; event_name?: string };
    if (!v.ok) return json({ ok: false, error: v.error, attempts_left: v.attempts_left, event_id: v.event_id });
    const urls = (v.tickets ?? []).map((t) => t.url).filter((u): u is string => !!u);
    if (v.channel === "sms" && v.org_id && urls.length) {
      // The ticket text is best effort: the page shows the links right away.
      const cfg = await smsConfig(sb, v.org_id);
      if (smsAvailable(live(), cfg)) {
        const sent = await sendSms(fetch, cfg!, v.to!, ticketsText(v.event_name, urls));
        if (!("id" in sent)) console.error("exos-rsvp: ticket text failed", sent.error);
      }
    }
    return json({ ok: true, tickets: v.tickets ?? [], channel: v.channel });
  } catch (err) {
    console.error("exos-rsvp failed", redactError(err));
    return json({ ok: false, error: "unavailable" }, 500);
  }
});

// Run after the response without delaying it (EdgeRuntime on Supabase).
function background(p: Promise<unknown>): void {
  const rt = (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } }).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
  else void p;
}

function live(): boolean {
  return Deno.env.get("EXOS_SMS_LIVE") === "on";
}

// The org's texting account: Twilio first, then Telnyx.
async function smsConfig(sb: SupabaseClient, orgId: string): Promise<(SmsConfig & { status?: string }) | null> {
  for (const provider of ["twilio", "telnyx"] as const) {
    const { data } = await sb.rpc("exos_integration_config", { p_org_id: orgId, p_provider: provider });
    const d = data as { config?: Record<string, unknown>; secret?: string | null; status?: string } | null;
    if (d && d.secret && d.status !== "error") return { provider, config: d.config ?? {}, secret: d.secret, status: d.status };
  }
  return null;
}

function maskEmail(e: string | undefined): string {
  const [user, domain] = String(e ?? "").split("@");
  return user && domain ? `${user.slice(0, 2)}***@${domain}` : "your email";
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store" } });
}
