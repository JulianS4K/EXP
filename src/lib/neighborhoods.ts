// Neighborhood pages: /nyc (the list) and /nyc/:neighborhood ("This week in
// Bushwick"), mig 20261111110000, docs/google-events.md "Neighborhood pages".
// The SQL places each listed event (published, not noindex) in the nearest
// neighborhood whose circle holds its geocoded venue; this file shapes what
// the page shows and tells search engines. Pure up top, calls below.

import { supabase } from './supabase';

/** Mean Earth radius (m), the same as exos_geo_distance_m. */
const EARTH_M = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;

/** Great-circle distance in meters (haversine). Must equal exos_geo_distance_m in SQL. */
export function distanceMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const a = Math.sin(rad(lat2 - lat1) / 2) ** 2
    + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
  return 2 * EARTH_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

export interface NeighborhoodCircle { slug: string; lat: number; lng: number; radiusM: number }

/** The neighborhood a point is in: the nearest center whose circle holds it (as _exos_neighborhood_of). */
export function neighborhoodOf(lat: number, lng: number, circles: NeighborhoodCircle[]): string | null {
  let best: { slug: string; d: number } | null = null;
  for (const c of circles) {
    const d = distanceMeters(lat, lng, c.lat, c.lng);
    if (d > c.radiusM) continue;
    if (!best || d < best.d || (d === best.d && c.slug < best.slug)) best = { slug: c.slug, d };
  }
  return best?.slug ?? null;
}

/** A URL slug as the SQL keys it ("Bushwick" → "bushwick"), or null when it can't be one. */
export function normalizeSlug(raw: string | null | undefined): string | null {
  const s = (raw ?? '').trim().toLowerCase();
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(s) && s.length <= 60 ? s : null;
}

/** The window the page shows: 7 days ("this week") or up to 14 ("the next two weeks"). */
export function clampDays(raw: unknown): number {
  const n = Math.floor(Number(raw));
  return Number.isFinite(n) ? Math.min(14, Math.max(1, n)) : 7;
}

export function pageTitle(name: string, days = 7): string {
  return days <= 7 ? `This week in ${name}` : `The next ${days} days in ${name}`;
}

export function pageDescription(name: string, count: number, days = 7): string {
  const when = days <= 7 ? 'this week' : `in the next ${days} days`;
  if (count === 0) return `Live events in ${name}, New York, on Exos. Nothing listed ${when} yet.`;
  return `${count} live event${count === 1 ? '' : 's'} in ${name}, New York, ${when}: all-in prices, tickets on Exos.`;
}

// ── shapes the RPCs return ─────────────────────────────────────────────────

export interface NeighborhoodSummary { slug: string; name: string; borough: string | null; events: number }

export interface NeighborhoodEvent {
  id: string;
  name: string;
  slug: string | null;
  startsAt: string;
  endsAt: string | null;
  timezone: string | null;
  venueName: string | null;
  venueLocation: string | null;
  imageUrl: string | null;
  currency: string;
  fromPrice: number | null;
  soldOut: boolean;
  genres: string[];
  org: { name: string; slug: string | null };
}

export interface NeighborhoodPage {
  neighborhood: { slug: string; name: string; borough: string | null; city: string; timezone: string };
  days: number;
  events: NeighborhoodEvent[];
  /** Platform admins only: listed events in the window with no map pin. */
  missingCoordinates: number | null;
}

const s = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v : null);
const n = (v: unknown): number | null => {
  const x = typeof v === 'string' ? Number(v) : v;
  return typeof x === 'number' && Number.isFinite(x) ? x : null;
};

export function parseSummaries(data: unknown): NeighborhoodSummary[] {
  return (Array.isArray(data) ? data : []).flatMap((r: any) => {
    const slug = s(r?.slug);
    const name = s(r?.name);
    return slug && name ? [{ slug, name, borough: s(r?.borough), events: n(r?.events) ?? 0 }] : [];
  });
}

export function parseEvent(r: any): NeighborhoodEvent | null {
  const id = s(r?.id);
  const name = s(r?.name);
  const startsAt = s(r?.starts_at);
  if (!id || !name || !startsAt) return null;
  return {
    id, name, startsAt,
    slug: s(r?.slug), endsAt: s(r?.ends_at), timezone: s(r?.timezone),
    venueName: s(r?.venue_name), venueLocation: s(r?.venue_location), imageUrl: s(r?.image_url),
    currency: (s(r?.currency) ?? 'usd').toUpperCase(),
    fromPrice: n(r?.from_price), soldOut: r?.sold_out === true,
    genres: Array.isArray(r?.genres) ? r.genres.filter((g: unknown): g is string => typeof g === 'string') : [],
    org: { name: s(r?.org?.name) ?? '', slug: s(r?.org?.slug) },
  };
}

