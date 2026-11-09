// exos_events.door_name_checkin, on its own so lib/events.ts (on every public
// page) doesn't pull in the door's scan logic (./decide re-exports these).

/** exos_events.door_name_checkin. */
export type NameCheckinMode = 'staff' | 'managers' | 'off';

/** The column's value, or null when the database doesn't have it yet. */
export function parseNameCheckinMode(v: unknown): NameCheckinMode | null {
  return v === 'staff' || v === 'managers' || v === 'off' ? v : null;
}
