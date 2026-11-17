// On-sale waiting room (mig 20261118120000; docs/organizer-guide.md "Waiting
// room for big on-sales"). Pure helpers (the browser's queue token, the
// polite jittered poll, what the queue page says) plus thin RPC wrappers.
// The SQL is the gate for everything: who is admitted, for how long, and the
// check in checkout and the hold functions. The page only shows the line.

import { supabase } from './supabase';

/** What the server answers for this browser (exos_wroom_join / _status). */
export type RoomState = 'off' | 'before' | 'lobby' | 'waiting' | 'admitted' | 'expired' | 'unknown' | 'busy' | 'full' | 'challenge';

export interface RoomStatus {
  state: RoomState;
  token?: string;
  phase?: string;
  onSaleAt?: Date | null;
  opensAt?: Date | null;
  position?: number;
  ahead?: number;
  etaMinutes?: number;
  admittedUntil?: Date | null;
  admitPerMinute?: number;
  pollAfterMs?: number;
  retryAfterMs?: number;
  /** 'full': the room ('room') or this network's share of it ('network');
   *  'expired': away 3+ minutes ('idle') or the turn lapsed unused ('lapsed'). */
  reason?: 'room' | 'network' | 'idle' | 'lapsed' | 'used';
  /** More than 10,000 people ahead (the server stops counting there). */
  positionCapped?: boolean;
  /** 'account': the signed-in buyer's own place (any browser resumes it). */
  kind?: 'anon' | 'account';
  /** The server saw a signed-in account ('full': signing in again won't help). */
  signedIn?: boolean;
}

const STATES: RoomState[] = ['off', 'before', 'lobby', 'waiting', 'admitted', 'expired', 'unknown', 'busy', 'full', 'challenge'];
const TOKEN_RE = /^[0-9a-f]{64}$/;

function date(v: unknown): Date | null {
  if (typeof v !== 'string') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}
function num(v: unknown): number | undefined {
  const n = Number(v);
  return v == null || !Number.isFinite(n) ? undefined : n;
}

/** The RPC's JSON as a RoomStatus; anything unexpected reads as no room. */
export function parseStatus(raw: unknown): RoomStatus {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const state = STATES.includes(r.state as RoomState) ? (r.state as RoomState) : 'off';
  return {
    state,
    token: typeof r.token === 'string' && TOKEN_RE.test(r.token) ? r.token : undefined,
    phase: typeof r.phase === 'string' ? r.phase : undefined,
    onSaleAt: date(r.on_sale_at),
    opensAt: date(r.opens_at),
    position: num(r.position),
    ahead: num(r.ahead),
    etaMinutes: num(r.eta_minutes),
    admittedUntil: date(r.admitted_until),
    admitPerMinute: num(r.admit_per_minute),
    pollAfterMs: num(r.poll_after_ms),
    retryAfterMs: num(r.retry_after_ms),
    reason: ['room', 'network', 'idle', 'lapsed', 'used'].includes(r.reason as string) ? (r.reason as RoomStatus['reason']) : undefined,
    positionCapped: r.position_capped === true,
    kind: r.kind === 'account' || r.kind === 'anon' ? r.kind : undefined,
    signedIn: r.signed_in === true,
  };
}

// --- the browser's token: one per browser and event -------------------------
// localStorage when it works; in-app browsers that block it keep the token in
// memory for the life of the page (a reload then joins again, at the back).
const memory = new Map<string, string>();
const key = (eventId: string) => `exos.wroom.${eventId}`;

export function readToken(eventId: string): string | null {
  try {
    const v = window.localStorage.getItem(key(eventId));
    if (v && TOKEN_RE.test(v)) return v;
  } catch {
    /* storage blocked */
  }
  return memory.get(eventId) ?? null;
}

export function saveToken(eventId: string, token: string): void {
  if (!TOKEN_RE.test(token)) return;
  memory.set(eventId, token);
  try {
    window.localStorage.setItem(key(eventId), token);
  } catch {
    /* storage blocked: memory only */
  }
}

export function clearToken(eventId: string): void {
  memory.delete(eventId);
  try {
    window.localStorage.removeItem(key(eventId));
  } catch {
    /* storage blocked */
  }
}

/** The checkout body's queue token (exos-checkout checks it first). */
export function queueBody(eventId: string): { queue_token?: string } {
  const t = readToken(eventId);
  return t ? { queue_token: t } : {};
}

