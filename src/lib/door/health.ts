// The door's sync-health panel (door audit #10): how old the saved list is,
// what is waiting to upload, when the last upload went through, how far this
// device's clock is from the server's, and what the server refused on replay.
// Pure helpers, unit-tested; OrganizerCheckIn renders them.

import { isServerAnswer } from './net';

/** Why an upload failed:
 *   'network' — the server wasn't reached: keep the scan, retry later
 *   'session' — the sign-in expired (PostgREST PGRST301/302 or a JWT
 *               message): refresh the session, then retry
 *   'auth'    — the server says this account may not upload these scans
 *               (42501, e.g. no longer door staff): stop retrying, keep them
 *   'server'  — any other server error: retry later */
export type ReplayErrorKind = 'network' | 'session' | 'auth' | 'server';

export function classifyReplayError(err: unknown): ReplayErrorKind {
  if (!isServerAnswer(err)) return 'network';
  const e = err as { code?: string; message?: string };
  if (e.code === 'PGRST301' || e.code === 'PGRST302' || /jwt/i.test(e.message ?? '')) return 'session';
  if (e.code === '42501' || /not authori[sz]ed|not assigned|permission denied/i.test(e.message ?? '')) return 'auth';
  return 'server';
}

/** A refused offline scan, kept on screen until dismissed. */
export interface ReplayConflict {
  ticketId: string;
  name?: string;
  reason: string;
  /** The server still recorded the admission (forced check-in). */
  forced: boolean;
  /** When the door admitted them (ms). */
  scannedAt: number;
  /** When the upload was answered (ms). */
  at: number;
}

const CONFLICT_TEXT: Record<string, string> = {
  used: 'already checked in',
  'already-inside': 'already inside on this list',
  voided: 'refunded / voided',
  'in-transfer': 'mid-transfer',
  'wrong-list': 'ticket type not on this list',
  'invalid-time': "outside this list's hours",
  'doors-not-open': 'before doors',
  'bad-scan-time': 'scan too old to upload',
  'barcode-rejected': 'code no longer valid (transferred or tampered)',
  'barcode-expired': 'code outside its time window',
  'event-cancelled': 'event cancelled',
  'not-assigned': 'scanner not assigned to this event',
  'wrong-event': 'another event',
  'needs-manager': 'typed entry needs a manager',
  'exit-not-allowed': 'exit on a list without re-entry',
};

export function conflictText(c: Pick<ReplayConflict, 'reason' | 'forced'>): string {
  const base = CONFLICT_TEXT[c.reason] ?? c.reason;
  return c.forced ? `${base} · admission recorded` : base;
}

/** "just now", "4 min", "2 h 5 min", "3 d". */
export function formatAge(ms: number): string {
  if (!Number.isFinite(ms) || ms < 60_000) return 'just now';
  const min = Math.floor(ms / 60_000);
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60);
  if (h < 48) return min % 60 ? `${h} h ${min % 60} min` : `${h} h`;
  return `${Math.floor(h / 24)} d`;
}

/** "+2.1 s" (this device is behind the server), "−0.4 s", "in sync". */
export function formatOffset(ms: number | null): string {
  if (ms == null || !Number.isFinite(ms)) return 'not measured';
  if (Math.abs(ms) < 100) return 'in sync';
  const s = Math.abs(ms) / 1000;
  const v = s >= 100 ? Math.round(s).toString() : s.toFixed(1);
  return `${ms > 0 ? '+' : '−'}${v} s`;
}

export type HealthLevel = 'ok' | 'warn' | 'bad';

export interface SyncHealthInput {
  now: number;
  online: boolean;
  /** When the roster in use was downloaded (ms), null = none on this device. */
  rosterSavedAt: number | null;
  rosterCount: number;
  ticketsSold: number;
  /** Scans waiting to upload, with when each was made. */
  pending: { scannedAt: number }[];
  lastSyncAt: number | null;
  /** Server minus device (ms), null when not measured. */
  clockOffsetMs: number | null;
  conflicts: number;
  /** Uploads stopped: the server refused this account (42501). */
  authBlocked: boolean;
  /** The saved list is kept in plain text (no WebCrypto / IndexedDB). */
  plaintextRoster?: boolean;
}

export interface SyncHealthLine {
  label: string;
  value: string;
  level: HealthLevel;
}

export interface SyncHealth {
  level: HealthLevel;
  lines: SyncHealthLine[];
}

/** A saved list older than this is flagged (it is re-pulled every minute
 *  while online, so an old one means the device has been offline a while). */
export const ROSTER_STALE_MS = 15 * 60_000;
/** A scan waiting longer than this is flagged. */
export const PENDING_STALE_MS = 10 * 60_000;
/** A clock further off than this is flagged: codes are 30-second windows. */
export const CLOCK_WARN_MS = 30_000;

export function syncHealth(i: SyncHealthInput): SyncHealth {
  const lines: SyncHealthLine[] = [];
  const rosterAge = i.rosterSavedAt != null ? i.now - i.rosterSavedAt : null;
  lines.push({
    label: 'Offline list',
    value:
      rosterAge == null
        ? 'not downloaded'
        : `${i.rosterCount}${i.ticketsSold > 0 ? ` / ${i.ticketsSold}` : ''} tickets · ${formatAge(rosterAge)} old${
            i.plaintextRoster ? ' · not encrypted' : ''
          }`,
    level: rosterAge == null ? 'bad' : rosterAge > ROSTER_STALE_MS || i.plaintextRoster ? 'warn' : 'ok',
  });
  const oldest = i.pending.reduce<number | null>((m, p) => (m == null || p.scannedAt < m ? p.scannedAt : m), null);
  lines.push({
    label: 'Waiting to upload',
    value:
      i.pending.length === 0
        ? 'nothing'
        : `${i.pending.length} scan${i.pending.length === 1 ? '' : 's'}${oldest != null ? ` · oldest ${formatAge(i.now - oldest)}` : ''}${
            i.authBlocked ? ' · not authorized to upload' : ''
          }`,
    level: i.authBlocked ? 'bad' : i.pending.length === 0 ? 'ok' : oldest != null && i.now - oldest > PENDING_STALE_MS ? 'warn' : 'ok',
  });
  lines.push({
    label: 'Last upload',
    value: i.lastSyncAt == null ? 'none this session' : `${formatAge(i.now - i.lastSyncAt)} ago`,
    level: 'ok',
  });
  lines.push({
    label: 'Clock vs server',
    value: formatOffset(i.clockOffsetMs),
    level: i.clockOffsetMs != null && Math.abs(i.clockOffsetMs) > CLOCK_WARN_MS ? 'warn' : 'ok',
  });
  lines.push({
    label: 'Conflicts',
    value: i.conflicts === 0 ? 'none' : `${i.conflicts} refused on upload`,
    level: i.conflicts === 0 ? 'ok' : 'warn',
  });
  const worst: HealthLevel = lines.some((l) => l.level === 'bad') ? 'bad' : lines.some((l) => l.level === 'warn') ? 'warn' : 'ok';
  return { level: !i.online && worst === 'ok' ? 'warn' : worst, lines };
}

/** The sign-out warning, or null when nothing is waiting. */
export function signOutWarning(pending: number): string | null {
  if (pending <= 0) return null;
  return `${pending} door check-in${pending === 1 ? " hasn't" : "s haven't"} uploaded yet. They stay on this device and upload the next time door staff for the event sign in here and open the scanner. Sign out anyway?`;
}
