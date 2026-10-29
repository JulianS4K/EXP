import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { nameFromSlug, parseEventUrl, withUtm, type ParsedEventUrl } from '../../supabase/functions/_shared/eventImport/urls.ts';
import {
  listImportChoices, readImportEvent, sourceStatus, toCheckResult, toImportData,
} from '../../supabase/functions/_shared/eventImport/eventbrite.ts';
import { isLinkOut, priceRange, sellsElsewhere, type WhereToBuy } from '../../supabase/functions/_shared/eventImport/linkOut.ts';
import { fetchPublicEventPage } from '../../supabase/functions/_shared/eventImport/publicPage.ts';
import { buildGoogleFeed, type FeedEventRow, type FeedTierRow } from '../../supabase/functions/_shared/googleEvents/feed.ts';
import { buildCatalog, type CatalogEventRow } from '../../supabase/functions/_shared/catalog/feed.ts';
import { calendarEvent } from '../../supabase/functions/_shared/calendar/feed.ts';
import type { Fetch } from '../../supabase/functions/_shared/eventbrite/client.ts';
import { linkOutPriceLabel, parsePublicLinkOut } from './linkOut';

const ok = (r: ReturnType<typeof parseEventUrl>): ParsedEventUrl => {
  if ('error' in r) throw new Error(r.error);
  return r;
};

describe('parseEventUrl', () => {
  it('reads Eventbrite event links (any country site, old ?eid= links, no scheme)', () => {
    expect(ok(parseEventUrl('https://www.eventbrite.com/e/rooftop-party-tickets-1234567890?aff=ebdssbdestsearch')))
      .toEqual({ platform: 'eventbrite', sourceId: '1234567890', url: 'https://www.eventbrite.com/e/rooftop-party-tickets-1234567890' });
    expect(ok(parseEventUrl('eventbrite.co.uk/e/1234567890'))).toMatchObject({ sourceId: '1234567890', url: 'https://www.eventbrite.co.uk/e/1234567890' });
    expect(ok(parseEventUrl('http://eventbrite.com/e/x-tickets-987654321/'))).toMatchObject({ url: 'https://www.eventbrite.com/e/x-tickets-987654321' });
    expect(ok(parseEventUrl('https://www.eventbrite.com/myevent?eid=555555555'))).toMatchObject({ sourceId: '555555555', url: 'https://www.eventbrite.com/e/555555555' });
  });
  it('reads Luma links (slug or evt- id) and Posh links', () => {
    expect(ok(parseEventUrl('https://lu.ma/summer-rooftop'))).toEqual({ platform: 'luma', sourceId: 'summer-rooftop', url: 'https://lu.ma/summer-rooftop' });
    expect(ok(parseEventUrl('https://luma.com/event/manage/evt-AbC123xyz'))).toEqual({ platform: 'luma', sourceId: 'evt-AbC123xyz', url: 'https://luma.com/event/evt-AbC123xyz' });
    expect(ok(parseEventUrl('https://posh.vip/e/neon-nights?t=abc'))).toEqual({ platform: 'posh', sourceId: 'neon-nights', url: 'https://posh.vip/e/neon-nights' });
  });
  it('refuses what is not an event page', () => {
    for (const bad of ['', 'not a link', 'https://evil.example.com/e/1234567890', 'https://www.eventbrite.com/o/some-org-123456',
      'https://lu.ma/discover', 'https://lu.ma/a/b', 'https://posh.vip/f/x', 'ftp://lu.ma/x',
      'https://user:pw@www.eventbrite.com/e/1234567890', 'https://www.eventbrite.com:8443/e/1234567890',
      'https://www.eventbrite.com.evil.example/e/1234567890', 'javascript:alert(1)']) {
      expect(parseEventUrl(bad), bad).toHaveProperty('error');
    }
    expect(parseEventUrl(42)).toHaveProperty('error');
  });
  it('suggests a name from a slug, not from ids or random codes', () => {
    expect(nameFromSlug(ok(parseEventUrl('https://lu.ma/summer-rooftop')))).toBe('Summer Rooftop');
    expect(nameFromSlug(ok(parseEventUrl('https://lu.ma/x7k2p9q')))).toBe('');
    expect(nameFromSlug(ok(parseEventUrl('https://www.eventbrite.com/e/1234567890')))).toBe('');
  });
  it('adds tracking parameters', () => {
    expect(withUtm('https://www.eventbrite.com/e/1?aff=x', { utm_source: 'google' })).toBe('https://www.eventbrite.com/e/1?aff=x&utm_source=google');
  });
});

