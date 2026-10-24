// Scanner event scope at the door (exos_event_staff, mig 20260929041000): a
// scanner limited to some events sees only those on the door home, and the
// scanner page says "not assigned" when the server refuses this account for
// the event. Pure, unit-tested.

/** The events a member may open at the door. `assigned` = their
 *  exos_event_staff event ids in the org (empty: every event); owners and
 *  managers see every event. */
export function assignedDoorEvents<T extends { id: string }>(events: T[], role: string | null, assigned: string[] | null): T[] {
  if (role !== 'scanner' || !assigned || assigned.length === 0) return events;
  const ok = new Set(assigned);
  return events.filter((e) => ok.has(e.id));
}

/** The server refused this account for this event's door (the roster and the
 *  check-in RPCs raise 42501 "not assigned to this event", or answer reason
 *  'not-assigned'). Other 42501s are "not door staff" (signed out, removed). */
export type DoorAccessProblem = 'not-assigned' | 'not-staff' | null;
export function doorAccessProblem(err: unknown): DoorAccessProblem {
  if (!err || typeof err !== 'object') return null;
  const e = err as { code?: unknown; message?: unknown; reason?: unknown };
  if (e.reason === 'not-assigned') return 'not-assigned';
  if (e.code !== '42501') return null;
  return /not assigned/i.test(typeof e.message === 'string' ? e.message : '') ? 'not-assigned' : 'not-staff';
}

export const NOT_ASSIGNED_TEXT =
  "You're not assigned to scan this event. Ask an owner or manager to add it to your events.";
export const NOT_STAFF_TEXT =
  'The server refused this check-in for this account (signed out, or no longer door staff for this event). Sign in again or ask a manager.';