export function parsePage(data: unknown): NeighborhoodPage | null {
  const d = data as any;
  const nb = d?.neighborhood;
  if (!nb || !s(nb.slug) || !s(nb.name)) return null;
  return {
    neighborhood: { slug: nb.slug, name: nb.name, borough: s(nb.borough), city: s(nb.city) ?? 'nyc', timezone: s(nb.timezone) ?? 'America/New_York' },
    days: clampDays(d.days),
    events: (Array.isArray(d.events) ? d.events : []).map(parseEvent).filter((e: NeighborhoodEvent | null): e is NeighborhoodEvent => !!e),
    missingCoordinates: n(d.missing_coordinates),
  };
}

/** Events grouped by calendar day in the neighborhood's zone, in order: [{ day: 'Fri, Nov 13', events }]. */
export function groupByDay(events: NeighborhoodEvent[], tz: string): { day: string; events: NeighborhoodEvent[] }[] {
  const fmt = (iso: string, zone: string) => {
    try {
      return new Intl.DateTimeFormat('en-US', { timeZone: zone, weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(iso));
    } catch {
      return new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(iso));
    }
  };
  const out: { day: string; events: NeighborhoodEvent[] }[] = [];
  for (const e of [...events].sort((a, b) => a.startsAt.localeCompare(b.startsAt) || a.id.localeCompare(b.id))) {
    const day = fmt(e.startsAt, tz);
    const last = out[out.length - 1];
    if (last && last.day === day) last.events.push(e);
    else out.push({ day, events: [e] });
  }
  return out;
}

/**
 * schema.org JSON-LD for the page: a CollectionPage whose mainEntity is an
 * ItemList of the events (each an Event with its start, place and page URL).
 * eventUrl builds each event's public link.
 */
export function neighborhoodJsonLd(p: NeighborhoodPage, pageUrl: string, eventUrl: (id: string) => string): Record<string, unknown> {
  const title = pageTitle(p.neighborhood.name, p.days);
  return {
    '@context': 'https://schema.org',
    '@type': 'CollectionPage',
    name: title,
    url: pageUrl,
    about: { '@type': 'Place', name: `${p.neighborhood.name}, New York` },
    mainEntity: {
      '@type': 'ItemList',
      numberOfItems: p.events.length,
      itemListElement: p.events.map((e, i) => ({
        '@type': 'ListItem',
        position: i + 1,
        url: eventUrl(e.id),
        item: {
          '@type': 'Event',
          name: e.name,
          startDate: e.startsAt,
          ...(e.endsAt ? { endDate: e.endsAt } : {}),
          eventStatus: 'https://schema.org/EventScheduled',
          eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
          url: eventUrl(e.id),
          ...(e.imageUrl ? { image: e.imageUrl } : {}),
          location: {
            '@type': 'Place',
            name: e.venueName ?? p.neighborhood.name,
            address: e.venueLocation ?? `${p.neighborhood.name}, New York`,
          },
          ...(e.org.name ? { organizer: { '@type': 'Organization', name: e.org.name } } : {}),
          ...(e.fromPrice != null ? {
            offers: {
              '@type': 'Offer', price: e.fromPrice, priceCurrency: e.currency, url: eventUrl(e.id),
              availability: e.soldOut ? 'https://schema.org/SoldOut' : 'https://schema.org/InStock',
            },
          } : {}),
        },
      })),
    },
  };
}

// ── calls (anon OK) ───────────────────────────────────────────────────────

export async function listNeighborhoods(city = 'nyc', days = 7): Promise<NeighborhoodSummary[]> {
  const { data, error } = await supabase.rpc('exos_neighborhoods_list', { p_city: city, p_days: days });
  if (error) throw new Error(error.message);
  return parseSummaries(data);
}

/** null: no such neighborhood. */
export async function getNeighborhoodPage(slug: string, days = 7): Promise<NeighborhoodPage | null> {
  const { data, error } = await supabase.rpc('exos_neighborhood_page', { p_slug: slug, p_days: days });
  if (error) throw new Error(error.message);
  return parsePage(data);
}
