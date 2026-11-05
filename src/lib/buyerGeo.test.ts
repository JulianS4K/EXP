import { describe, expect, it } from 'vitest';
import { cityLabel, countryName, countryRows, mixedCurrencies, parseBuyerGeo, sharePct } from './buyerGeo';

// exos_event_buyer_geo's answer (tests/exos/test_buyer_geo_genre.sql BG3).
const RAW = {
  org_id: 'o', event_id: 'e', since: null, orders: 8, tickets: 9, located_orders: 6, unknown_orders: 2,
  countries: [
    { country: 'US', currency: 'USD', orders: 4, tickets: 5, gross_cents: 10500 },
    { country: 'GB', currency: 'USD', orders: 1, tickets: 1, gross_cents: 3000 },
  ],
  cities: [
    { country: 'US', region: 'NY', city: 'New York', currency: 'USD', orders: 3, tickets: 4, gross_cents: 8000 },
    { country: 'GB', region: 'England', city: 'London', currency: 'USD', orders: 1, tickets: 1, gross_cents: 3000 },
  ],
  unknown: [{ country: null, currency: 'USD', orders: 2, tickets: 2, gross_cents: 2000 }],
  other_tickets: 2,
};

describe('buyer locations report', () => {
  it('parses the RPC answer', () => {
    const r = parseBuyerGeo(RAW)!;
    expect(r.orders).toBe(8);
    expect(r.countries[0]).toEqual({ country: 'US', region: null, city: null, currency: 'USD', orders: 4, tickets: 5, gross_cents: 10500 });
    expect(r.other_tickets).toBe(2);
    expect(parseBuyerGeo(null)).toBeNull();
    expect(parseBuyerGeo({})).toMatchObject({ orders: 0, countries: [], cities: [], unknown: [] });
  });
  it('puts the unknown row after the countries', () => {
    const rows = countryRows(parseBuyerGeo(RAW)!);
    expect(rows.map((r) => r.country)).toEqual(['US', 'GB', null]);
    expect(countryRows(parseBuyerGeo({ ...RAW, unknown: [{ country: null, currency: 'USD', orders: 0 }] })!)).toHaveLength(2);
  });
  it('names places', () => {
    expect(countryName('US', 'en')).toBe('United States');
    expect(countryName(null)).toBe('Unknown');
    const r = parseBuyerGeo(RAW)!;
    expect(cityLabel(r.cities[0], 'en')).toBe('New York, NY');
    expect(cityLabel(r.cities[1], 'en')).toBe('London, United Kingdom');
  });
  it('shares and currencies', () => {
    expect(sharePct(4, 8)).toBe(50);
    expect(sharePct(1, 0)).toBe(0);
    expect(mixedCurrencies(parseBuyerGeo(RAW)!)).toBe(false);
    expect(mixedCurrencies(parseBuyerGeo({ ...RAW, unknown: [{ country: null, currency: 'EUR', orders: 1 }] })!)).toBe(true);
  });
});
