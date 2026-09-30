import { describe, expect, it } from 'vitest';
import {
  buildCatalog,
  catalogCsv,
  catalogLink,
  catalogRss,
  csvField,
  formatPrice,
  parseFeedPath,
  priceAndAvailability,
  renderCatalog,
  resolvePlatform,
  xmlText,
  type CatalogEventRow,
  type CatalogTierRow,
} from '../../../supabase/functions/_shared/catalog/feed.ts';

const NOW = new Date('2026-10-01T12:00:00Z');
const BASE = 'https://exos.example.com/bridge';
const ORG = { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: 'Blue Room Presents', slug: 'blue-room' };
const EV_ID = '11111111-1111-4111-8111-111111111111';

const ev = (over: Partial<CatalogEventRow> = {}): CatalogEventRow => ({
  id: EV_ID,
  slug: 'late-night-jazz',
  org_id: ORG.id,
  name: 'Late Night Jazz',
  description: '<p>Two sets.</p>  <b>Bar</b> opens early.',
  starts_at: '2026-11-07T02:00:00Z',
  ends_at: null,
  timezone: 'America/New_York',
  currency: 'usd',
  venue_name: 'Blue Room',
  venue_address: { city: 'Brooklyn', country: 'US' },
  primary_performer_name: 'The Trio',
  category: 'music',
  genres: ['jazz'],
  image_url: 'https://img.example.com/a.jpg',
  total_tickets: 0,
  tickets_sold: 3,
  gallery: [{ url: 'https://img.example.com/b.jpg' }, { url: 'http://insecure.example.com/c.jpg' }, { url: 'https://img.example.com/a.jpg' }],
  ...over,
});

const tier = (over: Partial<CatalogTierRow> = {}): CatalogTierRow => ({
  id: '22222222-2222-4222-8222-222222222222',
  event_id: EV_ID,
  price: 20,
  capacity: 100,
  sold: 3,
  sales_start: null,
  sales_end: null,
  price_schedule: [],
  exclusive_tax_percent: 8.875,
  ...over,
});

const build = (events: CatalogEventRow[], tiers: CatalogTierRow[], platform: 'meta' | 'tiktok' | 'google' = 'meta') =>
  buildCatalog({ org: ORG, events, tiers }, { appBase: BASE, platform, now: NOW });

describe('formatPrice', () => {
  it('writes two decimals and the upper-case currency code', () => {
    expect(formatPrice(2178, 'usd')).toBe('21.78 USD');
    expect(formatPrice(500, 'EUR')).toBe('5.00 EUR');
    expect(formatPrice(0, '')).toBe('0.00 USD');
    expect(formatPrice(-5, 'usd')).toBe('0.00 USD');
    expect(formatPrice(1999.6, 'gbp')).toBe('20.00 GBP');
  });
});

describe('priceAndAvailability', () => {
  it('is the lowest all-in price among tiers on sale (storefront semantics)', () => {
    const r = priceAndAvailability(ev(), [tier(), tier({ id: 't2', price: 15, exclusive_tax_percent: 0 }), tier({ id: 't3', price: 10, sold: 100 })], NOW);
    expect(r).toEqual({ cents: 1500, availability: 'in stock', opensAt: null });
  });

  it('adds exclusive tax and uses the scheduled price in force', () => {
    const r = priceAndAvailability(ev(), [tier({ price_schedule: [{ price: 30, startsAt: '2026-09-01T00:00:00Z' }] })], NOW);
    expect(r?.cents).toBe(3266); // 30.00 + 8.875% = 32.66
  });

  it('is preorder with the earliest opening when every open tier is still to come', () => {
    const r = priceAndAvailability(ev(), [
      tier({ sales_start: '2026-10-05T16:00:00Z', price: 25 }),
      tier({ id: 't2', sales_start: '2026-10-03T16:00:00Z', price: 40 }),
      tier({ id: 't3', sales_end: '2026-09-30T00:00:00Z', price: 5 }),
    ], NOW);
    expect(r?.availability).toBe('preorder');
    expect(r?.opensAt).toBe(Date.parse('2026-10-03T16:00:00Z'));
    expect(r?.cents).toBe(2722); // 25.00 all-in
  });

  it('is out of stock when every tier is sold out or closed, or the event is full', () => {
    expect(priceAndAvailability(ev(), [tier({ sold: 100 })], NOW)?.availability).toBe('out of stock');
    expect(priceAndAvailability(ev(), [tier({ sales_end: '2026-09-01T00:00:00Z' })], NOW)?.availability).toBe('out of stock');
    expect(priceAndAvailability(ev({ total_tickets: 50, tickets_sold: 50 }), [tier()], NOW)?.availability).toBe('out of stock');
  });

  it('treats capacity 0 as unlimited', () => {
    expect(priceAndAvailability(ev(), [tier({ capacity: 0, sold: 9999 })], NOW)?.availability).toBe('in stock');
  });
});

