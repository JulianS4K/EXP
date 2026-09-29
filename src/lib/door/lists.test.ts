import { describe, it, expect } from 'vitest';
import {
  NO_LIST,
  checkinListInputError,
  effectiveDirection,
  listAdmitsTier,
  listWindow,
  loadDirection,
  loadListChoice,
  mapCheckinListRow,
  parseListState,
  pickList,
  saveDirection,
  saveListChoice,
  withDirection,
  type DoorCheckinList,
} from './lists';
import type { StorageLike } from './kv';

const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';
const NOW = Date.UTC(2026, 8, 29, 22, 0, 0);
const HOUR = 3_600_000;

class Mem implements StorageLike {
  m = new Map<string, string>();
  get length() { return this.m.size; }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  getItem(k: string) { return this.m.get(k) ?? null; }
  setItem(k: string, v: string) { this.m.set(k, v); }
  removeItem(k: string) { this.m.delete(k); }
}

const list = (over: Partial<DoorCheckinList> = {}): DoorCheckinList => ({
  id: 'l1', name: 'Main', tierIds: null, allowReentry: false, validFrom: null, validUntil: null, sortOrder: 0, ...over,
});

describe('mapCheckinListRow', () => {
  it('maps a row; re-entry is off unless the row says true', () => {
    expect(mapCheckinListRow({ id: 'a', name: 'VIP', tier_ids: ['t1'], allow_reentry: true, valid_from: null, sort_order: 2 }))
      .toEqual({ id: 'a', name: 'VIP', tierIds: ['t1'], allowReentry: true, validFrom: null, validUntil: null, sortOrder: 2 });
    expect(mapCheckinListRow({ id: 'b', name: 'Main', tier_ids: null }).allowReentry).toBe(false);
    expect(mapCheckinListRow({ id: 'b', name: 'Main', tier_ids: [] }).tierIds).toBeNull();
  });
});

describe('the list picker', () => {
  const a = list({ id: 'a', name: 'Main', sortOrder: 1 });
  const b = list({ id: 'b', name: 'VIP', sortOrder: 0 });
  it('no lists → no list', () => {
    expect(pickList(null, 'a')).toBeNull();
    expect(pickList([], null)).toBeNull();
  });
  it('a remembered list wins, a deleted one falls back to the first by order', () => {
    expect(pickList([a, b], 'a')?.id).toBe('a');
    expect(pickList([a, b], 'gone')?.id).toBe('b');
    expect(pickList([a, b], null)?.id).toBe('b');
  });
  it('"no list" is a choice too', () => {
    expect(pickList([a, b], NO_LIST)).toBeNull();
  });
  it('is remembered per device and event', () => {
    const mem = new Mem();
    expect(loadListChoice(mem, EVENT)).toBeNull();
    saveListChoice(mem, EVENT, 'a');
    expect(loadListChoice(mem, EVENT)).toBe('a');
    saveListChoice(mem, EVENT, null);
    expect(loadListChoice(mem, EVENT)).toBe(NO_LIST);
    expect(loadListChoice(mem, 'other')).toBeNull();
    expect(loadListChoice(null, EVENT)).toBeNull();
  });
  it('direction: exits only on a re-entry list', () => {
    expect(effectiveDirection(null, 'exit')).toBe('entry');
    expect(effectiveDirection(list(), 'exit')).toBe('entry');
    expect(effectiveDirection(list({ allowReentry: true }), 'exit')).toBe('exit');
    const mem = new Mem();
    expect(loadDirection(mem, EVENT)).toBe('entry');
    saveDirection(mem, EVENT, 'exit');
    expect(loadDirection(mem, EVENT)).toBe('exit');
  });
});

describe('list rules', () => {
  it('tiers', () => {
    expect(listAdmitsTier(list(), 't9')).toBe(true);
    expect(listAdmitsTier(list({ tierIds: ['t1'] }), 't1')).toBe(true);
    expect(listAdmitsTier(list({ tierIds: ['t1'] }), 't2')).toBe(false);
    expect(listAdmitsTier(list({ tierIds: ['t1'] }), null)).toBe(true);
  });
  it('window', () => {
    expect(listWindow(list(), NOW)).toBe('open');
    expect(listWindow(list({ validFrom: new Date(NOW + HOUR).toISOString() }), NOW)).toBe('not-yet');
    expect(listWindow(list({ validUntil: new Date(NOW - HOUR).toISOString() }), NOW)).toBe('closed');
    expect(listWindow(list({ validFrom: new Date(NOW - HOUR).toISOString(), validUntil: new Date(NOW + HOUR).toISOString() }), NOW)).toBe('open');
  });
  it('list state', () => {
    expect(parseListState({ a: 'entry', b: 'exit', c: 'sideways' })).toEqual({ a: 'entry', b: 'exit' });
    expect(parseListState(null)).toBeUndefined();
    expect(parseListState({})).toBeUndefined();
    expect(withDirection(undefined, 'a', 'entry')).toEqual({ a: 'entry' });
    expect(withDirection({ a: 'entry', b: 'entry' }, 'a', 'exit')).toEqual({ a: 'exit', b: 'entry' });
  });
});

describe('checkinListInputError', () => {
  const ok = { name: 'Main door', tierIds: null, allowReentry: false, validFrom: null, validUntil: null };
  it('accepts a plain list', () => expect(checkinListInputError(ok)).toBeNull());
  it('needs a name and at least one ticket type', () => {
    expect(checkinListInputError({ ...ok, name: '  ' })).toMatch(/name/);
    expect(checkinListInputError({ ...ok, name: 'x'.repeat(61) })).toMatch(/60/);
    expect(checkinListInputError({ ...ok, tierIds: [] })).toMatch(/ticket type/);
  });
  it('checks the window', () => {
    expect(checkinListInputError({ ...ok, validFrom: '2026-09-29T22:00:00Z', validUntil: '2026-09-29T21:00:00Z' })).toMatch(/end after/);
    expect(checkinListInputError({ ...ok, validFrom: 'nope' })).toMatch(/start/);
  });
});
