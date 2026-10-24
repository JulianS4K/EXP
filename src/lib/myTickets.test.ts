import { describe, expect, it } from 'vitest';
import { activePassCount, eventIsOver, orderArrived, splitTicketGroups, type TicketLike } from './myTickets';

const NOW = Date.parse('2026-10-20T12:00:00Z');
const ts = (iso: string) => ({ toMillis: () => Date.parse(iso) });
const ev = (start: string, end?: string) => ({ date: ts(start), timing: end ? { endTime: ts(end) } : undefined });
const tk = (id: string, status: string, event: TicketLike['event'], extra: Partial<TicketLike> = {}): TicketLike => ({ id, status, event, ...extra });

describe('My Tickets tabs', () => {
  it('knows when an event is over', () => {
    expect(eventIsOver(ev('2026-10-19T20:00:00Z', '2026-10-20T02:00:00Z'), NOW)).toBe(true);
    expect(eventIsOver(ev('2026-10-20T08:00:00Z'), NOW)).toBe(false); // started 4 h ago, no end time
    expect(eventIsOver(ev('2026-10-19T20:00:00Z'), NOW)).toBe(true); // 16 h after the start
    expect(eventIsOver(ev('2026-11-01T20:00:00Z'), NOW)).toBe(false);
    expect(eventIsOver({ date: { toMillis: () => 0 } }, NOW)).toBe(false); // no date
  });

  it('splits upcoming from past / used / refunded, by date', () => {
    const later = ev('2026-12-01T20:00:00Z');
    const soon = ev('2026-10-25T20:00:00Z');
    const past = ev('2026-09-01T20:00:00Z');
    const olderPast = ev('2026-08-01T20:00:00Z');
    const { active, archive } = splitTicketGroups({
      later: [tk('a', 'active', later)],
      soon: [tk('b', 'active', soon), tk('c', 'used', soon)],
      past: [tk('d', 'active', past)],
      olderPast: [tk('e', 'used', olderPast)],
      used: [tk('f', 'used', soon)],
      refunded: [tk('g', 'voided', later)],
    }, NOW);
    // Upcoming: soonest first. Archive: newest event first.
    expect(active.map(([id]) => id)).toEqual(['soon', 'later']);
    expect(archive.map(([id]) => id)).toEqual(['refunded', 'used', 'past', 'olderPast']);
  });

  it('counts only passes still to use', () => {
    const e = ev('2026-12-01T20:00:00Z');
    expect(activePassCount([
      tk('a', 'active', e), tk('b', 'used', e), tk('c', 'voided', e), tk('d', 'active', e, { pendingTransferId: 'x' }),
    ])).toBe(1);
  });
});

describe('back from Stripe', () => {
  it('waits for the session\'s tickets', () => {
    expect(orderArrived([tk('a', 'active', null, { orderId: 'cs_other' })], 'cs_1', 1)).toBe(false);
    expect(orderArrived([tk('a', 'active', null, { orderId: 'cs_1' })], 'cs_1', null)).toBe(true);
  });
  it('without a session id, any ticket on the first load, then more than before', () => {
    expect(orderArrived([], null, null)).toBe(false);
    expect(orderArrived([tk('a', 'active', null)], null, null)).toBe(true);
    expect(orderArrived([tk('a', 'active', null)], null, 1)).toBe(false);
    expect(orderArrived([tk('a', 'active', null), tk('b', 'active', null)], null, 1)).toBe(true);
  });
});
