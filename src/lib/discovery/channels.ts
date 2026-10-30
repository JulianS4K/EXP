// Discovery listings for one event (mig 20261029130000, docs/organizer-guide.md
// "Discovery listings"). Pure: turns exos_discovery_event_channels' answer
// into one row per channel. Feed channels are computed with the feeds' own
// rules (Google: feedBlocker, ad catalog: catalogBlocker, calendar: the RPC's
// verdict from exos_calendar_public_feed); manual channels show their record.

import { feedBlocker, type FeedEventRow, type FeedTierRow } from '../../../supabase/functions/_shared/googleEvents/feed.ts';
import { catalogBlocker, type CatalogEventRow, type CatalogTierRow } from '../../../supabase/functions/_shared/catalog/feed.ts';
import {
  discoveryChannel,
  feedStatus,
  type ChannelStatus,
  type DiscoveryChannel,
  type DiscoveryKind,
  type PublicationStatus,
} from '../../../supabase/functions/_shared/discovery/channels.ts';

export interface PublicationRecord {
  id: string;
  event_id?: string;
  channel_id?: string;
  status: PublicationStatus;
  live_url?: string | null;
  rejection_reason?: string | null;
  next_action?: string | null;
  note?: string | null;
  queued_at?: string | null;
  submitted_at?: string | null;
  decided_at?: string | null;
  updated_at?: string | null;
  minutes_spent?: number;
}

/** _exos_discovery_event_json: the event's feed columns + public tiers. */
export type DiscoveryEvent = FeedEventRow & CatalogEventRow & {
  org_name?: string | null;
  org_slug?: string | null;
  tiers: Array<FeedTierRow & CatalogTierRow>;
};

export interface EventChannelsResponse {
  event: DiscoveryEvent;
  calendar: { status: 'live' | 'not_eligible'; reason: string | null };
  can_edit: boolean;
  /** Free-tier cap on manual channels (null = no cap) and how many this event uses. */
  manual_cap?: number | null;
  manual_used?: number;
  /** Manual minutes logged on this event (discovery pilot). */
  minutes_spent?: number;
  channels: Array<{
    id: string; name: string; kind: DiscoveryKind; region: string;
    submission_url: string | null; verified: boolean;
    publication: PublicationRecord | null;
  }>;
}

export interface DiscoveryRow {
  id: string;
  name: string;
  kind: DiscoveryKind;
  region: string;
  submissionUrl: string | null;
  verified: boolean;
  status: ChannelStatus;
  /** Feed channels: why the event isn't in the feed. Manual: the rejection reason. */
  reason: string | null;
  liveUrl: string | null;
  nextAction: string | null;
  publication: PublicationRecord | null;
  /** The code-side entry (notes, submitter, what live means). */
  info: DiscoveryChannel | undefined;
}

export function discoveryRows(r: EventChannelsResponse, now: Date = new Date()): DiscoveryRow[] {
  const e = r.event;
  const tiers = Array.isArray(e.tiers) ? e.tiers : [];
  return r.channels.map((c) => {
    const base = {
      id: c.id, name: c.name, kind: c.kind, region: c.region, submissionUrl: c.submission_url,
      verified: c.verified, info: discoveryChannel(c.id),
    };
    if (c.kind === 'feed') {
      const v = c.id === 'google_events' ? feedStatus(feedBlocker(e, tiers, now))
        : c.id === 'ad_catalog' ? feedStatus(e.status === 'published' ? catalogBlocker(e, tiers, now) : 'not published')
        : c.id === 'calendar_ics' ? r.calendar
        : { status: 'not_eligible' as const, reason: 'no status for this feed yet' };
      return { ...base, status: v.status, reason: v.reason, liveUrl: null, nextAction: null, publication: null };
    }
    const p = c.publication;
    return {
      ...base,
      status: p?.status ?? 'not_submitted',
      reason: p?.status === 'rejected' ? p.rejection_reason ?? null : null,
      liveUrl: p?.live_url ?? null,
      nextAction: p?.next_action ?? null,
      publication: p,
    };
  });
}
