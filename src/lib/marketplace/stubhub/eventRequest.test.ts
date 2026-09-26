import { describe, it, expect } from 'vitest';
import {
  ListingMappingError,
  countryCode,
  exosEventForListing,
  planStubHubEventRequest,
  type ExosEventRow,
} from './listing';
import { STUBHUB_ENDPOINTS } from './endpoints';

const ROW: ExosEventRow = {
  name: '  Late Night Jazz ',
  starts_at: '2026-11-07T02:00:00+00:00',
  venue_name: 'Blue Room',
  venue_location: 'Blue Room',
  venue_address: { street: '1 Main St', city: 'Brooklyn', region: 'NY', country: 'United States', postal: '11201' },
};

describe('planStubHubEventRequest', () => {
  it('builds the PUT /sellerevents body from the exos_events row', () => {
    const plan = planStubHubEventRequest(ROW);
    expect(plan).toEqual({
      endpoint: 'createSellerEvent',
      method: 'PUT',
      path: '/sellerevents',
      body: {
        event: { name: 'Late Night Jazz', start_date: '2026-11-07T02:00:00.000Z', date_confirmed: true },
        venue: { name: 'Blue Room', city: 'Brooklyn', state_province: 'NY' },
        country: { code: 'US' },
      },
    });
  });

  it('plans the same call the writer would make', () => {
    const plan = planStubHubEventRequest(ROW);
    const ep = STUBHUB_ENDPOINTS[plan.endpoint];
    expect([ep.method, ep.path, ep.access]).toEqual([plan.method, plan.path, 'write']);
  });

  it('falls back to venue_location for the venue name', () => {
    const plan = planStubHubEventRequest({ ...ROW, venue_name: ' ', venue_location: 'The Hall' });
    expect(plan.body.venue.name).toBe('The Hall');
  });

  it('leaves out region and country when they are missing or unknown', () => {
    const plan = planStubHubEventRequest({ ...ROW, venue_address: { city: 'Lagos', country: 'Nigeria' } });
    expect(plan.body.venue).toEqual({ name: 'Blue Room', city: 'Lagos' });
    expect(plan.body.country).toBeUndefined();
  });

  it('refuses a row it cannot describe, saying what to fix', () => {
    const bad: Array<[Partial<ExosEventRow>, RegExp]> = [
      [{ venue_address: null }, /venue city is required/],
      [{ venue_address: { city: '  ' } }, /venue city is required/],
      [{ name: '' }, /event name is required/],
      [{ starts_at: null }, /start time is required/],
      [{ starts_at: 'not a date' }, /not a date/],
      [{ venue_name: null, venue_location: null }, /venue name is required/],
    ];
    for (const [patch, msg] of bad) {
      expect(() => planStubHubEventRequest({ ...ROW, ...patch })).toThrow(ListingMappingError);
      expect(() => planStubHubEventRequest({ ...ROW, ...patch })).toThrow(msg);
    }
  });
});

describe('exosEventForListing', () => {
  it('reads the structured address', () => {
    expect(exosEventForListing(ROW)).toEqual({
      name: 'Late Night Jazz',
      startsAt: '2026-11-07T02:00:00+00:00',
      venueName: 'Blue Room',
      venueCity: 'Brooklyn',
      venueStateProvince: 'NY',
      countryCode: 'US',
    });
  });
});

describe('countryCode', () => {
  it('maps the usual spellings of free-text countries', () => {
    for (const s of ['US', 'us', 'U.S.', 'USA', 'U.S.A.', 'United States', ' united  states ']) expect(countryCode(s)).toBe('US');
    expect(countryCode('UK')).toBe('GB');
    expect(countryCode('Canada')).toBe('CA');
  });

  it('returns undefined rather than guessing', () => {
    for (const s of ['', '  ', 'Atlantis', 'U', undefined, null, 42]) expect(countryCode(s)).toBeUndefined();
  });
});
