// SMS marketing (mig 20261016120000): fan opt-in with stored consent, and
// organizer campaigns sent from the org's own Twilio / Telnyx number.

import { supabase } from './supabase';

/** The exact words a fan agrees to (stored with their opt-in). */
export function consentText(orgName: string): string {
  return `Text me about ${orgName}'s events at this number. Up to 8 msgs/month. Msg & data rates may apply. ` +
    'Reply STOP to cancel, HELP for help. Consent is not a condition of purchase.';
}

/** +E.164 from what a fan typed (US / CA 10 digits assumed without a +). */
export function normalizePhone(raw: string): string | null {
  const s = raw.replace(/[^0-9+]/g, '');
  if (/^\+[1-9][0-9]{7,14}$/.test(s)) return s;
  if (/^[2-9][0-9]{9}$/.test(s)) return `+1${s}`;
  if (/^1[2-9][0-9]{9}$/.test(s)) return `+${s}`;
  return null;
}

const SUFFIX = ' Reply STOP to opt out.';

/** What the fan's phone shows: "<org>: <text> Reply STOP to opt out." */
export function finalBody(orgName: string, body: string): string {
  return `${orgName.slice(0, 40)}: ${body.trim()}${SUFFIX}`;
}

/** SMS segments (GSM-7: 160 / 153; anything else UCS-2: 70 / 67). Carriers bill per segment. */
export function segments(text: string): { count: number; unicode: boolean } {
  // deno-lint-ignore no-control-regex
  const gsm = /^[\n\r -~£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¡ÄÖÑÜ§¿äöñüà€^{}\\[\]~|]*$/.test(text);
  const n = [...text].length;
  if (gsm) return { count: n <= 160 ? 1 : Math.ceil(n / 153), unicode: false };
  return { count: n <= 70 ? 1 : Math.ceil(n / 67), unicode: true };
}

export interface SmsCampaign {
  id: string; audience: 'org' | 'event_buyers'; eventId: string | null; body: string; status: string;
  sendAfter: Date; createdAt: Date; queued: number; skippedCap: number; sent: number; dryRun: number; failed: number;
}

export interface SmsOverview { subscribers: number; optedOut: number; provider: string | null; campaigns: SmsCampaign[] }

export function parseOverview(d: any): SmsOverview {
  return {
    subscribers: Number(d?.subscribers) || 0,
    optedOut: Number(d?.opted_out) || 0,
    provider: d?.provider ?? null,
    campaigns: (Array.isArray(d?.campaigns) ? d.campaigns : []).map((c: any) => ({
      id: String(c.id), audience: c.audience === 'event_buyers' ? 'event_buyers' : 'org', eventId: c.event_id ?? null,
      body: String(c.body ?? ''), status: String(c.status ?? ''), sendAfter: new Date(c.send_after), createdAt: new Date(c.created_at),
      queued: Number(c.queued) || 0, skippedCap: Number(c.skipped_cap) || 0, sent: Number(c.sent) || 0,
      dryRun: Number(c.dry_run) || 0, failed: Number(c.failed) || 0,
    })),
  };
}

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, ''));

export async function optIn(orgId: string, orgName: string, phone: string, eventId?: string | null, source = 'ticket') {
  const { data, error } = await supabase.rpc('exos_sms_opt_in', {
    p_org_id: orgId, p_phone: phone, p_consent_text: consentText(orgName), p_event_id: eventId ?? null, p_source: source,
  });
  if (error) throw msg(error);
  return data as { subscribed: boolean; phone: string };
}

export async function myStatus(orgId: string): Promise<{ subscribed: boolean; phoneHint: string } | null> {
  const { data, error } = await supabase.rpc('exos_sms_my_status', { p_org_id: orgId });
  if (error || !data) return null;
  return { subscribed: data.subscribed === true, phoneHint: String(data.phone_hint ?? '') };
}

export async function optOut(orgId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_sms_opt_out_mine', { p_org_id: orgId });
  if (error) throw msg(error);
}

export async function smsOverview(orgId: string): Promise<SmsOverview> {
  const { data, error } = await supabase.rpc('exos_sms_campaigns', { p_org_id: orgId });
  if (error) throw msg(error);
  return parseOverview(data);
}

export async function audienceSize(orgId: string, audience: 'org' | 'event_buyers', eventId?: string) {
  const { data, error } = await supabase.rpc('exos_sms_audience', { p_org_id: orgId, p_audience: audience, p_event_id: eventId ?? null });
  if (error) throw msg(error);
  return { total: Number(data?.total) || 0, capped: Number(data?.capped) || 0, reachable: Number(data?.reachable) || 0 };
}

export async function createCampaign(orgId: string, body: string, audience: 'org' | 'event_buyers', eventId?: string, sendAt?: Date | null) {
  const { data, error } = await supabase.rpc('exos_sms_create_campaign', {
    p_org_id: orgId, p_body: body.trim(), p_audience: audience, p_event_id: eventId ?? null, p_send_at: sendAt ? sendAt.toISOString() : null,
  });
  if (error) throw msg(error);
  return { queued: Number(data?.queued) || 0, skippedCap: Number(data?.skipped_cap) || 0, sendAfter: new Date(data?.send_after) };
}

export async function cancelCampaign(id: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_sms_cancel_campaign', { p_campaign_id: id });
  if (error) throw msg(error);
  return Number(data) || 0;
}
