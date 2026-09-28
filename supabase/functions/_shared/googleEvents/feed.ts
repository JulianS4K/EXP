// The Exos events feed for Google (Search and Maps "Tickets"), served by
// supabase/functions/exos-google-feed (docs/google-events.md).
//
// Google's events ticketing program takes a JSON feed of events. Its partner
// spec is shared during onboarding (the public pages only describe it), so
// each feed item is a schema.org Event, the vocabulary Google documents for
// event data (Search Central "Event" structured data): name, startDate with
// the venue's UTC offset, location as a Place with a postal address and
// coordinates, eventStatus, performers, organizer, and an Offer per ticket
// type. Everything Google-specific (the category, the Place ID, the feed
// wrapper) sits outside the schema.org object in `googleFields` / the
// wrapper, so mapping onto the partner spec later is one function, not a
// rewrite.
//
// What goes in:
//   * published events that haven't ended, with at least one public ticket
//     type, a venue address and a start time;
//   * cancelled events that were on sale (tickets sold) and haven't
//     started, as EventCancelled, so Google takes the listing down with
//     the reason rather than just dropping it.
// Events that can't be listed are returned in `skipped` with the reason (for
// the organizer / operator; Google never sees them). The feed is a snapshot:
// an event missing from it is removed.
//
// Prices are all-in (ticket price plus any tax added at checkout; Exos adds
// no buyer fee), the price the buyer pays: Google's policy and US all-in
// pricing rules both want the total up front. Offer URLs go to the Exos
// checkout with that ticket type in the cart, tagged utm_source=google.
//
// Pure: no Deno or Supabase imports; the edge function does the reads.

import { allInCents, effectiveTierPrice } from '../pricing.ts';
import { ageLimit, marketCategory, marketTitle, type MarketCategory } from '../marketplace/eventStandard.ts';

export const GOOGLE_FEED_VERSION = 1;

export interface FeedEventRow {
  id: string;
  slug: string | null;
  org_id: string;
  name: string;
  description: string | null;
  status: 'published' | 'cancelled' | string;
  starts_at: string | null;
  doors_at: string | null;
  ends_at: string | null;
  timezone: string | null;
  currency: string | null;
  venue_name: string | null;
  venue_address: unknown;
  primary_performer_name: string | null;
  performer_names: string[] | null;
  category: string | null;
  genres: string[] | null;
  image_url: string | null;
  tickets_sold: number | null;
}

export interface FeedTierRow {
  id: string;
  event_id: string;
  name: string;
  description: string | null;
  price: number | string;
  capacity: number;
  sold: number;
  sales_start: string | null;
  sales_end: string | null;
  price_schedule: unknown;
  exclusive_tax_percent: number | string | null;
}

export interface FeedGeo {
  lat: number;
  lng: number;
  place_id: string | null;
}

export interface FeedOrg {
  id: string;
  name: string;
  slug: string | null;
}

export interface FeedInput {
  events: FeedEventRow[];
  /** Public ticket types, any order. */
  tiers: FeedTierRow[];
  geo: ReadonlyMap<string, FeedGeo>;
  orgs: ReadonlyMap<string, FeedOrg>;
}

export interface FeedOptions {
  /** Public SPA base, e.g. https://exos.example.com/bridge (no trailing slash). */
  appBase: string;
  now?: Date;
}

/** The categories Google tailors its event experience to (concerts, sports, theatre, exhibits, workshops). */
export type GoogleEventCategory = 'CONCERT' | 'SPORTS' | 'THEATRE' | 'EXHIBIT' | 'WORKSHOP' | 'OTHER';

export interface GoogleFeedItem {
  id: string;
  /** For the partner spec: fields that aren't schema.org. */
  googleFields: {
    category: GoogleEventCategory;
    /** Google Maps Place ID of the venue, when Exos geocoded it. */
    placeId: string | null;
    /** The Exos "official seller" claim: Exos is the organizer's primary ticketer. */
    sellerType: 'PRIMARY';
    updatedFrom: 'exos';
  };
  event: SchemaEvent;
}

