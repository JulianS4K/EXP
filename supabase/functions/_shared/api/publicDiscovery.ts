// The no-credential /v1/public/… routes of exos-api (auth `public`,
// claude/exos-fan-api, mig 20261105110000): public discovery (events,
// venues, search, event series) over the public views and RPCs the
// storefront reads, and signup forms through the same SQL as exos-signup.
// Nothing here reads a row the storefront could not.
//
// Pure TypeScript, imported by vitest (src/lib/apiPublicDiscovery.test.ts).

/** Requests per network (hashed IP) per minute on the public discovery routes. */
export const PUBLIC_PER_IP_PER_MIN = 60;
/** Signups per network per minute and per form per minute (as exos-signup). */
export const SIGNUP_PER_IP_PER_MIN = 10;
export const SIGNUP_PER_FORM_PER_MIN = 120;
/** Signup bodies are small: 16 KB, as exos-signup. */
export const SIGNUP_MAX_BODY = 16 * 1024;

export class PublicParamError extends Error {}

/** Search words safe inside a PostgREST or() ilike filter: letters, digits and a little punctuation. */
export function cleanSearch(s: string | null | undefined): string {
  return (s ?? '').normalize('NFKC').replace(/[^\p{L}\p{N} '&.-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
}

/** ?q= of GET /public/search: 2-80 characters once cleaned. */
export function searchQuery(q: URLSearchParams): string {
  const s = cleanSearch(q.get('q') ?? q.get('query'));
  if (s.length < 2) throw new PublicParamError('q must be at least 2 letters or digits');
  return s;
}

/** An ISO date or timestamp query parameter, or null. */
export function isoOf(q: URLSearchParams, name: string): string | null {
  const v = q.get(name);
  if (v === null || v === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v) || Number.isNaN(Date.parse(v))) {
    throw new PublicParamError(`${name} must be an ISO 8601 date or time`);
  }
  return new Date(v).toISOString();
}

/** A venue (organizer) reference: its id or its slug; null when it can be neither (a 404). */
export function venueRef(raw: string | undefined): { id: string } | { slug: string } | null {
  const v = (raw ?? '').trim();
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)) return { id: v.toLowerCase() };
  if (/^[a-z0-9][a-z0-9-]{0,62}$/.test(v)) return { slug: v };
  return null;
}

/** A no-credential read route: the _exos_api_public action and its path target. */
export interface PublicRead {
  action: 'events.list' | 'event.get' | 'venues.list' | 'venue.get' | 'search' | 'series.list' | 'series.get';
  target?: 'id';
}

/** Route id -> _exos_api_public action (_shared/api/routes.ts, auth `public`). */
export const PUBLIC_READS: Readonly<Record<string, PublicRead>> = {
  'public-discovery-events': { action: 'events.list' },
  'public-discovery-event': { action: 'event.get', target: 'id' },
  'public-venues': { action: 'venues.list' },
  'public-venue': { action: 'venue.get', target: 'id' },
  'public-search': { action: 'search' },
  'public-event-series-list': { action: 'series.list' },
  'public-event-series': { action: 'series.get', target: 'id' },
};

/** The no-credential write routes (signup forms, through the same SQL as exos-signup). */
export const PUBLIC_WRITES: ReadonlySet<string> = new Set(['public-create-fan', 'public-create-form-submission']);

/** The args of a public read from its query (filters checked here, again in SQL). */
export function publicReadArgs(routeId: string, q: URLSearchParams): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (routeId === 'public-search') out.q = searchQuery(q);
  if (routeId === 'public-discovery-events' || routeId === 'public-venues') {
    const s = cleanSearch(q.get('q') ?? q.get('query'));
    if (s.length >= 2) out.q = s;
  }
  if (routeId === 'public-discovery-events' || routeId === 'public-event-series-list') {
    const raw = q.get('venue_id') ?? q.get('venue') ?? q.get('organizer');
    if (raw !== null) {
      const v = venueRef(raw);
      if (!v) throw new PublicParamError('venue_id must be an organizer id or slug');
      out.venue = 'id' in v ? v.id : v.slug;
    } else if (routeId === 'public-event-series-list') {
      throw new PublicParamError('venue_id (the organizer\'s id or slug) is required');
    }
  }
  if (routeId === 'public-discovery-events') {
    const after = isoOf(q, 'starts_after');
    const before = isoOf(q, 'starts_before');
    if (after) out.starts_after = after;
    if (before) out.starts_before = before;
  }
  return out;
}

/** A public ticket type as _exos_api_public returns it (before pricing). */
export interface PublicTierRow {
  id: string;
  event_id?: string;
  name: string;
  description?: string | null;
  price: number | string;
  price_schedule?: unknown;
  sales_start?: string | null;
  sales_end?: string | null;
  exclusive_tax_percent?: number | string | null;
  sold_out?: boolean;
  passed_on_fees?: unknown;
}

/** What a buyer is shown for a ticket type: the all-in price only, never a fee line. */
export interface PublicTicketType {
  id: string;
  name: string;
  description: string | null;
  price_cents: number;
  on_sale: boolean;
  sold_out: boolean;
  sales_start: string | null;
  sales_end: string | null;
}

/**
 * Prices a public ticket type all-in (the scheduled price, passed-on fees and
 * exclusive tax, as every Exos price a buyer sees). `allIn` is pricing.ts's
 * allInCents, `scheduled` its effectiveTierPrice, `fees` fees.ts's
 * parseUnitFees: passed in so this file stays free of Deno imports.
 */
export interface PricingFns<F> {
  scheduled: (base: number, schedule: unknown, now: Date) => number;
  allIn: (cents: number, taxPercent: number, fees: readonly F[]) => number;
  fees: (raw: unknown) => F[];
}

export function publicTicketType<F>(t: PublicTierRow, now: Date, h: PricingFns<F>): PublicTicketType {
  const base = h.scheduled(Number(t.price) || 0, t.price_schedule, now);
  const cents = h.allIn(Math.round(base * 100), Number(t.exclusive_tax_percent) || 0, h.fees(t.passed_on_fees));
  const opens = t.sales_start ? Date.parse(t.sales_start) : NaN;
  const ends = t.sales_end ? Date.parse(t.sales_end) : NaN;
  const sold = t.sold_out === true;
  return {
    id: t.id, name: t.name, description: t.description ?? null, price_cents: cents,
    on_sale: !sold && !(opens > now.getTime()) && !(ends < now.getTime()),
    sold_out: sold, sales_start: t.sales_start ?? null, sales_end: t.sales_end ?? null,
  };
}

/**
 * A public event with its ticket types priced: `ticket_types` all-in,
 * `from_price_cents` the lowest one on sale (else the lowest), and the base
 * `from_price` dropped (a buyer never sees a price without its fees).
 * `withTypes` false (lists) leaves the ticket types out.
 */
export function pricePublicEvent(
  e: Record<string, unknown>, priced: PublicTicketType[], withTypes: boolean,
): Record<string, unknown> {
  const { from_price: _base, ticket_types: _raw, ...rest } = e;
  const pool = priced.some((t) => t.on_sale) ? priced.filter((t) => t.on_sale) : priced;
  const from = pool.length ? Math.min(...pool.map((t) => t.price_cents)) : null;
  return { ...rest, from_price_cents: from, ...(withTypes ? { ticket_types: priced } : {}) };
}
