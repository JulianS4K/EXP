// Kiosk mode (mig 20261113100000, docs/pos.md "Kiosk mode"): the pure side of
// the self-serve screen. A kiosk sells one event's public ticket types by card
// on its own reader; this file is its state machine, its reset rules and the
// one thing it keeps in the browser (the kiosk credential).
//
//   pick ──next──▶ questions ──next──▶ paying ──card──▶ done
//    ▲               │  (only when the event asks)  │           │
//    └────back───────┘                             └─declined─▶ failed
//   reset (Done, a timeout, idle, or a new sale) goes back to pick with a new
//   order key and every buyer field cleared.
//
// Every rule is enforced in SQL (_exos_pos_kiosk_*); this only drives the screen.

import type { CardSaleState } from '../../supabase/functions/_shared/pos/walkup.ts';

/** Idle on pick / questions with something chosen: start over. */
export const KIOSK_IDLE_MS = 60_000;
/** After a sale: back to the start this long after the last touch. */
export const KIOSK_DONE_MS = 30_000;
/** A declined or cancelled card: the message stays this long. */
export const KIOSK_FAILED_MS = 10_000;
/** Waiting on the reader with nobody touching the screen: cancel on the reader. */
export const KIOSK_PAY_IDLE_MS = 90_000;
/** Never wait on the reader longer than the places are held (5 minutes). */
export const KIOSK_PAY_MAX_MS = 5 * 60_000 - 15_000;

export const KIOSK_STORAGE_KEY = 'exos.kiosk.v1';
/** Kept across a reset: the kiosk's credential and the cookie choice. Everything else goes. */
export const KIOSK_KEEP_KEYS: readonly string[] = [KIOSK_STORAGE_KEY, 'exos.consent.v2'];

export type KioskStep = 'pick' | 'questions' | 'paying' | 'done' | 'failed';

export interface KioskState {
  step: KioskStep;
  tierId: string | null;
  quantity: number;
  /** A new UUID per sale: a double tap or a retry is the same sale. */
  orderKey: string;
  orderId: string | null;
  card: CardSaleState | null;
  declineCode: string | null;
  /** Last touch on the screen (ms). */
  lastInputAt: number;
  /** When the current step began (ms). */
  stepAt: number;
}

export type KioskEvent =
  | { type: 'touch'; at: number }
  | { type: 'pick'; tierId: string; at: number }
  | { type: 'quantity'; quantity: number; max: number; at: number }
  | { type: 'next'; asksQuestions: boolean; at: number }
  | { type: 'back'; at: number }
  | { type: 'charging'; orderId: string; at: number }
  | { type: 'card'; state: CardSaleState; declineCode?: string | null; at: number }
  | { type: 'reset'; orderKey: string; at: number };

export function kioskStart(orderKey: string, at: number): KioskState {
  return { step: 'pick', tierId: null, quantity: 1, orderKey, orderId: null, card: null, declineCode: null, lastInputAt: at, stepAt: at };
}

/** The quantity a buyer may pick: 1 to the event's max per order and what's left. */
export function kioskMaxQuantity(maxPerOrder: number, remaining: number | null): number {
  const cap = Math.max(1, Math.min(10, Math.floor(maxPerOrder) || 1));
  return remaining === null ? cap : Math.max(0, Math.min(cap, remaining));
}

export function kioskReducer(s: KioskState, e: KioskEvent): KioskState {
  switch (e.type) {
    case 'touch':
      return { ...s, lastInputAt: e.at };
    case 'pick':
      if (s.step !== 'pick') return s;
      return { ...s, tierId: e.tierId, quantity: 1, lastInputAt: e.at };
    case 'quantity': {
      if (s.step !== 'pick') return s;
      const q = Math.max(1, Math.min(Math.floor(e.quantity), Math.max(1, e.max)));
      return { ...s, quantity: q, lastInputAt: e.at };
    }
    case 'next':
      if (s.step === 'pick' && s.tierId) {
        return { ...s, step: e.asksQuestions ? 'questions' : 'paying', card: e.asksQuestions ? null : 'starting', lastInputAt: e.at, stepAt: e.at };
      }
      if (s.step === 'questions') return { ...s, step: 'paying', card: 'starting', lastInputAt: e.at, stepAt: e.at };
      return s;
    case 'back':
      if (s.step === 'questions') return { ...s, step: 'pick', lastInputAt: e.at, stepAt: e.at };
      return s;
    case 'charging':
      if (s.step !== 'paying') return s;
      return { ...s, orderId: e.orderId, card: 'waiting' };
    case 'card':
      if (s.step !== 'paying') return s;
      if (e.state === 'succeeded') return { ...s, step: 'done', card: 'succeeded', stepAt: e.at, lastInputAt: e.at };
      if (e.state === 'waiting' || e.state === 'starting') return { ...s, card: e.state };
      return { ...s, step: 'failed', card: e.state, declineCode: e.declineCode ?? null, stepAt: e.at, lastInputAt: e.at };
    case 'reset':
      return kioskStart(e.orderKey, e.at);
  }
}

