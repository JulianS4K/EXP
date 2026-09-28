import { describe, expect, it } from 'vitest';
import { EXOS_TRANSFER_STOCK, type ExosAllocation } from '.';
import { planStubHubListing } from './stubhub';
import { planSeatGeekListings } from './seatgeek';
import { planGametimeListings } from './gametime';
import { planGoTicketsListings } from './gotickets';
import { planVividListings } from './vivid';
import { planTevoListings } from './tevo';

const A: ExosAllocation = {
  id: '0f8fad5b-d9cb-469f-a165-70867728950e',
  requested_qty: 4,
  unit_price: 45,
  internal_seats: '{[1,5)}',
  tier: { name: 'GA', price: 40 },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    venue_name: 'Blue Room', venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
  },
};

describe('every marketplace lists Exos tickets as mobile or electronic transfer', () => {
  it('uses the one standard in each plan', () => {
    const body = <T>(p: { listings: Array<{ request: { body: T } }> }) => p.listings[0].request.body;
    expect(planStubHubListing(A).ticket_type_from).toEqual(['MobileTransfer', 'ElectronicTransfer']);
    expect(body(planSeatGeekListings(A))).toMatchObject({ stock_type: 'mobile', is_edelivery: true });
    expect(body(planGametimeListings(A))).toMatchObject({ Stock: 'mobile_transfer', edelivery_ind: 'Y' });
    expect(body(planGoTicketsListings(A))).toMatchObject({ stockType: 'MOBILE_TICKETS' });
    expect(body(planVividListings(A))).toMatchObject({ stockType: 'ELECTRONIC', electronicTransfer: true });
    expect(body(planTevoListings(A))).toMatchObject({ inventory: { ticket: { format: 'TM_mobile' } } });
    expect(Object.keys(EXOS_TRANSFER_STOCK).sort()).toEqual(['evo', 'gametime', 'gotickets', 'seatgeek', 'stubhub', 'vivid']);
  });
});