export interface GoogleFeed {
  feed_metadata: {
    provider: 'Exos';
    version: number;
    generated_at: string;
    processing_instruction: 'PROCESS_AS_SNAPSHOT';
    total_events: number;
  };
  events: GoogleFeedItem[];
}

export interface SkippedEvent {
  event_id: string;
  name: string;
  reason: string;
}

// ── schema.org shapes (the subset we fill) ──────────────────────────

type Iso = string;

export interface SchemaOffer {
  '@type': 'Offer';
  name: string;
  url: string;
  price: string;
  priceCurrency: string;
  availability: 'https://schema.org/InStock' | 'https://schema.org/SoldOut' | 'https://schema.org/PreOrder' | 'https://schema.org/Discontinued';
  validFrom?: Iso;
  validThrough?: Iso;
  category: 'primary';
  seller: { '@type': 'Organization'; name: 'Exos' };
  sku: string;
}

export interface SchemaEvent {
  '@context': 'https://schema.org';
  '@type': 'Event' | 'MusicEvent' | 'ComedyEvent' | 'TheaterEvent' | 'SportsEvent' | 'Festival';
  '@id': string;
  identifier: string;
  url: string;
  name: string;
  description?: string;
  startDate: Iso;
  endDate?: Iso;
  doorTime?: Iso;
  eventStatus: 'https://schema.org/EventScheduled' | 'https://schema.org/EventCancelled';
  eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode';
  location: {
    '@type': 'Place';
    name: string;
    address: {
      '@type': 'PostalAddress';
      streetAddress?: string;
      addressLocality?: string;
      addressRegion?: string;
      postalCode?: string;
      addressCountry?: string;
    };
    geo?: { '@type': 'GeoCoordinates'; latitude: number; longitude: number };
    hasMap?: string;
  };
  image?: string[];
  performer?: Array<{ '@type': 'PerformingGroup'; name: string }>;
  organizer?: { '@type': 'Organization'; name: string; url?: string };
  offers: SchemaOffer[];
  typicalAgeRange?: string;
  isAccessibleForFree?: boolean;
}

// ── helpers ─────────────────────────────────────────────────────────

const text = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

/** "2026-11-06T21:00:00-05:00": the instant in the venue's zone, with its offset. */
export function zonedIso(utc: string, timeZone: string): string | null {
  const t = Date.parse(utc);
  if (Number.isNaN(t)) return null;
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-US', {
      timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'longOffset',
    }).formatToParts(new Date(t));
  } catch {
    return null;
  }
  const p = (type: string) => parts.find((x) => x.type === type)?.value ?? '';
  const off = p('timeZoneName').replace(/^GMT/, '');
  const offset = off === '' ? '+00:00' : /^[+-]\d{2}:\d{2}$/.test(off) ? off : null;
  if (!offset) return null;
  return `${p('year')}-${p('month')}-${p('day')}T${p('hour')}:${p('minute')}:${p('second')}${offset}`;
}

const COUNTRY: Record<string, string> = { 'united states': 'US', 'united states of america': 'US', usa: 'US', us: 'US', canada: 'CA', 'united kingdom': 'GB', uk: 'GB' };

function address(v: unknown): SchemaEvent['location']['address'] {
  const a = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  const country = text(a.country);
  const out: SchemaEvent['location']['address'] = { '@type': 'PostalAddress' };
  if (text(a.street)) out.streetAddress = text(a.street);
  if (text(a.city)) out.addressLocality = text(a.city);
  if (text(a.region)) out.addressRegion = text(a.region);
  const postal = text(a.postal) || text(a.postal_code) || text(a.postalCode) || text(a.zip);
  if (postal) out.postalCode = postal;
  if (country) out.addressCountry = COUNTRY[country.toLowerCase()] ?? country;
  return out;
}

const SCHEMA_TYPE: Record<MarketCategory, SchemaEvent['@type']> = {
  concerts: 'MusicEvent', nightlife: 'MusicEvent', festivals: 'Festival', comedy: 'ComedyEvent',
  theater: 'TheaterEvent', sports: 'SportsEvent', other: 'Event',
};

