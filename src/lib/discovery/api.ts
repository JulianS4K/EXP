// RPC calls for discovery listings (mig 20261029130000). Nothing here talks
// to a third party: Exos only records what a person did on the channel.

import { supabase } from '../supabase';
import type { DiscoveryEvent, EventChannelsResponse, PublicationRecord } from './channels';
import type { PublicationStatus } from '../../../supabase/functions/_shared/discovery/channels.ts';

export async function eventChannels(eventId: string): Promise<EventChannelsResponse> {
  const { data, error } = await supabase.rpc('exos_discovery_event_channels', { p_event_id: eventId });
  if (error) throw error;
  return data as EventChannelsResponse;
}

export async function queueListing(eventId: string, channelId: string, note?: string): Promise<PublicationRecord> {
  const { data, error } = await supabase.rpc('exos_discovery_queue', { p_event_id: eventId, p_channel_id: channelId, p_note: note ?? null });
  if (error) throw error;
  return data as PublicationRecord;
}

export async function withdrawListing(eventId: string, channelId: string): Promise<PublicationRecord> {
  const { data, error } = await supabase.rpc('exos_discovery_withdraw', { p_event_id: eventId, p_channel_id: channelId });
  if (error) throw error;
  return data as PublicationRecord;
}

export async function setListingStatus(
  publicationId: string, status: PublicationStatus,
  opts: { liveUrl?: string; reason?: string; nextAction?: string; minutes?: number | null } = {},
): Promise<PublicationRecord> {
  const { data, error } = await supabase.rpc('exos_discovery_set_status', {
    p_publication_id: publicationId, p_status: status,
    p_live_url: opts.liveUrl ?? null, p_reason: opts.reason ?? null, p_next_action: opts.nextAction ?? null,
    p_minutes: opts.minutes ?? null,
  });
  if (error) throw error;
  return data as PublicationRecord;
}

export interface QueueItem extends PublicationRecord {
  channel_name: string;
  submission_url: string | null;
  event: DiscoveryEvent;
}

export interface MinutesByOrg {
  org_id: string;
  org_name: string;
  minutes: number;
  events: number;
  submissions: number;
  minutes_per_event: number;
  by_event: Array<{ event_id: string; name: string; starts_at: string | null; minutes: number; submissions: number; channels: Record<string, number> }>;
}

/** Manual minutes per event and per org (discovery pilot). No org: every org, operator only. */
export async function discoveryMinutes(orgId?: string, since?: string, until?: string): Promise<MinutesByOrg[]> {
  const { data, error } = await supabase.rpc('exos_discovery_minutes', {
    p_org_id: orgId ?? null, p_since: since ?? null, p_until: until ?? null,
  });
  if (error) throw error;
  return (data ?? []) as MinutesByOrg[];
}

/** Operator only (exos_is_admin). */
export async function listingQueue(status: PublicationStatus = 'queued', channelId?: string): Promise<QueueItem[]> {
  const { data, error } = await supabase.rpc('exos_discovery_queue_list', {
    p_status: status, p_channel_id: channelId ?? null, p_limit: 200,
  });
  if (error) throw error;
  return (data ?? []) as QueueItem[];
}
