import { describe, expect, it } from 'vitest';
import {
  buildGoogleFeed,
  feedBlocker,
  offerUrl,
  zonedIso,
  type FeedEventRow,
  type FeedTierRow,
} from '../../../supabase/functions/_shared/googleEvents/feed.ts';

const NOW = new Date('2026-10-01T12:00:00Z');
const BASE = 'https://exos.example.com/bridge';

const ev = (over: Partial<FeedEventRow> = {}): FeedEventRow => ({
  id: '11111111-1111-4111-8111-111111111111',
  slug: 'late-night-jazz',
  org_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  name: 'LATE NIGHT JAZZ 🎷 w/ The Trio (21+)',
  description: '<p>Two sets.</p>  <b>Bar</b> opens early.',
  status: 'published',
  starts_at: '2026-11-07T02:00:00Z',
  doors_at: '2026-11-07T01:00:00Z',
  ends_at: null,
  timezone: 'America/New_York',
  currency: 'usd',
  venue_name: 'Blue Room',
  venue_address: { street: '1 Main St', city: 'Brooklyn', region: 'NY', postal: '11211', country: 'United States' },
  primary_performer_name: 'The Trio',
  performer_names: null,
  category: 'music',
  genres: ['jazz'],
  image_url: 'https://img.example.com/a.jpg',
  tickets_sold: 3,
  ...over,
});

const tier = (over: Partial<FeedTierRow> = {}): FeedTierRow => ({
  id: '22222222-2222-4222-8222-222222222222',
  event_id: '11111111-1111-4111-8111-111111111111',
  name: 'GA',
  description: null,
  price: 20,
  capacity: 100,
  sold: 3,
  sales_start: null,
  sales_end: null,
  price_schedule: [],
  exclusive_tax_percent: 8.875,
  ...over,
});

