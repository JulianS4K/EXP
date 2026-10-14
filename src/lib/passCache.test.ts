import { describe, expect, it } from 'vitest';
import { Timestamp } from './timestamp';
import { decodePasses, encodePasses, passesExpired, type SavedPasses } from './passCache';

const start = Date.UTC(2026, 9, 20, 2, 0);
const saved = (): SavedPasses => ({
  event: { id: 'e1', title: 'Fall Party', date: Timestamp.fromMillis(start) } as any,
  tickets: [{ id: 't1', status: 'active', barcodeSecret: 's', createdAt: Timestamp.fromMillis(start - 86400000) } as any],
  savedAt: start - 3600000,
});

describe('pass cache', () => {
  it('round-trips, Timestamps included', () => {
    const back = decodePasses(encodePasses(saved()))!;
    expect(back.event?.date).toBeInstanceOf(Timestamp);
    expect(back.event?.date.toMillis()).toBe(start);
    expect((back.tickets[0] as any).createdAt.toMillis()).toBe(start - 86400000);
    expect(back.tickets[0].barcodeSecret).toBe('s');
    expect(back.savedAt).toBe(start - 3600000);
  });
  it('junk is null', () => {
    expect(decodePasses('nope')).toBeNull();
    expect(decodePasses('{"tickets":3}')).toBeNull();
  });
  it('kept until two days after the start', () => {
    expect(passesExpired(saved(), start + 86400000)).toBe(false);
    expect(passesExpired(saved(), start + 3 * 86400000)).toBe(true);
    expect(passesExpired({ ...saved(), event: null }, start + 9e10)).toBe(false);
  });
});
