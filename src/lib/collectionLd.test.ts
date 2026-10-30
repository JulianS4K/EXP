import { describe, expect, it } from 'vitest';
import { collectionJsonLd } from './collectionLd';

describe('collectionJsonLd', () => {
  it('describes the collection as an EventSeries with sub-events', () => {
    const ld = collectionJsonLd({
      id: 'c1', name: 'Winter', slug: 'winter', description: null, image_url: null, org: { name: 'Blue Room', slug: 'blue room' },
      events: [
        { id: 'e1', name: 'Jazz', slug: null, starts_at: '2026-11-07T01:00:00Z', ends_at: null, timezone: 'America/New_York',
          venue_name: 'Blue Room', venue_location: 'Brooklyn', image_url: null, currency: 'usd', from_price: 20, sold_out: false },
        { id: 'e2', name: 'Late', slug: null, starts_at: '2026-11-14T01:00:00Z', ends_at: '2026-11-14T04:00:00Z', timezone: null,
          venue_name: null, venue_location: null, image_url: null, currency: null, from_price: null, sold_out: true },
      ],
    }, 'https://exos.example');
    expect(ld['@type']).toBe('EventSeries');
    expect(ld.url).toBe('https://exos.example/c/blue%20room/winter');
    expect(ld).not.toHaveProperty('description');
    const sub = ld.subEvent as Record<string, any>[];
    expect(sub[0]).toMatchObject({ startDate: '2026-11-07T01:00:00Z', location: { name: 'Blue Room', address: 'Brooklyn' },
      offers: { price: 20, priceCurrency: 'USD', availability: 'https://schema.org/InStock' } });
    expect(sub[1]).toMatchObject({ endDate: '2026-11-14T04:00:00Z' });
    expect(sub[1]).not.toHaveProperty('offers');
    expect(sub[1]).not.toHaveProperty('location');
  });
});
