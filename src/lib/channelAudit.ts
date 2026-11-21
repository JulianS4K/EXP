// "What we'd send" (channel core, mig 20261121162400): the writes the channel
// core planned for the org's channels while they are dry runs, with the
// payload it would have sent (secrets already redacted), and how much of
// each platform limit they would use. Owners / managers read
// exos_channel_audit under RLS and exos_channel_usage_summary.
//
// Pure helpers first (vitest), then the reads.

import { supabase } from './supabase';
import {
  meterLine, rulesFor, thresholdFor, type LimitFacts, type LimitMeter, type LimitWindow,
} from '../../supabase/functions/_shared/channels/limits.ts';

export interface ChannelAuditRow {
  id: string;
  channel: string;
  op: string;
  method: string;
  path: string;
  live: boolean;
  request: { headers?: Record<string, string>; body?: unknown } | null;
  response: Record<string, unknown> | null;
  status: number | null;
  ok: boolean | null;
  error: string | null;
  warnings: Array<{ ruleId?: string; action?: string; reason?: string; remaining?: number; would?: number }> | null;
  event_id: string | null;
  at: string;
}

export interface UsageSummaryRow {
  platform: string;
  metric: string;
  scope_key: string;
  live_day: number; planned_day: number;
  live_week: number; planned_week: number;
  live_year: number; planned_year: number;
}

export const CHANNEL_LABEL: Record<string, string> = {
  eventbrite: 'Eventbrite', luma: 'Luma', pretix: 'pretix', hievents: 'hi.events', dice: 'DICE', discord: 'Discord',
  stubhub: 'StubHub', seatgeek: 'SeatGeek', vivid: 'Vivid Seats', tickpick: 'TickPick', gametime: 'Gametime',
  gotickets: 'GoTickets', evo: 'Ticket Evolution', meetup: 'Meetup', shotgun: 'Shotgun', tickettailor: 'Ticket Tailor',
  allevents: 'AllEvents', linkedin: 'LinkedIn', google_events: 'Google events',
  // The ads phase (mig 20261121190500): dry runs only.
  meta_ads: 'Meta Ads', reddit_ads: 'Reddit Ads', reddit: 'Reddit', google_customer_match: 'Google Customer Match', x_ads: 'X Ads',
  // The social posting / listing phase (mig 20261121203000): dry runs only.
  instagram: 'Instagram', tiktok: 'TikTok', google_business: 'Google Business Profile',
};

/** What an ad step does, in words ("What we'd send" and the Boost preview). */
export const AD_STEP_LABEL: Record<string, string> = {
  'campaign.create': 'Create the campaign (paused)',
  'adset.create': 'Create the ad set (paused)',
  'ad_group.create': 'Create the ad group (paused)',
  'creative.create': 'Create the ad creative',
  'post.create': 'Create the ad post',
  'ad.create': 'Create the ad (paused)',
  'audience.create': 'Create the audience',
  'audience.add_users': 'Upload hashed people to the audience',
  'audience.add_members': 'Upload hashed people to the list',
  'conversion.send': 'Report a purchase',
  // Social posts and listings (mig 20261121203000).
  'post.container': 'Upload the post (a container)',
  'post.publish': 'Publish the post',
  'post.creator_info': 'Check what the account may post',
  'post.init': 'Post (TikTok pulls the image)',
  'post.local_post': 'Post the event on the Business Profile',
  'event.create_draft': 'Create the event (draft)',
  'event.publish': 'Publish the draft',
  'event.allocation': 'Set the attendee limit',
  'event.create_on_page': 'Create the event on the page',
};
export const stepLabel = (op: string): string => AD_STEP_LABEL[op] ?? op;
export const channelLabel = (id: string): string => CHANNEL_LABEL[id] ?? id;

/** Planned writes, newest first, grouped by channel (channels in order of their latest plan). */
export function groupPlanned(rows: ChannelAuditRow[]): Array<{ channel: string; label: string; rows: ChannelAuditRow[] }> {
  const planned = rows.filter((r) => !r.live && r.method !== 'GET' && r.method !== 'HEAD')
    .sort((a, b) => b.at.localeCompare(a.at));
  const out: Array<{ channel: string; label: string; rows: ChannelAuditRow[] }> = [];
  for (const r of planned) {
    let g = out.find((x) => x.channel === r.channel);
    if (!g) out.push(g = { channel: r.channel, label: channelLabel(r.channel), rows: [] });
    g.rows.push(r);
  }
  return out;
}

const pick = (row: UsageSummaryRow, w: LimitWindow | null): { live: number; planned: number } =>
  w === 'day' ? { live: row.live_day, planned: row.planned_day }
    : w === 'week' ? { live: row.live_week, planned: row.planned_week }
      : { live: row.live_year, planned: row.planned_year };

/** One meter per counted rule the summary has usage for: "would use N of M" (planned on top of live). */
export function usageMeters(summary: UsageSummaryRow[], facts: Record<string, LimitFacts> = {}): Array<LimitMeter & { scope: string; line: string }> {
  const out: Array<LimitMeter & { scope: string; line: string }> = [];
  for (const row of summary) {
    for (const r of rulesFor(row.platform)) {
      if (r.kind !== 'usage' || r.metric !== row.metric) continue;
      const t = thresholdFor(r, facts[row.platform] ?? {});
      if (t === null) continue;
      // A per-minute rate (Reddit) isn't a budget the summary's windows can show.
      if (r.window === 'minute' || r.window === 'quarter_hour') continue;
      const u = pick(row, r.window);
      // The plans are what switching on would add: "would use live + planned of M".
      const m: LimitMeter = { ruleId: r.id, platform: r.platform, metric: r.metric, window: r.window, threshold: t, live: u.live, planned: u.planned, would: u.planned };
      out.push({ ...m, scope: row.scope_key, line: meterLine(m) });
    }
  }
  return out;
}

/** The payload as the panel shows it: pretty JSON, capped. */
export function payloadText(r: ChannelAuditRow, max = 4000): string {
  const text = JSON.stringify(r.request?.body ?? null, null, 2) ?? 'null';
  return text.length > max ? `${text.slice(0, max)}\n… (${text.length - max} more characters)` : text;
}

const COLS = 'id, channel, op, method, path, live, request, response, status, ok, error, warnings, event_id, at';

/** The org's latest planned (dry-run) writes. */
export async function fetchPlannedWrites(orgId: string, limit = 50): Promise<ChannelAuditRow[]> {
  const { data, error } = await supabase.from('exos_channel_audit').select(COLS)
    .eq('org_id', orgId).eq('live', false).order('at', { ascending: false }).limit(limit);
  if (error) throw error;
  return (data ?? []) as ChannelAuditRow[];
}

export async function fetchUsageSummary(orgId: string): Promise<UsageSummaryRow[]> {
  const { data, error } = await supabase.rpc('exos_channel_usage_summary', { p_org_id: orgId });
  if (error) throw error;
  return Array.isArray(data) ? data as UsageSummaryRow[] : [];
}
