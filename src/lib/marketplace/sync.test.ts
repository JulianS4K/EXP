import { describe, expect, it } from 'vitest';
import {
  formatSeatRanges,
  parseSeatRanges,
  seatBlocks,
  seatCount,
  planDelist,
  syncListings,
} from '.';
import { planGametimeListings } from './gametime';
import { exosSellerListingId, planSeatGeekListings, type SeatGeekAllocation } from './seatgeek';
import { planStubHubListing, type AllocationForListing } from './stubhub';

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

describe('SeatGeek sync', () => {

  it('creates everything when SeatGeek has nothing (dry-run)', () => {
    const s = syncListings(planSeatGeekListings(a), null);
    expect(s.action).toBe('create');
    expect(s.ops.create).toEqual([exosSellerListingId(ALLOC, 1), exosSellerListingId(ALLOC, 2)]);
  });

  it('diffs against what the marketplace has: update, delete, nothing', () => {
    const live = planSeatGeekListings(a);
    expect(syncListings(live, live).action).toBe('none');
    // Listing 2 (5-6) sold out; the price went up.
    const next = planSeatGeekListings({ ...a, requested_qty: 4, internal_seats: '{[1,5)}', unit_price: 50, previous: live });
    const s = syncListings(next, live);
    expect(s.action).toBe('update');
    expect(s.ops.create).toEqual([]);
    expect(s.ops.update).toEqual([{ listing_id: exosSellerListingId(ALLOC, 1), patch: { cost: 50 } }]);
    expect(s.ops.delete).toEqual([exosSellerListingId(ALLOC, 2)]);
  });

  it('delists only Exos listings, the way each marketplace takes it', () => {
    const live = planSeatGeekListings(a);
    const withBroker = { listings: [...live.listings, { listing_id: 'broker-123' }] };
    const d = planDelist('seatgeek', withBroker);
    expect(d?.requests).toEqual([{
      endpoint: 'bulkDeleteListings', method: 'POST', path: '/listings/bulk-delete',
      body: { seller_listing_ids: [exosSellerListingId(ALLOC, 1), exosSellerListingId(ALLOC, 2)] },
    }]);
    expect(planDelist('stubhub', withBroker)?.requests.map((r) => [r.method, r.path])).toEqual([
      ['DELETE', `/externalsellerlistings/${exosSellerListingId(ALLOC, 1)}`],
      ['DELETE', `/externalsellerlistings/${exosSellerListingId(ALLOC, 2)}`],
    ]);
    expect(planDelist('seatgeek', null)).toBeNull();
  });
});

describe('the same listings on every marketplace', () => {
  const sh: AllocationForListing = { ...a, event: { ...a.event!, venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' } } };

  it('StubHub, SeatGeek and Gametime get the same blocks, ids and seats', () => {
    const shape = (p: { listings: Array<{ listing_id: string; seat_from: number; seat_thru: number; quantity: number }> }) =>
      p.listings.map((l) => [l.listing_id, l.seat_from, l.seat_thru, l.quantity]);
    const want = [[exosSellerListingId(ALLOC, 1), 1, 4, 4], [exosSellerListingId(ALLOC, 2), 5, 6, 2]];
    expect(shape(planStubHubListing(sh))).toEqual(want);
    expect(shape(planSeatGeekListings(a))).toEqual(want);
    expect(shape(planGametimeListings(a))).toEqual(want);
    // StubHub: external_id is the Exos listing id, the block's seats, no display cap.
    expect(planStubHubListing(sh).listings[1].request.body).toMatchObject({
      external_id: exosSellerListingId(ALLOC, 2), number_of_tickets: 2, split_type: 'Any',
      seating: { section: 'General Admission', row: 'GA', seat_from: '5', seat_to: '6' },
    });
    expect(planStubHubListing(sh).listings[0].request.body).not.toHaveProperty('display_number_of_tickets');
  });

  it('StubHub updates and delists through the same sync', () => {
    const live = planStubHubListing({ ...sh, stubhubEventId: '1' });
    const next = planStubHubListing({ ...sh, stubhubEventId: '1', unit_price: 50, previous: live });
    expect(syncListings(next, live).ops.update.map((u) => Object.keys(u.patch))).toEqual([['ticket_price'], ['ticket_price']]);
  });
});

describe('a live listing waiting to shrink', () => {
  it('lists the lowest list_qty seats; the rest stay held', () => {
    // Holds 6 (seats 1-6) but should show 2 until the marketplace takes it.
    const p = planSeatGeekListings({ ...a, list_qty: 2 });
    expect(p.listings.map((l) => [l.seat_from, l.seat_thru, l.quantity])).toEqual([[1, 2, 2]]);
    expect(() => planSeatGeekListings({ ...a, list_qty: 7 })).toThrow(/internal seat numbers/);
  });
});
