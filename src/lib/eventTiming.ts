// Event timing checks shared by Create Event and Edit Event (both used to
// differ: Edit saved doors after the show, an end before the start, or a
// start in the past). Times are UTC epoch ms; null = not set.

export interface EventTimes {
  startMs: number | null;
  doorsMs?: number | null;
  endMs?: number | null;
  /** The start as saved (Edit only). An event whose saved start has already
   *  passed can still be edited as long as the start itself isn't changed. */
  savedStartMs?: number | null;
}

/** The first problem with these times, or null when they're fine. */
export function timingProblem(t: EventTimes, now: number = Date.now()): string | null {
  const { startMs, doorsMs, endMs, savedStartMs } = t;
  if (startMs == null || !Number.isFinite(startMs)) return 'Please set the show start time.';
  const unchanged = savedStartMs != null && savedStartMs === startMs;
  if (!unchanged && startMs < now) return 'Show start time must be in the future.';
  if (doorsMs != null && Number.isFinite(doorsMs) && doorsMs > startMs) {
    return 'Doors must open before the show starts.';
  }
  if (endMs != null && Number.isFinite(endMs) && endMs <= startMs) {
    return 'Show end must be after the show start.';
  }
  return null;
}
