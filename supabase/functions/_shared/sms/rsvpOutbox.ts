// The phone-RSVP resend outbox (exos_rsvp_sms_outbox, mig 20261102150000):
// tickets re-texted to a number that already RSVP'd, queued by the SQL so the
// request that triggered it answers exactly like any other (no timing or
// content difference on the request path). Drained in the background by
// exos-rsvp (EdgeRuntime.waitUntil, not awaited) and by exos-sms-drain's cron.

import { sendSms, type SmsConfig } from "./providers.ts";

type Rpc = { rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }> };

export async function drainRsvpSms(
  sb: Rpc,
  live: boolean,
  configFor: (orgId: string) => Promise<SmsConfig | null>,
  f: typeof fetch = fetch,
): Promise<{ sent: number; failed: number }> {
  const { data, error } = await sb.rpc("exos_rsvp_sms_claim", { p_limit: 20 });
  if (error || !Array.isArray(data)) return { sent: 0, failed: 0 };
  let sent = 0, failed = 0;
  const cache = new Map<string, SmsConfig | null>();
  for (const m of data as { id: string; org_id: string; phone: string; body: string }[]) {
    if (!live) {
      await sb.rpc("exos_rsvp_sms_mark", { p_id: m.id, p_status: "failed", p_error: "texts are off" });
      failed++;
      continue;
    }
    if (!cache.has(m.org_id)) cache.set(m.org_id, await configFor(m.org_id));
    const cfg = cache.get(m.org_id);
    if (!cfg) {
      await sb.rpc("exos_rsvp_sms_mark", { p_id: m.id, p_status: "failed", p_error: "provider disconnected" });
      failed++;
      continue;
    }
    const r = await sendSms(f, cfg, m.phone, m.body);
    if ("id" in r) {
      await sb.rpc("exos_rsvp_sms_mark", { p_id: m.id, p_status: "sent" });
      sent++;
    } else {
      await sb.rpc("exos_rsvp_sms_mark", { p_id: m.id, p_status: r.retry ? "queued" : "failed", p_error: r.error });
      if (!r.retry) failed++;
    }
  }
  return { sent, failed };
}