describe('catalogLink', () => {
  it('links the event page with the platform UTM tags', () => {
    const u = new URL(catalogLink(BASE, ev(), 'tiktok'));
    expect(u.origin + u.pathname).toBe(`${BASE}/e/late-night-jazz`);
    expect(Object.fromEntries(u.searchParams)).toEqual({
      utm_source: 'tiktok', utm_medium: 'paid_social', utm_campaign: 'catalog', utm_content: EV_ID,
    });
  });

  it('falls back to /event/<id> without a slug', () => {
    expect(catalogLink(BASE, ev({ slug: null }), 'google')).toMatch(`${BASE}/event/${EV_ID}?utm_source=google&`);
  });
});

describe('buildCatalog', () => {
  it('builds one item per event with the required fields', () => {
    const { items, skipped } = build([ev()], [tier()]);
    expect(skipped).toEqual([]);
    expect(items).toHaveLength(1);
    const it0 = items[0];
    expect(it0.id).toBe(EV_ID);
    expect(it0.title).toBe('Late Night Jazz');
    expect(it0.description).toBe('Two sets. Bar opens early.');
    expect(it0.availability).toBe('in stock');
    expect(it0.condition).toBe('new');
    expect(it0.price).toBe('21.78 USD');
    expect(it0.brand).toBe('Blue Room Presents');
    expect(it0.imageLink).toBe('https://img.example.com/a.jpg');
    expect(it0.additionalImageLinks).toEqual(['https://img.example.com/b.jpg']);
    expect(it0.productType).toBe('Event Tickets > Concerts');
    expect(it0.customLabels).toEqual(['2026-11-06', 'Blue Room', 'Brooklyn', 'concerts', 'later']);
    expect(it0.expirationDate).toBe('2026-11-07T03:00:00-05:00');
  });

  it('writes a description when the event has none', () => {
    const { items } = build([ev({ description: null })], [tier()]);
    expect(items[0].description).toBe('Late Night Jazz at Blue Room, Brooklyn, 2026-11-06. Tickets on Exos.');
  });

  it('uses the first gallery image when there is no cover', () => {
    const { items } = build([ev({ image_url: null })], [tier()]);
    expect(items[0].imageLink).toBe('https://img.example.com/b.jpg');
  });

  it('leaves out events that are over, have no tiers or no https image, and other orgs', () => {
    const { items, skipped } = build([
      ev({ id: 'past', starts_at: '2026-09-30T01:00:00Z' }),
      ev({ id: 'notiers' }),
      ev({ id: 'noimg', image_url: 'http://x.example.com/a.jpg', gallery: [] }),
      ev({ id: 'other', org_id: 'someone-else' }),
    ], [tier({ event_id: 'past' }), tier({ event_id: 'noimg' })]);
    expect(items).toEqual([]);
    expect(skipped.map((s) => [s.event_id, s.reason])).toEqual([
      ['past', 'already over'],
      ['noimg', 'no https image (every ad platform requires one)'],
      ['notiers', 'no public ticket types'],
    ]);
  });

  it('adds availability_date for a presale', () => {
    const { items } = build([ev()], [tier({ sales_start: '2026-10-03T16:00:00Z' })]);
    expect(items[0].availability).toBe('preorder');
    expect(items[0].availabilityDate).toBe('2026-10-03T12:00:00-04:00');
  });
});

