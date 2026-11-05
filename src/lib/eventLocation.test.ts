import { describe, expect, it } from 'vitest';
import {
  blankLocationDraft, draftFromView, draftToPayload, effectiveRevealAt, feedLocation, holderLocation, isRevealed,
  locationBlockers, needsCapacity, orgTypeDefaults, parseLocationMode, parseOrgType, publicLocation, publicVenueFields,
  revealAtFromHours, revealPreset, salesOpen, validateLocationDraft, venueMatchKey,
} from './eventLocation';
import { revealedLocation, type WalletPayload } from '../../supabase/functions/_shared/wallet/payload.ts';
import { buildApplePassJson } from '../../supabase/functions/_shared/wallet/apple.ts';
import { buildEventTicketClass, buildEventTicketObject } from '../../supabase/functions/_shared/wallet/google.ts';

const START = '2026-12-12T23:00:00.000Z';
const SECRET = 'ZQX 77 Kent Ave';

describe('reveal rules', () => {
  it('reveals at the reveal time, never later than the start', () => {
    expect(effectiveRevealAt('2026-12-11T23:00:00Z', START)).toBe('2026-12-11T23:00:00.000Z');
    expect(effectiveRevealAt('2026-12-13T01:00:00Z', START)).toBe(START);
    expect(effectiveRevealAt(null, START)).toBe(START);
    expect(effectiveRevealAt('2026-12-11T23:00:00Z', null)).toBe('2026-12-11T23:00:00.000Z');
    expect(effectiveRevealAt(null, null)).toBeNull();
    expect(effectiveRevealAt('nonsense', START)).toBe(START);
  });
  it('is revealed from that moment on', () => {
    const at = '2026-12-11T23:00:00Z';
    expect(isRevealed(at, START, new Date('2026-12-11T22:59:59Z'))).toBe(false);
    expect(isRevealed(at, START, new Date('2026-12-11T23:00:00Z'))).toBe(true);
    // A reschedule to before the reveal: holders still get it by the start.
    expect(isRevealed('2026-12-13T00:00:00Z', START, new Date(START))).toBe(true);
    expect(isRevealed(null, null, new Date())).toBe(false);
  });
  it('counts presets back from the start', () => {
    expect(revealAtFromHours(START, 24)).toBe('2026-12-11T23:00:00.000Z');
    expect(revealAtFromHours(START, 0)).toBe(START);
    expect(revealAtFromHours(START, -1)).toBeNull();
    expect(revealAtFromHours(START, 721)).toBeNull();
    expect(revealAtFromHours(null, 24)).toBeNull();
    expect(revealPreset(24)).toBe(24);
    expect(revealPreset(5)).toBeNull();
  });
});

describe('modes and org types', () => {
  it('parses with safe defaults', () => {
    expect(parseLocationMode('tba')).toBe('tba');
    expect(parseLocationMode('underground')).toBe('venue_record');
    expect(parseLocationMode(undefined)).toBe('venue_record');
    expect(parseOrgType('collective')).toBe('collective');
    expect(parseOrgType('venue')).toBe('organizer');
  });
  it('org type is a label plus defaults', () => {
    expect(orgTypeDefaults('organizer')).toEqual({ defaultLocationMode: 'venue_record', hideVenueManagement: false });
    expect(orgTypeDefaults('promoter')).toEqual({ defaultLocationMode: 'unlisted_venue', hideVenueManagement: true });
    expect(blankLocationDraft('collective').mode).toBe('unlisted_venue');
    expect(blankLocationDraft().mode).toBe('venue_record');
  });
  it('sales wait for an explicit yes on tba only', () => {
    expect(salesOpen('tba', null)).toBe(false);
    expect(salesOpen('tba', false)).toBe(false);
    expect(salesOpen('tba', true)).toBe(true);
    expect(salesOpen('secret_location', null)).toBe(true);
    expect(needsCapacity('venue_record')).toBe(false);
    expect(needsCapacity('unlisted_venue')).toBe(true);
  });
});

