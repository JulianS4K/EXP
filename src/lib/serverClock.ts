// Server-corrected clock for rotating barcodes.
//
// The pass signs a code for the current 30-second window of the PHONE's
// clock, and the door accepts ±2 windows (about a minute). A phone whose clock
// is a few minutes off shows a code the door calls expired. The server clock
// (exos_server_time(), mig 20260929040000) fixes that: we measure how far this
// device is from it once and sign / verify with the corrected time.
//
// Pure module state + helpers (no network here — see syncServerClock in
// lib/tickets.ts), so it is unit-tested directly.

const BUCKET_MS = 30_000;
// A round trip slower than this says little about the clock; ignore it.
const MAX_RTT_MS = 10_000;
// Below this we leave the device clock alone (network noise).
const MIN_OFFSET_MS = 1_500;

let offsetMs = 0;
/** The last measured offset, before small ones are rounded to zero (the
 *  door's sync-health panel shows it). null until a measurement succeeds. */
let measuredMs: number | null = null;

/** Offset (server minus device) from one request: sent at t0, answered with
 *  the server's time, received at t1 (device ms). null when the round trip
 *  was too slow to trust. */
export function estimateOffset(t0: number, serverMs: number, t1: number): number | null {
  if (!Number.isFinite(t0) || !Number.isFinite(t1) || !Number.isFinite(serverMs)) return null;
  const rtt = t1 - t0;
  if (rtt < 0 || rtt > MAX_RTT_MS) return null;
  return Math.round(serverMs - (t0 + rtt / 2));
}

/** Record a measured offset (small ones are treated as zero). */
export function setClockOffset(ms: number | null): void {
  if (ms == null || !Number.isFinite(ms)) return;
  measuredMs = ms;
  offsetMs = Math.abs(ms) < MIN_OFFSET_MS ? 0 : ms;
}

/** Server minus device as last measured (ms), or null when never measured. */
export function getMeasuredOffset(): number | null {
  return measuredMs;
}

export function getClockOffset(): number {
  return offsetMs;
}

/** Device time corrected to the server clock. */
export function serverNow(deviceNow: number = Date.now()): number {
  return deviceNow + offsetMs;
}

/** Seconds left in the current 30-second window (1..30), on the server clock. */
export function secondsLeftInWindow(deviceNow: number = Date.now()): number {
  const s = 30 - (Math.floor(serverNow(deviceNow) / 1000) % 30);
  return s === 0 ? 30 : s;
}

/** Whole minutes (rounded, at least 1) between a code's window and now. */
export function skewMinutes(codeBucket: number, now: number): number {
  const ms = codeBucket * BUCKET_MS - now;
  return Math.max(1, Math.round(Math.abs(ms) / 60_000));
}

/** Door copy for a correctly signed code from the wrong time window. A code
 *  from the future can only be a phone clock set ahead; one from the past is
 *  either a clock set behind or a screenshot. */
export function describeSkew(codeBucket: number, now: number): string {
  const ahead = codeBucket * BUCKET_MS > now;
  const n = skewMinutes(codeBucket, now);
  const mins = `${n} min`;
  return ahead
    ? `The attendee's phone clock is about ${mins} fast. Ask them to reopen the pass (it corrects itself once online) or fix the phone's time.`
    : `This code is about ${mins} old — a screenshot, or a phone clock that is ${mins} slow. Ask them to reopen the live pass and rescan.`;
}

// The measured offset is kept on the device (localStorage) so a door phone
// that reloads the page while offline still signs / verifies / timestamps on
// the server clock (sim SIM-DOOR-3c): without it, a phone whose clock is a few
// minutes off refuses every rotating code offline and uploads its scans with
// the wrong time. A kept offset is trusted for a day.
export const CLOCK_OFFSET_KEY = 'exos:clock-offset';
export const CLOCK_OFFSET_TTL_MS = 24 * 60 * 60 * 1000;

type OffsetStore = Pick<Storage, 'getItem' | 'setItem'>;

/** Keep a measured offset (best-effort). */
export function saveClockOffset(storage: OffsetStore | null, ms: number, deviceNow: number = Date.now()): void {
  if (!storage || !Number.isFinite(ms)) return;
  try {
    storage.setItem(CLOCK_OFFSET_KEY, JSON.stringify({ ms: Math.round(ms), at: deviceNow }));
  } catch {
    /* storage blocked */
  }
}

/** The kept offset when nothing was measured on this page load yet and the
 *  kept one is under a day old (by the device clock). Returns what it set. */
export function restoreClockOffset(storage: OffsetStore | null, deviceNow: number = Date.now()): number | null {
  if (measuredMs != null || !storage) return null;
  let v: unknown;
  try {
    v = JSON.parse(storage.getItem(CLOCK_OFFSET_KEY) ?? 'null');
  } catch {
    return null;
  }
  const o = v as { ms?: unknown; at?: unknown } | null;
  if (!o || typeof o.ms !== 'number' || !Number.isFinite(o.ms) || typeof o.at !== 'number') return null;
  // Saved "in the future" means the device clock moved back since: don't trust it.
  if (o.at > deviceNow + 60_000 || deviceNow - o.at > CLOCK_OFFSET_TTL_MS) return null;
  setClockOffset(o.ms);
  return o.ms;
}

/** Test hook. */
export function resetClockOffset(): void {
  offsetMs = 0;
  measuredMs = null;
}
