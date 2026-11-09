// Group buy v2, "pay separately" (mig 20261108120000): sizes, the countdown,
// seat states, the host's text and the server's answers.
import { describe, expect, it, vi } from 'vitest';
// The browser client, as far as these calls go (group pay 2: the start's slot, seat labels).
const sb = vi.hoisted(() => {
  const calls: { kind: string; args: unknown[] }[] = [];
  let next: { data: unknown; error: unknown } = { data: null, error: null };
  const chain = {
    update: (...a: unknown[]) => { calls.push({ kind: 'update', args: a }); return chain; },
    eq: (...a: unknown[]) => { calls.push({ kind: 'eq', args: a }); return chain; },
    select: (...a: unknown[]) => { calls.push({ kind: 'select', args: a }); return Promise.resolve(next); },
  };
  return {
    calls,
    answer: (r: { data: unknown; error: unknown }) => { next = r; },
    client: {
      rpc: (...a: unknown[]) => { calls.push({ kind: 'rpc', args: a }); return Promise.resolve(next); },
      from: (...a: unknown[]) => { calls.push({ kind: 'from', args: a }); return chain; },
    },
  };
});
vi.mock('./supabase', () => ({ supabase: sb.client }));
import {
  canStartGroup, coverableSeats, formatCountdown, friendsPayingNow, groupSeatPrice, maxGroupSize, normalizeSeatLabel, seatLabel,
  seatMessage, seatPayable, seatSmsUrl, secondsLeft, setSeatLabel, startGroup, SEAT_LABEL_MAX, SEAT_TOKEN_RE, toGroup, toSeatView,
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

// Group pay 2 (mig 20261110110000).
describe('seat labels (the host page only)', () => {
  it('stores a trimmed, single-spaced, printable name of at most 40 characters; empty clears it', () => {
    expect(normalizeSeatLabel('  Sam  ')).toBe('Sam');
    expect(normalizeSeatLabel('Sam\n  and\tJo')).toBe('Sam and Jo');
    expect(normalizeSeatLabel('\u0007Sam\u007f')).toBe('Sam');
    expect(normalizeSeatLabel('   ')).toBeNull();
    expect(normalizeSeatLabel(null)).toBeNull();
    expect(normalizeSeatLabel('x'.repeat(60))).toHaveLength(SEAT_LABEL_MAX);
    expect(normalizeSeatLabel('a'.repeat(39) + ' b')).toBe('a'.repeat(39));
    expect(Array.from(normalizeSeatLabel('🎉'.repeat(50)) ?? '')).toHaveLength(SEAT_LABEL_MAX);
  });
  it('saves through the seat row (RLS: host or admin) and says so when nothing was saved', async () => {
    sb.calls.length = 0;
    sb.answer({ data: [{ id: 's1', label: 'Sam' }], error: null });
    await expect(setSeatLabel('s1', '  Sam ')).resolves.toBe('Sam');
    expect(sb.calls.map((c) => c.kind)).toEqual(['from', 'update', 'eq', 'select']);
    expect(sb.calls[0].args).toEqual(['exos_group_buy_seats']);
    expect(sb.calls[1].args).toEqual([{ label: 'Sam' }]);
    expect(sb.calls[2].args).toEqual(['id', 's1']);
    sb.answer({ data: [], error: null });
    await expect(setSeatLabel('s1', 'Sam')).rejects.toThrow(/only the host/);
    sb.calls.length = 0;
    sb.answer({ data: [{ id: 's1', label: null }], error: null });
    await expect(setSeatLabel('s1', '   ')).resolves.toBeNull();
    expect(sb.calls[1].args).toEqual([{ label: null }]);
  });
  it('reads labels, the slot and the locked price from the host\'s group; the seat page has no labels', () => {
    const g = toGroup({
      id: 'g', event_id: 'e', tier_id: 't', quantity: 2, deadline: '2026-11-09T12:30:00Z', status: 'open',
      slot_id: '20261112T1000', unit_price_cents: 2000,
      seats: [{ id: 'a', seat_no: 1, state: 'waiting', label: 'Sam', path: '/p' }, { id: 'b', seat_no: 2, state: 'waiting', label: null, path: '/q' }],
    });
    expect(g.slotId).toBe('20261112T1000');
    expect(g.unitPriceCents).toBe(2000);
    expect(g.seats.map((x) => x.label)).toEqual(['Sam', null]);
    const v = toSeatView({ seat_no: 1, seats: 2, state: 'waiting', deadline: '2026-11-09T12:30:00Z', event_id: 'e', tier_id: 't',
      slot_id: '20261112T1000', unit_price_cents: 2000, label: 'Sam' }, 0);
    expect(v).toMatchObject({ slotId: '20261112T1000', unitPriceCents: 2000 });
    expect(JSON.stringify(v)).not.toContain('Sam');
  });
});

describe('price steps and time slots', () => {
  it('a seat costs the price the group locked (all-in), else today\'s price', () => {
    const tier = { exclusiveTaxPercent: 10, passedOnFees: [] };
    expect(groupSeatPrice(tier, 2000, 33)).toBe(22);
    expect(groupSeatPrice(tier, null, 33)).toBe(33);
    expect(groupSeatPrice(tier, 0, 33)).toBe(33);
  });
  it('a timed group sends its slot; any other group sends none', async () => {
    sb.calls.length = 0;
    sb.answer({ data: { id: 'g', event_id: 'e', tier_id: 't', quantity: 2, deadline: '2026-11-09T12:30:00Z', status: 'open', seats: [] }, error: null });
    await startGroup('e', 't', 2, '20261112T1000');
    await startGroup('e', 't', 2);
    expect(sb.calls.map((c) => c.args)).toEqual([
      ['exos_group_buy_start', { p_event_id: 'e', p_tier_id: 't', p_quantity: 2, p_slot_id: '20261112T1000' }],
      ['exos_group_buy_start', { p_event_id: 'e', p_tier_id: 't', p_quantity: 2 }],
    ]);
    sb.answer({ data: null, error: { message: 'exos_group_buy_start: only 1 left at this price, and a group pays one price: start the group at the next price' } });
    await expect(startGroup('e', 't', 2)).rejects.toThrow(/^only 1 left at this price/);
  });
});
