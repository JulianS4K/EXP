// The public listing feed (docs/listing-feed.md): an organization's public
// events with their lineups, page-numbered, for listing sites (Bandsintown,
// JamBase, Songkick) and a venue's own website. Served by exos-api at
// GET /v1/public/events (and the Opendate-style alias /v1/public/confirms),
// authenticated with a per-partner shared key.
//
// Shaped like Opendate's public "confirms" listing so a partner that already
// reads Opendate can switch base URL and key: the same envelope
// (current_page, per_page, total_entries, total_pages, collection), the same
// paging rules (per_page default 30, capped at 250), the same filters and sort
// keys, and the same per-performer fields — including the deprecated flat
// copies of the artist fields (id, name, permalink, image_url,
// image_thumb_url_for_json) older readers still use.
//
// The database decides what is listable and redacts secret venues
// (exos_listing_feed_source, mig 20261030110000); this module filters, sorts,
// pages and shapes. Prices are all-in (passed-on fees included, like every
// other Exos feed).
//
// Pure: no Deno or Supabase imports (vitest imports it).

import { allInCents, effectiveTierPrice } from '../pricing.ts';
import { parseUnitFees, type UnitFee } from '../fees.ts';
import { eventPageUrl, zonedIso } from '../googleEvents/feed.ts';
import { orderedLineup, parseLineup, spotifyLinks, type LineupSlot } from '../artists.ts';

export const PER_PAGE_DEFAULT = 30;
export const PER_PAGE_MAX = 250;
export const PAGE_MAX = 10_000;
/** Seconds a partner may cache a response (Cache-Control max-age). */
export const FEED_MAX_AGE = 60;

// ── Source rows (exos_listing_feed_source) ──────────────────────────────────

export interface SourceVenue {
  secret: boolean;
  online: boolean;
  venue_id: string | null;
  name: string | null;
  permalink: string | null;
  city: string | null;
  region: string | null;
  country: string | null;
}

export interface SourceTier {
  id: string;
  price: number | string;
  capacity: number;
  sold: number;
  sales_start: string | null;
  sales_end: string | null;
  price_schedule?: unknown;
  exclusive_tax_percent?: number | string | null;
  /** Added by the edge function (withPublicTierFees). */
  passed_on_fees?: readonly UnitFee[] | null;
}

export interface SourceEvent {
  id: string;
  slug: string | null;
  name: string;
  status: string;
  starts_at: string;
  ends_at: string | null;
  doors_at: string | null;
  timezone: string | null;
  currency: string | null;
  image_url: string | null;
  genres: unknown;
  subgenres: unknown;
  performer_names: unknown;
  format: string | null;
  tickets_sold: number | null;
  total_tickets: number | null;
  created_at: string | null;
  updated_at: string | null;
  published_at: string | null;
  venue: SourceVenue;
  tiers: SourceTier[];
  lineup: unknown;
}

export interface FeedSource {
  key: { id: string; org_id: string; partner_type: string };
  events: SourceEvent[];
}

// ── Query parameters ───────────────────────────────────────────────────────

export class FeedParamError extends Error {}

const SORTS = {
  'start_time asc': { key: 'start', dir: 1 },
  'start_time desc': { key: 'start', dir: -1 },
  'published_at asc': { key: 'published', dir: 1 },
  'published_at desc': { key: 'published', dir: -1 },
} as const;
export type FeedSort = keyof typeof SORTS;

