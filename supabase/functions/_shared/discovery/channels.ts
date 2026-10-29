// Discovery channels: where an Exos event can be listed so fans find it
// (spec item 8, docs/organizer-guide.md "Discovery listings").
//
// Three kinds:
//   feed    Exos serves a feed the channel reads. The status is computed
//           from that feed's own eligibility rule (feedBlocker, catalogBlocker,
//           exos_calendar_public_feed), never stored.
//   api     Exos submits through the channel's API. None today: no channel
//           we checked takes an event with an org-level credential inside
//           the read-only rule (CLAUDE.md), see the notes on Edmtrain and
//           Meetup.
//   manual  A person submits the event on the channel's form and records
//           the result (queued -> submitted -> live / rejected) in
//           exos_discovery_publications (mig 20261029130000).
//
// The ids are mirrored by the seed of public.exos_discovery_channels in that
// migration; src/lib/discovery/channels.test.ts checks the two agree.
//
// Submission URLs were looked up on 2026-10-29 by web search (the pages
// themselves weren't reachable from the build session). `verified: true`
// means the channel's own help or submission page was found at that URL;
// false means only the channel's site is known.
//
// Pure: no Deno or Supabase imports.

export type DiscoveryKind = 'feed' | 'api' | 'manual';

/** Who does the submitting on a manual channel. */
export type Submitter = 'operator' | 'organizer';

export interface DiscoveryChannel {
  id: string;
  name: string;
  kind: DiscoveryKind;
  /** 'US', 'NYC', 'global', … */
  region: string;
  /** Manual channels: where to submit (or the help page that says how). */
  submissionUrl: string | null;
  verified: boolean;
  /** Manual channels: who can submit (the Exos operator, or only the organizer's own account). */
  submitter?: Submitter;
  /** Feed channels: what "live" means for this channel. */
  liveMeans?: string;
  notes: string;
}

export const DISCOVERY_CHANNELS: readonly DiscoveryChannel[] = [
  // ── feeds (status computed) ────────────────────────────────────────
  {
    id: 'google_events', name: 'Google Search & Maps (events feed)', kind: 'feed', region: 'global',
    submissionUrl: null, verified: true,
    liveMeans: 'in the exos-google-feed snapshot',
    notes: "Exos's events feed (docs/google-events.md). Google reads it once Exos is in Google's events ticketing program (not applied for yet). Event pages also carry schema.org JSON-LD for regular Search.",
  },
  {
    id: 'calendar_ics', name: 'Calendar feeds (Google / Apple / Outlook)', kind: 'feed', region: 'global',
    submissionUrl: null, verified: true,
    liveMeans: "in the organizer's subscribable .ics calendar",
    notes: 'exos-calendar org and venue calendars (docs/calendar.md). Subscribers see new events on their own.',
  },
  {
    id: 'ad_catalog', name: 'Ad catalogs (Meta, TikTok, Google Merchant)', kind: 'feed', region: 'global',
    submissionUrl: null, verified: true,
    liveMeans: "in the organizer's catalog feed",
    notes: 'exos-catalog-feed (docs/marketing-catalog.md). The platforms only read it once the organizer adds the feed URL in their catalog manager.',
  },
  // ── manual (queued, worked by a person) ────────────────────────────
  {
    id: 'donyc', name: 'DoNYC', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://donyc.com/p/how-to-nyc', verified: true, submitter: 'operator',
    notes: 'Register on the site, then email DoNYC to ask for event-editing rights (granted per account, anti-spam). After that, "Add Event".',
  },
  {
    id: 'timeout_nyc', name: 'Time Out New York', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://www.timeout.com/newyork/get-listed', verified: true, submitter: 'operator',
    notes: 'Editorial: event listings go by email to the section editor (music, comedy, nightlife…); venues use the form. No guarantee of a listing.',
  },
  {
    id: 'cityspark', name: 'CitySpark local calendars', kind: 'manual', region: 'US',
    submissionUrl: 'https://intercom.help/cityspark/en/articles/12429064-how-to-submit-an-event-to-cityspark', verified: true, submitter: 'operator',
    notes: 'One submission (free, account needed) is shared to every CitySpark-powered calendar near the venue (local papers, TV station sites) within 24-48 h. Submit once: a second copy makes duplicates. Listings are managed at hub.cityspark.com.',
  },
  {
    id: 'resident_advisor', name: 'Resident Advisor (RA)', kind: 'manual', region: 'global',
    submissionUrl: 'https://support.ra.co/article/12-submitting-events', verified: true, submitter: 'organizer',
    notes: "Electronic music. Submitted from a promoter account (RA Pro); RA reviews each event. Check whether RA accepts an outside ticket link for the event or wants tickets on RA.",
  },
  {
    id: 'oh_my_rockness', name: 'Oh My Rockness', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://www.ohmyrockness.com', verified: false, submitter: 'operator',
    notes: 'Hand-curated listings of (mostly small) shows. No public submission form found; contact them through the site.',
  },
  {
    id: 'edmtrain', name: 'Edmtrain', kind: 'manual', region: 'US',
    submissionUrl: 'https://edmtrain.com', verified: false, submitter: 'operator',
    notes: "Electronic music. The Edmtrain API is read-only (event and location listings with a client key); it takes no submissions. The site has \"Add Event\" (sign-in) and \"Promote Your Event\" links.",
  },
  {
    id: 'meetup', name: 'Meetup', kind: 'manual', region: 'global',
    submissionUrl: 'https://www.meetup.com', verified: false, submitter: 'organizer',
    notes: "Events live in the organizer's own Meetup group, so the organizer posts it. Meetup's GraphQL API has createEvent, but only for a group organizer with Meetup Pro and an approved OAuth client, and it would be a new third-party write: an operator decision, not built.",
  },
  {
    id: 'songkick', name: 'Songkick', kind: 'manual', region: 'global',
    submissionUrl: 'https://support.songkick.com/hc/en-us/articles/360011925897', verified: true, submitter: 'organizer',
    notes: 'Promoters and venues use "Add an event" in the site footer (signed in); artists use Tourbox. Unconfirmed reports that Songkick is shutting down: check before spending time on it.',
  },
  {
    id: 'bandsintown', name: 'Bandsintown', kind: 'manual', region: 'global',
    submissionUrl: 'https://help.artists.bandsintown.com/en/articles/7039442-add-an-event', verified: true, submitter: 'organizer',
    notes: "Each artist adds the date in Bandsintown for Artists (a lineup entry doesn't add it to the other artists' pages). The ticketing-partner feed (KANBAN) would replace this.",
  },
];

