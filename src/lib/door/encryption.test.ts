// Encryption at rest for the door's saved list (lib/door/kv doorCipher +
// lib/door/roster load/save). Node has WebCrypto (globalThis.crypto.subtle).
import { describe, it, expect } from 'vitest';
import { DEVICE_KEY, doorCipher, isSealed, localStorageKV, type DoorKV, type StorageLike } from './kv';
import { loadRoster, pruneRosters, rosterKey, saveRoster, wipeDoorRosters, type DoorRoster } from './roster';

const NOW = Date.UTC(2026, 8, 29, 22, 0, 0);
const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';

/** An IndexedDB stand-in: keeps values as objects (structured clone). */
function objectKV(): DoorKV & { m: Map<string, unknown> } {
  const m = new Map<string, unknown>();
  return {
    m,
    async get<T>(k: string) { return m.get(k) as T | undefined; },
    async set(k, v) { m.set(k, v); return true; },
    async del(k) { m.delete(k); },
    async keys(prefix) { return [...m.keys()].filter((k) => k.startsWith(prefix)); },
    async canStoreObjects() { return true; },
  };
}

class Mem implements StorageLike {
  m = new Map<string, string>();
  get length() { return this.m.size; }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  getItem(k: string) { return this.m.get(k) ?? null; }
  setItem(k: string, v: string) { this.m.set(k, v); }
  removeItem(k: string) { this.m.delete(k); }
}

const roster: DoorRoster = {
  't-1': { used: false, name: 'Ada Lovelace', tier: 'VIP', barcodeSecret: 'super-secret-1', tierId: 'tier-vip' },
  't-2': { used: true, name: 'Grace Hopper', tier: 'GA', barcodeSecret: 'super-secret-2', lists: { 'l-1': 'exit' } },
};

const bytes = (v: unknown) => {
  const b = v as { ct: ArrayBuffer };
  return new TextDecoder().decode(new Uint8Array(b.ct));
};

describe('doorCipher', () => {
  it('makes one non-extractable AES-GCM key per device and keeps it in the store', async () => {
    const kv = objectKV();
    const c = await doorCipher(kv);
    expect(c).not.toBeNull();
    const key = kv.m.get(DEVICE_KEY) as CryptoKey;
    expect(key.type).toBe('secret');
    expect(key.extractable).toBe(false);
    expect((key.algorithm as { name: string }).name).toBe('AES-GCM');
    await expect(globalThis.crypto.subtle.exportKey('raw', key)).rejects.toThrow();
    // A second cipher (next page load) reuses the stored key.
    const c2 = await doorCipher(kv);
    expect(kv.m.get(DEVICE_KEY)).toBe(key);
    expect(await c2!.open(await c!.seal({ a: 1 }))).toEqual({ a: 1 });
  });

  it('seals with a fresh IV each time; the ciphertext holds no plain text', async () => {
    const c = (await doorCipher(objectKV()))!;
    const a = await c.seal(roster);
    const b = await c.seal(roster);
    expect(isSealed(a)).toBe(true);
    expect(Buffer.from(a.iv).equals(Buffer.from(b.iv))).toBe(false);
    expect(bytes(a)).not.toContain('super-secret');
  });

  it('another device key cannot open it', async () => {
    const a = (await doorCipher(objectKV()))!;
    const b = (await doorCipher(objectKV()))!;
    await expect(b.open(await a.seal(roster))).rejects.toThrow();
  });

  it('falls back (null) where WebCrypto or an object store is missing', async () => {
    expect(await doorCipher(objectKV(), null)).toBeNull();
    expect(await doorCipher(localStorageKV(new Mem()))).toBeNull();
    const noCaps: DoorKV = { ...objectKV(), canStoreObjects: undefined };
    expect(await doorCipher(noCaps)).toBeNull();
  });
});

