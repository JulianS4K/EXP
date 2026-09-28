import { describe, expect, it } from 'vitest';
import {
  LISTING_FIELD_MAP,
  LISTING_ID_FIELDS,
  assertListingId,
  buyableQuantities,
  exosListingId,
  marketSplitFor,
  parseMarketSplit,
  planExosListings,
  splitBlockMax,
  type ExosAllocation,
  type MarketSplit,
  type SplitChannel,
} from '.';
import { planGametimeListings } from './gametime';
import { planGoTicketsListings } from './gotickets';
import { planSeatGeekListings } from './seatgeek';
import { planStubHubListing } from './stubhub';
import { planTevoListings } from './tevo';
import { planVividListings } from './vivid';

const ALLOC = '0f8fad5b-d9cb-469f-a165-70867728950e';

const alloc = (split: MarketSplit | null, over: Partial<ExosAllocation> = {}): ExosAllocation => ({
  id: ALLOC,
  requested_qty: 6,
  unit_price: 45,
  internal_seats: '{[1,7)}',
  tier: { name: 'GA', price: 40, market_split: split },
  event: {
    name: 'Late Night Jazz', starts_at: '2026-11-07T02:00:00Z', occurs_at_local: '2026-11-06T21:00:00-05:00',
    timezone: 'America/New_York', venue_name: 'Blue Room', venue_address: { city: 'Brooklyn' }, currency: 'USD',
    purchase_limits: { maxPerOrder: 4 },
  },
  ...over,
});

/** Every planner's request bodies, by channel. */
function bodies(a: ExosAllocation): Record<SplitChannel, Array<Record<string, unknown>>> {
  const remoteIds = Object.fromEntries(planExosListings(a, 't').listings.map((l, i) => [l.listing_id, 1_900_000_001 + i]));
  const b = <T>(p: { listings: Array<{ request: { body: T } }> }) => p.listings.map((l) => l.request.body as Record<string, unknown>);
  return {
    stubhub: b(planStubHubListing({ ...a, event: { ...a.event!, id: 'e1' } } as Parameters<typeof planStubHubListing>[0])),
    seatgeek: b(planSeatGeekListings(a)),
    gametime: b(planGametimeListings(a)),
    gotickets: b(planGoTicketsListings(a)),
    vivid: b(planVividListings(a)),
    evo: b(planTevoListings({ ...a, tevoEventId: '123', officeId: 9, remoteIds })),
  };
}

const at = (o: unknown, path: string): unknown => path.split('.').reduce<unknown>((v, k) => (v as Record<string, unknown> | undefined)?.[k], o);

describe('split policy', () => {
  it('reads the stored value, anything else is any', () => {
    expect(parseMarketSplit('pairs')).toBe('pairs');
    expect(parseMarketSplit(null)).toBe('any');
    expect(parseMarketSplit('Pairs')).toBe('any');
  });

  it('says what a buyer can take', () => {
    expect(buyableQuantities('any', 4)).toEqual([1, 2, 3, 4]);
    expect(buyableQuantities('no_single', 4)).toEqual([1, 2, 4]);
    expect(buyableQuantities('pairs', 6)).toEqual([2, 4, 6]);
    expect(buyableQuantities('together', 4)).toEqual([4]);
    expect(buyableQuantities('any', 0)).toEqual([]);
  });

  it('keeps pairs listings even under the max per order', () => {
    expect(splitBlockMax('pairs', 5)).toBe(4);
    expect(splitBlockMax('pairs', null)).toBeNull();
    expect(splitBlockMax('any', 5)).toBe(5);
    expect(() => splitBlockMax('pairs', 1)).toThrow(/at least 2/);
  });

  it('maps to every marketplace, custom lists ending at the quantity', () => {
    expect(marketSplitFor('stubhub', 'no_single', 4)).toEqual({ type: 'AvoidOne', values: null });
    expect(marketSplitFor('stubhub', 'pairs', 4)).toEqual({ type: 'Pairs', values: null });
    expect(marketSplitFor('stubhub', 'together', 4)).toEqual({ type: 'None', values: null });
    expect(marketSplitFor('seatgeek', 'no_single', 4)).toEqual({ type: 'DONTLEAVEONE', values: null });
    expect(marketSplitFor('seatgeek', 'pairs', 6)).toEqual({ type: 'CUSTOM', values: [2, 4, 6] });
    expect(marketSplitFor('seatgeek', 'together', 3)).toEqual({ type: 'CUSTOM', values: [3] });
    expect(marketSplitFor('vivid', 'together', 3)).toEqual({ type: 'CUSTOM', values: [3] });
    expect(marketSplitFor('gametime', 'together', 3)).toEqual({ type: 'NOSPLIT', values: null });
    expect(marketSplitFor('gotickets', 'no_single', 3)).toEqual({ type: 'NEVER_LEAVE_ONE', values: null });
    expect(marketSplitFor('evo', 'together', 3)).toEqual({ type: 'NONE', values: null });
    expect(() => marketSplitFor('seatgeek', 'pairs', 3)).toThrow(/even/);
    for (const ch of Object.keys(LISTING_ID_FIELDS) as SplitChannel[]) {
      expect(marketSplitFor(ch, 'any', 4).values).toBeNull();
      const custom = marketSplitFor(ch, 'pairs', 4).values;
      if (custom) expect(custom[custom.length - 1]).toBe(4);
    }
  });
});

