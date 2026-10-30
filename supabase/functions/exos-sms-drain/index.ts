// exos-sms-drain — sends queued SMS campaigns from each organizer's own Twilio
// / Telnyx account, and takes their STOP / START replies (mig 20261016120000;
// docs/organizer-guide.md "Text messages").
//
// Sending is OFF unless EXOS_SMS_LIVE=on: until then every due message is
// marked dry_run (what would have been sent), so an install can't text fans
// by accident. Consent, quiet hours, the 30-day cap and opt-outs are enforced
// in SQL before a message is claimed.
//
// Routes:
//   POST /cron                          X-Cron-Secret. Claims due messages and sends them.
//   POST /inbound/twilio?org=<uuid>     Twilio inbound webhook (X-Twilio-Signature checked
//        with the org's auth token). Answers empty TwiML.
//   POST /inbound/telnyx?org=<uuid>     Telnyx webhook (Ed25519 signature checked with the
//        org's webhook public key from Integrations).
// Deploy with --no-verify-jwt.
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET, EXOS_SMS_LIVE,
// EXOS_APP_URL (fills {{app_url}} in texts that link into the app, like the
// weekly channel report; such a text fails rather than going out without it).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { redactError } from "../_shared/log.ts";
import { fillAppUrl, normalizeAppUrl } from "../_shared/mail-render.ts";
import { safeEqual, sendSms, type SmsConfig, telnyxInbound, telnyxVerified, twilioSignature } from "../_shared/sms/providers.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUDGET_MS = 50_000;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const parts = url.pathname.replace(/\/+$/, "").split("/");
  const route = parts.pop() ?? "";
  const parent = parts.pop() ?? "";
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    if (route === "cron") {
      const authErr = requireCronSecret(req);
      if (authErr) return authErr;
      return json(await drain(sb));
    }
    if (parent === "inbound" && (route === "twilio" || route === "telnyx")) {
      const org = url.searchParams.get("org") ?? "";
      if (!UUID.test(org)) return new Response("bad org", { status: 400 });
      const cfg = await config(sb, org, route);
      if (!cfg) return new Response("not connected", { status: 404 });
      const raw = await req.text();
      if (route === "twilio") {
        const params = Object.fromEntries(new URLSearchParams(raw));
        const publicUrl = `${Deno.env.get("SUPABASE_URL")!.replace(/\/+$/, "")}/functions/v1/exos-sms-drain/inbound/twilio?org=${org}`;
        const want = await twilioSignature(publicUrl, params, cfg.secret ?? "");
        if (!safeEqual(want, req.headers.get("x-twilio-signature") ?? "")) return new Response("bad signature", { status: 403 });
        await sb.rpc("exos_sms_inbound", { p_org_id: org, p_from: params.From ?? "", p_text: params.Body ?? "" });
        return new Response('<?xml version="1.0" encoding="UTF-8"?><Response/>', { headers: { "content-type": "text/xml" } });
      }
      const pub = String(cfg.config.webhook_public ?? "");
      const ok = pub && await telnyxVerified(raw, req.headers.get("telnyx-signature-ed25519") ?? "", req.headers.get("telnyx-timestamp") ?? "", pub);
      if (!ok) return new Response("bad signature", { status: 403 });
      const msg = telnyxInbound(JSON.parse(raw));
      if (msg) await sb.rpc("exos_sms_inbound", { p_org_id: org, p_from: msg.from, p_text: msg.text });
      return json({ ok: true });
    }
    return new Response("not found", { status: 404 });
  } catch (err) {
    console.error("exos-sms-drain failed", redactError(err));
    return new Response("error", { status: 500 });
  }
});

async function config(sb: SupabaseClient, org: string, provider: string): Promise<SmsConfig | null> {
  const { data } = await sb.rpc("exos_integration_config", { p_org_id: org, p_provider: provider });
  const d = data as { config?: Record<string, unknown>; secret?: string | null; status?: string } | null;
  if (!d) return null;
  return { provider: provider as SmsConfig["provider"], config: d.config ?? {}, secret: d.secret ?? null };
}

async function drain(sb: SupabaseClient) {
  const live = Deno.env.get("EXOS_SMS_LIVE") === "on";
  const appUrl = normalizeAppUrl(Deno.env.get("EXOS_APP_URL"));
  const deadline = Date.now() + BUDGET_MS;
  const { data, error } = await sb.rpc("exos_sms_claim", { p_limit: 100 });
  if (error) {
    console.error("exos-sms-drain: claim failed", redactError(error));
    return { ok: false };
  }
  const cache = new Map<string, SmsConfig | null>();
  let sent = 0, dry = 0, failed = 0;
  for (const m of (data ?? []) as { id: string; org_id: string; provider: string; phone: string; body: string }[]) {
    if (Date.now() > deadline) {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: "queued", p_error: "out of time" });
      continue;
    }
    if (!live) {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: "dry_run" });
      dry++;
      continue;
    }
    const key = `${m.org_id}:${m.provider}`;
    if (!cache.has(key)) cache.set(key, await config(sb, m.org_id, m.provider));
    const cfg = cache.get(key);
    if (!cfg) {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: "failed", p_error: "provider disconnected" });
      failed++;
      continue;
    }
    // The weekly channel report text links into the app ({{app_url}}, mig 20261029120000).
    const body = fillAppUrl(m.body, appUrl);
    if (body === null) {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: "failed", p_error: "EXOS_APP_URL unset; the text links into the app" });
      failed++;
      continue;
    }
    const r = await sendSms(fetch, cfg, m.phone, body);
    // `in` narrows the union whether or not strictNullChecks is on (CI's deno check has it off).
    if ("id" in r) {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: "sent", p_provider_id: r.id });
      sent++;
    } else {
      await sb.rpc("exos_sms_mark", { p_id: m.id, p_status: r.retry ? "queued" : "failed", p_error: r.error });
      if (!r.retry) failed++;
    }
  }
  return { ok: true, live, sent, dry_run: dry, failed };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}
