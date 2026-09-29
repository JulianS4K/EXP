// A tiny async key-value store for the door's offline copy. IndexedDB when the
// browser has it (no ~5 MB localStorage quota, no JSON stringify of the whole
// roster on the main thread), localStorage otherwise (private windows and old
// browsers where IndexedDB won't open). Every call is wrapped: a blocked or
// full store answers undefined / false, it never throws into the scanner.

export interface DoorKV {
  get<T = unknown>(key: string): Promise<T | undefined>;
  /** false when the write failed (quota, blocked). */
  set(key: string, value: unknown): Promise<boolean>;
  del(key: string): Promise<void>;
  keys(prefix: string): Promise<string[]>;
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
  };
}

let shared: DoorKV | null = null;
/** The door's store for this page (IndexedDB, localStorage fallback). */
export function doorKV(): DoorKV {
  if (!shared) shared = indexedDbKV(localStorageKV(safeLocalStorage()));
  return shared;
}
