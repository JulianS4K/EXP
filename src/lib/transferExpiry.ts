// Transfers and their claim links expire when the event ends
// (mig 20261002101500). This mirrors the database rule `_exos_event_over` so
// the claim page can say "expired" before the hourly sweep marks the row:
// over = the end time, else the start + 12 hours; no start time never ends.
// The database is the authority (it refuses the claim either way).
import type { Event, Transfer } from '../types';

export const NO_END_GRACE_MS = 12 * 60 * 60 * 1000;

export function eventEndMs(start?: Date | null, end?: Date | null): number | null {
  if (end && !Number.isNaN(end.getTime())) return end.getTime();
  if (start && !Number.isNaN(start.getTime())) return start.getTime() + NO_END_GRACE_MS;
  return null;
}

export function eventOver(start?: Date | null, end?: Date | null, now: number = Date.now()): boolean {
  const ends = eventEndMs(start, end);
  return ends !== null && ends <= now;
}

/** Event rows map an unset start to the epoch (see lib/events.ts), so only a real time counts. */
function realDate(ts?: { toDate(): Date } | null): Date | null {
  const d = ts?.toDate();
  return d && d.getTime() > 0 ? d : null;
}

export function eventIsOver(ev?: Pick<Event, 'timing'> | null, now: number = Date.now()): boolean {
  if (!ev?.timing) return false;
  return eventOver(realDate(ev.timing.startTime), realDate(ev.timing.endTime), now);
}

/** True when a claim link can no longer be used because its event is over. */
export function transferExpired(
  transfer: Pick<Transfer, 'status'> | null | undefined,
  ev?: Pick<Event, 'timing'> | null,
  now: number = Date.now(),
): boolean {
  if (!transfer) return false;
  if (transfer.status === 'expired') return true;
  return transfer.status === 'pending' && eventIsOver(ev, now);
}