// ---- Eventbrite -------------------------------------------------------------

const NOW = new Date('2026-10-01T12:00:00Z');
const EB_EVENT = {
  id: '1234567890', name: { text: 'Rooftop Party' }, summary: 'Sunset set', description: { text: 'Long description' },
  url: 'https://www.eventbrite.com/e/rooftop-party-tickets-1234567890',
  start: { utc: '2026-11-07T01:00:00Z', timezone: 'America/New_York' }, end: { utc: '2026-11-07T05:00:00Z' },
  status: 'live', currency: 'USD', online_event: false, is_free: false,
  logo: { original: { url: 'https://img.evbuc.com/x.jpg' } }, category: { short_name: 'Music' },
  venue: { name: 'Roof', address: { address_1: '1 Main St', city: 'Brooklyn', region: 'NY', postal_code: '11201', country: 'US' } },
  ticket_availability: { is_sold_out: false, minimum_ticket_price: { major_value: '25.00', currency: 'USD' }, maximum_ticket_price: { major_value: '45.00', currency: 'USD' } },
};
const CLASSES = [
  { name: 'Early', cost: { major_value: '25.00' }, on_sale_status: 'SOLD_OUT' },
  { name: 'GA', cost: { major_value: '45.00' }, on_sale_status: 'AVAILABLE' },
  { name: 'Comp', hidden: true, free: true },
  { name: 'Tip jar', donation: true },
];

function fakeFetch(): { fetch: Fetch; calls: Array<{ url: string; method?: string }> } {
  const calls: Array<{ url: string; method?: string }> = [];
  const fetch: Fetch = async (input, init) => {
    calls.push({ url: input, method: init?.method });
    const u = new URL(input);
    const body = u.pathname === '/v3/events/1234567890/' ? EB_EVENT
      : u.pathname === '/v3/events/1234567890/ticket_classes/' ? { ticket_classes: CLASSES }
      : u.pathname === '/v3/users/me/organizations/' ? { organizations: [{ id: '77' }] }
      : u.pathname === '/v3/organizations/77/events/' ? { events: [EB_EVENT, { id: 'bad' }] }
      : null;
    return new Response(JSON.stringify(body ?? { error: 'NOT_FOUND' }), { status: body ? 200 : 404 });
  };
  return { fetch, calls };
}

