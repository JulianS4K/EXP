import { describe, it, expect } from 'vitest';
import { planStubHubListing, STUBHUB_ENDPOINTS, type AllocationForListing } from '.';

const A: AllocationForListing = {
  id: '5e000000-0000-0000-0000-0000000000b1',
  requested_qty: 20,
  unit_price: null,
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' },
    currency: 'usd', purchase_limits: { maxPerOrder: 6, maxPerAccount: 8 },
  },
};

describe('planStubHubListing', () => {
  it('lists the whole allocation, showing at most max-per-order at a time', () => {
    const p = planStubHubListing({ ...A, stubhubEventId: '104857' });
    expect(p).toMatchObject({ endpoint: 'createSellerListing', method: 'POST', path: '/events/104857/sellerlistings', display_cap: 6 });
    expect(p.body).toMatchObject({
      external_id: A.id, number_of_tickets: 20, display_number_of_tickets: 6, split_type: 'AvoidOne',
      seating: { section: 'GA' }, ticket_price: { amount: 40, currency_code: 'USD' }, published: false, ticket_type: null,
    });
    expect(p.ticket_type_from).toEqual(['TicketTransfer', 'MobileTransfer']);
    const ep = STUBHUB_ENDPOINTS[p.endpoint];
    expect([ep.method, ep.path]).toEqual(['POST', '/events/{eventId}/sellerlistings']);
  });

  it('uses the requested-event listing when StubHub has no event for it yet', () => {
    const p = planStubHubListing(A);
    expect(p).toMatchObject({ endpoint: 'createSellerListingForRequestedEvent', path: '/sellerlistings' });
    expect(p.body).toMatchObject({
      number_of_tickets: 20, display_number_of_tickets: 6,
      event: { name: 'Late Night Jazz', start_date: '2026-11-06T21:00:00-05:00' },
      venue: { name: 'Blue Room', city: 'Brooklyn', state_province: 'NY' },
    });
  });

  it('prefers the listing price and the section label; no cap without a per-order limit', () => {
    const p = planStubHubListing({
      ...A, unit_price: '55', tier: { name: 'GA', price: 40, section_label: 'Floor' },
      event: { ...A.event!, purchase_limits: null }, stubhubEventId: '1',
    });
    expect(p.body).toMatchObject({ ticket_price: { amount: 55, currency_code: 'USD' }, seating: { section: 'Floor' } });
    expect(p.body).not.toHaveProperty('display_number_of_tickets');
    expect(p.display_cap).toBeNull();
  });

  it('refuses what it cannot list', () => {
    expect(() => planStubHubListing({ ...A, tier: null })).toThrow(/ticket type/);
    expect(() => planStubHubListing({ ...A, requested_qty: 0, stubhubEventId: '1' })).toThrow(/requested_qty/);
    expect(() => planStubHubListing({ ...A, event: { ...A.event!, venue_address: null } })).toThrow(/venue city/);
  });
});
