import { describe, expect, it } from 'vitest';
import { isFullTicketId, rosterMatches } from './doorSearch';

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
