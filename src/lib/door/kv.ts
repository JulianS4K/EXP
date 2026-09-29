// A tiny async key-value store for the door's offline copy. IndexedDB when the
// browser has it (no ~5 MB localStorage quota, no JSON stringify of the whole
// roster on the main thread), localStorage otherwise (private windows and old
// browsers where IndexedDB won't open). Every call is wrapped: a blocked or
// full store answers undefined / false, it never throws into the scanner.
//
// Encryption at rest (door audit #11, first step): the roster holds every
// ticket's barcode secret, so it is sealed with AES-GCM under a per-device
// CryptoKey that is generated NON-EXTRACTABLE (WebCrypto) and kept in
// IndexedDB next to the data. Script on the page can still ask the browser to
// decrypt, but the key bytes can't be read or copied off the device, and a
// dump of the IndexedDB files or of localStorage shows no names or secrets.
// Where WebCrypto or IndexedDB is missing (old browsers, some private
// windows), doorCipher() answers null and the roster is stored as before, in
// plain text; the scanner shows a warning.

export interface DoorKV {
  get<T = unknown>(key: string): Promise<T | undefined>;
  /** false when the write failed (quota, blocked). */
  set(key: string, value: unknown): Promise<boolean>;
  del(key: string): Promise<void>;
  keys(prefix: string): Promise<string[]>;
  /** True when values are kept as structured clones (IndexedDB), so a
   *  CryptoKey can be stored. A JSON store (localStorage) can't. */
  canStoreObjects?(): Promise<boolean>;
}

export type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem' | 'key' | 'length'>;

/** window.localStorage, or null when reading it throws (blocked cookies). */
export function safeLocalStorage(): StorageLike | null {
  try {
    return typeof localStorage !== 'undefined' ? localStorage : null;
  } catch {
    return null;
  }
}

export function storageKeys(storage: StorageLike | null, prefix: string): string[] {
  const out: string[] = [];
  if (!storage) return out;
  try {
    for (let i = 0; i < storage.length; i++) {
      const k = storage.key(i);
      if (k && k.startsWith(prefix)) out.push(k);
    }
  } catch {
    /* storage blocked */
  }
  return out;
}

export function localStorageKV(storage: StorageLike | null): DoorKV {
  return {
    async get<T>(key: string) {
      try {
        const raw = storage?.getItem(key);
        return raw == null ? undefined : (JSON.parse(raw) as T);
      } catch {
        return undefined;
      }
    },
    async set(key, value) {
      if (!storage) return false;
      try {
        storage.setItem(key, JSON.stringify(value));
        return true;
      } catch {
        return false;
      }
    },
    async del(key) {
      try {
        storage?.removeItem(key);
      } catch {
        /* storage blocked */
      }
    },
    async keys(prefix) {
      return storageKeys(storage, prefix);
    },
    async canStoreObjects() {
      return false;
    },
  };
}

const DB_NAME = 'exos-door';
const STORE = 'kv';

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error('indexedDB blocked'));
  });
}

