// exos-sms-relay — the masked SMS relay for group chats (mig 20261031230000;
// docs/group-chat.md). Members text the group from their own phone to a
// platform pool number; the text lands in the in-app chat and goes out to the
// other opted-in members from each one's own pool number. Nobody sees anyone's
// real number.
//
// Sending real SMS is the only third-party write here, and it is OFF unless
// EXOS_SMS_RELAY=on: until then every due text is marked dry_run. STOP / HELP
// are always recorded (compliance doesn't wait for the switch). US A2P 10DLC
// registration of the pool numbers comes before turning it on.
//
// Routes:
//   POST /cron               X-Cron-Secret. Claims due texts and sends them.
//   POST /inbound/twilio     Twilio inbound webhook; X-Twilio-Signature checked with
//                            EXOS_RELAY_TWILIO_AUTH_TOKEN. Answers empty TwiML.
//   POST /inbound/telnyx     Telnyx webhook; Ed25519 signature checked with
//                            EXOS_RELAY_TELNYX_PUBLIC_KEY (5-minute window).
// Inbound bodies are capped at 64 KB while streaming. Deploy with --no-verify-jwt.
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET, EXOS_SMS_RELAY,
//      EXOS_SMS_RELAY_PUBLIC_URL (the URL Twilio posts to, without the
//      /inbound/twilio suffix; default <SUPABASE_URL>/functions/v1/exos-sms-relay),
//      EXOS_RELAY_TWILIO_ACCOUNT_SID, EXOS_RELAY_TWILIO_AUTH_TOKEN,
//      EXOS_RELAY_TELNYX_API_KEY, EXOS_RELAY_TELNYX_PUBLIC_KEY, EXOS_RELAY_TELNYX_PROFILE_ID.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import { redactError } from "../_shared/log.ts";
import { safeEqual, sendSms, type SmsConfig, telnyxVerified, twilioSignature } from "../_shared/sms/providers.ts";
import {
  parseTelnyxRelay, parseTwilioRelay, type RelayInbound, relayKeyword, relayLive, relayRoute, relaySenderConfig,
} from "../_shared/sms/relay.ts";

const BUDGET_MS = 50_000;
const env = (k: string) => Deno.env.get(k);

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = relayRoute(url.pathname);
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!route) return new Response("not found", { status: 404 });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    if (route.kind === "cron") {
      const authErr = requireCronSecret(req);
      if (authErr) return authErr;
      return json(await drain(sb, 200));
    }
    const raw = await readCapped(req, MAX_BODY_BYTES);
    if (raw === null) return new Response("too large", { status: 413 });

    let msg: RelayInbound | null;
    if (route.provider === "twilio") {
      const token = env("EXOS_RELAY_TWILIO_AUTH_TOKEN") ?? "";
      if (!token) return new Response("not configured", { status: 503 });
      const params = Object.fromEntries(new URLSearchParams(raw));
      const base = (env("EXOS_SMS_RELAY_PUBLIC_URL") ?? `${env("SUPABASE_URL")!.replace(/\/+$/, "")}/functions/v1/exos-sms-relay`)
        .replace(/\/+$/, "");
      const want = await twilioSignature(`${base}/inbound/twilio${url.search}`, params, token);
      if (!safeEqual(want, req.headers.get("x-twilio-signature") ?? "")) return new Response("bad signature", { status: 403 });
      msg = parseTwilioRelay(params);
    } else {
      const pub = env("EXOS_RELAY_TELNYX_PUBLIC_KEY") ?? "";
      if (!pub) return new Response("not configured", { status: 503 });
      const ok = await telnyxVerified(raw, req.headers.get("telnyx-signature-ed25519") ?? "", req.headers.get("telnyx-timestamp") ?? "", pub);
      if (!ok) return new Response("bad signature", { status: 403 });
      let body: unknown = null;
      try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
      msg = parseTelnyxRelay(body);
    }

    if (msg) {
      const { data, error } = await sb.rpc("exos_sms_relay_inbound", {
        p_provider: route.provider, p_from: msg.from, p_to: msg.to, p_text: msg.text,
        p_keyword: relayKeyword(msg.text), p_provider_ref: msg.id,
      });
      if (error) {
        console.error("exos-sms-relay: inbound failed", redactError(error));
        return new Response("error", { status: 500 }); // the provider retries
      }
      // Keyword answers and fresh relays go out now rather than on the next cron tick.
      if (data && (data as { action?: string }).action !== "ignored") await drain(sb, 50).catch(() => {});
    }
    return route.provider === "twilio"
      ? new Response('<?xml version="1.0" encoding="UTF-8"?><Response/>', { headers: { "content-type": "text/xml" } })
      : json({ ok: true });
  } catch (err) {
    console.error("exos-sms-relay failed", redactError(err));
    return new Response("error", { status: 500 });
  }
});

async function drain(sb: SupabaseClient, limit: number) {
  const live = relayLive(env);
  const deadline = Date.now() + BUDGET_MS;
  const { data, error } = await sb.rpc("exos_sms_relay_claim", { p_limit: limit });
  if (error) {
    console.error("exos-sms-relay: claim failed", redactError(error));
    return { ok: false };
  }
  let sent = 0, dry = 0, failed = 0;
  for (const m of (data ?? []) as { id: string; provider: string; from_phone: string; to_phone: string; body: string }[]) {
    if (Date.now() > deadline) {
      await sb.rpc("exos_sms_relay_mark", { p_id: m.id, p_status: "queued", p_error: "out of time" });
      continue;
    }
    if (!live) {
      await sb.rpc("exos_sms_relay_mark", { p_id: m.id, p_status: "dry_run" });
      dry++;
      continue;
    }
    const cfg: SmsConfig | null = relaySenderConfig(m.provider, m.from_phone, env);
    if (!cfg) {
      await sb.rpc("exos_sms_relay_mark", { p_id: m.id, p_status: "failed", p_error: "relay provider not configured" });
      failed++;
      continue;
    }
    const r = await sendSms(fetch, cfg, m.to_phone, m.body);
    if ("id" in r) {
      await sb.rpc("exos_sms_relay_mark", { p_id: m.id, p_status: "sent", p_provider_id: r.id });
      sent++;
    } else {
      await sb.rpc("exos_sms_relay_mark", { p_id: m.id, p_status: r.retry ? "queued" : "failed", p_error: r.error });
      if (!r.retry) failed++;
    }
  }
  return { ok: true, live, sent, dry_run: dry, failed };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}
