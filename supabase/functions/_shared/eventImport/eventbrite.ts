// Event import with link-out, Eventbrite side (mig 20261029170000): read an
// organizer's events through the official API v3 and turn each into what
// exos_link_out_import / exos_link_out_check_apply take.
//
// READ ONLY: every request goes through _shared/eventbrite/client.ts ebGet
// (GET to www.eventbriteapi.com only). Nothing is written to Eventbrite.
// The token is the org's (see tokens note in exos-event-import/index.ts).
//
// Pure: fetch is injected, no Deno or Supabase imports (vitest imports it).

import { ebGet, isEbId, type EbPagination, type EbResult, type Fetch } from '../eventbrite/client.ts';
import { parseEventUrl } from './urls.ts';

export type SourceStatus = 'on_sale' | 'sold_out' | 'cancelled' | 'ended' | 'unknown';

/** Display only: never an Exos ticket type. */
export interface DisplayTicketType {
  name: string;
  min_price: number | null;
  max_price: number | null;
  sold_out: boolean;
  free: boolean;
}

/** The p_data of exos_link_out_import (and, minus the page fields, p_result of exos_link_out_check_apply). */
export interface ImportData {
  source_event_id: string;
  source_url: string;
  source_status: SourceStatus;
  name: string;
  summary: string | null;
  description: string | null;
  starts_at: string | null;
  ends_at: string | null;
  timezone: string | null;
  venue_name: string | null;
  venue_address: { street?: string; city?: string; region?: string; postal?: string; country?: string } | null;
  online: boolean;
  image_url: string | null;
  category: string | null;
  currency: string | null;
  price_min: number | null;
  price_max: number | null;
  is_free: boolean;
  ticket_types: DisplayTicketType[];
}

/** What the picker shows for one Eventbrite event. */
export interface ImportChoice {
  id: string;
  name: string;
  start: string | null;
  status: SourceStatus;
  url: string;
  venue: string | null;
  price_min: number | null;
  price_max: number | null;
  currency: string | null;
  image_url: string | null;
}

/** expand= for event reads: everything the import copies, in one request. */
export const EVENT_EXPAND = 'venue,ticket_availability,category,logo';

type Raw = Record<string, any>;

const str = (v: unknown, max: number): string | null => {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  return s ? s.slice(0, max) : null;
};

/** "25.00" / 2500 (minor units) → 25. Null when absent or not a price. */
export function money(v: unknown): number | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as Raw;
  if (typeof o.major_value === 'string' && /^[0-9]{1,9}(\.[0-9]{1,2})?$/.test(o.major_value)) return Number(o.major_value);
  if (typeof o.value === 'number' && Number.isInteger(o.value) && o.value >= 0) return o.value / 100;
  return null;
}

/** Eventbrite's event status and ticket availability as the import's status. */
export function sourceStatus(e: Raw, now: Date = new Date()): SourceStatus {
  const st = String(e?.status ?? '').toLowerCase();
  if (st === 'canceled' || st === 'cancelled') return 'cancelled';
  if (st === 'ended' || st === 'completed') return 'ended';
  const end = Date.parse(e?.end?.utc ?? '');
  if (Number.isFinite(end) && end < now.getTime()) return 'ended';
  if (e?.ticket_availability?.is_sold_out === true) return 'sold_out';
  if (st === 'live' || st === 'started') return 'on_sale';
  return 'unknown';
}

function https(v: unknown): string | null {
  const s = str(v, 1000);
  return s && /^https:\/\/[^\s/]+\.[^\s]+$/.test(s) ? s : null;
}

/** The event's public page: Eventbrite's own url when it is one, else /e/<id>. */
export function eventUrl(e: Raw): string {
  const parsed = parseEventUrl(e?.url);
  if (!('error' in parsed) && parsed.platform === 'eventbrite' && parsed.sourceId === e.id) return parsed.url;
  return `https://www.eventbrite.com/e/${e.id}`;
}

/** One ticket class for display (hidden and donation classes left out). */
export function displayType(t: Raw): DisplayTicketType | null {
  if (!t || t.hidden === true || t.donation === true) return null;
  const name = str(t.display_name ?? t.name, 120);
  if (!name) return null;
  const free = t.free === true;
  const cost = free ? 0 : money(t.cost);
  return {
    name,
    min_price: cost,
    max_price: cost,
    sold_out: String(t.on_sale_status ?? '').toUpperCase() === 'SOLD_OUT',
    free,
  };
}