export interface FeedQuery {
  page: number;
  perPage: number;
  genres: string[];
  excludeGenres: string[];
  venueId: string | null;
  artistId: string | null;
  startGte: Date;
  startLte: Date | null;
  sort: FeedSort;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VENUE_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

/** Every value of `name`, `name[]` and the Ransack-style `q[name]`. */
function all(q: URLSearchParams, name: string): string[] {
  return [...q.getAll(name), ...q.getAll(`${name}[]`), ...q.getAll(`q[${name}]`)];
}

function one(q: URLSearchParams, name: string): string | null {
  const v = all(q, name);
  return v.length ? v[0] : null;
}

function listParam(q: URLSearchParams, name: string): string[] {
  return [...new Set(all(q, name).flatMap((s) => s.split(',')).map((s) => s.trim().toLowerCase()).filter(Boolean))].slice(0, 50);
}

function positiveInt(raw: string | null, name: string, fallback: number): number {
  if (raw === null || raw === '') return fallback;
  if (!/^\d{1,7}$/.test(raw) || Number(raw) < 1) throw new FeedParamError(`${name} must be a positive integer.`);
  return Number(raw);
}

function dateParam(raw: string | null, name: string): Date | null {
  if (raw === null || raw === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(raw.trim()) || Number.isNaN(Date.parse(raw))) {
    throw new FeedParamError(`${name} must be an ISO 8601 date or date-time.`);
  }
  return new Date(raw.trim());
}

/**
 * The feed's query: page / per_page (Opendate's rules: default 30, values above
 * 250 are treated as 250, anything but a positive integer is a 400), genre /
 * exclude_genre (comma-separated or repeated, case-insensitive, subgenres
 * count), venue_id, artist_id, start_time_gteq (default now) and
 * start_time_lteq (plain or q[…]), and q[s]. tag_id is refused: Exos events
 * have no tags, and silently ignoring it would return everything.
 */
export function parseFeedQuery(q: URLSearchParams, now: Date = new Date()): FeedQuery {
  if (all(q, 'tag_id').length || all(q, 'tag_ids').length) {
    throw new FeedParamError('tag_id is not supported: Exos events have no tags. Filter with genre, venue_id or artist_id.');
  }
  const page = positiveInt(one(q, 'page'), 'page', 1);
  if (page > PAGE_MAX) throw new FeedParamError(`page must be at most ${PAGE_MAX}.`);
  const perPage = Math.min(PER_PAGE_MAX, positiveInt(one(q, 'per_page'), 'per_page', PER_PAGE_DEFAULT));
  const startGte = dateParam(one(q, 'start_time_gteq'), 'start_time_gteq') ?? now;
  const startLte = dateParam(one(q, 'start_time_lteq'), 'start_time_lteq');
  const sortRaw = q.get('q[s]') ?? q.get('sort');
  let sort: FeedSort = 'start_time asc';
  if (sortRaw !== null && sortRaw.trim() !== '') {
    const s = sortRaw.trim().toLowerCase().replace(/\s+/g, ' ');
    const normalized = (s in SORTS ? s : `${s} asc`) as FeedSort;
    if (!(normalized in SORTS)) {
      throw new FeedParamError('q[s] must be "start_time asc", "start_time desc", "published_at asc" or "published_at desc".');
    }
    sort = normalized;
  }
  const venueId = one(q, 'venue_id');
  if (venueId !== null && !VENUE_ID_RE.test(venueId)) throw new FeedParamError('venue_id is invalid.');
  const artistId = one(q, 'artist_id');
  if (artistId !== null && !UUID_RE.test(artistId)) throw new FeedParamError('artist_id must be an artist id (a UUID).');
  return {
    page, perPage,
    genres: listParam(q, 'genre'),
    excludeGenres: listParam(q, 'exclude_genre'),
    venueId, artistId: artistId?.toLowerCase() ?? null,
    startGte, startLte, sort,
  };
}

// ── Select, sort, page ───────────────────────────────────────────────────────

const strList = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);
const ms = (s: string | null | undefined): number => {
  const t = s ? Date.parse(s) : NaN;
  return Number.isNaN(t) ? 0 : t;
};

function eventGenres(e: SourceEvent): Set<string> {
  return new Set([...strList(e.genres), ...strList(e.subgenres)].map((g) => g.trim().toLowerCase()));
}

function hasArtist(e: SourceEvent, artistId: string): boolean {
  return parseLineup(e.lineup).some((s) =>
    s.artist_id.toLowerCase() === artistId || (s.artist.canonical_artist_id ?? '').toLowerCase() === artistId);
}

