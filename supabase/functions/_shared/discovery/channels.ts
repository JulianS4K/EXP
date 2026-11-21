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
// Genres (2026-11-21): each channel lists the event categories it suits
// (MarketCategory, derived by marketCategory). The organizer's Discovery
// listings show the channels for the event's category first and hide the
// rest behind "Show all channels". GENRE_CHANNELS below is the one place the
// mapping lives; the operator can change it there.
//
// Pure: no Deno or Supabase imports.

import type { MarketCategory } from '../marketplace/eventStandard.ts';
import { regionApplies, type CityConfig } from './cities.ts';

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
  /** Manual channels: the steps to submit, shown under "How to submit". */
  steps?: readonly string[];
  /** Manual channels with no known way to submit (no URL): shown as "How to submit: unknown". */
  howToSubmit?: 'unknown';
  /** The event categories this channel suits, from GENRE_CHANNELS ('all' = every event). */
  genres: readonly MarketCategory[] | 'all';
  /** Narrower than the category: e.g. Resident Advisor lists electronic music only. */
  subgenre?: string;
  notes: string;
}

type ChannelSpec = Omit<DiscoveryChannel, 'genres'>;

const CHANNEL_SPECS: readonly ChannelSpec[] = [
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
    submissionUrl: 'https://support.ra.co/article/12-submitting-events', verified: true, submitter: 'organizer', subgenre: 'electronic',
    notes: "Electronic music. Submitted from a promoter account (RA Pro); RA reviews each event. Check whether RA accepts an outside ticket link for the event or wants tickets on RA.",
  },
  {
    id: 'oh_my_rockness', name: 'Oh My Rockness', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://www.ohmyrockness.com', verified: false, submitter: 'operator',
    notes: 'Hand-curated listings of (mostly small) shows. No public submission form found; contact them through the site.',
  },
  {
    id: 'edmtrain', name: 'Edmtrain', kind: 'manual', region: 'US',
    submissionUrl: 'https://edmtrain.com', verified: false, submitter: 'operator', subgenre: 'electronic',
    notes: "Electronic music. The Edmtrain API is read-only (event and location listings with a client key); it takes no submissions. The site has \"Add Event\" (sign-in) and \"Promote Your Event\" links.",
  },
  {
    id: 'meetup', name: 'Meetup', kind: 'manual', region: 'global',
    submissionUrl: 'https://www.meetup.com', verified: false, submitter: 'organizer',
    notes: "Events live in the organizer's own Meetup group, so the organizer posts it. Meetup's GraphQL API has createEvent, but only for a group organizer with Meetup Pro and an approved OAuth client, and it would be a new third-party write: an operator decision, not built.",
  },
  {
    id: 'bandsintown', name: 'Bandsintown', kind: 'manual', region: 'global',
    submissionUrl: 'https://help.artists.bandsintown.com/en/articles/7039442-add-an-event', verified: true, submitter: 'organizer',
    notes: "Each artist adds the date in Bandsintown for Artists (a lineup entry doesn't add it to the other artists' pages). The ticketing-partner feed (KANBAN) would replace this.",
  },
  {
    // Posh "Third-Party Links" (2026-10-05): a Posh event page whose Get
    // Tickets button opens an outside ticket page. No API: the organizer makes
    // it by hand on posh.vip. Seeded by mig 20261104150000; refused for
    // link-out events (src/lib/discovery/poshLink.ts, _exos_posh_link_blocked).
    // No Posh help page for it was found, so the link is the site.
    id: 'posh_link', name: 'Posh (third-party link)', kind: 'manual', region: 'global',
    submissionUrl: 'https://posh.vip', verified: false, submitter: 'organizer',
    steps: [
      'Sign in to Posh on the web (posh.vip). Creating and editing these events is web-only for now, not in the Posh app.',
      'Open Create Event and pick External tickets (next to Sell tickets and RSVP).',
      'Fill in the event from the Posh kit below (title, date and time, venue, description, image).',
      'Paste the Exos ticket link from the kit as the external ticket URL, so Get Tickets on Posh opens Exos.',
      'Publish on Posh, then come back and mark it live here with the Posh event link.',
    ],
    notes: "Your event gets a Posh page; Get Tickets sends fans to your Exos ticket link, and they buy on Exos. Free to list. Posh counts page views and ticket-link clicks on its side: enter them here to see views -> clicks -> Exos orders. Exos never writes to Posh. Not for events you sell on Posh.",
  },
  // ── added 2026-11-21 (promotion: genre-aware channels) ─────────────
  // Checked 2026-11-21: The Skint's form and AllEvents' publishing page were
  // read on the sites; Spotify's help page was found by search. Fever's free
  // listing (its "0% Commission Link") is only described in Fever's terms; no
  // public page for it was found, so the link is Fever's business site.
  // Nonsense NYC: no submission method found, so no link.
  {
    id: 'the_skint', name: 'The Skint', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://theskint.com/submit-an-event/', verified: true, submitter: 'operator',
    notes: 'Free and cheap NYC events, hand-picked daily. A web form (date, time, price, RSVP, description, event link, contact). Curated: a submission is not a guarantee. Paid placements are a separate form.',
  },
  {
    id: 'allevents', name: 'AllEvents', kind: 'manual', region: 'global',
    submissionUrl: 'https://allevents.in/pages/publish-events', verified: true, submitter: 'organizer',
    notes: 'Free to post (sign in, set up a brand page, then "Post Event"). Post it with your Exos ticket link; AllEvents also sells tickets, which you don\'t need.',
  },
  {
    id: 'fever', name: 'Fever (free listing)', kind: 'manual', region: 'global',
    submissionUrl: 'https://business.feverup.com', verified: false, submitter: 'organizer',
    notes: "Fever's terms describe a free listing through its 0% Commission Link (fees only when tickets sell on Fever). No public page for it was found: ask Fever's organizer team through the business site's contact form, and list with your Exos ticket link.",
  },
  {
    id: 'nonsense_nyc', name: 'Nonsense NYC', kind: 'manual', region: 'NYC',
    submissionUrl: null, verified: false, submitter: 'operator', howToSubmit: 'unknown',
    notes: 'A weekly email of underground and odd NYC events, art and parties. How to submit is unknown: no form or address was found. It prefers plain-text details over a Partiful link. Record what worked here if you get a listing.',
  },
  {
    id: 'spotify', name: 'Spotify concerts', kind: 'manual', region: 'global',
    submissionUrl: 'https://support.spotify.com/artists/article/concerts', verified: true, submitter: 'organizer',
    notes: "Spotify lists concerts from its ticketing partners (Ticketmaster, AXS, ...). Exos isn't one, so each artist adds the date in Bandsintown, which Spotify reads; it shows on the artist's Spotify profile within about a day.",
  },
  {
    // Operator 2026-11-21 ("Also partiful"). No public API, and Partiful's
    // terms bar scraping and bots: nothing is automated or read. The
    // organizer makes an invite page on their own account with the Partiful
    // kit (src/lib/discovery/partiful.ts) and points guests to Exos checkout.
    id: 'partiful', name: 'Partiful', kind: 'manual', region: 'NYC',
    submissionUrl: 'https://partiful.com', verified: false, submitter: 'organizer',
    steps: [
      'Create the event on your own Partiful account (partiful.com or the app).',
      'Fill it in from the Partiful kit below: title, date and time, venue, description, cover image.',
      'Put the Exos ticket link from the kit in the description and the event link, so guests buy on Exos.',
      'Share the Partiful link or invite guests, then mark it live here with the Partiful event link.',
    ],
    notes: 'The invite and RSVP page for a party crowd; tickets stay on Exos. Free events take unlimited guests by link; in-app invites are capped at 1,000 per event. Nothing is sent to or read from Partiful.',
  },
  // Lowest priority: reports that Songkick is winding down.
  {
    id: 'songkick', name: 'Songkick', kind: 'manual', region: 'global',
    submissionUrl: 'https://support.songkick.com/hc/en-us/articles/360011925897', verified: true, submitter: 'organizer',
    notes: 'Promoters and venues use "Add an event" in the site footer (signed in); artists use Tourbox. Unconfirmed reports that Songkick is shutting down: check before spending time on it.',
  },
];

