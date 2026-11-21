// @vitest-environment jsdom
// The door's offline scan queue: localStorage as before, mirrored to the
// native app's durable store, restored when the OS cleared web storage.
import { afterEach, describe, expect, it } from 'vitest';
import { loadPendingQueueRaw, mergeRestored, pendingKey, restorePendingQueueRaw, savePendingQueue } from './pendingStore';
import { registerPlatformAdapters, resetPlatformAdapters, type DurableStore } from '../platform/adapters';
import type { QueuedScan } from '../offlineCheckins';

const scan = (ref: string): QueuedScan => ({ ref, ticketId: `t-${ref}`, payload: null, scannedAt: 1, source: 'manual' });

function memoryStore(delayMs = 0) {
  const data = new Map<string, string>();
  const wait = () => new Promise((r) => setTimeout(r, delayMs));
  const store: DurableStore = {
    async get(k) {
      await wait();
      return data.get(k) ?? null;
    },
    async set(k, v) {
      await wait();
      data.set(k, v);
      return true;
    },
    async remove(k) {
      data.delete(k);
    },
  };
  return { store, data };
}

const settle = () => new Promise((r) => setTimeout(r, 30));

afterEach(() => {
  resetPlatformAdapters();
  localStorage.clear();
});

describe('on the web', () => {
  it('is localStorage under the same key as before, with no mirror', async () => {
    savePendingQueue('e1', [scan('a')]);
    expect(localStorage.getItem('pending_updates_e1')).toBe(JSON.stringify([scan('a')]));
    expect(loadPendingQueueRaw('e1')).toBe(JSON.stringify([scan('a')]));
    localStorage.clear();
    expect(await restorePendingQueueRaw('e1')).toBeNull();
    savePendingQueue(undefined, [scan('a')]);
    expect(localStorage.length).toBe(0);
  });
});

describe('in the native app', () => {
  it('mirrors every write', async () => {
    const { store, data } = memoryStore();
    registerPlatformAdapters({ storage: store });
    savePendingQueue('e1', [scan('a'), scan('b')]);
    savePendingQueue('e1', [scan('b')]);
    await settle();
    expect(data.get(pendingKey('e1'))).toBe(JSON.stringify([scan('b')]));
  });

  it('restores a queue the OS cleared, but not over a present (even empty) one', async () => {
    const { store, data } = memoryStore();
    registerPlatformAdapters({ storage: store });
    data.set(pendingKey('e1'), JSON.stringify([scan('a')]));
    expect(await restorePendingQueueRaw('e1')).toBe(JSON.stringify([scan('a')]));
    localStorage.setItem(pendingKey('e1'), '[]'); // a finished sync
    expect(await restorePendingQueueRaw('e1')).toBeNull();
  });

  it('a scan made while the old queue is being read does not overwrite it', async () => {
    const { store, data } = memoryStore(10);
    registerPlatformAdapters({ storage: store });
    data.set(pendingKey('e1'), JSON.stringify([scan('a'), scan('b')]));
    const restoring = restorePendingQueueRaw('e1');
    savePendingQueue('e1', [scan('c')]); // the door scanned before the read came back
    const raw = await restoring;
    expect(raw).toBe(JSON.stringify([scan('a'), scan('b')]));
    const merged = mergeRestored([scan('c')], JSON.parse(raw!));
    savePendingQueue('e1', merged);
    await settle();
    expect(JSON.parse(data.get(pendingKey('e1'))!).map((q: QueuedScan) => q.ref)).toEqual(['c', 'a', 'b']);
  });

  it('mergeRestored adds only what the page does not hold yet', () => {
    const cur = [scan('a')];
    expect(mergeRestored(cur, [scan('a')])).toBe(cur);
    expect(mergeRestored(cur, [scan('a'), scan('b')]).map((q) => q.ref)).toEqual(['a', 'b']);
  });
});