/** Filters, sorts and pages the source events. Ties break on the id. */
export function selectFeed(events: readonly SourceEvent[], q: FeedQuery): { total: number; totalPages: number; rows: SourceEvent[] } {
  const from = q.startGte.getTime();
  const to = q.startLte ? q.startLte.getTime() : Infinity;
  const rows = events.filter((e) => {
    const start = ms(e.starts_at);
    if (!e.starts_at || start < from || start > to) return false;
    if (q.venueId && e.venue.venue_id !== q.venueId) return false;
    if (q.artistId && !hasArtist(e, q.artistId)) return false;
    const genres = eventGenres(e);
    if (q.genres.length && !q.genres.some((g) => genres.has(g))) return false;
    if (q.excludeGenres.some((g) => genres.has(g))) return false;
    return true;
  });
  const { key, dir } = SORTS[q.sort];
  const at = (e: SourceEvent) => (key === 'start' ? ms(e.starts_at) : ms(e.published_at ?? e.created_at));
  rows.sort((a, b) => (at(a) - at(b)) * dir || a.id.localeCompare(b.id));
  const start = (q.page - 1) * q.perPage;
  return { total: rows.length, totalPages: Math.ceil(rows.length / q.perPage), rows: rows.slice(start, start + q.perPage) };
}

// ── Entries ───────────────────────────────────────────────────────────────────

export interface FeedArtist {
  id: string | null;
  name: string;
  permalink: string | null;
  updated_at: string | null;
  image_url: string | null;
  image_thumb_url: string | null;
  spotify_id: string | null;
  spotify_uri: string | null;
  spotify_url: string | null;
  canonical_artist_id: string | null;
}

export interface FeedPerformer {
  performer_id: string;
  artist_id: string | null;
  act_type: string;
  position: number;
  set_time: string | null;
  updated_at: string | null;
  artist: FeedArtist;
  /** Deprecated Opendate aliases: copies, kept for older readers. */
  id: string;
  name: string;
  permalink: string | null;
  image_url: string | null;
  image_thumb_url_for_json: string | null;
}

export interface FeedEntry {
  id: string;
  title: string;
  start_time: string | null;
  end_time: string | null;
  doors_time: string | null;
  timezone: string;
  venue_id: string | null;
  venue_permalink: string | null;
  venue_name: string | null;
  city: string | null;
  region: string | null;
  country: string | null;
  online: boolean;
  ticket_url: string | null;
  image_url: string | null;
  genres: string[];
  price_min: number | null;
  price_max: number | null;
  currency: string;
  on_sale: boolean;
  sold_out: boolean;
  published_at: string | null;
  updated_at: string | null;
  performers: FeedPerformer[];
}

export interface EntryOptions {
  /** Public SPA base, e.g. https://exos.example.com/bridge (no trailing slash). */
  appBase: string;
  partnerType: string;
  now?: Date;
}

const iso = (s: string | null | undefined): string | null => (s && !Number.isNaN(Date.parse(s)) ? new Date(s).toISOString() : null);

function tierAllIn(t: SourceTier, now: Date): number {
  const scheduled = effectiveTierPrice(Number(t.price), t.price_schedule, now);
  return allInCents(Math.round(scheduled * 100), Number(t.exclusive_tax_percent) || 0, parseUnitFees(t.passed_on_fees)) / 100;
}

function performer(s: LineupSlot): FeedPerformer {
  const a = s.artist;
  const sp = spotifyLinks(a.spotify_id);
  const artist: FeedArtist = {
    id: a.id, name: a.name, permalink: a.permalink || null, updated_at: iso(a.updated_at),
    image_url: a.image_url ?? null, image_thumb_url: a.image_thumb_url ?? a.image_url ?? null,
    ...sp, canonical_artist_id: a.canonical_artist_id ?? null,
  };
  return {
    performer_id: s.id, artist_id: s.artist_id, act_type: s.act_type, position: s.position,
    set_time: iso(s.set_time), updated_at: iso(s.updated_at), artist,
    id: s.id, name: artist.name, permalink: artist.permalink, image_url: artist.image_url,
    image_thumb_url_for_json: artist.image_thumb_url,
  };
}

