import { describe, it, expect } from 'vitest';
import {
  channelsFromEnv,
  decideMatch,
  exosEventRef,
  localDate,
  normalizeSeatGeekOrder,
  normalizeStubHubSale,
  platformEventToCandidate,
  scoreMatch,
  seatGeekChannel,
  seatGeekEventSearchUrl,
  stubHubChannel,
  catalogEventToCandidate,
  type EventCandidate,
  type ExosEventRef,
} from '.';

const EV: ExosEventRef = {
  id: 'e1',
  name: 'Late Night Jazz with the Blue Trio',
  startsAt: '2026-11-07T02:00:00Z',
  occursAtLocal: '2026-11-06T21:00:00-05:00',
  venueName: 'Blue Room',
  venueCity: 'Brooklyn',
  venueRegion: 'NY',
  countryCode: 'United States',
};

const cand = (p: Partial<EventCandidate>): EventCandidate => ({
  channel: 'stubhub', externalEventId: '1', name: EV.name, startsAt: EV.startsAt,
  startsLocal: '2026-11-06T21:00:00-05:00', venueName: 'Blue Room', venueCity: 'Brooklyn', ...p,
});

describe('exosEventRef / localDate', () => {
  it('reads the row and prefers the venue-local date', () => {
    const ref = exosEventRef({
      id: 'e1', name: ' Show ', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
      venue_name: null, venue_location: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY' },
    });
    expect(ref).toMatchObject({ name: 'Show', venueName: 'Blue Room', venueCity: 'Brooklyn', venueRegion: 'NY', countryCode: null });
    expect(localDate(ref!)).toBe('2026-11-06');
    expect(localDate({ startsAt: '2026-11-07T02:00:00Z', occursAtLocal: null })).toBe('2026-11-07');
  });

  it('returns null for an event it cannot describe', () => {
    expect(exosEventRef({ id: 'x', name: '', starts_at: '2026-01-01T00:00:00Z', venue_name: 'V' })).toBeNull();
    expect(exosEventRef({ id: 'x', name: 'N', starts_at: null, venue_name: 'V' })).toBeNull();
  });
});

describe('event matching', () => {
  it('links an exact match', () => {
    const d = decideMatch(EV, [cand({}), cand({ externalEventId: '2', name: 'Morning Yoga', startsAt: '2026-11-06T14:00:00Z' })]);
    expect(d.decision).toBe('link');
    expect(d.best?.candidate.externalEventId).toBe('1');
    expect(d.best?.score).toBe(1);
  });

  it('never matches across local days, even with the same name', () => {
    const s = scoreMatch(EV, cand({ startsLocal: '2026-11-07T21:00:00-05:00', startsAt: '2026-11-08T02:00:00Z' }));
    expect(s.score).toBe(0);
    expect(decideMatch(EV, [s.candidate]).decision).toBe('none');
  });

  it('uses the local date, not the UTC one (9pm show is the 6th locally, the 7th in UTC)', () => {
    expect(scoreMatch(EV, cand({})).reasons).toContain('same day');
  });

  it('sends two near-identical candidates to review', () => {
    const d = decideMatch(EV, [cand({}), cand({ externalEventId: '2' })]);
    expect(d.decision).toBe('review');
  });

  it('sends a partial name match to review, and a different city down', () => {
    expect(decideMatch(EV, [cand({ name: 'Blue Trio', venueName: null, venueCity: null, startsAt: null })]).decision).toBe('review');
    const other = scoreMatch(EV, cand({ venueCity: 'Chicago' }));
    expect(other.reasons).toContain('different city');
    expect(other.score).toBeLessThan(scoreMatch(EV, cand({})).score);
  });

  it('finds nothing in an unrelated catalog', () => {
    expect(decideMatch(EV, [cand({ name: 'Rangers vs Devils', venueName: 'Garden', venueCity: 'New York' })]).decision).toBe('none');
    expect(decideMatch(EV, []).decision).toBe('none');
  });
});

