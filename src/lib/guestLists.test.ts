import { describe, expect, it } from 'vitest';
import {
  applyArrival,
  capLeft,
  countsByList,
  dropFromQueue,
  enqueueArrival,
  listCounts,
  normalizeForSearch,
  overlayPending,
  remainingFor,
  searchGuests,
  validateGuestInput,
  type GuestEntry,
} from './guestLists';

const g = (id: string, name: string, plusOnes = 0, arrived = 0, listId = 'L1'): GuestEntry => ({
  id, listId, guestName: name, plusOnes, arrived, arrivedAt: null, note: null,
});

describe('guest list model', () => {
  const entries = [g('1', 'Ana Ruiz', 2, 1), g('2', 'Ben Lee', 1), g('3', 'José Núñez', 0, 0, 'L2')];

  it('counts heads and arrivals', () => {
    expect(listCounts(entries)).toEqual({ entries: 3, heads: 6, arrived: 1 });
    const by = countsByList(entries, ['L1', 'L2', 'L3']);
    expect(by.L1).toEqual({ entries: 2, heads: 5, arrived: 1 });
    expect(by.L3).toEqual({ entries: 0, heads: 0, arrived: 0 });
    expect(capLeft(5, entries.filter((e) => e.listId === 'L1'))).toBe(0);
    expect(capLeft(null, entries)).toBeNull();
    expect(remainingFor(entries[0])).toBe(2);
  });

  it('validates guest input against limits and the cap', () => {
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 1 }, { maxPlusOnes: 2, capLeft: 2 })).toBeNull();
    expect(validateGuestInput({ guestName: ' ', plusOnes: 0 }, { maxPlusOnes: 2 })).toMatch(/name/);
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 3 }, { maxPlusOnes: 2 })).toMatch(/up to 2/);
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 2 }, { maxPlusOnes: 2, capLeft: 2 })).toMatch(/Only 2/);
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 0 }, { maxPlusOnes: 2, capLeft: 0 })).toMatch(/full/);
    // Editing an existing party counts only the extra heads.
    expect(validateGuestInput({ guestName: 'Ben', plusOnes: 2 }, { maxPlusOnes: 2, capLeft: 1, currentHeads: 2 })).toBeNull();
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 0, email: 'nope' }, { maxPlusOnes: 2 })).toMatch(/email/);
    expect(validateGuestInput({ guestName: 'Cleo', plusOnes: 0, phone: 'call me' }, { maxPlusOnes: 2 })).toMatch(/phone/);
  });

  it('searches names like a door list', () => {
    expect(normalizeForSearch('  José   NÚÑEZ ')).toBe('jose nunez');
    expect(searchGuests(entries, 'jose').map((e) => e.id)).toEqual(['3']);
    expect(searchGuests(entries, 'nunez').map((e) => e.id)).toEqual(['3']);
    expect(searchGuests(entries, 'ana r').map((e) => e.id)).toEqual(['1']);
    expect(searchGuests(entries, 'ruiz').map((e) => e.id)).toEqual(['1']);
    expect(searchGuests(entries, 'zz')).toEqual([]);
    expect(searchGuests(entries, '').map((e) => e.guestName)).toEqual(['Ana Ruiz', 'Ben Lee', 'José Núñez']);
    // A name starting with the query ranks above a later-word match.
    const more = [g('4', 'Lee Park'), g('5', 'Ben Lee')];
    expect(searchGuests(more, 'lee').map((e) => e.id)).toEqual(['4', '5']);
  });

  it('applies partial arrivals without overshooting', () => {
    const r1 = applyArrival(entries[0], 1, 'T');
    expect(r1.ok && r1.entry?.arrived).toBe(2);
    expect(applyArrival(entries[0], 3)).toEqual({ ok: false, reason: "over", remaining: 2 });
    expect(applyArrival(g('x', 'X', 0, 1), 1)).toEqual({ ok: false, reason: 'used', remaining: 0 });
    expect(applyArrival(entries[1], 0)).toMatchObject({ ok: false, reason: 'bad-count' });
    const r2 = applyArrival(entries[1], 2, 'T');
    expect(r2.ok && r2.entry?.arrivedAt).toBe("T");
  });

  it('queues pending arrivals idempotently and overlays them', () => {
    let q = enqueueArrival([], { ref: 'r1', entryId: '2', count: 1, at: 1 });
    q = enqueueArrival(q, { ref: 'r1', entryId: '2', count: 1, at: 1 });
    q = enqueueArrival(q, { ref: 'r2', entryId: '2', count: 5, at: 2 });
    expect(q.map((p) => p.ref)).toEqual(['r1', 'r2']);
    const over = overlayPending(entries, q);
    expect(over.find((e) => e.id === '2')!.arrived).toBe(2); // clamped at party size
    expect(dropFromQueue(q, ['r1']).map((p) => p.ref)).toEqual(['r2']);
  });
});