/** One feed entry, snake_case like the rest of the API. */
export function feedEntry(e: SourceEvent, opts: EntryOptions): FeedEntry {
  const now = opts.now ?? new Date();
  const tz = e.timezone || 'UTC';
  const zoned = (s: string | null) => (s ? zonedIso(s, tz) ?? iso(s) : null);
  const tiers = Array.isArray(e.tiers) ? e.tiers : [];
  const prices = tiers.map((t) => tierAllIn(t, now)).filter((p) => Number.isFinite(p) && p >= 0);
  const left = (t: SourceTier) => (t.capacity > 0 ? t.capacity - t.sold : Infinity);
  const total = Number(e.total_tickets) || 0;
  const soldOut = (total > 0 && (Number(e.tickets_sold) || 0) >= total) || (tiers.length > 0 && tiers.every((t) => left(t) <= 0));
  const inWindow = tiers.some((t) =>
    left(t) > 0
    && (!t.sales_start || ms(t.sales_start) <= now.getTime())
    && (!t.sales_end || ms(t.sales_end) >= now.getTime()));
  const utm = new URLSearchParams({
    utm_source: opts.partnerType === 'other' ? 'listing' : opts.partnerType,
    utm_medium: 'listing',
    utm_campaign: 'listing_feed',
  });
  const lineup = orderedLineup(parseLineup(e.lineup));
  const performers: FeedPerformer[] = lineup.length
    ? lineup.map(performer)
    // Free-text performer names only: names, no artist record.
    : strList(e.performer_names).map((n) => n.trim()).filter(Boolean).map((name, i) => {
        const id = `${e.id}-p${i + 1}`;
        return {
          performer_id: id, artist_id: null, act_type: i === 0 ? 'headline' : 'support', position: i + 1,
          set_time: null, updated_at: iso(e.updated_at),
          artist: {
            id: null, name, permalink: null, updated_at: null, image_url: null, image_thumb_url: null,
            spotify_id: null, spotify_uri: null, spotify_url: null, canonical_artist_id: null,
          },
          id, name, permalink: null, image_url: null, image_thumb_url_for_json: null,
        };
      });
  const v = e.venue ?? ({} as SourceVenue);
  return {
    id: e.id,
    title: e.name ?? '',
    start_time: zoned(e.starts_at),
    end_time: zoned(e.ends_at),
    doors_time: zoned(e.doors_at),
    timezone: tz,
    venue_id: v.venue_id ?? null,
    venue_permalink: v.permalink ?? null,
    venue_name: v.name ?? null,
    city: v.city ?? null,
    region: v.region ?? null,
    country: v.country ?? null,
    online: v.online === true,
    ticket_url: opts.appBase ? `${eventPageUrl(opts.appBase, e)}?${utm.toString()}` : null,
    image_url: e.image_url && /^https?:\/\//i.test(e.image_url) ? e.image_url : null,
    genres: strList(e.genres),
    price_min: prices.length ? Math.min(...prices) : null,
    price_max: prices.length ? Math.max(...prices) : null,
    currency: (e.currency || 'USD').toUpperCase(),
    on_sale: !soldOut && inWindow,
    sold_out: soldOut,
    published_at: iso(e.published_at ?? e.created_at),
    updated_at: iso(e.updated_at),
    performers,
  };
}

export interface FeedPage {
  current_page: number;
  per_page: number;
  total_entries: number;
  total_pages: number;
  collection: FeedEntry[];
}

/** The whole response for a list request. */
export function buildFeedPage(events: readonly SourceEvent[], q: FeedQuery, opts: EntryOptions): FeedPage {
  const { total, totalPages, rows } = selectFeed(events, q);
  return {
    current_page: q.page,
    per_page: q.perPage,
    total_entries: total,
    total_pages: totalPages,
    collection: rows.map((e) => feedEntry(e, opts)),
  };
}

/** True when an If-None-Match header names this (strong) ETag. Weak forms match too. */
export function etagMatches(ifNoneMatch: string | null, etag: string): boolean {
  if (!ifNoneMatch) return false;
  if (ifNoneMatch.trim() === '*') return true;
  return ifNoneMatch.split(',').map((s) => s.trim().replace(/^W\//, '')).includes(etag);
}

/** A shared key's shape: sh_live_ + 48 hex. */
export const SHARED_KEY_RE = /^sh_live_[0-9a-f]{48}$/;
