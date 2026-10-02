import { describe, expect, it } from 'vitest';
import { Timestamp } from './timestamp';
import { eventEndMs, eventIsOver, eventOver, NO_END_GRACE_MS, transferExpired } from './transferExpiry';

const NOW = Date.parse('2026-10-02T12:00:00Z');
const at = (iso: string) => new Date(iso);
const ev = (start?: string, end?: string) => ({
  timing: {
    startTime: Timestamp.fromDate(start ? new Date(start) : new Date(0)),
    endTime: end ? Timestamp.fromDate(new Date(end)) : undefined,
  },
});

describe('event over (mirrors _exos_event_over)', () => {
  it('uses the end time when there is one', () => {
    expect(eventOver(at('2026-10-02T05:00:00Z'), at('2026-10-02T11:59:00Z'), NOW)).toBe(true);
    expect(eventOver(at('2026-10-02T05:00:00Z'), at('2026-10-02T12:01:00Z'), NOW)).toBe(false);
    expect(eventOver(null, at('2026-10-02T12:00:00Z'), NOW)).toBe(true); // at the end exactly
  });

  it('falls back to the start + 12 hours', () => {
    expect(eventEndMs(at('2026-10-01T23:00:00Z'), null)).toBe(Date.parse('2026-10-01T23:00:00Z') + NO_END_GRACE_MS);
    expect(eventOver(at('2026-10-01T23:00:00Z'), null, NOW)).toBe(true);   // 13 h ago
    expect(eventOver(at('2026-10-02T01:00:00Z'), null, NOW)).toBe(false);  // 11 h ago
  });

  it('never ends without a start time', () => {
    expect(eventOver(null, null, NOW)).toBe(false);
    expect(eventIsOver(ev(), NOW)).toBe(false);          // epoch start = unset
    expect(eventIsOver(null, NOW)).toBe(false);
    expect(eventIsOver({ timing: undefined }, NOW)).toBe(false);
  });

  it('reads an event row', () => {
    expect(eventIsOver(ev('2026-10-02T05:00:00Z', '2026-10-02T10:00:00Z'), NOW)).toBe(true);
    expect(eventIsOver(ev('2026-10-02T05:00:00Z'), NOW)).toBe(false);
  });
});

describe('transferExpired', () => {
  const ended = ev('2026-10-01T20:00:00Z', '2026-10-02T02:00:00Z');
  const live = ev('2026-10-02T10:00:00Z', '2026-10-02T23:00:00Z');

  it('is expired once marked, whatever the event', () => {
    expect(transferExpired({ status: 'expired' }, live, NOW)).toBe(true);
  });
  it('a pending link expires with its event', () => {
    expect(transferExpired({ status: 'pending' }, ended, NOW)).toBe(true);
    expect(transferExpired({ status: 'pending' }, live, NOW)).toBe(false);
    expect(transferExpired({ status: 'pending' }, null, NOW)).toBe(false);
  });
  it('a claimed or cancelled link is not "expired"', () => {
    expect(transferExpired({ status: 'completed' }, ended, NOW)).toBe(false);
    expect(transferExpired({ status: 'cancelled' }, ended, NOW)).toBe(false);
    expect(transferExpired(null, ended, NOW)).toBe(false);
  });
});
