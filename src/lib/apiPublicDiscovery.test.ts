// Public discovery and signups with no credential (mig 20261105110000,
// exos-api/publicApi.ts): routes, query args, and all-in pricing.

import { describe, expect, it } from 'vitest';
import {
  cleanSearch, isoOf, pricePublicEvent, PUBLIC_READS, PUBLIC_WRITES, PublicParamError, publicReadArgs, publicTicketType,
  searchQuery, venueRef,
} from '../../supabase/functions/_shared/api/publicDiscovery.ts';
import { matchRoute, publicAuthAt, ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import { allInCents, effectiveTierPrice } from '../../supabase/functions/_shared/pricing.ts';
import { parseUnitFees } from '../../supabase/functions/_shared/fees.ts';

const PRICING = { scheduled: effectiveTierPrice, allIn: allInCents, fees: parseUnitFees };
const U = '7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

describe('public routes', () => {
  const pub = ROUTES.filter((r) => r.auth === 'public');

  it('every public route is a read or a signup, with no scope', () => {
    expect(pub.map((r) => r.id).sort()).toEqual([...Object.keys(PUBLIC_READS), ...PUBLIC_WRITES].sort());
    for (const r of pub) {
      expect(r.scope, r.id).toBeNull();
      expect(r.path.startsWith('/public/'), r.id).toBe(true);
      expect(r.method, r.id).toBe(PUBLIC_WRITES.has(r.id) ? 'POST' : 'GET');
    }
  });

  it('dispatch by path keeps the three /public families apart', () => {
    expect(publicAuthAt('/public/venues')).toBe('public');
    expect(publicAuthAt(`/public/discovery/events/${U}`)).toBe('public');
    expect(publicAuthAt('/public/website_event_series')).toBe('public');
    expect(publicAuthAt('/public/events')).toBe('shared_key');
    expect(publicAuthAt(`/public/confirms/${U}/ticket_types`)).toBe('partner_key');
    expect(matchRoute('GET', '/public/discovery/confirms')?.route.id).toBe('public-discovery-events');
    expect(matchRoute('POST', `/public/forms/${U}/submissions`)?.route.id).toBe('public-create-form-submission');
  });
});

describe('query args', () => {
  it('search words are letters, digits and a little punctuation', () => {
    expect(cleanSearch("  Rock_%n' Roll*  ")).toBe("Rock n' Roll");
    expect(searchQuery(new URLSearchParams('query=jazz'))).toBe('jazz');
    expect(() => searchQuery(new URLSearchParams('q=%25'))).toThrow(PublicParamError);
  });

  it('organizer by id or slug; ISO times', () => {
    expect(venueRef(U.toUpperCase())).toEqual({ id: U });
    expect(venueRef('blue-room')).toEqual({ slug: 'blue-room' });
    expect(venueRef('Blue Room')).toBeNull();
    expect(isoOf(new URLSearchParams('a=2026-12-01'), 'a')).toBe('2026-12-01T00:00:00.000Z');
    expect(() => isoOf(new URLSearchParams('a=soon'), 'a')).toThrow(/ISO 8601/);
  });

  it('per route', () => {
    expect(publicReadArgs('public-discovery-events', new URLSearchParams('q=j&venue_id=blue-room&starts_after=2026-12-01')))
      .toEqual({ venue: 'blue-room', starts_after: '2026-12-01T00:00:00.000Z' });
    expect(publicReadArgs('public-venues', new URLSearchParams('q=blue'))).toEqual({ q: 'blue' });
    expect(() => publicReadArgs('public-event-series-list', new URLSearchParams())).toThrow(/venue_id/);
    expect(() => publicReadArgs('public-discovery-events', new URLSearchParams('venue_id=Not A Slug'))).toThrow(/venue_id/);
    expect(publicReadArgs('public-discovery-event', new URLSearchParams('q=x'))).toEqual({});
  });
});

describe('all-in prices', () => {
  const now = new Date('2026-11-05T12:00:00Z');
  const base = { id: U, event_id: U, name: 'GA', price: 25, exclusive_tax_percent: 0, sold_out: false };

  it('a ticket type shows the all-in price and nothing that adds to it', () => {
    const fee = [{ calc: 'fixed', amount_cents: 300, taxable: false }];
    const t = publicTicketType({ ...base, passed_on_fees: fee }, now, PRICING);
    expect(t).toEqual({ id: U, name: 'GA', description: null, price_cents: allInCents(2500, 0, parseUnitFees(fee)),
                        on_sale: true, sold_out: false, sales_start: null, sales_end: null });
    expect(t.price_cents).toBeGreaterThan(2500);
    expect(Object.keys(t)).not.toContain('passed_on_fees');
  });

  it('price schedule, tax and sales window', () => {
    const t = publicTicketType({ ...base, exclusive_tax_percent: 10,
      price_schedule: [{ price: 30, startsAt: '2026-11-01T00:00:00Z' }] }, now, PRICING);
    expect(t.price_cents).toBe(3300);
    expect(publicTicketType({ ...base, sales_start: '2026-12-01T00:00:00Z' }, now, PRICING).on_sale).toBe(false);
    expect(publicTicketType({ ...base, sales_end: '2026-11-01T00:00:00Z' }, now, PRICING).on_sale).toBe(false);
    expect(publicTicketType({ ...base, sold_out: true }, now, PRICING).on_sale).toBe(false);
  });

  it("an event's from price is the lowest on sale; the base price is dropped", () => {
    const cheap = publicTicketType({ ...base, price: 10, sold_out: true }, now, PRICING);
    const ga = publicTicketType(base, now, PRICING);
    const e = pricePublicEvent({ id: U, name: 'Show', from_price: 10, ticket_types: [{}] }, [cheap, ga], false);
    expect(e).toEqual({ id: U, name: 'Show', from_price_cents: ga.price_cents });
    expect(pricePublicEvent({ id: U, from_price: 10 }, [cheap], true)).toEqual({ id: U, from_price_cents: 1000, ticket_types: [cheap] });
    expect(pricePublicEvent({ id: U }, [], false)).toEqual({ id: U, from_price_cents: null });
  });
});
