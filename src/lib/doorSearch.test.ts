import { describe, expect, it } from 'vitest';
import { isFullTicketId, maskEmail, rosterMatches } from './doorSearch';

const roster = {
  '11111111-2222-3333-4444-5555550a1b2c': { name: 'Jo Buyer', tier: 'GA', used: false },
  '11111111-2222-3333-4444-555555ffffff': { name: 'Joanna Park', tier: 'VIP', used: true },
  '11111111-2222-3333-4444-555555123456': { name: 'Sam Lee', tier: 'GA', used: false },
};

describe('isFullTicketId', () => {
  it('recognises UUIDs and QR payloads', () => {
    expect(isFullTicketId('11111111-2222-3333-4444-555555123456')).toBe(true);
    expect(isFullTicketId('T-abc:def:123')).toBe(true);
    expect(isFullTicketId('123456')).toBe(false);
    expect(isFullTicketId('Jo')).toBe(false);
  });
});

describe('rosterMatches', () => {
  it('finds by name, not-yet-admitted first', () => {
    expect(rosterMatches(roster, 'jo').map(([, e]) => e.name)).toEqual(['Jo Buyer', 'Joanna Park']);
  });
  it('finds by the tail of the pass id', () => {
    expect(rosterMatches(roster, '123456').map(([, e]) => e.name)).toEqual(['Sam Lee']);
    expect(rosterMatches(roster, '0A1B2C').map(([, e]) => e.name)).toEqual(['Jo Buyer']);
  });
  it('ignores short queries and full ids', () => {
    expect(rosterMatches(roster, 'j')).toEqual([]);
    expect(rosterMatches(roster, '11111111-2222-3333-4444-555555123456')).toEqual([]);
  });
  it('does not treat a short hex-looking name as an id tail', () => {
    expect(rosterMatches(roster, 'abe')).toEqual([]);
  });
});

describe('rosterMatches: will-call (parked tickets)', () => {
  const roster = {
    'aaaaaaaa-0000-4000-8000-000000000001': { name: 'Jane Doe', claimName: 'Jane Doe', claimEmailMasked: 'j***@gmail.com', parked: true },
    'aaaaaaaa-0000-4000-8000-000000000002': { name: 'k***@example.org', claimName: null, claimEmailMasked: 'k***@example.org', parked: true },
    'aaaaaaaa-0000-4000-8000-000000000003': { name: 'Olive Owner' },
  };
  it('finds a parked ticket by the buyer name', () => {
    expect(rosterMatches(roster, 'jane').map(([id]) => id)).toEqual(['aaaaaaaa-0000-4000-8000-000000000001']);
  });
  it('finds by the visible part of the masked email', () => {
    expect(rosterMatches(roster, 'example.org').map(([id]) => id)).toEqual(['aaaaaaaa-0000-4000-8000-000000000002']);
  });
  it('finds by the full email typed in, compared masked', () => {
    expect(rosterMatches(roster, ' Kim@Example.org ').map(([id]) => id)).toEqual(['aaaaaaaa-0000-4000-8000-000000000002']);
    expect(rosterMatches(roster, 'bob@example.org')).toEqual([]);
  });
});

describe('maskEmail', () => {
  it('masks like exos_mask_email', () => {
    expect(maskEmail('Jane.Doe@gmail.com')).toBe('j***@gmail.com');
    expect(maskEmail('@gmail.com')).toBeNull();
    expect(maskEmail('jane')).toBeNull();
    expect(maskEmail(null)).toBeNull();
  });
});