describe('saved roster, encrypted', () => {
  it('saves sealed and loads it back', async () => {
    const kv = objectKV();
    const c = await doorCipher(kv);
    expect(await saveRoster(kv, EVENT, roster, NOW, c)).toBe(true);
    const raw = kv.m.get(rosterKey(EVENT)) as { _savedAt: number; sealed: unknown; data?: unknown };
    expect(raw._savedAt).toBe(NOW);
    expect(raw.data).toBeUndefined();
    expect(isSealed(raw.sealed)).toBe(true);
    expect(JSON.stringify(raw)).not.toContain('Ada');
    expect(await loadRoster(kv, null, EVENT, NOW + 1000, c)).toEqual({ _savedAt: NOW, data: roster });
  });

  it('migrates a plain-text roster on first load', async () => {
    const kv = objectKV();
    await saveRoster(kv, EVENT, roster, NOW, null);
    expect((kv.m.get(rosterKey(EVENT)) as { data?: unknown }).data).toBeDefined();
    const c = await doorCipher(kv);
    expect(await loadRoster(kv, null, EVENT, NOW + 1000, c)).toEqual({ _savedAt: NOW, data: roster });
    const after = kv.m.get(rosterKey(EVENT)) as { sealed?: unknown; data?: unknown };
    expect(after.data).toBeUndefined();
    expect(isSealed(after.sealed)).toBe(true);
    expect(await loadRoster(kv, null, EVENT, NOW + 2000, c)).toEqual({ _savedAt: NOW, data: roster });
  });

  it('moves an old localStorage copy into the store, sealed', async () => {
    const kv = objectKV();
    const legacy = new Mem();
    legacy.setItem(rosterKey(EVENT), JSON.stringify({ _savedAt: NOW, data: roster }));
    const c = await doorCipher(kv);
    expect((await loadRoster(kv, legacy, EVENT, NOW + 1000, c))?.data).toEqual(roster);
    expect(legacy.getItem(rosterKey(EVENT))).toBeNull();
    expect(isSealed((kv.m.get(rosterKey(EVENT)) as { sealed: unknown }).sealed)).toBe(true);
  });

  it('a copy this device cannot open is dropped (re-download)', async () => {
    const kv = objectKV();
    const other = (await doorCipher(objectKV()))!;
    await saveRoster(kv, EVENT, roster, NOW, other);
    const mine = await doorCipher(kv);
    expect(await loadRoster(kv, null, EVENT, NOW + 1000, mine)).toBeNull();
    expect(kv.m.has(rosterKey(EVENT))).toBe(false);
  });

  it('without a cipher a sealed copy is unreadable and dropped; plain text still works', async () => {
    const kv = objectKV();
    await saveRoster(kv, EVENT, roster, NOW, await doorCipher(kv));
    expect(await loadRoster(kv, null, EVENT, NOW + 1000, null)).toBeNull();
    await saveRoster(kv, EVENT, roster, NOW, null);
    expect((await loadRoster(kv, null, EVENT, NOW + 1000, null))?.data).toEqual(roster);
  });

  it('the TTL sweep reads sealed rosters without decrypting and keeps the key', async () => {
    const kv = objectKV();
    const c = await doorCipher(kv);
    await saveRoster(kv, EVENT, roster, NOW, c);
    await saveRoster(kv, 'old', roster, NOW - 25 * 3600_000, c);
    await pruneRosters(kv, NOW);
    expect(kv.m.has(rosterKey(EVENT))).toBe(true);
    expect(kv.m.has(rosterKey('old'))).toBe(false);
    expect(kv.m.has(DEVICE_KEY)).toBe(true);
  });

  it('sign-out wipes the rosters and the device key', async () => {
    const kv = objectKV();
    const c = await doorCipher(kv);
    await saveRoster(kv, EVENT, roster, NOW, c);
    await wipeDoorRosters(kv);
    expect(kv.m.size).toBe(0);
    // The next cipher is a new key: the old blob (if any survived) can't be read.
    expect((await doorCipher(kv))).not.toBeNull();
    expect(kv.m.get(DEVICE_KEY)).not.toBe(undefined);
  });
});
