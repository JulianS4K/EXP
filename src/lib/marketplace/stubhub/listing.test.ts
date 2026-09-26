import { describe, it, expect } from 'vitest';
import {
  ListingMappingError,
  allowedValues,
  buildCreateListingRequest,
  checkListingConstraints,
  type ExosDistributionRow,
  type ListingDetails,
} from './listing';

const ROW: ExosDistributionRow = {
  id: '6f1c2b1e-0000-4000-8000-000000000001',
  channel: 'stubhub',
  requested_qty: 4,
  unit_price: '85.5',
};

const DETAILS: ListingDetails = {
  ticketType: 'ETicket',
  splitType: 'Any',
  section: 'GA',
  currency: 'USD',
};

describe('buildCreateListingRequest', () => {
  it('maps a distribution row, keyed by its id, unpublished by default', () => {
    expect(buildCreateListingRequest(ROW, DETAILS)).toEqual({
      external_id: ROW.id,
      number_of_tickets: 4,
      ticket_type: 'ETicket',
      split_type: 'Any',
      seating: { section: 'GA', row: null, seat_from: null, seat_to: null },
      ticket_price: { amount: 85.5, currency_code: 'USD' },
      published: false,
    });
  });

  it('can price as proceeds and carries optional fields', () => {
    const req = buildCreateListingRequest(ROW, {
      ...DETAILS,
      priceAs: 'ticket_proceeds',
      faceValue: 75,
      row: 'A',
      seatFrom: '1',
      seatTo: '4',
      inHandAt: new Date(Date.UTC(2026, 9, 1)),
      instantDelivery: true,
      published: true,
      notes: 'Exos primary',
    });
    expect(req.ticket_price).toBeUndefined();
    expect(req.ticket_proceeds).toEqual({ amount: 85.5, currency_code: 'USD' });
    expect(req).toMatchObject({
      face_value: { amount: 75, currency_code: 'USD' },
      seating: { section: 'GA', row: 'A', seat_from: '1', seat_to: '4' },
      in_hand_at: '2026-10-01T00:00:00.000Z',
      instant_delivery: true,
      published: true,
      notes: 'Exos primary',
    });
  });

  it('rounds prices to cents', () => {
    expect(buildCreateListingRequest({ ...ROW, unit_price: 10.005 }, DETAILS).ticket_price?.amount).toBe(10.01);
  });

  it.each([
    [{ ...ROW, channel: 'seatgeek' }, DETAILS, /channel/],
    [{ ...ROW, requested_qty: null }, DETAILS, /requested_qty/],
    [{ ...ROW, requested_qty: 0 }, DETAILS, /requested_qty/],
    [{ ...ROW, requested_qty: 1.5 }, DETAILS, /requested_qty/],
    [{ ...ROW, unit_price: null }, DETAILS, /unit_price/],
    [{ ...ROW, unit_price: 'abc' }, DETAILS, /unit_price/],
    [{ ...ROW, unit_price: 0 }, DETAILS, /unit_price/],
    [ROW, { ...DETAILS, currency: 'usd' }, /ISO 4217/],
    [ROW, { ...DETAILS, section: '  ' }, /section/],
  ] as const)('rejects bad input %#', (row, details, msg) => {
    expect(() => buildCreateListingRequest(row as ExosDistributionRow, details)).toThrow(ListingMappingError);
    expect(() => buildCreateListingRequest(row as ExosDistributionRow, details)).toThrow(msg);
  });
});

describe('allowedValues', () => {
  it('reads strings or id/name/value objects, null when unknown', () => {
    expect(allowedValues(['Any', 'Pairs'])).toEqual(new Set(['Any', 'Pairs']));
    expect(allowedValues([{ id: 3, name: 'ETicket' }])).toEqual(new Set(['3', 'ETicket']));
    expect(allowedValues([{ other: 1 }])).toBeNull();
    expect(allowedValues([])).toBeNull();
    expect(allowedValues(undefined)).toBeNull();
  });
});

describe('checkListingConstraints', () => {
  const req = buildCreateListingRequest(ROW, DETAILS);

  it('passes when nothing is constrained', () => {
    expect(checkListingConstraints(req, {})).toEqual([]);
  });

  it('flags quantity and price bounds', () => {
    const issues = checkListingConstraints(req, {
      min_number_of_tickets: 6,
      max_ticket_price: { amount: 50, currency_code: 'USD' },
      min_ticket_price: { amount: 10, currency_code: 'USD' },
    });
    expect(issues.map((i) => i.field)).toEqual(['number_of_tickets', 'ticket_price']);
    expect(issues[1].message).toMatch(/above maximum 50/);
  });

  it('flags a currency mismatch instead of comparing across currencies', () => {
    const issues = checkListingConstraints(req, { min_ticket_price: { amount: 1, currency_code: 'GBP' } });
    expect(issues).toEqual([{ field: 'ticket_price', message: 'currency USD but constraints are in GBP' }]);
  });

  it('flags missing seats, location and unknown split/ticket types', () => {
    const issues = checkListingConstraints(req, {
      seats_required: true,
      ticket_location_required: true,
      _embedded: { split_types: ['Pairs'], ticket_types: [{ name: 'Paper' }] },
    });
    expect(issues.map((i) => i.field)).toEqual(['seating', 'ticket_location_address_id', 'split_type', 'ticket_type']);
  });

  it('does not demand a location on an update', () => {
    expect(checkListingConstraints({ number_of_tickets: 2 }, { ticket_location_required: true })).toEqual([]);
  });
});
