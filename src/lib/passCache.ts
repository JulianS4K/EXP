// The last copy of a ticket page, kept on the device so the pass still opens
// at a door with no signal (a reload offline otherwise shows nothing). The
// QR is signed on the device from the ticket's secret, so a saved copy shows
// a code the door accepts, as the live page does.
//
// Stored under `registry_pass_<uid>_<ticketId>`: sign-out already wipes every
// `registry_` key (AuthContext), so a shared phone keeps nothing. A copy is
// dropped two days after the event starts.

import { Timestamp } from './timestamp';
import type { Event, Ticket } from '../types';

export interface SavedPasses {
  event: Event | null;
  tickets: Ticket[];
  savedAt: number;
}

const PREFIX = 'registry_pass_';
const KEEP_AFTER_START_MS = 2 * 24 * 3600 * 1000;

const keyFor = (uid: string, ticketId: string) => `${PREFIX}${uid}_${ticketId}`;

/** JSON with Timestamps kept (they come back as Timestamps). */
export function encodePasses(p: SavedPasses): string {
  return JSON.stringify(p, function (this: Record<string, unknown>, k, v) {
    const raw = this[k];
    return raw instanceof Timestamp ? { __ts: raw.toMillis() } : v;
  });
}

export function decodePasses(s: string): SavedPasses | null {
  try {
    const p = JSON.parse(s, (_k, v) =>
      v && typeof v === 'object' && typeof v.__ts === 'number' && Object.keys(v).length === 1 ? Timestamp.fromMillis(v.__ts) : v,
    );
    if (!p || !Array.isArray(p.tickets)) return null;
    return { event: p.event ?? null, tickets: p.tickets, savedAt: Number(p.savedAt) || 0 };
  } catch {
    return null;
  }
}

/** Too old to keep: two days after the event started. */
export function passesExpired(p: SavedPasses, now = Date.now()): boolean {
  const start = p.event?.date instanceof Timestamp ? p.event.date.toMillis() : 0;
  return start > 0 && now > start + KEEP_AFTER_START_MS;
}

export function savePasses(uid: string, ticketId: string, event: Event | null, tickets: Ticket[]): void {
  try {
    localStorage.setItem(keyFor(uid, ticketId), encodePasses({ event, tickets, savedAt: Date.now() }));
  } catch {
    /* storage full or unavailable: the live page still works */
  }
}

export function loadPasses(uid: string, ticketId: string): SavedPasses | null {
  try {
    const raw = localStorage.getItem(keyFor(uid, ticketId));
    const p = raw ? decodePasses(raw) : null;
    if (p && passesExpired(p)) {
      localStorage.removeItem(keyFor(uid, ticketId));
      return null;
    }
    return p;
  } catch {
    return null;
  }
}
