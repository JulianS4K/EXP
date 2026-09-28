import { describe, expect, it } from 'vitest';
import {
  SELLER_FEES,
  netEqualListCents,
  netEqualListPrice,
  payoutCents,
  planExosListings,
  sellerFeeCents,
  type ExosAllocation,
  type SplitChannel,
} from '.';
import { planGametimeListings } from './gametime';
import { planSeatGeekListings } from './seatgeek';
import { planTevoListings } from './tevo';

const CHANNELS: SplitChannel[] = ['stubhub', 'seatgeek', 'gametime', 'gotickets', 'vivid', 'evo'];

describe('seller fees', () => {
  it('match the rates measured on real orders', () => {
    expect(sellerFeeCents('evo', 3248)).toBe(97); // TEvo 8089940-19196777
    expect(sellerFeeCents('evo', 95760)).toBe(2873); // 8090084-19197170
    expect(sellerFeeCents('evo', 2150)).toBe(65); // half a cent rounds up
    expect(sellerFeeCents('seatgeek', 27600)).toBe(1380); // SeatGeek grvru3xr89l
    expect(sellerFeeCents('seatgeek', 13905)).toBeCloseTo(695.25, 6); // unrounded
    for (const ch of ['stubhub', 'gametime', 'gotickets', 'vivid'] as const) {
      expect(SELLER_FEES[ch]).toBeNull();
      expect(sellerFeeCents(ch, 10000)).toBe(0);
    }
  });
});

describe('net-equal list price', () => {
  it('is the smallest price that nets at least the Exos price, for any quantity', () => {
    for (const ch of CHANNELS) {
      for (const target of [1, 99, 500, 3248, 4000, 4011, 11278, 24819, 99999]) {
        const list = netEqualListCents(ch, target);
        for (let n = 1; n <= 12; n++) expect(payoutCents(ch, list, n), `${ch} ${target} x${n}`).toBeGreaterThanOrEqual(target * n);
        if (list > target) expect(payoutCents(ch, list - 2, 1), `${ch} ${target} tight`).toBeLessThan(target);
      }
    }
  });

  it('grosses up by the store fee, and leaves unknown stores at the Exos price', () => {
    expect(netEqualListPrice('seatgeek', 40)).toBe(42.11); // 42.11 x 0.95 = 40.0045
    expect(netEqualListPrice('evo', 40)).toBe(41.25); // 41.25 - 1.24 = 40.01
    expect(netEqualListPrice('vivid', 40)).toBe(40);
    expect(netEqualListPrice('stubhub', 40)).toBe(40);
  });
});

describe('planners list net-equal', () => {
  const alloc = (over: Partial<ExosAllocation> = {}): ExosAllocation => ({
    id: '0f8fad5b-d9cb-469f-a165-70867728950e',
    requested_qty: 4,
    unit_price: null,
    internal_seats: '{[1,5)}',
    tier: { name: 'GA', price: 40 },
    event: {
      name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
      timezone: 'America/New_York', venue_name: 'Blue Room', venue_address: { city: 'Brooklyn' }, currency: 'USD',
      purchase_limits: { maxPerOrder: 4 },
    },
    ...over,
  });

  it('prices each store so the organizer nets the Exos price there', () => {
    expect(planSeatGeekListings(alloc()).listings[0].request.body.cost).toBe(42.11);
    expect(planTevoListings(alloc()).listings[0].request.body.inventory.ticket.price).toBe(41.25);
    expect(planGametimeListings(alloc()).listings[0].request.body.Cost).toBe('40.00');
    const set = planExosListings(alloc(), 'SeatGeek', 'seatgeek');
    expect(set.listings[0]).toMatchObject({ price: 42.11, exos_price: 40 });
    // The listed price rides on every stored entry, for the fee on each sale.
    expect(planSeatGeekListings(alloc()).listings[0].unit_price).toBe(42.11);
  });

  it("keeps the organizer's higher marketplace price, and lifts a lower one to net-equal", () => {
    expect(planSeatGeekListings(alloc({ unit_price: 50 })).listings[0].request.body.cost).toBe(50);
    expect(planSeatGeekListings(alloc({ unit_price: 41 })).listings[0].request.body.cost).toBe(42.11);
  });
});
