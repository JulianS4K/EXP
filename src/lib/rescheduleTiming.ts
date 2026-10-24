// Reschedule timing (mig 20261021130000). Moving the start moves doors and
// end by the same amount unless the organizer sets them; exos_reschedule_event
// does the same server-side and refuses doors after the start or an end before
// it. Pure, unit-tested.

/** `value` moved by however far the start moved (null in, null out). */
export function shiftWithStart(value: Date | null, oldStart: Date | null, newStart: Date | null): Date | null {
  if (!value || !oldStart || !newStart) return value;
  return new Date(value.getTime() + (newStart.getTime() - oldStart.getTime()));
}

/** What's wrong with the new times, or null: doors <= start <= end. */
export function timingProblem(start: Date | null, doors: Date | null, end: Date | null): string | null {
  if (!start) return null;
  if (doors && doors.getTime() > start.getTime()) return "Doors can't open after the start.";
  if (end && end.getTime() < start.getTime()) return "The end can't be before the start.";
  return null;
}
