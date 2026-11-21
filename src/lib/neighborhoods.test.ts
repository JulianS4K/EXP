import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  clampDays, distanceMeters, groupByDay, neighborhoodJsonLd, neighborhoodOf, normalizeSlug, pageDescription, pageTitle,
  parsePage, parseSummaries, type NeighborhoodCircle,
} from './neighborhoods';

const MIG = readFileSync(resolve(__dirname, '../../supabase/migrations/20261111110000_exos_neighborhoods.sql'), 'utf8');

/** The seeded circles, read from the migration so the two can't drift. */
function seeded(): NeighborhoodCircle[] {
  const re = /\('([a-z0-9-]+)',\s*'nyc',\s*'[^']+',\s*'[^']+',\s*([\d.-]+),\s*([\d.-]+),\s*(\d+),\s*\d+\)/g;
  return [...MIG.matchAll(re)].map((m) => ({ slug: m[1], lat: Number(m[2]), lng: Number(m[3]), radiusM: Number(m[4]) }));
}

describe('distanceMeters (the same pairs as tests/exos/test_neighborhoods.sql)', () => {
  it('matches exos_geo_distance_m', () => {
    expect(distanceMeters(40.699, -73.92, 40.7128, -73.957)).toBeCloseTo(3475.9, 0);
    expect(distanceMeters(40.758, -73.9855, 40.6413, -73.7781)).toBeCloseTo(21773.4, 0);
    expect(distanceMeters(40.7096, -73.9235, 40.7096, -73.9235)).toBe(0);
  });
});

describe('neighborhoodOf', () => {
  const circles = seeded();
  it('reads every seeded neighborhood from the migration', () => {
    expect(circles.length).toBeGreaterThanOrEqual(11);
    for (const slug of ['bushwick', 'williamsburg', 'greenpoint', 'ridgewood', 'lower-east-side', 'east-village', 'harlem',
      'crown-heights', 'bed-stuy', 'astoria', 'long-island-city']) {
      expect(circles.map((c) => c.slug)).toContain(slug);
    }
  });
  it('places venues as the SQL does: nearest center inside its circle', () => {
    expect(neighborhoodOf(40.7096, -73.9235, circles)).toBe('bushwick'); // Elsewhere
    expect(neighborhoodOf(40.758, -73.9855, circles)).toBe('midtown'); // Times Square
    expect(neighborhoodOf(40.7205, -73.985, circles)).toBe('lower-east-side'); // inside LES and East Village: LES is nearer
    expect(neighborhoodOf(40.5795, -74.1502, circles)).toBeNull(); // Staten Island
  });
});

describe('page text', () => {
  it('normalizes slugs and clamps the window', () => {
    expect(normalizeSlug(' Bushwick ')).toBe('bushwick');
    expect(normalizeSlug('long-island-city')).toBe('long-island-city');
    expect(normalizeSlug('../etc')).toBeNull();
    expect(normalizeSlug('')).toBeNull();
    expect(clampDays(99)).toBe(14);
    expect(clampDays('3')).toBe(3);
    expect(clampDays('x')).toBe(7);
  });
  it('titles and descriptions', () => {
    expect(pageTitle('Bushwick')).toBe('This week in Bushwick');
    expect(pageTitle('Bushwick', 14)).toBe('The next 14 days in Bushwick');
    expect(pageDescription('Bushwick', 1)).toBe('1 live event in Bushwick, New York, this week: all-in prices, tickets on Exos.');
    expect(pageDescription('Bushwick', 0)).toContain('Nothing listed this week yet.');
  });
});

const PAGE = {
  neighborhood: { slug: 'bushwick', name: 'Bushwick', borough: 'Brooklyn', city: 'nyc', timezone: 'America/New_York' },
  days: 7,
  events: [
    { id: 'e2', name: 'Late', starts_at: '2026-11-14T03:00:00+00:00', venue_name: 'Elsewhere', venue_location: 'Brooklyn, NY',
      currency: 'usd', from_price: 25, sold_out: false, org: { name: 'Org', slug: 'org' } },
    { id: 'e1', name: 'Early', starts_at: '2026-11-13T23:00:00+00:00', currency: 'usd', from_price: null, org: { name: 'Org', slug: 'org' } },
    { id: 'bad' },
  ],
};

describe('parsing and JSON-LD', () => {
  it('parses the RPC answers, dropping malformed rows; no admin count unless sent', () => {
    expect(parseSummaries([{ slug: 'bushwick', name: 'Bushwick', borough: 'Brooklyn', events: '3' }, { slug: '' }]))
      .toEqual([{ slug: 'bushwick', name: 'Bushwick', borough: 'Brooklyn', events: 3 }]);
    const p = parsePage(PAGE)!;
    expect(p.events.map((e) => e.id)).toEqual(['e2', 'e1']);
    expect(p.missingCoordinates).toBeNull();
    expect(parsePage({ ...PAGE, missing_coordinates: 4 })!.missingCoordinates).toBe(4);
    expect(parsePage(null)).toBeNull();
  });
  it('groups by day in the neighborhood zone (11 PM UTC on the 13th is the 13th in New York; 3 AM UTC on the 14th too)', () => {
    const p = parsePage(PAGE)!;
    const days = groupByDay(p.events, 'America/New_York');
    expect(days).toHaveLength(1);
    expect(days[0].day).toBe('Fri, Nov 13');
    expect(days[0].events.map((e) => e.id)).toEqual(['e1', 'e2']);
  });
  it('builds a CollectionPage with an ItemList of events', () => {
    const p = parsePage(PAGE)!;
    const ld = neighborhoodJsonLd(p, 'https://exos.example/bridge/nyc/bushwick', (id) => `https://exos.example/bridge/event/${id}`) as any;
    expect(ld['@type']).toBe('CollectionPage');
    expect(ld.name).toBe('This week in Bushwick');
    expect(ld.mainEntity.numberOfItems).toBe(2);
    const first = ld.mainEntity.itemListElement[0];
    expect(first.position).toBe(1);
    expect(first.item['@type']).toBe('Event');
    expect(first.item.offers).toMatchObject({ price: 25, priceCurrency: 'USD' });
    expect(ld.mainEntity.itemListElement[1].item.offers).toBeUndefined();
    expect(JSON.stringify(ld)).not.toContain('"bad"');
  });
});