/** The x-exos-queue header the hold / free-claim RPCs read in SQL. */
export function queueHeader(eventId: string): string {
  return readToken(eventId) ?? '';
}

// --- polling ----------------------------------------------------------------
/**
 * The next poll: the server's suggestion (farther back = slower), spread by
 * ±25 % so a crowd that loaded the page together doesn't poll together, and
 * kept between 2 s and 5 min. rand is Math.random in the page.
 */
export function nextPollMs(s: RoomStatus, rand: () => number = Math.random): number {
  const base = s.state === 'busy' ? (s.retryAfterMs ?? 5000)
    : s.pollAfterMs ?? (s.state === 'waiting' ? 15000 : s.state === 'full' ? 60000 : 30000);
  const jittered = base * (0.75 + 0.5 * Math.min(Math.max(rand(), 0), 1));
  return Math.round(Math.min(Math.max(jittered, 2000), 300000));
}

/** Does this state hold the buy box back (show the queue instead)? */
export function blocksBuying(s: RoomStatus | null): boolean {
  return !!s && (s.state === 'lobby' || s.state === 'waiting' || s.state === 'expired' || s.state === 'busy'
    || s.state === 'unknown' || s.state === 'full' || s.state === 'challenge');
}

/** "about 3 minutes" / "less than a minute". */
export function waitWords(minutes: number | undefined): string {
  if (minutes == null) return '';
  if (minutes <= 1) return 'less than a minute';
  if (minutes < 60) return `about ${minutes} minutes`;
  const h = Math.round(minutes / 6) / 10;
  return `about ${h} hour${h === 1 ? '' : 's'}`;
}

export interface QueueView {
  heading: string;
  detail: string;
  /** Join again (a lapsed turn). */
  rejoin: boolean;
}

/** What the queue says for a state (plain words; no other buyer's data). */
export function queueView(s: RoomStatus, fmt: (d: Date) => string = (d) => d.toLocaleTimeString()): QueueView {
  switch (s.state) {
    case 'lobby':
      return {
        heading: "You're in the waiting room",
        detail: (s.onSaleAt ? `Tickets go on sale at ${fmt(s.onSaleAt)}. ` : '')
          + 'Everyone here before then gets a random place in line at the on-sale, so there is no need to refresh.',
        rejoin: false,
      };
    case 'waiting':
      return {
        heading: s.positionCapped ? "You're number 10,000+ in line"
          : s.position != null ? `You're number ${s.position.toLocaleString()} in line` : "You're in line",
        detail: `Estimated wait: ${waitWords(s.etaMinutes) || 'a few minutes'}. Keep this page open; it updates on its own.`,
        rejoin: false,
      };
    case 'admitted':
      return {
        heading: "It's your turn",
        detail: s.admittedUntil ? `Pick your tickets and check out by ${fmt(s.admittedUntil)}.` : 'Pick your tickets and check out.',
        rejoin: false,
      };
    case 'expired':
      if (s.reason === 'used') {
        return {
          heading: 'You used your turn',
          detail: 'Your order went through. To buy more, join the line again, at the back.',
          rejoin: true,
        };
      }
      return s.reason === 'idle'
        ? {
          heading: 'Your place was released',
          detail: 'This page was closed or asleep for a while and the line has filled up since, so your place went to the people still waiting. You can join the line again, at the back.',
          rejoin: true,
        }
        : {
          heading: 'Your turn has passed',
          detail: 'You can join the line again, at the back.',
          rejoin: true,
        };
    case 'busy':
      return {
        heading: 'Lots of people are arriving',
        detail: 'Holding your spot to join the line. This takes a few seconds.',
        rejoin: false,
      };
    case 'full':
      // Signed in already (an account too new for a seat): nothing to offer
      // but the retry.
      if (s.signedIn) {
        return {
          heading: 'The line is full right now',
          detail: "We'll keep trying: this page asks again every minute. Keep it open.",
          rejoin: false,
        };
      }
      return {
        heading: 'The waiting room is full',
        detail: (s.reason === 'network'
          ? 'Too many people on your network have joined this line.'
          : 'The line is as long as the organizer allows for guests.')
          + ' Sign in to get a place, or wait here: this page tries again every minute.',
        rejoin: false,
      };
    case 'unknown':
      return { heading: 'Joining the line', detail: 'One moment.', rejoin: false };
    case 'challenge':
      return { heading: 'One quick check', detail: "Confirm you're a person to get your place in line.", rejoin: false };
    case 'before':
      return {
        heading: 'Tickets are not on sale yet',
        detail: s.opensAt ? `The waiting room opens at ${fmt(s.opensAt)}.` : '',
        rejoin: false,
      };
    default:
      return { heading: '', detail: '', rejoin: false };
  }
}