export type KioskTimerAction = 'none' | 'reset' | 'cancel-and-reset';

/** What the clock says to do now (checked every second). */
export function kioskTimer(s: KioskState, now: number): KioskTimerAction {
  switch (s.step) {
    case 'pick':
      // Nothing chosen: nothing to clear.
      if (s.tierId === null && s.quantity === 1) return 'none';
      return now - s.lastInputAt >= KIOSK_IDLE_MS ? 'reset' : 'none';
    case 'questions':
      return now - s.lastInputAt >= KIOSK_IDLE_MS ? 'reset' : 'none';
    case 'paying':
      if (now - s.stepAt >= KIOSK_PAY_MAX_MS || now - s.lastInputAt >= KIOSK_PAY_IDLE_MS) {
        return s.orderId ? 'cancel-and-reset' : 'reset';
      }
      return 'none';
    case 'done':
      return now - Math.max(s.stepAt, s.lastInputAt) >= KIOSK_DONE_MS ? 'reset' : 'none';
    case 'failed':
      return now - s.stepAt >= KIOSK_FAILED_MS ? 'reset' : 'none';
  }
}

/** Seconds left before the screen starts over (for "Starting over in 12 s"), or null. */
export function kioskSecondsLeft(s: KioskState, now: number): number | null {
  const left = s.step === 'done' ? KIOSK_DONE_MS - (now - Math.max(s.stepAt, s.lastInputAt))
    : s.step === 'failed' ? KIOSK_FAILED_MS - (now - s.stepAt)
    : null;
  return left === null ? null : Math.max(0, Math.ceil(left / 1000));
}

/** The kiosk's credential as this browser keeps it. */
export interface KioskCredential {
  token: string;
  device_id: string;
  event_id: string;
  session_id: string;
}

const TOKEN_RE = /^exk_[0-9a-f]{64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem' | 'key' | 'length'>;

function safe<T>(fn: () => T, fallback: T): T {
  try {
    return fn();
  } catch {
    return fallback;
  }
}

export function parseKioskCredential(raw: string | null): KioskCredential | null {
  if (!raw) return null;
  const v = safe(() => JSON.parse(raw) as Partial<KioskCredential>, null);
  if (!v || typeof v.token !== 'string' || !TOKEN_RE.test(v.token)) return null;
  if (![v.device_id, v.event_id, v.session_id].every((x) => typeof x === 'string' && UUID_RE.test(x))) return null;
  return { token: v.token, device_id: v.device_id!, event_id: v.event_id!, session_id: v.session_id! };
}

export function readKioskCredential(storage: StorageLike | null | undefined): KioskCredential | null {
  return storage ? parseKioskCredential(safe(() => storage.getItem(KIOSK_STORAGE_KEY), null)) : null;
}

export function saveKioskCredential(storage: StorageLike, c: KioskCredential): void {
  storage.setItem(KIOSK_STORAGE_KEY, JSON.stringify(c));
}

export function clearKioskCredential(storage: StorageLike | null | undefined): void {
  if (storage) safe(() => storage.removeItem(KIOSK_STORAGE_KEY), undefined);
}

/**
 * Clear what a buyer may have left in this browser: every key but the kiosk's
 * credential and the cookie choice (a form draft, a signed-in session, a
 * cart). Returns how many keys went. Never throws (storage may be blocked).
 */
export function wipeBuyerStorage(storage: StorageLike | null | undefined, keep: readonly string[] = KIOSK_KEEP_KEYS): number {
  if (!storage) return 0;
  const keys = safe(() => {
    const out: string[] = [];
    for (let i = 0; i < storage.length; i++) {
      const k = storage.key(i);
      if (k !== null && !keep.includes(k)) out.push(k);
    }
    return out;
  }, [] as string[]);
  for (const k of keys) safe(() => storage.removeItem(k), undefined);
  return keys.length;
}

/** This browser's localStorage, or null where it's blocked (reading it can throw). */
export function kioskStorage(): Storage | null {
  return safe(() => (typeof window === 'undefined' ? null : window.localStorage), null);
}

/** Kiosk mode keeps the browser on /kiosk: any other path goes back there. */
export function kioskRedirect(pathname: string, credential: KioskCredential | null): string | null {
  if (!credential) return null;
  return pathname === '/kiosk' ? null : '/kiosk';
}

/** What the PIN pad says after an exit attempt. */
export function kioskExitText(r: { ok: boolean; error?: string; attempts_left?: number; retry_after_seconds?: number }): string | null {
  if (r.ok) return null;
  switch (r.error) {
    case 'wrong-pin': return `Wrong PIN. ${r.attempts_left ?? 0} ${r.attempts_left === 1 ? 'try' : 'tries'} left before a 5-minute lock.`;
    case 'locked': return `Locked after too many wrong PINs. Try again in ${Math.ceil((r.retry_after_seconds ?? 300) / 60)} min.`;
    case 'rate': return 'Too many tries. Wait a minute.';
    default: return "That didn't work. Try again.";
  }
}
