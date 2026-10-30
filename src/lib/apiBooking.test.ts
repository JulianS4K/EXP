// Booking bodies for the partner API (supabase/functions/_shared/api/booking.ts).
// The SQL (mig 20261030100000, tests/exos/test_booking.sql) validates again;
// these check what a route lets through and the error mapping.

import { describe, expect, it } from 'vitest';
import {
  BodyError, bookingDbError, clearBody, convertBody, holdBody, isIsoDate, parseActivity, parseContact,
  parseHoldFilters, parseNote, parseRoom, parseVenue, venueView,
} from '../../supabase/functions/_shared/api/booking.ts';

const V = '7a10c3e1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

describe('venues and rooms', () => {
  it('takes the venue fields, folds the contact into columns and refuses org_id', () => {
    const row = parseVenue({
      name: ' Lincoln Hall ', time_zone: 'America/Chicago', capacity: '520', website: 'https://lincolnhall.example',
      relationship: 'rented', contact: { name: 'Club GM', email: 'GM@Metro.example' }, org_id: 'x', id: 'y',
      address: { city: 'Chicago', region: 'IL', bogus: 1 },
    }, false);
    expect(row).toEqual({
      name: 'Lincoln Hall', timezone: 'America/Chicago', capacity: 520, website: 'https://lincolnhall.example/',
      relationship: 'rented', contact_name: 'Club GM', contact_email: 'gm@metro.example', contact_phone: null,
      address: { city: 'Chicago', region: 'IL' },
    });
  });

  it('refuses bad venue input', () => {
    expect(() => parseVenue({}, false)).toThrow(BodyError);
    expect(() => parseVenue({ name: 'X', relationship: 'stolen' }, false)).toThrow(/relationship/);
    expect(() => parseVenue({ name: 'X', website: 'http://x.example' }, false)).toThrow(/https/);
    expect(() => parseVenue({ name: 'X', permalink: 'Bad Slug' }, false)).toThrow(/permalink/);
    expect(() => parseVenue({ name: 'X', capacity: -1 }, false)).toThrow(/capacity/);
    expect(() => parseVenue({ name: 'X', contact: { email: 'nope' } }, false)).toThrow(/contact.email/);
    expect(() => parseVenue({}, true)).toThrow(/Nothing to update/);
    expect(() => parseVenue([], true)).toThrow(/JSON object/);
  });

  it('PATCH touches only what is sent; contact null clears it', () => {
    expect(parseVenue({ capacity: null }, true)).toEqual({ capacity: null });
    expect(parseVenue({ contact: null }, true)).toEqual({ contact_name: null, contact_email: null, contact_phone: null });
  });

  it('shows the contact as one object, or null', () => {
    expect(venueView({ id: V, name: 'X', contact_name: null, contact_email: null, contact_phone: null }).contact).toBeNull();
    expect(venueView({ id: V, name: 'X', contact_email: 'a@b.co' }).contact).toEqual({ name: null, email: 'a@b.co', phone: null });
    expect(venueView({ id: V, name: 'X' }).relationship).toBe('owned');
  });

  it('rooms: colour alias, capacity, name', () => {
    expect(parseRoom({ name: 'Main', calendar_color_hex: '#FF5733', capacity: 450 }, false))
      .toEqual({ name: 'Main', color: '#FF5733', capacity: 450 });
    expect(() => parseRoom({ name: 'Main', color: 'red' }, false)).toThrow(/color/);
    expect(() => parseRoom({ capacity: 1 }, false)).toThrow(/name/);
  });
});

