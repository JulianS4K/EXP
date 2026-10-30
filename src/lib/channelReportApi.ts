// Reads / settings for sales by channel and the weekly report (mig
// 20261029120000). Parsing is the shared reader the weekly mail uses
// (supabase/functions/_shared/channelReport.ts), so screen and mail agree.

import { supabase } from './supabase';
import {
  parseChannelReport, parseEventChannels, type ChannelReport, type EventChannels,
} from '../../supabase/functions/_shared/channelReport.ts';

export interface EventChannelReport extends EventChannels {
  from: string | null;
  to: string | null;
}

/** The event's channels: last full ISO week + to date. null when unavailable (older DB / no access). */
export async function getEventChannelReport(eventId: string): Promise<EventChannelReport | null> {
  const { data, error } = await supabase.rpc('exos_event_channel_report', { p_event_id: eventId });
  if (error) {
    console.warn('channel report unavailable (non-fatal):', error.message);
    return null;
  }
  const e = parseEventChannels(data);
  if (!e) return null;
  const d = data as { from?: unknown; to?: unknown };
  return { ...e, from: typeof d.from === 'string' ? d.from : null, to: typeof d.to === 'string' ? d.to : null };
}

/** The org's weekly report, as the Monday mail carries it. */
export async function getOrgChannelReport(orgId: string, weekStart?: string): Promise<ChannelReport | null> {
  const { data, error } = await supabase.rpc('exos_org_channel_report', { p_org_id: orgId, p_week_start: weekStart ?? null });
  if (error) {
    console.warn('org channel report unavailable (non-fatal):', error.message);
    return null;
  }
  return parseChannelReport(data);
}

export interface ChannelReportSettings {
  enabled: boolean;
  smsPhoneHint: string | null;
  smsProvider: string | null;
  canEdit: boolean;
  lastWeek: string | null;
}

function parseSettings(d: any): ChannelReportSettings {
  return {
    enabled: d?.enabled !== false,
    smsPhoneHint: typeof d?.sms_phone_hint === 'string' ? d.sms_phone_hint : null,
    smsProvider: typeof d?.sms_provider === 'string' ? d.sms_provider : null,
    canEdit: d?.can_edit === true,
    lastWeek: typeof d?.last_week === 'string' ? d.last_week : null,
  };
}

export async function getChannelReportSettings(orgId: string): Promise<ChannelReportSettings | null> {
  const { data, error } = await supabase.rpc('exos_channel_report_settings', { p_org_id: orgId });
  if (error) return null;
  return parseSettings(data);
}

/** Owner: on / off, and the weekly text's number: null keeps it, '' clears it, else the new number. */
export async function setChannelReport(orgId: string, enabled: boolean, smsPhone: string | null): Promise<ChannelReportSettings> {
  const { data, error } = await supabase.rpc('exos_set_channel_report', {
    p_org_id: orgId, p_enabled: enabled, p_sms_phone: smsPhone === null ? null : smsPhone.trim(),
  });
  if (error) throw new Error(error.message.replace(/^exos_\w+: /, ''));
  return parseSettings(data);
}