// The default category -> channel mapping, best first (operator 2026-11-21;
// change it here). 'all' channels suit every event (the feeds, and the
// general calendars and listing sites). Festivals suit every channel, Fever
// first. Sports and other have no channels of their own beyond 'all' and
// AllEvents.
const EVERY = CHANNEL_SPECS.map((c) => c.id);
export const GENRE_CHANNELS: Readonly<Record<MarketCategory | 'all', readonly string[]>> = {
  all: ['google_events', 'calendar_ics', 'ad_catalog', 'cityspark', 'posh_link'],
  concerts: ['bandsintown', 'spotify', 'donyc', 'oh_my_rockness', 'songkick'],
  nightlife: ['resident_advisor', 'edmtrain', 'nonsense_nyc', 'partiful'],
  comedy: ['timeout_nyc', 'the_skint', 'donyc'],
  theater: ['timeout_nyc'],
  festivals: ['fever', ...EVERY.filter((id) => id !== 'fever')],
  food_drink: ['timeout_nyc', 'the_skint', 'fever'],
  community: ['meetup', 'allevents', 'the_skint', 'partiful'],
  business: ['meetup', 'allevents', 'the_skint'],
  sports: [],
  other: ['allevents'],
};

const CATEGORY_KEYS = Object.keys(GENRE_CHANNELS).filter((k) => k !== 'all') as MarketCategory[];