// --- Turnstile (a room's CAPTCHA in front of new places) ---------------------
/** The platform's Cloudflare Turnstile site key (public), or '' when not set up. */
export const TURNSTILE_SITE_KEY: string =
  (((import.meta as unknown as { env?: Record<string, string | undefined> }).env?.VITE_TURNSTILE_SITE_KEY) ?? '').trim();
/** The widget's action; exos-wroom-join refuses a token made for another. */
export const TURNSTILE_ACTION = 'wroom';
export const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

/** What the queue shows for a room asking for the check: the widget, a
 *  "can't take new places" note without a site key, or nothing. */
export function challengeMode(s: RoomStatus | null, siteKey: string): 'widget' | 'unavailable' | null {
  if (s?.state !== 'challenge') return null;
  return siteKey ? 'widget' : 'unavailable';
}

/** A new place after the check passed (exos-wroom-join). Keeps the token. */
export async function joinWithChallenge(eventId: string, turnstileToken: string): Promise<RoomStatus> {
  const { data, error } = await supabase.functions.invoke('exos-wroom-join', {
    body: { event_id: eventId, token: readToken(eventId), turnstile_token: turnstileToken },
  });
  if (error) {
    let reason = '';
    try { reason = ((await (error as { context?: Response }).context?.json()) as { reason?: string })?.reason ?? ''; } catch { /* not JSON */ }
    if (reason === 'challenge_failed' || reason === 'challenge_required') return { state: 'challenge' };
    throw new Error(error.message);
  }
  const s = parseStatus(data);
  if (s.token) saveToken(eventId, s.token);
  return s;
}

// --- RPCs -------------------------------------------------------------------
/** Arrive (or come back with this browser's token). Keeps a new token. */
export async function joinRoom(eventId: string): Promise<RoomStatus> {
  const { data, error } = await supabase.rpc('exos_wroom_join', { p_event_id: eventId, p_token: readToken(eventId) });
  if (error) throw new Error(error.message);
  const s = parseStatus(data);
  if (s.token) saveToken(eventId, s.token);
  if (s.state === 'off') clearToken(eventId);
  return s;
}

/** Poll this browser's place. */
export async function pollRoom(eventId: string): Promise<RoomStatus> {
  const token = readToken(eventId);
  if (!token) return joinRoom(eventId);
  const { data, error } = await supabase.rpc('exos_wroom_status', { p_event_id: eventId, p_token: token });
  if (error) throw new Error(error.message);
  const s = parseStatus(data);
  if (s.state === 'unknown') clearToken(eventId);
  return s;
}

/** Give up a lapsed turn and join again at the back. */
export async function rejoinRoom(eventId: string): Promise<RoomStatus> {
  clearToken(eventId);
  return joinRoom(eventId);
}

// --- organizers -------------------------------------------------------------
export interface RoomSummary {
  enabled: boolean;
  phase: 'off' | 'before' | 'lobby' | 'live';
  windowMinutes: number;
  admitPerMinute: number;
  admissionMinutes: number;
  idleCloseMinutes: number;
  /** The organizer's line cap, or null (automatic). */
  maxEntries: number | null;
  /** Cloudflare Turnstile in front of new places. */
  turnstile: boolean;
  /** The organizer's on-sale pin, or null (from the ticket types). */
  opensAtPin: Date | null;
  /** The cap in force. */
  cap: number | null;
  onSaleAt: Date | null;
  opensAt: Date | null;
  closedAt: Date | null;
  closedReason: 'idle' | 'organizer' | null;
  counts: { waiting: number; admitted: number; checkedOut: number; expired: number; accounts: number; total: number };
  waitMinutes: number;
  canManage: boolean;
  /** Things the organizer should know (e.g. 'live_now': the line goes live at once). */
  warnings: { code: string; message: string }[];
}

