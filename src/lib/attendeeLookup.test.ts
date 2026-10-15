import { describe, expect, it } from 'vitest';
import { checkedInOnText, parseLookup, statusLabel, STATUS_WORDS } from './attendeeLookup';

describe('attendee lookup (mig 20261014120000)', () => {
  it('parses rows and counts, dropping unknown words', () => {
    const r = parseLookup({
      counts: { Attending: 2, 'Checked In': '3', Refunded: 9 },
      rows: [
        { source: 'Eventbrite', name: 'Kim', email: 'kim@x.com', ticket: 'GA', status: 'Checked In', detail: 'Checked In',
          refunded: false, checked_in_at: '2026-10-14T21:04:30Z', checked_in_on: 'eventbrite', code_status: 'used',
          ref: 'eb:7101', channel: 'eventbrite' },
        { name: 'Vic', status: 'Nope', checked_in_on: 'moon', code_status: 'x', ref: 'ord-1' },
      ],
    });
    expect(r.counts).toEqual({ Attending: 2, 'Checked In': 3 });
    expect(r.rows[0]).toMatchObject({ checkedInOn: 'eventbrite', codeStatus: 'used', status: 'Checked In' });
    expect(r.rows[1]).toMatchObject({ source: 'Exos', status: null, checkedInOn: null, codeStatus: null, channel: 'exos', email: null });
    expect(parseLookup(null)).toEqual({ counts: {}, rows: [] });
  });
  it('labels', () => {
    expect(STATUS_WORDS).toEqual(['Attending', 'Checked In', 'Not Attending', 'Transferred']);
    expect(statusLabel({ status: 'Not Attending', refunded: true })).toBe('Not Attending (refunded)');
    expect(statusLabel({ status: 'Attending', refunded: true })).toBe('Attending');
    expect(statusLabel({ status: null, refunded: false })).toBe('Unknown');
    expect(checkedInOnText('both')).toBe("at the Exos door and on Eventbrite's app");
    expect(checkedInOnText(null)).toBe('');
  });
});