function genresOf(id: string): readonly MarketCategory[] | 'all' {
  if (GENRE_CHANNELS.all.includes(id)) return 'all';
  return CATEGORY_KEYS.filter((k) => GENRE_CHANNELS[k].includes(id));
}

export const DISCOVERY_CHANNELS: readonly DiscoveryChannel[] = CHANNEL_SPECS.map((c) => ({ ...c, genres: genresOf(c.id) }));

const BY_ID = new Map(DISCOVERY_CHANNELS.map((c) => [c.id, c]));

/** Does this channel suit an event of this category? */
export function suitsCategory(c: Pick<DiscoveryChannel, 'genres'>, category: MarketCategory): boolean {
  return c.genres === 'all' || c.genres.includes(category);
}

/**
 * Order channels for an event's category and city: the category's own
 * channels in GENRE_CHANNELS order, then the all-genre ones (catalog order),
 * then (only with showAll) the rest in catalog order. With `city` (the
 * event's, from cities.ts; null = not a configured city), a city-only channel
 * (DoNYC, region 'NYC') fits only events in that city, so other events fall
 * back to the channels with no city region. A channel the event already has
 * a record on (`keep`) is never hidden.
 */
export function rankChannels<T extends { id: string }>(
  items: readonly T[], category: MarketCategory,
  opts: { showAll?: boolean; keep?: (item: T) => boolean; city?: CityConfig | null; us?: boolean } = {},
): Array<T & { fits: boolean }> {
  const own = GENRE_CHANNELS[category];
  const catalog = new Map(EVERY.map((id, i) => [id, i]));
  const score = (id: string): number => {
    const i = own.indexOf(id);
    if (i >= 0) return i;
    if (GENRE_CHANNELS.all.includes(id)) return 1000 + (catalog.get(id) ?? 999);
    return 2000 + (catalog.get(id) ?? 999);
  };
  return items
    .map((it) => {
      const c = BY_ID.get(it.id);
      const inCity = !c || opts.city === undefined || regionApplies(c.region, opts.city, opts.us ?? true);
      return { ...it, fits: (c ? suitsCategory(c, category) : true) && inCity };
    })
    .filter((it) => opts.showAll || it.fits || (opts.keep?.(it) ?? false))
    .sort((a, b) => score(a.id) - score(b.id));
}


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