/** An Eventbrite event (expanded with EVENT_EXPAND) and its ticket classes as import data. */
export function toImportData(e: Raw, classes: Raw[] = [], now: Date = new Date()): ImportData | null {
  if (!e || !isEbId(e.id)) return null;
  const types = classes.map(displayType).filter((x): x is DisplayTicketType => x !== null).slice(0, 50);
  const ta = e.ticket_availability ?? {};
  const prices = types.map((t) => t.min_price).filter((p): p is number => p !== null);
  let min = money(ta.minimum_ticket_price);
  let max = money(ta.maximum_ticket_price);
  if (min === null && prices.length) min = Math.min(...prices);
  if (max === null && prices.length) max = Math.max(...prices);
  if (min !== null && max !== null && min > max) [min, max] = [max, min];
  const currency = str(ta.minimum_ticket_price?.currency ?? e.currency, 3)?.toUpperCase() ?? null;
  const v = (e.venue ?? {}) as Raw;
  const a = (v.address ?? {}) as Raw;
  const addr: ImportData['venue_address'] = {};
  const street = [str(a.address_1, 200), str(a.address_2, 200)].filter(Boolean).join(', ');
  if (street) addr.street = street;
  if (str(a.city, 120)) addr.city = str(a.city, 120)!;
  if (str(a.region, 120)) addr.region = str(a.region, 120)!;
  if (str(a.postal_code, 20)) addr.postal = str(a.postal_code, 20)!;
  if (str(a.country, 60)) addr.country = str(a.country, 60)!;
  const isFree = e.is_free === true || (types.length > 0 && types.every((t) => t.free));
  return {
    source_event_id: e.id,
    source_url: eventUrl(e),
    source_status: sourceStatus(e, now),
    name: str(e.name?.text, 200) ?? `Event ${e.id}`,
    summary: str(e.summary, 160),
    description: str(e.description?.text, 20000),
    starts_at: str(e.start?.utc, 40),
    ends_at: str(e.end?.utc, 40),
    timezone: str(e.start?.timezone, 64),
    venue_name: str(v.name, 200),
    venue_address: Object.keys(addr).length ? addr : null,
    online: e.online_event === true,
    image_url: https(e.logo?.original?.url) ?? https(e.logo?.url),
    category: str(e.category?.short_name ?? e.category?.name, 60)?.toLowerCase() ?? null,
    currency,
    price_min: isFree && min === null ? 0 : min,
    price_max: isFree && max === null ? 0 : max,
    is_free: isFree,
    ticket_types: types,
  };
}

/** The picker row. */
export function toChoice(e: Raw, now: Date = new Date()): ImportChoice | null {
  const d = toImportData(e, [], now);
  if (!d) return null;
  return {
    id: d.source_event_id, name: d.name, start: d.starts_at, status: d.source_status, url: d.source_url,
    venue: d.online ? 'Online' : d.venue_name, price_min: d.price_min, price_max: d.price_max,
    currency: d.currency, image_url: d.image_url,
  };
}

/** The ticket classes for display (GET /events/{id}/ticket_classes/), at most 5 pages. */
export async function readTicketClasses(f: Fetch, token: string, id: string): Promise<EbResult<Raw[]>> {
  const out: Raw[] = [];
  let continuation: string | undefined;
  for (let page = 0; page < 5; page++) {
    const r = await ebGet<{ ticket_classes?: Raw[]; pagination?: EbPagination }>(f, token, `/events/${id}/ticket_classes/`, { continuation });
    if (!r.ok) return { ...r, body: null };
    out.push(...(r.body?.ticket_classes ?? []));
    if (!r.body?.pagination?.has_more_items || !r.body.pagination.continuation) break;
    continuation = r.body.pagination.continuation;
  }
  return { ok: true, status: 200, body: out };
}

/**
 * One Eventbrite event read for import or re-check: GET /events/{id}/ with
 * EVENT_EXPAND, then its ticket classes (two requests). A failed ticket-class
 * read still imports the event, without per-type prices.
 */
export async function readImportEvent(f: Fetch, token: string, id: string, now: Date = new Date()): Promise<EbResult<ImportData>> {
  if (!isEbId(id)) return { ok: false, status: 400, body: null, error: 'bad event id' };
  const r = await ebGet<Raw>(f, token, `/events/${id}/`, { expand: EVENT_EXPAND });
  if (!r.ok || !r.body) return { ...r, body: null };
  const classes = await readTicketClasses(f, token, id);
  const d = toImportData(r.body, classes.ok ? classes.body ?? [] : [], now);
  return d ? { ok: true, status: 200, body: d } : { ok: false, status: 502, body: null, error: 'bad event' };
}

/**
 * The account's current and future events, live or started (the ones that
 * can be listed), across its organizations: at most 5 organizations and 4
 * pages each, sorted by start.
 */
export async function listImportChoices(f: Fetch, token: string, now: Date = new Date()): Promise<EbResult<ImportChoice[]>> {
  const orgs = await ebGet<{ organizations?: Raw[] }>(f, token, '/users/me/organizations/');
  if (!orgs.ok) return { ...orgs, body: null };
  const out: ImportChoice[] = [];
  for (const o of (orgs.body?.organizations ?? []).slice(0, 5)) {
    if (!isEbId(o?.id)) continue;
    let continuation: string | undefined;
    for (let page = 0; page < 4; page++) {
      const r = await ebGet<{ events?: Raw[]; pagination?: EbPagination }>(f, token, `/organizations/${o.id}/events/`, {
        status: 'live,started', time_filter: 'current_future', order_by: 'start_asc', expand: EVENT_EXPAND, continuation,
      });
      if (!r.ok) return { ...r, body: null };
      for (const e of r.body?.events ?? []) {
        const c = toChoice(e, now);
        if (c) out.push(c);
      }
      if (!r.body?.pagination?.has_more_items || !r.body.pagination.continuation) break;
      continuation = r.body.pagination.continuation;
    }
  }
  out.sort((a, b) => (a.start ?? '').localeCompare(b.start ?? ''));
  return { ok: true, status: 200, body: out };
}

/** What exos_link_out_check_apply takes from a re-read. */
export function toCheckResult(d: ImportData): Record<string, unknown> {
  return {
    source_status: d.source_status, starts_at: d.starts_at, ends_at: d.ends_at, price_min: d.price_min,
    price_max: d.price_max, currency: d.currency, is_free: d.is_free, ticket_types: d.ticket_types, source_url: d.source_url,
  };
}