describe('Eventbrite import', () => {
  it('maps an event and its ticket classes (display only; hidden and donation left out)', () => {
    const d = toImportData(EB_EVENT, CLASSES, NOW)!;
    expect(d).toMatchObject({
      source_event_id: '1234567890', source_url: 'https://www.eventbrite.com/e/rooftop-party-tickets-1234567890',
      source_status: 'on_sale', name: 'Rooftop Party', timezone: 'America/New_York', venue_name: 'Roof',
      venue_address: { street: '1 Main St', city: 'Brooklyn', region: 'NY', postal: '11201', country: 'US' },
      image_url: 'https://img.evbuc.com/x.jpg', category: 'music', currency: 'USD', price_min: 25, price_max: 45, is_free: false,
    });
    expect(d.ticket_types).toEqual([
      { name: 'Early', min_price: 25, max_price: 25, sold_out: true, free: false },
      { name: 'GA', min_price: 45, max_price: 45, sold_out: false, free: false },
    ]);
    expect(toCheckResult(d)).toMatchObject({ source_status: 'on_sale', starts_at: '2026-11-07T01:00:00Z', price_min: 25 });
  });
  it('reads the status: cancelled, ended, sold out, on sale, draft', () => {
    expect(sourceStatus({ status: 'canceled' }, NOW)).toBe('cancelled');
    expect(sourceStatus({ status: 'completed' }, NOW)).toBe('ended');
    expect(sourceStatus({ status: 'live', end: { utc: '2026-09-01T00:00:00Z' } }, NOW)).toBe('ended');
    expect(sourceStatus({ status: 'live', ticket_availability: { is_sold_out: true } }, NOW)).toBe('sold_out');
    expect(sourceStatus({ status: 'started' }, NOW)).toBe('on_sale');
    expect(sourceStatus({ status: 'draft' }, NOW)).toBe('unknown');
  });
  it('falls back to /e/<id> when Eventbrite gives no usable url, and to class prices', () => {
    const d = toImportData({ ...EB_EVENT, url: 'https://evil.example.com/x', ticket_availability: {} }, CLASSES, NOW)!;
    expect(d.source_url).toBe('https://www.eventbrite.com/e/1234567890');
    expect([d.price_min, d.price_max]).toEqual([25, 45]);
    expect(toImportData({ id: 'x' })).toBeNull();
  });
  it('reads only with GET, one expanded event request plus ticket classes', async () => {
    const { fetch, calls } = fakeFetch();
    const r = await readImportEvent(fetch, 'TOKEN123456', '1234567890', NOW);
    expect(r.ok && r.body?.price_min).toBe(25);
    expect(calls.every((c) => c.method === 'GET')).toBe(true);
    expect(new URL(calls[0].url).searchParams.get('expand')).toBe('venue,ticket_availability,category,logo');
    expect(calls).toHaveLength(2);
    expect((await readImportEvent(fetch, 'TOKEN123456', 'nope')).ok).toBe(false);
    expect((await readImportEvent(fetch, 'TOKEN123456', '999')).error).toBe('NOT_FOUND');
  });
  it('lists live and upcoming events across the account', async () => {
    const { fetch, calls } = fakeFetch();
    const r = await listImportChoices(fetch, 'TOKEN123456', NOW);
    expect(r.body).toEqual([expect.objectContaining({ id: '1234567890', name: 'Rooftop Party', venue: 'Roof', price_min: 25, status: 'on_sale' })]);
    expect(new URL(calls[1].url).searchParams.get('status')).toBe('live,started');
  });
  it('never reads a Luma / Posh public page (pending the operator)', async () => {
    await expect(fetchPublicEventPage(ok(parseEventUrl('https://lu.ma/x-party')))).rejects.toThrow(/not enabled/);
  });
});

// ---- Feeds --------------------------------------------------------------------

const BASE = 'https://exos.example.com/bridge';
const EV_ID = '11111111-1111-4111-8111-111111111111';
const ORG = { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: 'Roof Presents', slug: 'roof' };
const SRC = 'https://www.eventbrite.com/e/rooftop-party-tickets-1234567890';
const where = (over: Partial<WhereToBuy> = {}): WhereToBuy => ({
  event_id: EV_ID, sells_on: 'eventbrite', url: SRC, link_out: true, source_status: 'on_sale',
  price_min: '25.00', price_max: '45.00', currency: 'USD', is_free: false,
  ticket_types: [{ name: 'Early', min_price: 25, sold_out: true }, { name: 'GA', min_price: 45, sold_out: false }],
  previous_starts_at: null, rescheduled_at: null, ...over,
});
const gEv = (over: Partial<FeedEventRow> = {}): FeedEventRow => ({
  id: EV_ID, slug: 'rooftop', org_id: ORG.id, name: 'Rooftop Party', description: 'Sunset', status: 'published',
  starts_at: '2026-11-07T01:00:00Z', doors_at: null, ends_at: null, timezone: 'America/New_York', currency: 'usd',
  venue_name: 'Roof', venue_address: { city: 'Brooklyn', country: 'US' }, primary_performer_name: null, performer_names: null,
  category: 'music', genres: null, image_url: 'https://img.evbuc.com/x.jpg', tickets_sold: 0, ...over,
});
const gTier: FeedTierRow = {
  id: '22222222-2222-4222-8222-222222222222', event_id: EV_ID, name: 'GA', description: null, price: 20, capacity: 100,
  sold: 0, sales_start: null, sales_end: null, price_schedule: [], exclusive_tax_percent: 0,
};
const google = (e: FeedEventRow, tiers: FeedTierRow[], w?: WhereToBuy) => buildGoogleFeed({
  events: [e], tiers, geo: new Map(), orgs: new Map([[ORG.id, ORG]]), ...(w ? { buy: new Map([[EV_ID, w]]) } : {}),
}, { appBase: BASE, now: NOW });

