// One interface over the resale marketplaces Exos distributes into.
//
// Each marketplace is a MarketplaceChannel adapter. StubHub is the only one
// wired today (./stubhub/channel.ts); the others plug in the same way.
// The edge functions (exos-distribute, exos-marketplace-sales) run every
// channel the same way:
//
//   1. link    Exos event -> the channel's event id. findEvents() (read-only
//              catalog search) + scoreMatch(); a confident match is linked,
//              a close call is left for a human (exos_channel_event_links).
//   2. create  when nothing matches and the channel allows it,
//              planCreateEvent() (StubHub: PUT /sellerevents).
//   3. sell    sales come back as MarketplaceSale via normalizeSale().
//   4. fulfil  Exos mints the tickets and a claim link per ticket; the
//              channel's planFulfilByUrls() is the call that hands those links
//              to the marketplace.
//
// Every call that changes something on a marketplace comes back as a
// PlannedRequest (dry-run). Sending one needs an operator WriteAuthorization
// (Hard Rule #2: upstream ticketing APIs are read-only by default).
//
// No imports beyond sibling .ts files: loaded by Deno and by vitest.

export const CHANNEL_IDS = ['stubhub', 'seatgeek', 'vivid', 'tickpick', 'evo', 'automatiq'] as const;
export type ChannelId = (typeof CHANNEL_IDS)[number];

export function isChannelId(v: unknown): v is ChannelId {
  return typeof v === 'string' && (CHANNEL_IDS as readonly string[]).includes(v);
}

/** An Exos event as the channels see it (from its exos_events row). */
export interface ExosEventRef {
  id: string;
  name: string;
  /** UTC instant. */
  startsAt: string;
  /** Venue-local wall clock, TEvo format "YYYY-MM-DDTHH:MM:SS±HH:MM", when known. */
  occursAtLocal?: string | null;
  venueName: string;
  venueCity?: string | null;
  venueRegion?: string | null;
  countryCode?: string | null;
}

/** An event in a channel's catalog. */
export interface EventCandidate {
  channel: ChannelId;
  externalEventId: string;
  name: string;
  /** UTC instant when the channel gives one. */
  startsAt?: string | null;
  /** The channel's local date/time ("YYYY-MM-DD" or "YYYY-MM-DDTHH:MM..."), when that's all it gives. */
  startsLocal?: string | null;
  venueName?: string | null;
  venueCity?: string | null;
  url?: string | null;
}

/** A call that would change something on a marketplace. Recorded, not sent. */
export interface PlannedRequest {
  channel: ChannelId;
  endpoint: string;
  method: 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  path: string;
  body?: unknown;
}

export type SaleStatus = 'pending' | 'confirmed' | 'delivered' | 'cancelled' | 'unknown';

/** A marketplace sale, in one shape across channels. */
export interface MarketplaceSale {
  channel: ChannelId;
  externalOrderId: string;
  externalEventId: string | null;
  /**
   * The listing it sold from. Exos lists with external_id = its
   * exos_distribution_listings.id, so this is how a sale finds its tier.
   */
  externalListingId: string | null;
  quantity: number;
  status: SaleStatus;
  buyerEmail: string | null;
  proceeds: { amount: number; currency: string } | null;
  confirmBy: string | null;
  shipBy: string | null;
  createdAt: string | null;
  section: string | null;
  row: string | null;
}

export interface ChannelCapabilities {
  /** Read-only catalog search to link events. */
  findEvents: boolean;
  /** The marketplace lets a seller create an event (StubHub: PUT /sellerevents). */
  createEvent: boolean;
  /** Exos can list inventory on it directly (vs through Automatiq). */
  listings: boolean;
  /** A sale can be delivered by handing over one URL per ticket. */
  fulfilByUrls: boolean;
}

export interface MarketplaceChannel {
  readonly id: ChannelId;
  readonly label: string;
  readonly capabilities: ChannelCapabilities;
  findEvents?(ev: ExosEventRef): Promise<EventCandidate[]>;
  planCreateEvent?(ev: ExosEventRef): PlannedRequest;
  normalizeSale?(raw: unknown): MarketplaceSale;
  planFulfilByUrls?(sale: MarketplaceSale, claimUrls: string[]): PlannedRequest;
}

// ── Reading exos_events ──────────────────────────────────────────────

/** The exos_events columns the channels need. */
export interface ExosEventRowForChannels {
  id: string;
  name: string | null;
  starts_at: string | null;
  occurs_at_local?: string | null;
  venue_name: string | null;
  venue_location?: string | null;
  venue_address?: Record<string, unknown> | null;
}

const txt = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

export function exosEventRef(row: ExosEventRowForChannels): ExosEventRef | null {
  const name = txt(row.name);
  const venueName = txt(row.venue_name) || txt(row.venue_location);
  if (!name || !row.starts_at || !venueName) return null;
  const addr = row.venue_address ?? {};
  return {
    id: row.id,
    name,
    startsAt: row.starts_at,
    occursAtLocal: row.occurs_at_local ?? null,
    venueName,
    venueCity: txt(addr.city) || null,
    venueRegion: txt(addr.region) || null,
    countryCode: txt(addr.country) || null,
  };
}

/** The event's venue-local date, "YYYY-MM-DD" (UTC date when the local one is unknown). */
export function localDate(ev: Pick<ExosEventRef, 'startsAt' | 'occursAtLocal'>): string {
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(ev.occursAtLocal ?? '');
  return m ? m[1] : new Date(ev.startsAt).toISOString().slice(0, 10);
}
