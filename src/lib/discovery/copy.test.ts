import { describe, expect, it } from 'vitest';
import {
  addressLine,
  discoveryTicketLink,
  plainDescription,
  priceRange,
  submissionCopy,
  trackingLink,
} from '../../../supabase/functions/_shared/discovery/copy.ts';
import { readAttribution } from '../../../supabase/functions/_shared/attribution.ts';

const NOW = new Date('2026-10-01T12:00:00Z');
const BASE = 'https://exos.example.com/bridge';

const event = {
  id: '11111111-1111-4111-8111-111111111111',
  slug: 'late-night-jazz',
  name: 'Late Night Jazz',
  starts_at: '2026-11-07T02:00:00Z', // 9 PM New York
  doors_at: '2026-11-07T01:00:00Z',
  timezone: 'America/New_York',
  currency: 'USD',
  venue_name: 'Elsewhere',
  venue_address: { street: '599 Johnson Ave', city: 'Brooklyn', region: 'NY', postal: '11237', country: 'US' },
  image_url: 'https://cdn.example.com/a.jpg',
  summary: 'Two sets.',
  description_md: '**Bar** opens early.',
};

describe('trackingLink', () => {
  it('tags the event page per channel, and attribution keeps the tags', () => {
    const url = trackingLink(BASE, event, 'donyc');
    expect(url).toBe(`${BASE}/e/late-night-jazz?utm_source=donyc&utm_medium=listing&utm_campaign=discovery`);
    const q = new URL(url).searchParams;
    expect(readAttribution((k) => q.get(k))).toMatchObject({ utm_source: 'donyc', utm_medium: 'listing', utm_campaign: 'discovery' });
  });

  it('is the one ticket link the copy uses', () => {
    expect(discoveryTicketLink(BASE, event, 'donyc')).toBe(trackingLink(BASE, event, 'donyc'));
    expect(submissionCopy(event, [], 'donyc', BASE, NOW).ticketLink).toBe(discoveryTicketLink(BASE, event, 'donyc'));
  });

  it('falls back to /event/<id> with no slug', () => {
    expect(trackingLink(BASE, { id: 'abc', slug: null }, 'cityspark')).toContain('/event/abc?utm_source=cityspark');
  });
});

describe('priceRange (all-in)', () => {
  it('formats one price, a range, and free', () => {
    expect(priceRange([{ price: 20 }], 'USD', NOW)).toBe('$20.00');
    expect(priceRange([{ price: 20 }, { price: 45, exclusive_tax_percent: 10 }], 'USD', NOW)).toBe('$20.00 - $49.50');
    expect(priceRange([{ price: 0 }], 'USD', NOW)).toBe('Free');
    expect(priceRange([{ price: 0 }, { price: 15 }], 'USD', NOW)).toBe('Free - $15.00');
    expect(priceRange([], 'USD', NOW)).toBe('');
  });

  it('adds exclusive tax and uses the scheduled price in force', () => {
    const schedule = [{ price: 25, startsAt: '2026-09-01T00:00:00Z' }];
    expect(priceRange([{ price: 20, price_schedule: schedule, exclusive_tax_percent: 8.875 }], 'USD', NOW))
      .toBe(priceRange([{ price: 25, exclusive_tax_percent: 8.875 }], 'USD', NOW));
  });

  it('leaves out tiers that ended or sold out, unless nothing is left', () => {
    const tiers = [{ price: 10, sales_end: '2026-09-01T00:00:00Z' }, { price: 30, capacity: 5, sold: 5 }, { price: 40 }];
    expect(priceRange(tiers, 'USD', NOW)).toBe('$40.00');
    expect(priceRange([{ price: 10, capacity: 1, sold: 1 }], 'USD', NOW)).toBe('$10.00');
  });
});

describe('submissionCopy', () => {
  it('gives the copy-ready fields in venue time', () => {
    const c = submissionCopy(event, [{ price: 20 }, { price: 35 }], 'timeout_nyc', BASE, NOW);
    expect(c.title).toBe('Late Night Jazz');
    expect(c.when).toBe('Fri, Nov 6, 2026, 9:00 PM (doors 8:00 PM)');
    expect(c.date).toBe('2026-11-06');
    expect(c.time).toBe('21:00');
    expect(c.venue).toBe('Elsewhere');
    expect(c.address).toBe('599 Johnson Ave, Brooklyn, NY 11237, US');
    expect(c.price).toBe('$20.00 - $35.00');
    expect(c.ticketLink).toContain('utm_source=timeout_nyc');
    expect(c.image).toBe('https://cdn.example.com/a.jpg');
    expect(c.description).toBe('Two sets. Bar opens early.');
    expect(c.text.split('\n')).toEqual([
      'Late Night Jazz',
      'Fri, Nov 6, 2026, 9:00 PM (doors 8:00 PM)',
      'Elsewhere, 599 Johnson Ave, Brooklyn, NY 11237, US',
      'Tickets: $20.00 - $35.00 (all-in)',
      c.ticketLink,
      'https://cdn.example.com/a.jpg',
      '',
      'Two sets. Bar opens early.',
    ]);
  });

  it('drops http images, shows online events as Online, and copes with no start', () => {
    const c = submissionCopy({ ...event, image_url: 'http://x/a.jpg', format: 'online', starts_at: null }, [], 'meetup', BASE, NOW);
    expect(c.image).toBeNull();
    expect(c.venue).toBe('Online');
    expect(c.address).toBe('');
    expect(c.when).toBe('');
    expect(c.price).toBe('');
  });

  it('caps and flattens the description', () => {
    expect(plainDescription({ description: '<p>a</p>\n\n<b>b</b>' })).toBe('a b');
    expect(plainDescription({ description: 'x'.repeat(50) }, 10)).toBe(`${'x'.repeat(9)}…`);
  });

  it('builds an address from the parts it has', () => {
    expect(addressLine({ city: 'Brooklyn', country: 'US' })).toBe('Brooklyn, US');
    expect(addressLine(null)).toBe('');
    expect(addressLine({ street: '1 Main', zip: '10001' })).toBe('1 Main, 10001');
  });
});