describe('link-out rows', () => {
  it('tells link-out, sold elsewhere and Exos apart', () => {
    expect(isLinkOut(where())).toBe(true);
    expect(isLinkOut(where({ url: 'javascript:alert(1)' }))).toBe(false);
    expect(isLinkOut({ event_id: EV_ID, sells_on: 'pretix', url: 'https://pretix.eu/x/', link_out: false })).toBe(false);
    expect(sellsElsewhere({ event_id: EV_ID, sells_on: 'pretix', url: 'https://pretix.eu/x/', link_out: false })).toBe(true);
    expect(sellsElsewhere({ event_id: EV_ID, sells_on: 'exos', url: null, link_out: false })).toBe(false);
    expect(priceRange(where({ price_min: null, is_free: true }))).toEqual({ min: 0, max: 0, currency: 'USD' });
    expect(priceRange(where({ price_min: null }))).toBeNull();
  });
});

describe('Google feed, link-out', () => {
  it('offers the imported types at the organizer checkout, sold out per type, the platform as seller', () => {
    const { feed, skipped } = google(gEv(), [], where());
    expect(skipped).toEqual([]);
    const item = feed.events[0];
    expect(item.googleFields.sellerType).toBe('LINK_OUT');
    expect(item.event.eventStatus).toBe('https://schema.org/EventScheduled');
    expect(item.event.offers).toEqual([
      expect.objectContaining({ name: 'Early', price: '25.00', priceCurrency: 'USD', availability: 'https://schema.org/SoldOut',
        url: `${SRC}?utm_source=google&utm_medium=events_feed`, seller: { '@type': 'Organization', name: 'Eventbrite' } }),
      expect.objectContaining({ name: 'GA', price: '45.00', availability: 'https://schema.org/InStock' }),
    ]);
  });
  it('one offer at the lowest price without types; sold out everywhere when the source is', () => {
    const offers = google(gEv(), [], where({ ticket_types: [], source_status: 'sold_out' })).feed.events[0].event.offers;
    expect(offers).toEqual([expect.objectContaining({ name: 'Tickets', price: '25.00', availability: 'https://schema.org/SoldOut' })]);
  });
  it('rescheduled at the source: EventRescheduled with the previous start', () => {
    const e = google(gEv(), [], where({ rescheduled_at: '2026-09-30T00:00:00Z', previous_starts_at: '2026-11-06T01:00:00Z' })).feed.events[0].event;
    expect(e.eventStatus).toBe('https://schema.org/EventRescheduled');
    expect(e.previousStartDate).toBe('2026-11-05T20:00:00-05:00');
  });
  it('cancelled: EventCancelled even with no Exos sales; ended or priceless: left out', () => {
    const c = google(gEv({ status: 'cancelled' }), [], where({ source_status: 'cancelled' }));
    expect(c.feed.events[0].event.eventStatus).toBe('https://schema.org/EventCancelled');
    expect(c.feed.events[0].event.offers[0].availability).toBe('https://schema.org/Discontinued');
    expect(google(gEv(), [], where({ source_status: 'ended' })).skipped[0].reason).toBe('over at the source');
    expect(google(gEv(), [], where({ price_min: null })).skipped[0].reason).toMatch(/no price/);
  });
  it('an event sold on another backend keeps its types but links to that shop; an Exos event to the checkout', () => {
    const other = google(gEv(), [gTier], { event_id: EV_ID, sells_on: 'pretix', url: 'https://pretix.eu/x/', link_out: false });
    expect(other.feed.events[0].event.offers[0]).toMatchObject({ url: 'https://pretix.eu/x/?utm_source=google&utm_medium=events_feed', seller: { name: 'pretix' } });
    expect(other.feed.events[0].googleFields.sellerType).toBe('PRIMARY');
    const own = google(gEv(), [gTier], { event_id: EV_ID, sells_on: 'exos', url: null, link_out: false });
    expect(own.feed.events[0].event.offers[0].url).toMatch(/\/checkout\?/);
    expect(google(gEv(), [gTier]).feed.events[0].event.offers[0].seller.name).toBe('Exos');
  });
});