export function parseSummary(raw: unknown): RoomSummary {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const c = (r.counts && typeof r.counts === 'object' ? r.counts : {}) as Record<string, unknown>;
  const phase = ['before', 'lobby', 'live'].includes(String(r.phase)) ? (r.phase as RoomSummary['phase']) : 'off';
  return {
    enabled: r.enabled === true,
    phase,
    windowMinutes: num(r.window_minutes) ?? 15,
    admitPerMinute: num(r.admit_per_minute) ?? 200,
    admissionMinutes: num(r.admission_minutes) ?? 10,
    idleCloseMinutes: num(r.idle_close_minutes) ?? 10,
    maxEntries: num(r.max_entries) ?? null,
    turnstile: r.turnstile === true,
    opensAtPin: date(r.opens_at_pin),
    cap: num(r.cap) ?? null,
    onSaleAt: date(r.on_sale_at),
    opensAt: date(r.opens_at),
    closedAt: date(r.closed_at),
    closedReason: r.closed_reason === 'idle' || r.closed_reason === 'organizer' ? r.closed_reason : null,
    counts: {
      waiting: num(c.waiting) ?? 0, admitted: num(c.admitted) ?? 0, checkedOut: num(c.checked_out) ?? 0,
      expired: num(c.expired) ?? 0, accounts: num(c.accounts) ?? 0, total: num(c.total) ?? 0,
    },
    waitMinutes: num(r.wait_minutes) ?? 0,
    canManage: r.can_manage === true,
    warnings: (Array.isArray(r.warnings) ? r.warnings : [])
      .filter((w): w is { code: string; message: string } =>
        !!w && typeof w === 'object' && typeof (w as Record<string, unknown>).code === 'string'
        && typeof (w as Record<string, unknown>).message === 'string')
      .map((w) => ({ code: w.code, message: w.message.slice(0, 300) })),
  };
}

export interface RoomSettingsInput {
  windowMinutes: number;
  admitPerMinute: number;
  admissionMinutes: number;
  idleCloseMinutes: number;
  /** Most people in line; 0 = automatic (5 x capacity, at least 1,000). */
  maxEntries?: number;
  /** Turnstile on / off (undefined keeps it). */
  turnstile?: boolean;
  /** On-sale pin: a date sets it, null clears it, undefined keeps it. */
  opensAt?: Date | null;
}

/** The same bounds exos_wroom_configure checks; null when fine. */
export function settingsProblem(s: RoomSettingsInput): string | null {
  const int = (n: number, lo: number, hi: number) => Number.isInteger(n) && n >= lo && n <= hi;
  if (!int(s.windowMinutes, 0, 240)) return 'Opens before the on-sale: 0 to 240 minutes.';
  if (!int(s.admitPerMinute, 1, 20000)) return 'Let in per minute: 1 to 20,000.';
  if (!int(s.admissionMinutes, 2, 60)) return 'Time to check out: 2 to 60 minutes.';
  if (!int(s.idleCloseMinutes, 1, 240)) return 'Close when nobody waits for: 1 to 240 minutes.';
  if (s.maxEntries != null && s.maxEntries !== 0 && !int(s.maxEntries, 100, 1000000)) return 'Most people in line: 100 to 1,000,000, or blank for automatic.';
  return null;
}

export async function getRoomSummary(eventId: string): Promise<RoomSummary> {
  const { data, error } = await supabase.rpc('exos_wroom_summary', { p_event_id: eventId });
  if (error) throw new Error(error.message);
  return parseSummary(data);
}

export async function configureRoom(eventId: string, enabled: boolean, s: RoomSettingsInput): Promise<RoomSummary> {
  const { data, error } = await supabase.rpc('exos_wroom_configure', {
    p_event_id: eventId, p_enabled: enabled, p_window_minutes: s.windowMinutes, p_admit_per_minute: s.admitPerMinute,
    p_admission_minutes: s.admissionMinutes, p_idle_close_minutes: s.idleCloseMinutes, p_max_entries: s.maxEntries ?? 0,
    ...(s.turnstile === undefined ? {} : { p_turnstile: s.turnstile }),
    ...(s.opensAt === undefined ? {} : s.opensAt === null ? { p_clear_opens_at: true } : { p_opens_at: s.opensAt.toISOString() }),
  });
  if (error) throw new Error(error.message.replace(/^exos_wroom_configure: /, ''));
  return parseSummary(data);
}