describe('show schedule, notes, contacts', () => {
  it('defaults a row name from its kind and normalizes times', () => {
    expect(parseActivity({ kind: 'load_in', start_time: '2026-11-14T13:00:00-06:00' }, false)).toEqual({
      kind: 'load_in', name: 'Load in', starts_at: '2026-11-14T19:00:00.000Z',
    });
    expect(parseActivity({ set: false }, true)).toEqual({ is_set: false });
  });

  it('refuses bad rows', () => {
    expect(() => parseActivity({ kind: 'party', starts_at: '2026-11-14T19:00:00Z' }, false)).toThrow(/kind/);
    expect(() => parseActivity({ kind: 'set' }, false)).toThrow(/starts_at is required/);
    expect(() => parseActivity({ starts_at: '2026-11-14T20:00:00Z', ends_at: '2026-11-14T19:00:00Z' }, false)).toThrow(/ends_at/);
    expect(() => parseActivity({ starts_at: 'tomorrow' }, false)).toThrow(/ISO 8601/);
  });

  it('notes default to the API as author; contacts check role and email', () => {
    expect(parseNote({ body: ' Settle in the office. ', author_id: 'x' }, false)).toEqual({ body: 'Settle in the office.', author_name: 'API' });
    expect(() => parseNote({ body: '' }, false)).toThrow(/body/);
    expect(parseContact({ name: 'Ana', role: 'agent', email: 'ANA@x.co', title: 'Tour manager' }, false))
      .toEqual({ name: 'Ana', role: 'agent', email: 'ana@x.co', title: 'Tour manager' });
    expect(() => parseContact({ name: 'X', role: 'fan' }, false)).toThrow(/role/);
    expect(() => parseContact({ name: 'X', email: 'nope' }, false)).toThrow(/email/);
  });
});

describe('holds', () => {
  it('passes only the keys the SQL reads', () => {
    expect(holdBody({ title: 'A', positions: [], org_id: 'x', status: 'converted', created_by: 'y' }, false))
      .toEqual({ title: 'A', positions: [] });
    expect(() => holdBody({ title: 'A' }, false)).toThrow(/positions/);
    expect(() => holdBody({ org_id: 'x' }, true)).toThrow(/Nothing to update/);
  });

  it('list filters', () => {
    expect(parseHoldFilters(new URLSearchParams(`from=2026-11-01&to=2026-11-30&q%5Bvenue_id_eq%5D=${V}&status=active&title=band`)))
      .toEqual({ from: '2026-11-01', to: '2026-11-30', venueId: V, roomId: null, status: 'active', q: 'band' });
    expect(() => parseHoldFilters(new URLSearchParams('from=nov'))).toThrow(/from/);
    expect(() => parseHoldFilters(new URLSearchParams('from=2026-11-30&to=2026-11-01'))).toThrow(/before/);
    expect(() => parseHoldFilters(new URLSearchParams('status=maybe'))).toThrow(/status/);
    expect(() => parseHoldFilters(new URLSearchParams('venue_id=1'))).toThrow(/UUID/);
  });

  it('clear and convert bodies, with the Opendate spellings', () => {
    expect(clearBody(undefined)).toBeNull();
    expect(clearBody({ hold_position_ids: [V] })).toEqual([V]);
    expect(() => clearBody({ position_ids: [] })).toThrow(BodyError);
    expect(convertBody({ hold_position_id: V, clear_holds_on_day: true, junk: 1 })).toEqual({ position_id: V, clear_holds_on_day: true });
    expect(convertBody(undefined)).toEqual({});
    expect(() => convertBody({ position_id: 'nope' })).toThrow(/UUID/);
  });

  it('dates are real calendar dates', () => {
    expect(isIsoDate('2028-02-29')).toBe(true);
    expect(isIsoDate('2026-02-29')).toBe(false);
    expect(isIsoDate('2026-2-28')).toBe(false);
  });
});

describe('database errors', () => {
  it('maps the SQL codes to HTTP', () => {
    expect(bookingDbError({ code: '22023', message: 'title is required' })).toEqual({ status: 400, message: 'Title is required' });
    expect(bookingDbError({ code: 'P0002', message: 'Hold not found' })?.status).toBe(404);
    expect(bookingDbError({ code: '55000', message: 'That night is not an active night of this hold' })?.status).toBe(409);
    expect(bookingDbError({ code: '23505', message: 'duplicate key value violates unique constraint "x"' })?.message).toMatch(/conflicts/);
    expect(bookingDbError({ code: '23503', message: 'fk' })?.status).toBe(409);
    expect(bookingDbError({ code: '42501', message: 'not authorized' })).toEqual({ status: 404, message: 'Not found.' });
    expect(bookingDbError({ code: '08006', message: 'connection' })).toBeNull();
    expect(bookingDbError({ code: '22023', message: 'exos_venues: timezone must be an IANA zone' })?.message).toBe('Timezone must be an IANA zone');
  });
});