const cEv = (over: Partial<CatalogEventRow> = {}): CatalogEventRow => ({
  id: EV_ID, slug: 'rooftop', org_id: ORG.id, name: 'Rooftop Party', description: null, starts_at: '2026-11-07T01:00:00Z',
  timezone: 'America/New_York', currency: 'usd', venue_name: 'Roof', venue_address: { city: 'Brooklyn' },
  image_url: 'https://img.evbuc.com/x.jpg', total_tickets: 0, tickets_sold: 0, ...over,
});
const catalog = (w: WhereToBuy | null, platform: 'meta' | 'tiktok' | 'google' = 'meta') =>
  buildCatalog({ org: ORG, events: [cEv()], tiers: [], ...(w ? { linkOuts: new Map([[EV_ID, w]]) } : {}) }, { appBase: BASE, platform, now: NOW });

describe('catalog feed, link-out', () => {
  it('price = the lowest imported price, link = the organizer checkout, tagged', () => {
    const it0 = catalog(where()).items[0];
    expect(it0).toMatchObject({ price: '25.00 USD', availability: 'in stock' });
    expect(it0.link).toBe(`${SRC}?utm_source=meta&utm_medium=paid_social&utm_campaign=catalog&utm_content=${EV_ID}`);
    expect(it0.description).toMatch(/Tickets on Eventbrite\./);
  });
  it('Google Merchant Center: the Exos event page (its own domain); sold out = out of stock', () => {
    const it0 = catalog(where({ source_status: 'sold_out' }), 'google').items[0];
    expect(it0.link.startsWith(`${BASE}/e/rooftop?`)).toBe(true);
    expect(it0.availability).toBe('out of stock');
  });
  it('cancelled or ended at the source, or no tiers and no link-out: left out', () => {
    expect(catalog(where({ source_status: 'cancelled' })).skipped[0].reason).toBe('cancelled at the source');
    expect(catalog(where({ source_status: 'ended' })).skipped[0].reason).toBe('over at the source');
    expect(catalog(null).skipped[0].reason).toBe('no public ticket types');
  });
});

describe('calendar, link-out', () => {
  const row = { id: EV_ID, slug: 'rooftop', name: 'Rooftop', description: null, status: 'published', starts_at: '2026-11-07T01:00:00Z',
    ends_at: null, doors_at: null, timezone: 'America/New_York', venue_name: 'Roof', venue_address: null, updated_at: null };
  it('links the entry to where to buy', () => {
    expect(calendarEvent({ ...row, buy_on: 'eventbrite', buy_url: SRC }, { appBase: BASE })?.url).toBe(SRC);
    expect(calendarEvent({ ...row, buy_url: null }, { appBase: BASE })?.url).toBe(`${BASE}/e/rooftop`);
    expect(calendarEvent({ ...row, buy_url: 'javascript:x' }, { appBase: BASE })?.url).toBe(`${BASE}/e/rooftop`);
  });
});

describe('storefront link-out', () => {
  it('parses the public view row and labels the price', () => {
    const lo = parsePublicLinkOut({ event_id: EV_ID, platform: 'luma', url: 'https://lu.ma/x', source_status: 'sold_out',
      price_min: '10.00', price_max: '20.00', currency: 'usd', is_free: false, ticket_types: [{ name: 'GA', min_price: 10, sold_out: true }, { nope: 1 }] })!;
    expect(lo).toMatchObject({ platform: 'luma', status: 'sold_out', priceMin: 10, priceMax: 20, currency: 'USD' });
    expect(lo.ticketTypes).toEqual([{ name: 'GA', minPrice: 10, maxPrice: null, soldOut: true, free: false }]);
    expect(linkOutPriceLabel(lo)).toBe('$10.00 – $20.00');
    expect(linkOutPriceLabel({ priceMin: 0, priceMax: 0, isFree: true, currency: 'USD' })).toBe('Free');
    expect(linkOutPriceLabel({ priceMin: null, priceMax: null, isFree: false, currency: null })).toBeNull();
    expect(parsePublicLinkOut({ platform: 'dice', url: 'https://dice.fm/x' })).toBeNull();
    expect(parsePublicLinkOut({ platform: 'luma', url: 'http://lu.ma/x' })).toBeNull();
  });
});