describe('what to display', () => {
  const when = (iso: string) => `at ${iso}`;
  it('the public page of a secret event shows the area and the reveal time, no address, no map', () => {
    const p = publicLocation({ location_mode: 'secret_location', venue_location: 'Bushwick', location_reveal_at: '2026-12-11T23:00:00Z', starts_at: START }, when);
    expect(p).toMatchObject({ title: 'Secret location', detail: 'Bushwick', mappable: false, address: null });
    expect(p.note).toBe('Ticket holders get the address at 2026-12-11T23:00:00.000Z.');
  });
  it('tba says when tickets go on sale', () => {
    expect(publicLocation({ location_mode: 'tba', tba_allow_sales: false }).note).toMatch(/on sale once/);
    expect(publicLocation({ location_mode: 'tba', tba_allow_sales: true }).note).toMatch(/hear as soon/);
    expect(publicLocation({ location_mode: 'tba' }).mappable).toBe(false);
  });
  it('venues show their name and public address', () => {
    const p = publicLocation({ location_mode: 'unlisted_venue', venue_name: 'Warehouse 9', venue_location: 'Warehouse 9',
      venue_address: { street: '9 Dock St', city: 'Brooklyn' } });
    expect(p).toMatchObject({ title: 'Warehouse 9', detail: '9 Dock St, Brooklyn', mappable: true });
    // Legacy rows (no mode) are venue_record.
    expect(publicLocation({ venue_name: 'Elsewhere', venue_location: 'Brooklyn, NY' }).detail).toBe('Brooklyn, NY');
  });
  it('a holder sees the place once revealed, the time before', () => {
    const before = holderLocation({ location_mode: 'secret_location', venue_location: 'Bushwick', reveal_at: '2026-12-11T23:00:00Z', revealed: false, secret_location: null }, when);
    expect(before.revealed).toBe(false);
    expect(before.note).toBe('You\'ll get the address at 2026-12-11T23:00:00Z, here and by email.');
    expect(JSON.stringify(before)).not.toContain('Kent');
    const after = holderLocation({ location_mode: 'secret_location', venue_location: 'Bushwick', revealed: true,
      secret_location: { venue_name: 'Warehouse 9', address: { street: SECRET, city: 'Brooklyn' }, directions: 'Blue door' } });
    expect(after).toMatchObject({ revealed: true, title: 'Warehouse 9', detail: `${SECRET}, Brooklyn`, directions: 'Blue door', mappable: true });
  });
});

describe('feed filtering', () => {
  it('a private mode publishes the area only: no street, no pin', () => {
    // Even if a row somehow carried an address, the feed view drops it.
    const row = { location_mode: 'secret_location', venue_name: 'X', venue_location: 'Bushwick', venue_address: { street: SECRET } };
    expect(feedLocation(row)).toEqual({ name: 'Bushwick', address: null, geo: false });
    expect(JSON.stringify(feedLocation(row))).not.toContain('Kent');
    expect(feedLocation({ location_mode: 'tba', venue_location: null })).toEqual({ name: null, address: null, geo: false });
  });
  it('venues publish as before', () => {
    expect(feedLocation({ venue_name: 'Elsewhere', venue_address: { street: '599 Johnson Ave' } }))
      .toEqual({ name: 'Elsewhere', address: { street: '599 Johnson Ave' }, geo: true });
  });
});

describe('blockers (mirror of the SQL)', () => {
  it('secret needs area, address, reveal before start', () => {
    const codes = (r: Parameters<typeof locationBlockers>[0], s = false, c: number[] = []) => locationBlockers(r, s, c).map((b) => b.code);
    expect(codes({ location_mode: 'secret_location', starts_at: START })).toEqual(
      ['missing_location_area', 'missing_secret_address', 'missing_reveal_time']);
    expect(codes({ location_mode: 'secret_location', venue_location: 'B', starts_at: START, location_reveal_at: START }, true))
      .toEqual(['reveal_after_start']);
    expect(codes({ location_mode: 'secret_location', venue_location: 'B', starts_at: START, location_reveal_at: '2026-12-11T00:00:00Z' }, true, [50]))
      .toEqual([]);
    expect(codes({ location_mode: 'tba' })).toEqual(['tba_sales_choice']);
    expect(codes({ location_mode: 'tba', tba_allow_sales: false })).toEqual([]);
    // 0 closes sales (mig 20261105150000): one closed type is fine, all closed blocks.
    expect(codes({ location_mode: 'unlisted_venue', venue_address: { city: 'Queens' } }, false, [0, 10])).toEqual([]);
    expect(codes({ location_mode: 'unlisted_venue', venue_address: { city: 'Queens' } }, false, [0, 0])).toEqual(['capacity_required']);
    expect(locationBlockers({ location_mode: 'tba', tba_allow_sales: true }, false, [0])[0].message).toContain('0 closes sales');
    expect(codes({ location_mode: 'unlisted_venue' })).toEqual(['missing_venue_address']);
    expect(codes({ location_mode: 'venue_record' }, false, [0])).toEqual([]);
    expect(codes({ location_mode: 'secret_location', format: 'online' })).toEqual([]);
  });
});