describe('pairs listings', () => {
  it('lists even blocks and holds back the odd seat', () => {
    // Seats 1-7 (7), max per order 5 -> blocks of at most 4, seat 7 held back.
    const set = planExosListings(alloc('pairs', { requested_qty: 7, internal_seats: '{[1,8)}', event: { ...alloc(null).event!, purchase_limits: { maxPerOrder: 5 } } }), 'SeatGeek');
    expect(set.listings.map((l) => [l.seat_from, l.seat_thru])).toEqual([[1, 4], [5, 6]]);
    expect(set.listings.every((l) => l.quantity % 2 === 0 && l.split === 'pairs')).toBe(true);
    expect(set.notices.join(' ')).toMatch(/1 seat not listed/);
  });

  it('holds back the top seat of each odd run', () => {
    const set = planExosListings(alloc('pairs', { requested_qty: 6, internal_seats: '{[1,4),[10,13)}' }), 'SeatGeek');
    expect(set.listings.map((l) => [l.seat_from, l.seat_thru])).toEqual([[1, 2], [10, 11]]);
    expect(set.notices.join(' ')).toMatch(/2 seats not listed/);
  });

  it('refuses when no two seats sit together', () => {
    expect(() => planExosListings(alloc('pairs', { requested_qty: 1, internal_seats: '{[1,2)}' }), 'SeatGeek')).toThrow(/at least 2 seats/);
  });
});

describe('every planner follows the standard', () => {
  it('puts each standard field where LISTING_FIELD_MAP says', () => {
    const all = bodies(alloc('pairs'));
    for (const [ch, list] of Object.entries(all) as Array<[SplitChannel, Array<Record<string, unknown>>]>) {
      const map = LISTING_FIELD_MAP[ch];
      expect(list.length, ch).toBe(2);
      for (const body of list) {
        const id = String(at(body, map.id));
        expect(id, ch).toMatch(/^ex[a-z2-7]{26}[1-9]\d*$/);
        expect(at(body, map.section), ch).toBe('General Admission');
        expect(at(body, map.row), ch).toBe('GA');
        expect(at(body, map.split), ch).toBe(marketSplitFor(ch, 'pairs', Number(at(body, map.quantity) ?? 0) || 2).type);
        if (map.splitValues && at(body, map.split) === 'CUSTOM') expect(at(body, map.splitValues), ch).toBeTruthy();
        expect(String(at(body, map.notes)), ch).toMatch(/Delivered by Exos/);
      }
    }
  });

  it('sends the split each marketplace understands', () => {
    const pairs = bodies(alloc('pairs'));
    expect(pairs.stubhub[0].split_type).toBe('Pairs');
    expect(pairs.seatgeek[0]).toMatchObject({ split_type: 'CUSTOM', splits: '2,4' });
    expect(pairs.gametime[0]).toMatchObject({ Splittype: 'CUSTOM', Splitvalue: '2:4' });
    expect(pairs.gotickets[0]).toMatchObject({ splitType: 'CUSTOM', splitValuesSet: [2, 4] });
    expect(pairs.vivid[0]).toMatchObject({ splitType: 'CUSTOM', splitValue: '2,4' });
    expect(at(pairs.evo[0], 'inventory.ticket')).toMatchObject({ split_type: 'CUSTOM', split_override: [2, 4] });

    const any = bodies(alloc(null));
    expect(any.stubhub[0].split_type).toBe('Any');
    expect(any.seatgeek[0].split_type).toBe('ANY');
    expect(any.seatgeek[0]).not.toHaveProperty('splits');
    expect(any.gametime[0]).toMatchObject({ Splittype: 'ANY', Splitvalue: '' });
    expect(any.gotickets[0]).not.toHaveProperty('splitValuesSet');
    expect(any.vivid[0]).not.toHaveProperty('splitValue');
    expect(at(any.evo[0], 'inventory.ticket')).not.toHaveProperty('split_override');
  });

  it('flags custom split formats a marketplace does not document, without blocking', () => {
    const a = alloc('together');
    const gt = planGametimeListings(a);
    expect(gt.notices?.join(' ')).toBe('');
    const vv = planVividListings(a);
    expect(vv.notices?.join(' ')).toMatch(/splitValue/);
    expect(vv.unresolved.join(' ')).not.toMatch(/splitValue/);
    expect(planGametimeListings(alloc('pairs')).notices?.join(' ')).toMatch(/Splitvalue/);
  });
});

describe('listing ids', () => {
  it('fit every marketplace field', () => {
    const id = exosListingId(ALLOC, 9999);
    expect(id.length).toBeLessThanOrEqual(32);
    for (const ch of Object.keys(LISTING_ID_FIELDS) as SplitChannel[]) expect(assertListingId(ch, id)).toBe(id);
  });

  it('refuses ids that are not Exos ids', () => {
    expect(() => assertListingId('seatgeek', '1732279992')).toThrow(/not an Exos listing id/);
    expect(() => assertListingId('gotickets', `ex${'a'.repeat(40)}`)).toThrow(/not an Exos listing id/);
  });
});
