import { describe, expect, it } from 'vitest';
import { buildGeocodeUrl, parseGeocodeResponse, venueQuery } from '../../supabase/functions/_shared/geocode.ts';

describe('venueQuery (server + directions share it)', () => {
  it('uses venue_location when there is no structured address', () => {
    expect(venueQuery('Elsewhere', null, 'Bushwick, Brooklyn')).toBe('Elsewhere, Bushwick, Brooklyn');
  });
  it('ignores venue_location when it repeats the name or an address exists', () => {
    expect(venueQuery('Elsewhere', null, 'elsewhere')).toBe('Elsewhere');
    expect(venueQuery('Elsewhere', { city: 'Brooklyn' }, 'Bushwick')).toBe('Elsewhere, Brooklyn');
  });
  it('collapses whitespace', () => {
    expect(venueQuery('  Le  Poisson   Rouge ')).toBe('Le Poisson Rouge');
  });
});

describe('buildGeocodeUrl', () => {
  it('geocodes an address, biased to the US', () => {
    const u = new URL(buildGeocodeUrl({ address: 'Elsewhere, Brooklyn' }, 'KEY'));
    expect(u.origin + u.pathname).toBe('https://maps.googleapis.com/maps/api/geocode/json');
    expect(u.searchParams.get('address')).toBe('Elsewhere, Brooklyn');
    expect(u.searchParams.get('region')).toBe('us');
    expect(u.searchParams.get('key')).toBe('KEY');
  });
  it('refreshes by Place ID', () => {
    const u = new URL(buildGeocodeUrl({ placeId: 'ChIJabc' }, 'KEY'));
    expect(u.searchParams.get('place_id')).toBe('ChIJabc');
    expect(u.searchParams.has('address')).toBe(false);
  });
});

describe('parseGeocodeResponse', () => {
  it('takes the first result', () => {
    expect(parseGeocodeResponse({
      status: 'OK',
      results: [
        { place_id: 'ChIJ1', formatted_address: '599 Johnson Ave, Brooklyn, NY 11237, USA', geometry: { location: { lat: 40.7063, lng: -73.9232 } } },
        { place_id: 'ChIJ2', geometry: { location: { lat: 0, lng: 0 } } },
      ],
    })).toEqual({ status: 'ok', lat: 40.7063, lng: -73.9232, placeId: 'ChIJ1', formattedAddress: '599 Johnson Ave, Brooklyn, NY 11237, USA' });
  });
  it('maps ZERO_RESULTS and API errors', () => {
    expect(parseGeocodeResponse({ status: 'ZERO_RESULTS', results: [] })).toEqual({ status: 'zero_results' });
    expect(parseGeocodeResponse({ status: 'REQUEST_DENIED', error_message: 'API key invalid' }))
      .toEqual({ status: 'error', error: 'REQUEST_DENIED: API key invalid' });
  });
  it('rejects malformed or out-of-range results', () => {
    expect(parseGeocodeResponse(null).status).toBe('error');
    expect(parseGeocodeResponse({ status: 'OK', results: [{ place_id: 'x', geometry: { location: { lat: 91, lng: 0 } } }] }).status).toBe('error');
    expect(parseGeocodeResponse({ status: 'OK', results: [{ geometry: { location: { lat: 1, lng: 1 } } }] }).status).toBe('error');
  });
});