const build = (events: FeedEventRow[], tiers: FeedTierRow[]) =>
  buildGoogleFeed({
    events, tiers,
    geo: new Map([[events[0]?.id ?? '', { lat: 40.71, lng: -73.95, place_id: 'ChIJabc' }]]),
    orgs: new Map([['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: 'Blue Room Presents', slug: 'blue-room' }]]),
  }, { appBase: BASE, now: NOW });

describe('zonedIso', () => {
  it('writes the instant in the venue zone with its offset', () => {
    expect(zonedIso('2026-11-07T02:00:00Z', 'America/New_York')).toBe('2026-11-06T21:00:00-05:00');
    expect(zonedIso('2026-07-01T23:30:00Z', 'America/New_York')).toBe('2026-07-01T19:30:00-04:00');
    expect(zonedIso('2026-07-01T12:00:00Z', 'UTC')).toBe('2026-07-01T12:00:00+00:00');
    expect(zonedIso('nope', 'UTC')).toBeNull();
    expect(zonedIso('2026-07-01T12:00:00Z', 'Not/AZone')).toBeNull();
  });
});

describe('Google events feed', () => {
  it('builds a schema.org Event per listable event, all-in prices, tagged checkout links', () => {
    const { feed, skipped } = build([ev()], [tier(), tier({ id: '33333333-3333-4333-8333-333333333333', name: 'VIP', price: 50, sold: 100 })]);
    expect(skipped).toEqual([]);
    expect(feed.feed_metadata).toMatchObject({ provider: 'Exos', processing_instruction: 'PROCESS_AS_SNAPSHOT', total_events: 1 });
    const item = feed.events[0];
    expect(item.googleFields).toEqual({ category: 'CONCERT', placeId: 'ChIJabc', sellerType: 'PRIMARY', updatedFrom: 'exos' });
    const e = item.event;
    expect(e['@type']).toBe('MusicEvent');
    expect(e.name).toBe('LATE NIGHT JAZZ w/ The Trio'); // marketTitle: emoji and age stripped
    expect(e.url).toBe(`${BASE}/e/late-night-jazz`);
    expect(e.description).toBe('Two sets. Bar opens early.');
    expect(e.startDate).toBe('2026-11-06T21:00:00-05:00');
    expect(e.doorTime).toBe('2026-11-06T20:00:00-05:00');
    expect(e.eventStatus).toBe('https://schema.org/EventScheduled');
    expect(e.location).toEqual({
      '@type': 'Place', name: 'Blue Room',
      address: { '@type': 'PostalAddress', streetAddress: '1 Main St', addressLocality: 'Brooklyn', addressRegion: 'NY', postalCode: '11211', addressCountry: 'US' },
      geo: { '@type': 'GeoCoordinates', latitude: 40.71, longitude: -73.95 },
      hasMap: 'https://www.google.com/maps/place/?q=place_id:ChIJabc',
    });
    expect(e.performer).toEqual([{ '@type': 'PerformingGroup', name: 'The Trio' }]);
    expect(e.organizer).toEqual({ '@type': 'Organization', name: 'Blue Room Presents', url: `${BASE}/o/blue-room` });
    expect(e.typicalAgeRange).toBe('21-');
    // 20.00 + 8.875% tax = 21.78 all-in.
    expect(e.offers[0]).toMatchObject({ name: 'GA', price: '21.78', priceCurrency: 'USD', availability: 'https://schema.org/InStock', category: 'primary' });
    expect(e.offers[0].url).toBe(offerUrl(BASE, e.identifier, '22222222-2222-4222-8222-222222222222'));
    expect(new URL(e.offers[0].url).searchParams.get('utm_source')).toBe('google');
    expect(e.offers[1].availability).toBe('https://schema.org/SoldOut');
  });

  it('uses the store page content when the organizer set it', () => {
    const { feed } = build([ev({
      summary: 'Two sets of late jazz.',
      description_md: '## Tonight\n\n**Two sets**, [menu](https://x.com/menu).\n\n- Bar opens early',
      lineup: [{ name: 'The Trio' }, { name: 'Guest Horn' }, { nope: 1 } as never],
      min_age: 18,
    })], [tier()]);
    const e = feed.events[0].event;
    expect(e.description).toBe('Two sets of late jazz. Tonight Two sets, menu (https://x.com/menu). - Bar opens early');
    expect(e.performer).toEqual([
      { '@type': 'PerformingGroup', name: 'The Trio' },
      { '@type': 'PerformingGroup', name: 'Guest Horn' },
    ]);
    expect(e.typicalAgeRange).toBe('18-'); // min_age wins over "(21+)" in the title
    // All ages: no age range, even with "(21+)" in the title.
    expect(build([ev({ min_age: 0 })], [tier()]).feed.events[0].event.typicalAgeRange).toBeUndefined();
    // Empty store fields fall back to the legacy ones.
    const legacy = build([ev({ summary: null, description_md: null, lineup: [], min_age: null })], [tier()]).feed.events[0].event;
    expect(legacy.description).toBe('Two sets. Bar opens early.');
    expect(legacy.performer).toEqual([{ '@type': 'PerformingGroup', name: 'The Trio' }]);
    expect(legacy.typicalAgeRange).toBe('21-');
  });

  it('uses the scheduled price in force and marks presales and ended sales', () => {
    const { feed } = build([ev()], [
      tier({ price: 20, price_schedule: [{ startsAt: '2026-09-01T00:00:00Z', price: 25 }], exclusive_tax_percent: 0 }),
      tier({ id: '44444444-4444-4444-8444-444444444444', sales_start: '2026-10-05T14:00:00Z' }),
      tier({ id: '55555555-5555-4555-8555-555555555555', sales_end: '2026-09-30T00:00:00Z' }),
    ]);
    const [a, b, c] = feed.events[0].event.offers;
    expect(a.price).toBe('25.00');
    expect(b).toMatchObject({ availability: 'https://schema.org/PreOrder', validFrom: '2026-10-05T10:00:00-04:00' });
    expect(c.availability).toBe('https://schema.org/Discontinued');
  });

  it('lists a cancelled event that was on sale as EventCancelled, and leaves the rest out with a reason', () => {
    const cancelled = ev({ id: '66666666-6666-4666-8666-666666666666', status: 'cancelled' });
    const neverSold = ev({ id: '77777777-7777-4777-8777-777777777777', status: 'cancelled', tickets_sold: 0 });
    const over = ev({ id: '88888888-8888-4888-8888-888888888888', starts_at: '2026-09-20T02:00:00Z' });
    const noTz = ev({ id: '99999999-9999-4999-8999-999999999999', timezone: null });
    const noCity = ev({ id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', venue_address: { street: '1 Main St' } });
    const noTiers = ev({ id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' });
    const tiers = [cancelled, neverSold, over, noTz, noCity].map((e) => tier({ event_id: e.id }));
    const { feed, skipped } = build([cancelled, neverSold, over, noTz, noCity, noTiers], tiers);
    expect(feed.events.map((i) => i.id)).toEqual([cancelled.id]);
    expect(feed.events[0].event.eventStatus).toBe('https://schema.org/EventCancelled');
    expect(feed.events[0].event.offers[0].availability).toBe('https://schema.org/Discontinued');
    expect(Object.fromEntries(skipped.map((s) => [s.event_id, s.reason]))).toEqual({
      [neverSold.id]: 'cancelled before any sale (never listed)',
      [over.id]: 'already over',
      [noTz.id]: "no time zone (Google needs the venue's local time)",
      [noCity.id]: 'venue address needs at least a city and a country',
      [noTiers.id]: 'no public ticket types',
    });
  });

  it('marks free events and keeps an event on until it ends', () => {
    const { feed } = build([ev()], [tier({ price: 0 })]);
    expect(feed.events[0].event.isAccessibleForFree).toBe(true);
    expect(feed.events[0].event.offers[0].price).toBe('0.00');
    // Started two hours ago, no end time: still on (assumed 6 hours long).
    expect(feedBlocker(ev({ starts_at: '2026-10-01T10:00:00Z' }), [tier()], NOW)).toBeNull();
    expect(feedBlocker(ev({ starts_at: '2026-10-01T10:00:00Z', ends_at: '2026-10-01T11:00:00Z' }), [tier()], NOW)).toBe('already over');
  });

  it('leaves out hidden and online-only events, marks hybrid ones (mig 20261005090000)', () => {
    expect(feedBlocker(ev({ noindex: true }), [tier()], NOW)).toMatch(/hidden/);
    expect(feedBlocker(ev({ format: 'online' }), [tier()], NOW)).toMatch(/online-only/);
    expect(feedBlocker(ev({ format: 'hybrid' }), [tier()], NOW)).toBeNull();
    const { feed } = build([ev({ format: 'hybrid' })], [tier()]);
    expect(feed.events[0].event.eventAttendanceMode).toMatch(/Mixed/);
    expect(build([ev()], [tier()]).feed.events[0].event.eventAttendanceMode).toMatch(/Offline/);
  });

  it('never carries buyer or internal data', () => {
    const json = JSON.stringify(build([ev()], [tier()]).feed);
    expect(json).not.toMatch(/barcode|secret|email/i);
    expect(json).not.toMatch(/tickets_sold|capacity|"sold"/);
  });
});