describe('the editor draft', () => {
  it('a secret draft saves the area publicly and the place apart', () => {
    const d = { ...blankLocationDraft(), mode: 'secret_location' as const, area: 'Bushwick', venueName: 'Leftover',
      secretName: 'Warehouse 9', secretAddress: { street: SECRET, city: 'Brooklyn' }, directions: 'Blue door', revealHours: 24 };
    expect(publicVenueFields(d)).toEqual({ venueName: null, venueLocation: 'Bushwick', venueAddress: null });
    const p = draftToPayload(d, START);
    expect(p).toEqual({
      location_mode: 'secret_location', venue_location: 'Bushwick', location_reveal_at: '2026-12-11T23:00:00.000Z',
      secret_location: { venue_name: 'Warehouse 9', address: { street: SECRET, city: 'Brooklyn' }, directions: 'Blue door' },
    });
    expect(p).not.toHaveProperty('venue_name');
    expect(validateLocationDraft(d)).toBeNull();
    expect(validateLocationDraft({ ...d, secretAddress: { city: 'Brooklyn' } })).toMatch(/exact address/);
    expect(validateLocationDraft({ ...d, area: '' })).toMatch(/area/);
  });
  it('unlisted, tba and online', () => {
    const u = { ...blankLocationDraft('promoter'), venueName: 'Warehouse 9', address: { street: '', city: 'Brooklyn' } };
    expect(draftToPayload(u, START)).toEqual({ location_mode: 'unlisted_venue', venue_location: 'Warehouse 9',
      venue_name: 'Warehouse 9', venue_address: { city: 'Brooklyn' } });
    expect(validateLocationDraft({ ...u, address: {} })).toMatch(/address/);
    const t = { ...blankLocationDraft(), mode: 'tba' as const };
    expect(validateLocationDraft(t)).toMatch(/Choose/);
    expect(draftToPayload({ ...t, tbaAllowSales: true }, START)).toEqual({ location_mode: 'tba', venue_location: null, tba_allow_sales: true });
    expect(validateLocationDraft({ ...t }, { online: true })).toBeNull();
  });
  it('reads a saved location back', () => {
    const d = draftFromView({ location_mode: 'secret_location', venue_location: 'Bushwick', location_reveal_at: '2026-12-12T17:00:00Z',
      secret_location: { venue_name: 'W9', address: { street: SECRET }, directions: null } }, START);
    expect(d).toMatchObject({ mode: 'secret_location', area: 'Bushwick', secretName: 'W9', revealHours: 6 });
    expect(d.secretAddress.street).toBe(SECRET);
    expect(draftFromView(null, null).mode).toBe('venue_record');
  });
  it('match keys ignore case and spaces', () => {
    expect(venueMatchKey(' Warehouse 9 ', 'BROOKLYN')).toBe('warehouse 9|brooklyn');
    expect(venueMatchKey('Warehouse 9', '')).toBeNull();
  });
});

describe('wallet passes', () => {
  const base = (location: WalletPayload['location'], over: Partial<WalletPayload> = {}): WalletPayload => ({
    serial: 'exw' + '0'.repeat(32), pass_type: 'pass.com.exos.test', status: 'active', void_reason: null, code_epoch: 1,
    updated_at: '2026-11-05T00:00:00Z',
    ticket: { id: '11111111-1111-1111-1111-111111111111', status: 'active', tier_name: 'GA', section_label: null,
      attendee_name: null, in_transfer: false, check_in_at: null },
    event: { id: '22222222-2222-2222-2222-222222222222', name: 'Rave', status: 'published', starts_at: START, ends_at: null,
      doors_at: null, timezone: 'America/New_York', venue_name: null, venue_location: 'Bushwick', lat: null, lng: null },
    org_name: 'Collective', apple_code: 'W-x:a1:y', google_key_hex: 'ab'.repeat(20),
    google_pattern: 'W-x:g1:{totp_value_0}', location, ...over,
  });
  const revealed = { location_mode: 'secret_location', venue_location: 'Bushwick', revealed: true,
    secret_location: { venue_name: 'Warehouse 9', address: { street: SECRET, city: 'Brooklyn' }, directions: 'Blue door' } };
  it('carries the address only once revealed, only on the ticket\'s own object', () => {
    const before = base({ location_mode: 'secret_location', venue_location: 'Bushwick', revealed: false, secret_location: null });
    expect(revealedLocation(before)).toBeNull();
    const ID = { teamIdentifier: 'ABCDE12345', passTypeIdentifier: 'pass.com.exos.test', organizationName: 'Exos', webServiceURL: 'https://x.example/w' };
    const apple = (p: WalletPayload) => JSON.stringify(buildApplePassJson(p, ID as never, 'a'.repeat(32)));
    expect(apple(before)).not.toContain('Kent');
    expect(apple(before)).toContain('Secret location');
    const after = base(revealed);
    expect(revealedLocation(after)).toEqual({ name: 'Warehouse 9', line: `${SECRET}, Brooklyn`, directions: 'Blue door' });
    expect(JSON.stringify(buildEventTicketObject(after, '3388000000012345678'))).toContain(SECRET);
    expect(apple(after)).toContain(SECRET);
    expect(apple(after)).toContain('Blue door');
    // Google's class is shared by every holder's pass of the event: never there.
    expect(JSON.stringify(buildEventTicketClass(after, '3388000000012345678'))).not.toContain('Kent');
    // A void pass loses it.
    expect(revealedLocation(base(revealed, { status: 'voided', apple_code: null }))).toBeNull();
  });
});