const BY_ID = new Map(DISCOVERY_CHANNELS.map((c) => [c.id, c]));

export function discoveryChannel(id: string): DiscoveryChannel | undefined {
  return BY_ID.get(id);
}

export const MANUAL_CHANNELS = DISCOVERY_CHANNELS.filter((c) => c.kind === 'manual');
export const FEED_CHANNELS = DISCOVERY_CHANNELS.filter((c) => c.kind === 'feed');

/** Stored statuses (exos_discovery_publications.status). */
export type PublicationStatus = 'not_submitted' | 'queued' | 'submitted' | 'live' | 'rejected' | 'removed';
export const PUBLICATION_STATUSES: readonly PublicationStatus[] = ['not_submitted', 'queued', 'submitted', 'live', 'rejected', 'removed'];

/** What the organizer screen shows per channel. Feed channels are 'live' or 'not_eligible'. */
export type ChannelStatus = PublicationStatus | 'not_eligible';

export const STATUS_LABEL: Record<ChannelStatus, string> = {
  not_submitted: 'Not submitted',
  queued: 'Queued',
  submitted: 'Submitted',
  live: 'Live',
  rejected: 'Rejected',
  removed: 'Removed',
  not_eligible: 'Not listed',
};

/** A feed channel's status from that feed's own blocker (null = in the feed). */
export function feedStatus(blocker: string | null): { status: 'live' | 'not_eligible'; reason: string | null } {
  return blocker ? { status: 'not_eligible', reason: blocker } : { status: 'live', reason: null };
}

/** Status moves the RPC accepts (exos_discovery_set_status); 'queued' comes from exos_discovery_queue. */
export const NEXT_STATUSES: Record<PublicationStatus, readonly PublicationStatus[]> = {
  not_submitted: [],
  queued: ['submitted', 'live', 'rejected'],
  submitted: ['live', 'rejected'],
  live: ['removed'],
  rejected: [],
  removed: [],
};

/** Can this record be (re)queued? Mirrors exos_discovery_queue. */
export function canQueue(status: PublicationStatus | null | undefined): boolean {
  return !status || status === 'not_submitted' || status === 'rejected' || status === 'removed';
}

/** Free tier (operator, spec rev de8877d): events whose max capacity is at or
 *  under the cutoff (exos_platform_settings 'free_tier_max_capacity', default
 *  150) can use at most this many manual channels. Mirrors
 *  _exos_discovery_manual_cap; exos_discovery_event_channels returns the
 *  event's cap (null = none) and how many it uses. */
export const FREE_TIER_MANUAL_CAP = 5;
export const FREE_TIER_MAX_CAPACITY_DEFAULT = 150;

/** Does queueing this channel need a free slot (it isn't counted yet)? Mirrors exos_discovery_queue. */
export function takesSlot(status: PublicationStatus | null | undefined): boolean {
  return !status || status === 'not_submitted';
}

/** Could this event queue a manual channel it isn't using yet? */
export function hasManualSlot(cap: number | null | undefined, used: number): boolean {
  return cap == null || used < cap;
}

/** Minutes the operator logs per step (exos_discovery_set_status p_minutes, 0-600). */
export function parseMinutes(v: string | null | undefined): number | null | 'invalid' {
  const t = (v ?? '').trim();
  if (t === '') return null;
  if (!/^\d{1,3}$/.test(t)) return 'invalid';
  const n = Number(t);
  return n <= 600 ? n : 'invalid';
}
