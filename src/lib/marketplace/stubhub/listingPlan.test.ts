import { describe, it, expect } from 'vitest';
import { planStubHubListing, STUBHUB_ENDPOINTS, type AllocationForListing } from '.';
import { exosListingId } from '..';

const A: AllocationForListing = {
  id: '5e000000-0000-4000-8000-0000000000b1',
  requested_qty: 20,
  unit_price: null,
  internal_seats: '{[1,21)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' },
    currency: 'usd', purchase_limits: { maxPerOrder: 6, maxPerAccount: 8 },
  },
};

describe('planStubHubListing', () => {
  it('lists the allocation as blocks of at most max per order, with internal seats', () => {
    const p = planStubHubListing({ ...A, stubhubEventId: '104857' });
    expect(p.listings.map((l) => [l.listing_id, l.seat_from, l.seat_thru, l.quantity])).toEqual([
      [exosListingId(A.id, 1), 1, 6, 6], [exosListingId(A.id, 2), 7, 12, 6], [exosListingId(A.id, 3), 13, 18, 6], [exosListingId(A.id, 4), 19, 20, 2],
    ]);
    expect(p.per_order_cap).toBe(6);
    expect(p.listings[0].request).toMatchObject({ endpoint: 'createSellerListing', method: 'POST', path: '/events/104857/sellerlistings' });
    expect(p.listings[0].request.body).toMatchObject({
      external_id: exosListingId(A.id, 1), number_of_tickets: 6, split_type: 'Any',
      seating: { section: 'GA', row: 'GA', seat_from: '1', seat_to: '6' },
      ticket_price: { amount: 40, currency_code: 'USD' }, face_value: { amount: 40, currency_code: 'USD' },
      published: false, ticket_type: null,
    });
    expect(p.listings[0].request.body).not.toHaveProperty('display_number_of_tickets');
    expect(p.ticket_type_from).toEqual(['TicketTransfer', 'MobileTransfer']);
    const ep = STUBHUB_ENDPOINTS[p.listings[0].request.endpoint as keyof typeof STUBHUB_ENDPOINTS];
    expect([ep.method, ep.path]).toEqual(['POST', '/events/{eventId}/sellerlistings']);
  });

  it('uses the requested-event listing when StubHub has no event for it yet', () => {
    const p = planStubHubListing(A);
    expect(p.listings[0].request).toMatchObject({ endpoint: 'createSellerListingForRequestedEvent', path: '/sellerlistings' });
    expect(p.listings[0].request.body).toMatchObject({
      number_of_tickets: 6,
      event: { name: 'Late Night Jazz', start_date: '2026-11-06T21:00:00-05:00' },
      venue: { name: 'Blue Room', city: 'Brooklyn', state_province: 'NY' },
    });
  });

  it('prefers the listing price and the section label; one listing without a per-order limit', () => {
    const p = planStubHubListing({
      ...A, unit_price: '55', tier: { name: 'GA', price: 40, section_label: 'Floor' },
      event: { ...A.event!, purchase_limits: null }, stubhubEventId: '1',
    });
    expect(p.listings).toHaveLength(1);
    expect(p.listings[0].request.body).toMatchObject({ number_of_tickets: 20, ticket_price: { amount: 55, currency_code: 'USD' }, seating: { section: 'Floor' } });
  });

  it('refuses what it cannot list', () => {
    expect(() => planStubHubListing({ ...A, tier: null })).toThrow(/ticket type/);
    expect(() => planStubHubListing({ ...A, requested_qty: 0, stubhubEventId: '1' })).toThrow(/nothing allocated to StubHub/);
    expect(() => planStubHubListing({ ...A, event: { ...A.event!, venue_address: null } })).toThrow(/venue city/);
    expect(() => planStubHubListing({ ...A, internal_seats: null, stubhubEventId: '1' })).toThrow(/internal seat numbers/);
  });
});