describe('StubHub channel', () => {
  it('maps catalog events and sales', () => {
    const c = catalogEventToCandidate({
      id: 104857, name: 'Late Night Jazz', start_date: '2026-11-06T21:00:00-05:00',
      _embedded: { venue: { id: 9, name: 'Blue Room', city: 'Brooklyn' } },
      _links: { 'event:webpage': { href: 'https://www.stubhub.com/e/104857' } },
    });
    expect(c).toMatchObject({ channel: 'stubhub', externalEventId: '104857', venueCity: 'Brooklyn', url: 'https://www.stubhub.com/e/104857' });
    const sale = normalizeStubHubSale({
      id: 555, created_at: '2026-10-01T00:00:00Z', number_of_tickets: 2, status: 'Confirmed',
      proceeds: { amount: 90.5, currency_code: 'USD' }, external_listing_id: 'dist-row-1',
      confirm_by: '2026-10-02T00:00:00Z', seating: { section: 'GA' }, _embedded: { event: { id: 104857, name: 'x', start_date: 'y' } },
    });
    expect(sale).toMatchObject({
      externalOrderId: '555', externalEventId: '104857', externalListingId: 'dist-row-1', quantity: 2,
      status: 'confirmed', proceeds: { amount: 90.5, currency: 'USD' }, section: 'GA', buyerEmail: null,
    });
    expect(normalizeStubHubSale({ id: 1, status: 'SomethingNew', number_of_tickets: 1 }).status).toBe('unknown');
    expect(() => normalizeStubHubSale({})).toThrow();
  });

  it('plans event creation and URL fulfilment without a client', () => {
    const ch = stubHubChannel();
    expect(ch.capabilities).toEqual({ findEvents: false, createEvent: true, listings: true, fulfilByUrls: true });
    expect(ch.findEvents).toBeUndefined();
    const create = ch.planCreateEvent!(EV);
    expect(create).toMatchObject({ channel: 'stubhub', endpoint: 'createSellerEvent', method: 'PUT', path: '/sellerevents' });
    expect((create.body as { country?: { code: string } }).country).toEqual({ code: 'US' });
    expect(() => ch.planCreateEvent!({ ...EV, venueCity: null })).toThrow(/venue city is required/);
    const sale = normalizeStubHubSale({ id: 555, number_of_tickets: 1, status: 'Confirmed' });
    const fulfil = ch.planFulfilByUrls!(sale, ['https://x.test/bridge/claim/00000000-0000-4000-8000-000000000001']);
    expect(fulfil).toMatchObject({ endpoint: 'updateSale', method: 'PATCH', path: '/sales/555' });
    expect(() => ch.planFulfilByUrls!(sale, [])).toThrow();
  });
});

describe('SeatGeek channel', () => {
  it('cannot create events or fulfil, and searches only with a client id', () => {
    expect(seatGeekChannel().capabilities).toEqual({ findEvents: false, createEvent: false, listings: false, fulfilByUrls: false });
    expect(seatGeekChannel().planCreateEvent).toBeUndefined();
    expect(seatGeekChannel({ clientId: 'k' }).capabilities.findEvents).toBe(true);
  });

  it('searches the local day on the Platform API', async () => {
    const url = seatGeekEventSearchUrl(EV, 'cid');
    const u = new URL(url);
    expect(u.origin + u.pathname).toBe('https://api.seatgeek.com/2/events');
    expect(u.searchParams.get('datetime_local.gte')).toBe('2026-11-06T00:00:00');
    expect(u.searchParams.get('datetime_local.lte')).toBe('2026-11-06T23:59:59');
    expect(u.searchParams.get('client_id')).toBe('cid');

    const seen: string[] = [];
    const ch = seatGeekChannel({
      clientId: 'cid',
      fetch: (async (input: string) => {
        seen.push(input);
        return new Response(JSON.stringify({ events: [{
          id: 777, title: 'Late Night Jazz with the Blue Trio', datetime_local: '2026-11-06T21:00:00',
          datetime_utc: '2026-11-07T02:00:00', venue: { name: 'Blue Room', city: 'Brooklyn' },
        }] }), { status: 200 });
      }) as typeof fetch,
    });
    const found = await ch.findEvents!(EV);
    expect(seen).toHaveLength(1);
    expect(found[0]).toMatchObject({ channel: 'seatgeek', externalEventId: '777', startsAt: '2026-11-07T02:00:00Z' });
    expect(decideMatch(EV, found).decision).toBe('link');
  });

  it('keeps an explicit zone on datetime_utc', () => {
    expect(platformEventToCandidate({ id: 1, title: 't', datetime_utc: '2026-11-07T02:00:00Z' }).startsAt).toBe('2026-11-07T02:00:00Z');
  });

  it('reads Terminal-2 seatgeek_orders rows as sales', () => {
    const s = normalizeSeatGeekOrder({
      sg_order_id: 'SG-1', status: 'fulfilled', sg_event_id: 17692085, sg_listing_id: '567142963',
      sale_quantity: 4, payment_total: '533.75', created_at_sg: '2026-09-26T10:00:00Z', sale_section: 'LB104', sale_row: '9',
    });
    expect(s).toMatchObject({
      channel: 'seatgeek', externalOrderId: 'SG-1', externalEventId: '17692085', externalListingId: '567142963',
      quantity: 4, status: 'delivered', proceeds: { amount: 533.75, currency: 'USD' }, buyerEmail: null,
    });
    expect(normalizeSeatGeekOrder({ sg_order_id: 'x', status: 'confirmed' }).status).toBe('confirmed');
    expect(() => normalizeSeatGeekOrder({})).toThrow();
  });
});

describe('channelsFromEnv', () => {
  it('builds every channel; catalog search only with credentials', () => {
    const none = channelsFromEnv(() => undefined);
    expect([...none.keys()]).toEqual(['stubhub', 'seatgeek']);
    expect(none.get('stubhub')!.capabilities.findEvents).toBe(false);
    const env: Record<string, string> = { STUBHUB_CLIENT_ID: 'a', STUBHUB_CLIENT_SECRET: 'b', SEATGEEK_CLIENT_ID: 'c' };
    const all = channelsFromEnv((k) => env[k]);
    expect(all.get('stubhub')!.capabilities.findEvents).toBe(true);
    expect(all.get('seatgeek')!.capabilities.findEvents).toBe(true);
  });
});