const GOOGLE_CATEGORY: Record<MarketCategory, GoogleEventCategory> = {
  concerts: 'CONCERT', nightlife: 'CONCERT', festivals: 'CONCERT', comedy: 'THEATRE',
  theater: 'THEATRE', sports: 'SPORTS', other: 'OTHER',
};

export function eventPageUrl(appBase: string, e: Pick<FeedEventRow, 'id' | 'slug'>): string {
  return e.slug ? `${appBase}/e/${encodeURIComponent(e.slug)}` : `${appBase}/event/${e.id}`;
}

/** The Exos checkout with one of this ticket type in the cart, tagged as coming from Google. */
export function offerUrl(appBase: string, eventId: string, tierId: string): string {
  const q = new URLSearchParams({ event: eventId, products: `${tierId}:1`, utm_source: 'google', utm_medium: 'events_feed' });
  return `${appBase}/checkout?${q.toString()}`;
}

function plainDescription(v: string | null): string | undefined {
  const s = (v ?? '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, 5000) : undefined;
}

function offerFor(t: FeedTierRow, e: FeedEventRow, currency: string, appBase: string, now: Date, cancelled: boolean): SchemaOffer {
  const scheduled = effectiveTierPrice(Number(t.price), t.price_schedule, now);
  const cents = allInCents(Math.round(scheduled * 100), Number(t.exclusive_tax_percent) || 0);
  const left = t.capacity > 0 ? t.capacity - t.sold : Infinity;
  const notYet = !!t.sales_start && Date.parse(t.sales_start) > now.getTime();
  const ended = !!t.sales_end && Date.parse(t.sales_end) < now.getTime();
  const availability: SchemaOffer['availability'] = cancelled || ended
    ? 'https://schema.org/Discontinued'
    : left <= 0 ? 'https://schema.org/SoldOut'
    : notYet ? 'https://schema.org/PreOrder'
    : 'https://schema.org/InStock';
  const tz = e.timezone || 'UTC';
  const from = t.sales_start ? zonedIso(t.sales_start, tz) : null;
  const through = t.sales_end ? zonedIso(t.sales_end, tz) : null;
  return {
    '@type': 'Offer',
    name: t.name.slice(0, 200),
    url: offerUrl(appBase, e.id, t.id),
    price: (cents / 100).toFixed(2),
    priceCurrency: currency,
    availability,
    ...(from ? { validFrom: from } : {}),
    ...(through ? { validThrough: through } : {}),
    category: 'primary',
    seller: { '@type': 'Organization', name: 'Exos' },
    sku: t.id,
  };
}

/** Why an event can't go in the feed, or null. */
export function feedBlocker(e: FeedEventRow, tiers: FeedTierRow[], now: Date): string | null {
  if (e.status !== 'published' && e.status !== 'cancelled') return 'not published';
  if (!e.starts_at || Number.isNaN(Date.parse(e.starts_at))) return 'no start time';
  const end = e.ends_at && !Number.isNaN(Date.parse(e.ends_at)) ? Date.parse(e.ends_at) : Date.parse(e.starts_at) + 6 * 3600_000;
  if (end < now.getTime()) return 'already over';
  if (e.status === 'cancelled') {
    if (Date.parse(e.starts_at) < now.getTime()) return 'cancelled and past its start';
    if (!(Number(e.tickets_sold) > 0)) return 'cancelled before any sale (never listed)';
  }
  if (!e.timezone) return "no time zone (Google needs the venue's local time)";
  if (!text(e.venue_name)) return 'no venue name';
  const a = address(e.venue_address);
  if (!a.addressLocality || !a.addressCountry) return 'venue address needs at least a city and a country';
  if (!tiers.length) return 'no public ticket types';
  if (!marketTitle(e)) return 'no usable title';
  return null;
}

/** One event as a feed item. Call feedBlocker first. */
export function feedItem(
  e: FeedEventRow, tiers: FeedTierRow[], geo: FeedGeo | null, org: FeedOrg | null, opts: FeedOptions,
): GoogleFeedItem {
  const now = opts.now ?? new Date();
  const tz = e.timezone!;
  const currency = (e.currency || 'USD').toUpperCase();
  const cancelled = e.status === 'cancelled';
  const cat = marketCategory(e);
  const url = eventPageUrl(opts.appBase, e);
  const performers = (e.performer_names?.length ? e.performer_names : e.primary_performer_name ? [e.primary_performer_name] : [])
    .map((n) => text(n)).filter(Boolean).slice(0, 20);
  const offers = tiers.map((t) => offerFor(t, e, currency, opts.appBase, now, cancelled));
  const age = ageLimit(e.name);
  const start = zonedIso(e.starts_at!, tz)!;
  const endIso = e.ends_at ? zonedIso(e.ends_at, tz) : null;
  const doors = e.doors_at ? zonedIso(e.doors_at, tz) : null;
  const event: SchemaEvent = {
    '@context': 'https://schema.org',
    '@type': SCHEMA_TYPE[cat],
    '@id': url,
    identifier: e.id,
    url,
    name: marketTitle(e),
    ...(plainDescription(e.description) ? { description: plainDescription(e.description) } : {}),
    startDate: start,
    ...(endIso ? { endDate: endIso } : {}),
    ...(doors ? { doorTime: doors } : {}),
    eventStatus: cancelled ? 'https://schema.org/EventCancelled' : 'https://schema.org/EventScheduled',
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    location: {
      '@type': 'Place',
      name: text(e.venue_name).slice(0, 200),
      address: address(e.venue_address),
      ...(geo ? { geo: { '@type': 'GeoCoordinates', latitude: geo.lat, longitude: geo.lng } } : {}),
      ...(geo?.place_id ? { hasMap: `https://www.google.com/maps/place/?q=place_id:${encodeURIComponent(geo.place_id)}` } : {}),
    },
    ...(e.image_url ? { image: [e.image_url] } : {}),
    ...(performers.length ? { performer: performers.map((name) => ({ '@type': 'PerformingGroup' as const, name })) } : {}),
    ...(org ? { organizer: { '@type': 'Organization' as const, name: org.name, ...(org.slug ? { url: `${opts.appBase}/o/${encodeURIComponent(org.slug)}` } : {}) } } : {}),
    offers,
    ...(age ? { typicalAgeRange: `${age.replace('+', '')}-` } : {}),
    ...(offers.every((o) => o.price === '0.00') ? { isAccessibleForFree: true } : {}),
  };
  return {
    id: e.id,
    googleFields: { category: GOOGLE_CATEGORY[cat], placeId: geo?.place_id ?? null, sellerType: 'PRIMARY', updatedFrom: 'exos' },
    event,
  };
}

/** The whole feed (a snapshot), plus the events left out and why. */
export function buildGoogleFeed(input: FeedInput, opts: FeedOptions): { feed: GoogleFeed; skipped: SkippedEvent[] } {
  const now = opts.now ?? new Date();
  const byEvent = new Map<string, FeedTierRow[]>();
  for (const t of input.tiers) byEvent.set(t.event_id, [...(byEvent.get(t.event_id) ?? []), t]);
  const items: GoogleFeedItem[] = [];
  const skipped: SkippedEvent[] = [];
  for (const e of [...input.events].sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)) || a.id.localeCompare(b.id))) {
    const tiers = byEvent.get(e.id) ?? [];
    const why = feedBlocker(e, tiers, now);
    if (why) {
      skipped.push({ event_id: e.id, name: e.name, reason: why });
      continue;
    }
    items.push(feedItem(e, tiers, input.geo.get(e.id) ?? null, input.orgs.get(e.org_id) ?? null, opts));
  }
  return {
    feed: {
      feed_metadata: {
        provider: 'Exos',
        version: GOOGLE_FEED_VERSION,
        generated_at: now.toISOString(),
        processing_instruction: 'PROCESS_AS_SNAPSHOT',
        total_events: items.length,
      },
      events: items,
    },
    skipped,
  };
}