function run<T>(db: IDBDatabase, mode: IDBTransactionMode, op: (s: IDBObjectStore) => IDBRequest): Promise<T> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const req = op(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(req.result as T);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

/** IndexedDB-backed store; falls back to `fallback` for every call once
 *  IndexedDB fails to open. */
export function indexedDbKV(fallback: DoorKV): DoorKV {
  let dbP: Promise<IDBDatabase | null> | null = null;
  const db = () => {
    if (!dbP) {
      dbP = typeof indexedDB === 'undefined'
        ? Promise.resolve(null)
        : openDb().catch((err) => {
            console.warn('door cache: IndexedDB unavailable, using localStorage', err);
            return null;
          });
    }
    return dbP;
  };
  return {
    async get<T>(key: string) {
      const d = await db();
      if (!d) return fallback.get<T>(key);
      try {
        return (await run<T | undefined>(d, 'readonly', (s) => s.get(key))) ?? undefined;
      } catch {
        return undefined;
      }
    },
    async set(key, value) {
      const d = await db();
      if (!d) return fallback.set(key, value);
      try {
        await run(d, 'readwrite', (s) => s.put(value, key));
        return true;
      } catch (err) {
        console.warn('door cache: write failed', err);
        return false;
      }
    },
    async del(key) {
      const d = await db();
      if (!d) return fallback.del(key);
      try {
        await run(d, 'readwrite', (s) => s.delete(key));
      } catch {
        /* ignore */
      }
    },
    async keys(prefix) {
      const d = await db();
      if (!d) return fallback.keys(prefix);
      try {
        const all = await run<IDBValidKey[]>(d, 'readonly', (s) => s.getAllKeys());
        return all.filter((k): k is string => typeof k === 'string' && k.startsWith(prefix));
      } catch {
        return [];
      }
    },
    async canStoreObjects() {
      return (await db()) !== null;
    },
  };
}

let shared: DoorKV | null = null;
/** The door's store for this page (IndexedDB, localStorage fallback). */
export function doorKV(): DoorKV {
  if (!shared) shared = indexedDbKV(localStorageKV(safeLocalStorage()));
  return shared;
}

// --- Encryption at rest ------------------------------------------------------

/** Where this device's roster key lives in the door store. Not a registry_*
 *  key, so the TTL sweep leaves it alone; sign-out deletes it. */
export const DEVICE_KEY = 'door_device_key';

/** A sealed value: AES-GCM (256-bit key, 96-bit random IV) over its JSON. */
export interface SealedBlob {
  v: 1;
  iv: Uint8Array;
  ct: ArrayBuffer;
}

export interface DoorCipher {
  seal(value: unknown): Promise<SealedBlob>;
  /** Throws when the blob wasn't sealed with this device's key. */
  open<T = unknown>(blob: SealedBlob): Promise<T>;
}

export function isSealed(v: unknown): v is SealedBlob {
  if (!v || typeof v !== 'object') return false;
  const b = v as Partial<SealedBlob>;
  return b.v === 1 && b.iv instanceof Uint8Array && (b.ct instanceof ArrayBuffer || ArrayBuffer.isView(b.ct));
}

/** WebCrypto, when this browser has it (secure contexts only). */
export function webCrypto(): Crypto | null {
  try {
    const c = (globalThis as { crypto?: Crypto }).crypto;
    return c && c.subtle && typeof c.getRandomValues === 'function' ? c : null;
  } catch {
    return null;
  }
}

function isAesKey(k: unknown): k is CryptoKey {
  if (!k || typeof k !== 'object') return false;
  const key = k as CryptoKey;
  return key.type === 'secret' && (key.algorithm as { name?: string } | undefined)?.name === 'AES-GCM';
}

/** A cipher over this device's key: the stored one, or a new non-extractable
 *  key saved to `kv`. null when the store can't hold a CryptoKey or WebCrypto
 *  is missing (the caller then stores plain text and says so). */
export async function doorCipher(kv: DoorKV, crypto: Crypto | null = webCrypto()): Promise<DoorCipher | null> {
  if (!crypto || !kv.canStoreObjects) return null;
  try {
    if (!(await kv.canStoreObjects())) return null;
    let key = await kv.get<unknown>(DEVICE_KEY);
    if (!isAesKey(key)) {
      key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      if (!(await kv.set(DEVICE_KEY, key))) return null;
      // Another tab may have saved its key first: use whichever is stored.
      const stored = await kv.get<unknown>(DEVICE_KEY);
      if (isAesKey(stored)) key = stored;
    }
    const k = key as CryptoKey;
    return {
      async seal(value) {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, k, new TextEncoder().encode(JSON.stringify(value)));
        return { v: 1, iv, ct };
      },
      async open<T>(blob: SealedBlob) {
        const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: blob.iv }, k, blob.ct);
        return JSON.parse(new TextDecoder().decode(pt)) as T;
      },
    };
  } catch (err) {
    console.warn('door cache: encryption unavailable, the saved list stays in plain text', err);
    return null;
  }
}

let sharedCipher: Promise<DoorCipher | null> | null = null;
/** The cipher for doorKV(), created once per page. */
export function doorCipherShared(): Promise<DoorCipher | null> {
  if (!sharedCipher) sharedCipher = doorCipher(doorKV());
  return sharedCipher;
}
/** Sign-out deletes the key: the next cipher makes a new one. */
export function forgetDoorCipher(): void {
  sharedCipher = null;
}
