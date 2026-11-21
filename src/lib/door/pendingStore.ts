// Where the door keeps its queue of offline scans (pending_updates_{event}).
//
// localStorage stays the primary copy: it is synchronous, so a scan is saved
// before the next one starts, exactly as before. In the native app every
// write is also mirrored to the platform's durable store (Capacitor
// Preferences, lib/platform/adapters), because iOS may clear a web view's
// storage under disk pressure and a lost queue is lost check-ins. On load, a
// queue missing from localStorage (never an empty one: that's a finished
// sync) is restored from the mirror. On the web the mirror is localStorage
// itself, so nothing changes there.

import { platform, webDurableStore } from '../platform/adapters';
import type { QueuedScan } from '../offlineCheckins';

export const pendingKey = (eventId: string) => `pending_updates_${eventId}`;

// Mirror writes run one after another per key, and after a restore read in
// flight: a scan made while the old queue is still being read must not
// overwrite the mirror before the page has merged that queue back in.
const chain = new Map<string, Promise<unknown>>();

function after(key: string, op: () => Promise<unknown>): Promise<unknown> {
  const next = (chain.get(key) ?? Promise.resolve()).then(op, op).catch(() => undefined);
  chain.set(key, next);
  return next;
}

export function savePendingQueue(eventId: string | undefined, queue: QueuedScan[]): void {
  if (!eventId) return;
  const raw = JSON.stringify(queue);
  try {
    localStorage.setItem(pendingKey(eventId), raw);
  } catch {
    /* storage full / blocked: the in-memory queue still replays this session */
  }
  const store = platform().storage;
  if (store !== webDurableStore) void after(pendingKey(eventId), () => store.set(pendingKey(eventId), raw));
}

export function loadPendingQueueRaw(eventId: string): string | null {
  try {
    return localStorage.getItem(pendingKey(eventId));
  } catch {
    return null;
  }
}

/** The mirrored queue when localStorage has none (native app only; web: null). */
export async function restorePendingQueueRaw(eventId: string): Promise<string | null> {
  const store = platform().storage;
  if (store === webDurableStore) return null;
  if (loadPendingQueueRaw(eventId) !== null) return null;
  let got: string | null = null;
  await after(pendingKey(eventId), async () => {
    got = await store.get(pendingKey(eventId));
  });
  return got;
}

/** `restored` entries the in-memory queue doesn't hold yet (by client ref), appended. */
export function mergeRestored(current: QueuedScan[], restored: QueuedScan[]): QueuedScan[] {
  const have = new Set(current.map((q) => q.ref));
  const add = restored.filter((q) => !have.has(q.ref));
  return add.length ? [...current, ...add] : current;
}
