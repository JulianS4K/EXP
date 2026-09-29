import { describe, it, expect } from 'vitest';
import {
  REGISTRY_TTL_MS,
  deviceLabel,
  enqueueScan,
  isRegistryFresh,
  newClientRef,
  parseQueue,
  removeRefs,
  type QueuedScan,
} from './offlineCheckins';

const T1 = '11111111-2222-3333-4444-555555555555';
const T2 = '66666666-7777-8888-9999-000000000000';
const R1 = 'aaaaaaaa-0000-4000-8000-000000000001';
const R2 = 'aaaaaaaa-0000-4000-8000-000000000002';
const NOW = Date.UTC(2026, 8, 28, 22, 0, 0);

const scan = (ref: string, ticketId = T1): QueuedScan => ({
  ref, ticketId, payload: `T-${ticketId}:owner:1:sig`, scannedAt: NOW - 60_000, source: 'camera',
});

describe('newClientRef', () => {
  it('is a v4 uuid and unique', () => {
    const a = newClientRef();
    expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(newClientRef()).not.toBe(a);
  });
});

describe('parseQueue', () => {
  it('round-trips queued scans', () => {
    const q = [scan(R1), { ...scan(R2, T2), payload: null, source: 'manual' as const, reason: 'phone died' }];
    expect(parseQueue(JSON.stringify(q), NOW)).toEqual(q);
  });

  it('keeps a by-name check-in (with or without a note), and drops an unknown kind', () => {
    const byName: QueuedScan = { ...scan(R1), payload: null, source: 'manual', reason: 'ID checked', kind: 'name' };
    expect(parseQueue(JSON.stringify([byName]), NOW)).toEqual([byName]);
    const noNote: QueuedScan = { ...scan(R2, T2), payload: null, source: 'manual', kind: 'name' };
    expect(parseQueue(JSON.stringify([noNote]), NOW)).toEqual([noNote]);
    const odd = { ...scan(R2), kind: 'will-call' };
    expect(parseQueue(JSON.stringify([odd]), NOW)).toEqual([scan(R2)]);
  });

  it('turns legacy bare ids into typed entries scanned now', () => {
    const q = parseQueue(JSON.stringify([T1, 'not-a-uuid']), NOW, () => R1);
    expect(q).toEqual([{ ref: R1, ticketId: T1, payload: null, scannedAt: NOW, source: 'manual' }]);
  });

  it('skips junk', () => {
    expect(parseQueue(null, NOW)).toEqual([]);
    expect(parseQueue('{oops', NOW)).toEqual([]);
    expect(parseQueue('{"a":1}', NOW)).toEqual([]);
    expect(parseQueue(JSON.stringify([{ ...scan(R1), scannedAt: 'x' }, { ...scan('nope') }]), NOW)).toEqual([]);
  });
});

describe('enqueueScan / removeRefs', () => {
  it('adds once per ref and removes answered refs', () => {
    let q = enqueueScan([], scan(R1));
    q = enqueueScan(q, scan(R1));
    q = enqueueScan(q, scan(R2, T2));
    expect(q.map((s) => s.ref)).toEqual([R1, R2]);
    expect(removeRefs(q, [R1]).map((s) => s.ref)).toEqual([R2]);
  });
});

describe('isRegistryFresh', () => {
  it('keeps a roster for 24 hours', () => {
    expect(isRegistryFresh(NOW - REGISTRY_TTL_MS + 1000, NOW)).toBe(true);
    expect(isRegistryFresh(NOW - REGISTRY_TTL_MS - 1000, NOW)).toBe(false);
    expect(isRegistryFresh(NOW - 7 * 24 * 3600_000, NOW)).toBe(false);
    expect(isRegistryFresh(undefined, NOW)).toBe(false);
    expect(isRegistryFresh(NOW + 3600_000, NOW)).toBe(false);
  });
});

describe('deviceLabel', () => {
  it('makes one label per device and keeps it', () => {
    const store = new Map<string, string>();
    const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v) };
    const a = deviceLabel(storage, () => 0.5);
    expect(a).toBe('Door 8000');
    expect(deviceLabel(storage, () => 0.1)).toBe(a);
    expect(deviceLabel(null, () => 0)).toBe('Door 0000');
  });
});

describe('parseQueue: check-in lists (mig 20260929140000)', () => {
  const REF = '11111111-1111-4111-8111-111111111111';
  const TID = '22222222-2222-4222-8222-222222222222';
  const LIST = '33333333-3333-4333-8333-333333333333';
  const base = { ref: REF, ticketId: TID, payload: null, scannedAt: 1, source: 'camera' };
  it('keeps the list and direction of a list-aware scan', () => {
    expect(parseQueue(JSON.stringify([{ ...base, listId: LIST, direction: 'exit' }]), 0)[0]).toMatchObject({ listId: LIST, direction: 'exit' });
    expect(parseQueue(JSON.stringify([{ ...base, listId: null, direction: 'entry' }]), 0)[0]).toMatchObject({ listId: null, direction: 'entry' });
  });
  it('an old scan (no direction) stays old: it replays through the old RPC', () => {
    const q = parseQueue(JSON.stringify([{ ...base, listId: LIST }]), 0)[0];
    expect(q.direction).toBeUndefined();
    expect(q.listId).toBeUndefined();
  });
  it('drops a malformed list id and an unknown direction', () => {
    expect(parseQueue(JSON.stringify([{ ...base, listId: 'nope', direction: 'entry' }]), 0)[0].listId).toBeNull();
    expect(parseQueue(JSON.stringify([{ ...base, direction: 'sideways' }]), 0)[0].direction).toBeUndefined();
  });
});
