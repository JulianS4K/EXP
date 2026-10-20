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
//
// The last measurement is saved on the device (with when it was taken), so a
// door that opens on bad Wi-Fi starts from it instead of the raw device clock;
// a live measurement replaces it as soon as the server answers.

const BUCKET_MS = 30_000;
// A round trip slower than this says little about the clock; ignore it.
const MAX_RTT_MS = 10_000;
// Below this we leave the device clock alone (network noise).
const MIN_OFFSET_MS = 1_500;

let offsetMs = 0;
/** The last measured offset, before small ones are rounded to zero (the
 *  door's sync-health panel shows it). null until a measurement succeeds. */
let measuredMs: number | null = null;
/** When that offset was measured (device ms), and whether it was measured in
 *  this page load (false = restored from the device's saved copy). */
let measuredAt: number | null = null;
let measuredLive = false;

/** Where the last measurement is saved (localStorage). */
export const CLOCK_SAVE_KEY = 'exos:clock-offset';
/** A saved measurement older than this is not used. */
export const SAVED_OFFSET_MAX_AGE_MS = 24 * 60 * 60 * 1000;

/** Offset (server minus device) from one request: sent at t0, answered with
 *  the server's time, received at t1 (device ms). null when the round trip
 *  was too slow to trust. */
export function estimateOffset(t0: number, serverMs: number, t1: number): number | null {
  if (!Number.isFinite(t0) || !Number.isFinite(t1) || !Number.isFinite(serverMs)) return null;
  const rtt = t1 - t0;
  if (rtt < 0 || rtt > MAX_RTT_MS) return null;
  return Math.round(serverMs - (t0 + rtt / 2));
}

/** Record a measured offset (small ones are treated as zero). `live` =
 *  measured now against the server (false: restored from the saved copy). */
export function setClockOffset(ms: number | null, at: number = Date.now(), live = true): void {
  if (ms == null || !Number.isFinite(ms)) return;
  measuredMs = ms;
  measuredAt = at;
  measuredLive = live;
  offsetMs = Math.abs(ms) < MIN_OFFSET_MS ? 0 : ms;
}

/** Server minus device as last measured (ms), or null when never measured. */
export function getMeasuredOffset(): number | null {
  return measuredMs;
}

/** The offset in use, when it was measured and whether it is from this page
 *  load; null when there is none. */
export function getOffsetInfo(): { ms: number; at: number; live: boolean } | null {
  return measuredMs == null || measuredAt == null ? null : { ms: measuredMs, at: measuredAt, live: measuredLive };
}

type KV = Pick<Storage, 'getItem' | 'setItem'>;

/** Save a live measurement on the device. Best-effort. */
export function saveClockOffset(storage: KV | null, ms: number, at: number): void {
  try {
    storage?.setItem(CLOCK_SAVE_KEY, JSON.stringify({ ms, at }));
  } catch {
    /* storage full / blocked */
  }
}

/** The saved measurement, or null when there is none or it is too old. */
export function loadSavedOffset(storage: KV | null, now: number = Date.now()): { ms: number; at: number } | null {
  try {
    const p = JSON.parse(storage?.getItem(CLOCK_SAVE_KEY) ?? 'null') as { ms?: unknown; at?: unknown } | null;
    if (!p || typeof p.ms !== 'number' || typeof p.at !== 'number' || !Number.isFinite(p.ms) || !Number.isFinite(p.at)) return null;
    // A copy from "the future" means the device clock was moved back since.
    if (p.at > now + 60_000 || now - p.at > SAVED_OFFSET_MAX_AGE_MS) return null;
    return { ms: p.ms, at: p.at };
  } catch {
    return null;
  }
}

/** Use the saved measurement until a live one comes in. True when one was
 *  restored (never replaces a live measurement). */
export function restoreSavedOffset(storage: KV | null, now: number = Date.now()): boolean {
  if (measuredLive) return false;
  const saved = loadSavedOffset(storage, now);
  if (!saved) return false;
  setClockOffset(saved.ms, saved.at, false);
  return true;
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

/** Test hook. */
export function resetClockOffset(): void {
  offsetMs = 0;
  measuredMs = null;
  measuredAt = null;
  measuredLive = false;
}
