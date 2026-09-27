import { describe, expect, it } from 'vitest';
import {
  formatSeatRanges,
  parseSeatRanges,
  seatBlocks,
  seatCount,
  seatGeekDelist,
  seatGeekSync,
  stubHubDelist,
  stubHubSync,
} from '.';
import { exosSellerListingId, planSeatGeekListings, type SeatGeekAllocation } from './seatgeek';
import type { PlannedListing } from './stubhub';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';

describe('internal seat numbers', () => {
  it('parses Postgres multiranges', () => {
    expect(parseSeatRanges('{[1,5),[11,13)}')).toEqual([{ from: 1, thru: 4 }, { from: 11, thru: 12 }]);
    expect(parseSeatRanges('{}')).toEqual([]);
    expect(parseSeatRanges(null)).toEqual([]);
    expect(parseSeatRanges('{[3,5],(6,9)}')).toEqual([{ from: 3, thru: 5 }, { from: 7, thru: 8 }]);
    // Adjacent runs merge.
    expect(parseSeatRanges([{ from: 5, thru: 6 }, { from: 1, thru: 4 }])).toEqual([{ from: 1, thru: 6 }]);
    expect(() => parseSeatRanges('1-4')).toThrow(/seat range/);
  });

  it('counts, blocks and formats', () => {
    const r = parseSeatRanges('{[1,6),[11,13)}');
    expect(seatCount(r)).toBe(7);
    expect(seatBlocks(r, 2)).toEqual([{ from: 1, thru: 2 }, { from: 3, thru: 4 }, { from: 5, thru: 5 }, { from: 11, thru: 12 }]);
    expect(seatBlocks(r, null)).toEqual(r);
    expect(formatSeatRanges(parseSeatRanges('{[1,5),[7,8)}'))).toBe('1-4, 7');
  });
});

describe('SeatGeek sync', () => {
  const a: SeatGeekAllocation = {
    id: ALLOC,
    requested_qty: 6,
    unit_price: 45,
    internal_seats: '{[1,7)}',
    tier: { name: 'GA', price: 40 },
    event: {
      name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
      venue_name: 'Blue Room', venue_address: { city: 'Brooklyn' }, currency: 'USD', purchase_limits: { maxPerOrder: 4 },
    },
  };

  it('creates everything when SeatGeek has nothing (dry-run)', () => {
    const s = seatGeekSync(planSeatGeekListings(a), null);
    expect(s.action).toBe('create');
    expect(s.ops.create).toEqual([exosSellerListingId(ALLOC, 1), exosSellerListingId(ALLOC, 2)]);
  });

  it('diffs against what SeatGeek has: update, delete, nothing', () => {
    const live = planSeatGeekListings(a);
    expect(seatGeekSync(live, live).action).toBe('none');
    // Listing 2 (5-6) sold out; the price went up.
    const next = planSeatGeekListings({ ...a, requested_qty: 4, internal_seats: '{[1,5)}', unit_price: 50, previous: live.listings.map((l) => l.body) });
    const s = seatGeekSync(next, live);
    expect(s.action).toBe('update');
    expect(s.ops.create).toEqual([]);
    expect(s.ops.update).toEqual([{ seller_listing_id: exosSellerListingId(ALLOC, 1), patch: { cost: 50 } }]);
    expect(s.ops.delete).toEqual([exosSellerListingId(ALLOC, 2)]);
  });

  it('delists only Exos listings', () => {
    const live = planSeatGeekListings(a);
    const d = seatGeekDelist({ listings: [...live.listings, { body: { seller_listing_id: 'broker-123' } }] });
    expect(d).toMatchObject({ action: 'delist', endpoint: 'bulkDeleteListings', path: '/listings/bulk-delete' });
    expect(d!.body!.seller_listing_ids).toEqual([exosSellerListingId(ALLOC, 1), exosSellerListingId(ALLOC, 2)]);
    expect(seatGeekDelist(null)).toBeNull();
  });
});

describe('StubHub sync', () => {
  const plan: PlannedListing = {
    endpoint: 'createSellerListing', method: 'POST', path: '/events/1/sellerlistings',
    body: { external_id: ALLOC, number_of_tickets: 10, ticket_price: { amount: 40, currency_code: 'USD' }, display_number_of_tickets: 4 },
    display_cap: 4, ticket_type_from: [],
  };

  it('creates, then updates only what changed', () => {
    expect(stubHubSync(plan, null, ALLOC).action).toBe('create');
    expect(stubHubSync(plan, plan, ALLOC).action).toBe('none');
    const s = stubHubSync({ ...plan, body: { ...plan.body, number_of_tickets: 8 } }, plan, ALLOC);
    expect(s.action).toBe('update');
    expect(s.update).toEqual({
      endpoint: 'updateSellerListingByExternalId', method: 'PATCH', path: `/externalsellerlistings/${ALLOC}`, body: { number_of_tickets: 8 },
    });
    expect(stubHubDelist(ALLOC)).toMatchObject({ action: 'delist', method: 'DELETE', path: `/externalsellerlistings/${ALLOC}` });
  });
});
