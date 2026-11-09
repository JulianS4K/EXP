// Group buy v2, "pay separately" (mig 20261108120000): sizes, the countdown,
// seat states, the host's text and the server's answers.
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  canStartGroup, coverableSeats, formatCountdown, friendsPayingNow, maxGroupSize, seatLabel, seatMessage, seatPayable,
  seatSmsUrl, secondsLeft, SEAT_TOKEN_RE, toGroup, toSeatView,
} from './groupPay';

describe('group size', () => {
  it('caps a group at the event\'s per-order limit and at 10', () => {
    expect(maxGroupSize(undefined)).toBe(10);
    expect(maxGroupSize(0)).toBe(10);
    expect(maxGroupSize(4)).toBe(4);
    expect(maxGroupSize(25)).toBe(10);
    expect(canStartGroup(1, 6)).toBe(false);
    expect(canStartGroup(2, 6)).toBe(true);
    expect(canStartGroup(6, 6)).toBe(true);
    expect(canStartGroup(7, 6)).toBe(false);
    expect(canStartGroup(11, null)).toBe(false);
    expect(canStartGroup(2.5, null)).toBe(false);
  });
});

describe('countdown', () => {
  const deadline = '2026-11-09T12:30:00.000Z';
  it('counts the server\'s time, moved on by the local clock', () => {
    const fetched = Date.parse('2026-11-09T12:00:00.000Z');
    expect(secondsLeft(deadline, '2026-11-09T12:00:00.000Z', fetched, fetched)).toBe(1800);
    expect(secondsLeft(deadline, '2026-11-09T12:00:00.000Z', fetched, fetched + 61_000)).toBe(1739);
  });
  it('ignores a phone clock that is off', () => {
    // The phone thinks it is 5 minutes later than the server.
    const phoneNow = Date.parse('2026-11-09T12:05:00.000Z');
    expect(secondsLeft(deadline, '2026-11-09T12:00:00.000Z', phoneNow, phoneNow)).toBe(1800);
  });
  it('never goes below zero and survives junk', () => {
    const fetched = Date.parse('2026-11-09T12:00:00.000Z');
    expect(secondsLeft(deadline, null, fetched, fetched + 3_600_000)).toBe(0);
    expect(secondsLeft('nope', null, fetched, fetched)).toBe(0);
  });
  it('formats minutes and seconds', () => {
    expect(formatCountdown(1745)).toBe('29:05');
    expect(formatCountdown(9)).toBe('0:09');
    expect(formatCountdown(-3)).toBe('0:00');
  });
});

describe('seats', () => {
  it('labels every state', () => {
    expect(seatLabel('waiting')).toBe('Waiting');
    expect(seatLabel('paid')).toBe('Paid');
    expect(seatLabel('released')).toBe('Released');
    expect(seatLabel('covered')).toMatch(/covered/);
  });
  it('lets a friend pay a waiting seat, or their own checkout again, with more than a minute left', () => {
    const open = { groupStatus: 'open' as const };
    expect(seatPayable({ ...open, state: 'waiting', mine: false }, 600)).toBe(true);
    expect(seatPayable({ ...open, state: 'paying', mine: true }, 600)).toBe(true);
    expect(seatPayable({ ...open, state: 'paying', mine: false }, 600)).toBe(false);
    expect(seatPayable({ ...open, state: 'covering', mine: false }, 600)).toBe(false);
    expect(seatPayable({ ...open, state: 'paid', mine: false }, 600)).toBe(false);
    expect(seatPayable({ ...open, state: 'waiting', mine: false }, 60)).toBe(false);
    expect(seatPayable({ groupStatus: 'closed', state: 'waiting', mine: false }, 600)).toBe(false);
  });
  it('covering the rest takes every unpaid seat, and counts friends mid-checkout', () => {
    const g = toGroup({
      id: 'g', event_id: 'e', tier_id: 't', quantity: 4, deadline: '2026-11-09T12:30:00Z', status: 'open', can_cover: true,
      counts: { paid: 1, paying: 1, waiting: 1, released: 1 },
      seats: [
        { id: 'a', seat_no: 1, state: 'paid', path: '/group-pay/seat/' + 'a'.repeat(32) },
        { id: 'b', seat_no: 2, state: 'paying', path: '/group-pay/seat/' + 'b'.repeat(32) },
        { id: 'c', seat_no: 3, state: 'waiting', path: '/group-pay/seat/' + 'c'.repeat(32) },
        { id: 'd', seat_no: 4, state: 'released', path: '/group-pay/seat/' + 'd'.repeat(32) },
      ],
    });
    expect(coverableSeats(g).map((s) => s.seatNo)).toEqual([2, 3]);
    expect(friendsPayingNow(g)).toBe(1);
    expect(g.counts).toEqual({ paid: 1, paying: 1, waiting: 1, released: 1 });
    expect(g.status).toBe('open');
  });
});

describe('the host\'s text', () => {
  it('carries the seat link, the price and the time left', () => {
    const body = seatMessage({ eventTitle: 'Fall Party', seatNo: 2, url: 'https://x.test/group-pay/seat/abc', minutesLeft: 24.6, priceLabel: '$25.00' });
    expect(body).toContain('Fall Party (seat 2): $25.00.');
    expect(body).toContain('next 25 min');
    expect(body.split('\n').pop()).toBe('https://x.test/group-pay/seat/abc');
    expect(seatSmsUrl(body)).toBe('sms:?&body=' + encodeURIComponent(body));
  });
});

describe('the seat page read', () => {
  it('maps the server\'s answer, and nothing for an unknown link', () => {
    expect(toSeatView(null)).toBeNull();
    const v = toSeatView({
      seat_no: 2, seats: 4, state: 'waiting', mine: false, is_host: false, group_id: null, deadline: '2026-11-09T12:30:00Z',
      server_now: '2026-11-09T12:10:00Z', group_status: 'open', paid: 1, open: 3, event_id: 'e', tier_id: 't',
      event: { name: 'Fall Party', starts_at: '2026-11-20T23:00:00Z', venue_name: 'Elsewhere', image_url: null, currency: 'USD' },
    }, 0);
    expect(v).toMatchObject({ seatNo: 2, seats: 4, state: 'waiting', groupStatus: 'open', paid: 1, open: 3, event: { name: 'Fall Party', currency: 'USD' } });
    // An unpublished event: no ids, no event block.
    const gone = toSeatView({ seat_no: 1, seats: 2, state: 'paid', deadline: '2026-11-09T12:30:00Z', event_id: null, tier_id: null, event: null }, 0);
    expect(gone).toMatchObject({ eventId: '', tierId: '', event: null, state: 'paid' });
    expect(SEAT_TOKEN_RE.test('0123456789abcdef0123456789abcdef')).toBe(true);
    expect(SEAT_TOKEN_RE.test('0123456789ABCDEF0123456789abcdef')).toBe(false);
  });
});
