// Offline door queue: what the scanner keeps while it has no network, and how
// it is replayed (exos_check_in_offline, mig 20260929040000).
//
// Each queued scan keeps the code the camera read and when, so the server can
// check the signature against the ticket's CURRENT owner and secret for the
// window it was scanned in. A ticket transferred after the roster was synced
// then comes back as a conflict instead of silently counting the old holder.
// The ref is a per-scan nonce: replaying the same ref twice counts once.
//
// Pure helpers (no storage / network), unit-tested.

/** The cached roster (names + barcode secrets) is dropped after this. */
export const REGISTRY_TTL_MS = 24 * 60 * 60 * 1000;
/** The server refuses replays of scans older than this, unless the event
 *  ended less than REPLAY_AFTER_END_MS ago (mig 20260929140000; scans
 *  queued with a list / direction). At most REPLAY_MAX_AGE_MS either way. */
export const REPLAY_WINDOW_MS = 24 * 60 * 60 * 1000;
export const REPLAY_AFTER_END_MS = 48 * 60 * 60 * 1000;
export const REPLAY_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export interface QueuedScan {
  ref: string;
  ticketId: string;
  /** The scanned code (T-…); null for a typed override. */
  payload: string | null;
  /** When the door admitted them (ms, server-corrected clock). */
  scannedAt: number;
  source: 'camera' | 'manual';
  /** Typed override reason (owner / manager). */
  reason?: string;
  /** A check-in by name (optional note in `reason`): replayed through
   *  exos_door_checkin_by_name, mig 20260929130000. */
  kind?: 'name';
  /** Check-in lists (mig 20260929140000): set on scans queued by a build that
   *  knows lists (null = no list). Such a scan replays through the list-aware
   *  RPCs, which also record a refused entry as a forced check-in. */
  listId?: string | null;
  direction?: 'entry' | 'exit';
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function newClientRef(): string {
  const c: Crypto | undefined = typeof crypto !== 'undefined' ? crypto : undefined;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  const b = new Uint8Array(16);
  if (c && typeof c.getRandomValues === 'function') c.getRandomValues(b);
  else for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function isScan(v: unknown): v is QueuedScan {
  if (!v || typeof v !== 'object') return false;
  const s = v as Record<string, unknown>;
  return (
    typeof s.ref === 'string' && UUID_RE.test(s.ref) &&
    typeof s.ticketId === 'string' && UUID_RE.test(s.ticketId) &&
    (s.payload === null || typeof s.payload === 'string') &&
    typeof s.scannedAt === 'number' && Number.isFinite(s.scannedAt) &&
    (s.source === 'camera' || s.source === 'manual')
  );
}

/** Read a stored queue. Older builds stored bare ticket ids: those become
 *  typed entries (no code, no reason) scanned "now", so the server treats
 *  them as overrides and refuses them unless a manager re-admits — they are
 *  surfaced as conflicts rather than dropped. Malformed entries are skipped. */
export function parseQueue(
  raw: string | null,
  now: number,
  makeRef: () => string = newClientRef,
): QueuedScan[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: QueuedScan[] = [];
  for (const item of parsed) {
    if (typeof item === 'string') {
      if (UUID_RE.test(item)) out.push({ ref: makeRef(), ticketId: item, payload: null, scannedAt: now, source: 'manual' });
    } else if (isScan(item)) {
      out.push({
        ref: item.ref,
        ticketId: item.ticketId,
        payload: item.payload,
        scannedAt: item.scannedAt,
        source: item.source,
        ...(typeof item.reason === 'string' && item.reason ? { reason: item.reason } : {}),
        ...((item as { kind?: unknown }).kind === 'name' ? { kind: 'name' as const } : {}),
        ...listFields(item as { listId?: unknown; direction?: unknown }),
      });
    }
  }
  return out;
}

function listFields(item: { listId?: unknown; direction?: unknown }): Pick<QueuedScan, 'listId' | 'direction'> {
  if (item.direction !== 'entry' && item.direction !== 'exit') return {};
  const listId = typeof item.listId === 'string' && UUID_RE.test(item.listId) ? item.listId : null;
  return { listId, direction: item.direction };
}

/** Scans waiting to upload on this device, across events (sign-out warns). */
export function pendingScanCount(storage: Pick<Storage, 'length' | 'key' | 'getItem'> | null, now: number = Date.now()): number {
  let n = 0;
  if (!storage) return 0;
  try {
    for (let i = 0; i < storage.length; i++) {
      const k = storage.key(i);
      if (k && k.startsWith('pending_updates_')) n += parseQueue(storage.getItem(k), now, () => '').length;
    }
  } catch {
    /* storage blocked */
  }
  return n;
}

/** Add a scan (a ref already queued is not added twice). */
export function enqueueScan(queue: QueuedScan[], scan: QueuedScan): QueuedScan[] {
  if (queue.some((q) => q.ref === scan.ref)) return queue;
  return [...queue, scan];
}

/** Drop the scans the server has answered. */
export function removeRefs(queue: QueuedScan[], refs: Iterable<string>): QueuedScan[] {
  const done = new Set(refs);
  return queue.filter((q) => !done.has(q.ref));
}

/** Is a cached roster saved at `savedAt` still usable? */
export function isRegistryFresh(savedAt: unknown, now: number): boolean {
  return typeof savedAt === 'number' && Number.isFinite(savedAt) && savedAt <= now + 60_000 && now - savedAt <= REGISTRY_TTL_MS;
}

/** A stable, non-secret label for this scanning device ("Door 7F3A"), so
 *  "already used" can say where. */
export function deviceLabel(storage: Pick<Storage, 'getItem' | 'setItem'> | null, random: () => number = Math.random): string {
  const key = 'exos:door-device';
  try {
    const have = storage?.getItem(key);
    if (have && /^Door [0-9A-F]{4}$/.test(have)) return have;
  } catch {
    /* storage blocked */
  }
  const label = `Door ${Math.floor(random() * 0x10000).toString(16).toUpperCase().padStart(4, '0')}`;
  try {
    storage?.setItem(key, label);
  } catch {
    /* storage blocked */
  }
  return label;
}