describe('CSV', () => {
  it('quotes commas, quotes and line breaks (RFC 4180)', () => {
    expect(csvField('plain')).toBe('plain');
    expect(csvField('a,b')).toBe('"a,b"');
    expect(csvField('say "hi"')).toBe('"say ""hi"""');
    expect(csvField('two\nlines')).toBe('"two\nlines"');
  });

  it('writes the Meta header and rows', () => {
    const { items } = build([ev({ name: 'Jazz, "Live"' })], [tier()]);
    const csv = catalogCsv(items, 'meta');
    const [head, row] = csv.split('\r\n');
    expect(head).toBe('id,title,description,availability,condition,price,link,image_link,brand,additional_image_link,product_type,custom_label_0,custom_label_1,custom_label_2,custom_label_3,custom_label_4');
    expect(row.startsWith(`${EV_ID},"Jazz, ""Live""",`)).toBe(true);
    expect(row).toContain(',in stock,new,21.78 USD,');
    expect(csv.endsWith('\r\n')).toBe(true);
  });

  it('uses sku_id for TikTok', () => {
    expect(catalogCsv([], 'tiktok').startsWith('sku_id,title,description,availability,condition,price,link,image_link,brand,')).toBe(true);
  });
});

describe('RSS (Google Merchant Center)', () => {
  it('escapes XML and drops forbidden control characters', () => {
    expect(xmlText(`<a & 'b' "c">\u0001`)).toBe('&lt;a &amp; &apos;b&apos; &quot;c&quot;&gt;');
  });

  it('writes the g: namespace, Google availability values and identifier_exists', () => {
    const { items } = build([ev({ name: 'Rock & Roll' })], [tier()], 'google');
    const xml = catalogRss(items, { title: 'Blue Room events', link: `${BASE}/o/blue-room`, description: 'd' });
    expect(xml).toContain('<rss version="2.0" xmlns:g="http://base.google.com/ns/1.0">');
    expect(xml).toContain(`<g:id>${EV_ID}</g:id>`);
    expect(xml).toContain('<title>Rock &amp; Roll</title>');
    expect(xml).toContain('<g:availability>in_stock</g:availability>');
    expect(xml).toContain('<g:price>21.78 USD</g:price>');
    expect(xml).toContain('<g:identifier_exists>no</g:identifier_exists>');
    expect(xml).toContain('utm_source=google&amp;utm_medium=paid_social&amp;utm_campaign=catalog');
    expect(xml).toContain('<g:additional_image_link>https://img.example.com/b.jpg</g:additional_image_link>');
  });

  it('keeps Meta availability values with spaces', () => {
    const { items } = build([ev()], [tier()]);
    expect(renderCatalog(items, 'meta', 'xml', ORG, BASE).body).toContain('<g:availability>in stock</g:availability>');
  });
});

describe('request parsing', () => {
  it('reads the org slug and file type from the last path segment', () => {
    expect(parseFeedPath('/exos-catalog-feed/blue-room.csv')).toEqual({ slug: 'blue-room', fileType: 'csv' });
    expect(parseFeedPath('/functions/v1/exos-catalog-feed/blue-room.xml')).toEqual({ slug: 'blue-room', fileType: 'xml' });
    expect(parseFeedPath('/exos-catalog-feed/Blue Room.csv')).toBeNull();
    expect(parseFeedPath('/exos-catalog-feed/blue-room.json')).toBeNull();
    expect(parseFeedPath('/exos-catalog-feed')).toBeNull();
  });

  it('picks the platform, defaulting by file type', () => {
    expect(resolvePlatform('csv', null)).toEqual({ platform: 'meta' });
    expect(resolvePlatform('xml', '')).toEqual({ platform: 'google' });
    expect(resolvePlatform('csv', 'TikTok')).toEqual({ platform: 'tiktok' });
    expect(resolvePlatform('xml', 'meta')).toEqual({ platform: 'meta' });
    expect(resolvePlatform('xml', 'tiktok')).toEqual({ error: 'tiktok feeds are served as .csv' });
    expect(resolvePlatform('csv', 'google')).toEqual({ error: 'google feeds are served as .xml' });
    expect(resolvePlatform('csv', 'snap')).toEqual({ error: 'format must be meta, tiktok or google' });
  });
});
