// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('./supabase', () => ({ supabase: { rpc: h.rpc } }));

import {
  blocksBuying, challengeMode, clearToken, joinRoom, nextPollMs, parseStatus, parseSummary, pollRoom, queueBody, queueHeader,
  queueView, readToken, saveToken, settingsProblem, waitWords,
} from './waitingRoom';

const T1 = 'a'.repeat(64);
const T2 = 'b'.repeat(64);

beforeEach(() => {
  window.localStorage.clear();
  clearToken('e1');
  clearToken('e2');
  h.rpc.mockReset();
});
afterEach(() => vi.restoreAllMocks());

describe('parseStatus', () => {
  it('reads the server JSON and drops anything unexpected', () => {
    const s = parseStatus({ state: 'waiting', position: 42, ahead: 41, eta_minutes: 3, poll_after_ms: 15000,
      on_sale_at: '2026-11-20T17:00:00Z', token: T1, admit_per_minute: 200 });
    expect(s).toMatchObject({ state: 'waiting', position: 42, ahead: 41, etaMinutes: 3, pollAfterMs: 15000, token: T1 });
    expect(s.onSaleAt?.toISOString()).toBe('2026-11-20T17:00:00.000Z');
    expect(parseStatus({ state: 'weird' }).state).toBe('off');
    expect(parseStatus(null).state).toBe('off');
    expect(parseStatus({ state: 'lobby', token: 'short' }).token).toBeUndefined();
  });
});

describe('the browser token', () => {
  it('one per browser and event, kept in localStorage; the checkout body and header carry it', () => {
    expect(readToken('e1')).toBeNull();
    expect(queueBody('e1')).toEqual({});
    expect(queueHeader('e1')).toBe('');
    saveToken('e1', T1);
    saveToken('e2', T2);
    saveToken('e1', 'not-a-token');
    expect(readToken('e1')).toBe(T1);
    expect(window.localStorage.getItem('exos.wroom.e1')).toBe(T1);
    expect(queueBody('e1')).toEqual({ queue_token: T1 });
    expect(queueHeader('e2')).toBe(T2);
    clearToken('e1');
    expect(readToken('e1')).toBeNull();
  });

  it('falls back to memory when storage is blocked (in-app browsers)', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked'); });
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked'); });
    saveToken('e1', T1);
    expect(readToken('e1')).toBe(T1);
  });
});

describe('polling', () => {
  it('follows the server pace with ±25 % jitter, between 2 s and 5 min', () => {
    const s = parseStatus({ state: 'waiting', poll_after_ms: 20000 });
    expect(nextPollMs(s, () => 0)).toBe(15000);
    expect(nextPollMs(s, () => 0.5)).toBe(20000);
    expect(nextPollMs(s, () => 1)).toBe(25000);
    expect(nextPollMs(parseStatus({ state: 'waiting', poll_after_ms: 100 }), () => 0.5)).toBe(2000);
    expect(nextPollMs(parseStatus({ state: 'before', poll_after_ms: 9e6 }), () => 0.5)).toBe(300000);
    expect(nextPollMs(parseStatus({ state: 'busy', retry_after_ms: 5000 }), () => 0.5)).toBe(5000);
    // A crowd that loaded together spreads out.
    const spread = new Set(Array.from({ length: 50 }, (_, i) => nextPollMs(s, () => i / 50)));
    expect(spread.size).toBeGreaterThan(40);
  });
});

describe('queue state', () => {
  it('holds the buy box back while in line, never when off, before or admitted', () => {
    for (const st of ['lobby', 'waiting', 'expired', 'busy', 'unknown', 'full', 'challenge'] as const) expect(blocksBuying({ state: st })).toBe(true);
    expect(challengeMode({ state: 'challenge' }, 'k')).toBe('widget');
    expect(challengeMode({ state: 'challenge' }, '')).toBe('unavailable');
    expect(challengeMode({ state: 'waiting' }, 'k')).toBeNull();
    expect(challengeMode(null, 'k')).toBeNull();
    for (const st of ['off', 'before', 'admitted'] as const) expect(blocksBuying({ state: st })).toBe(false);
    expect(blocksBuying(null)).toBe(false);
  });

  it('says where you stand in plain words', () => {
    const fmt = (d: Date) => d.toISOString().slice(11, 16);
    expect(queueView(parseStatus({ state: 'waiting', position: 1234, eta_minutes: 7 }), fmt))
      .toMatchObject({ heading: "You're number 1,234 in line", rejoin: false });
    expect(queueView(parseStatus({ state: 'waiting', position: 3, eta_minutes: 1 }), fmt).detail).toContain('less than a minute');
    expect(queueView(parseStatus({ state: 'lobby', on_sale_at: '2026-11-20T17:00:00Z' }), fmt).detail)
      .toContain('Tickets go on sale at 17:00. Everyone here before then gets a random place');
    expect(queueView(parseStatus({ state: 'admitted', admitted_until: '2026-11-20T17:10:00Z' }), fmt).detail).toBe('Pick your tickets and check out by 17:10.');
    expect(queueView(parseStatus({ state: 'expired' }), fmt).rejoin).toBe(true);
    expect(queueView(parseStatus({ state: 'expired', reason: 'idle' }), fmt)).toMatchObject({ heading: 'Your place was released', rejoin: true });
    // The longest poll the page waits (30 s server pace + 25 % jitter) stays well inside the 3-minute idle window.
    for (const st of ['waiting', 'lobby'] as const) expect(nextPollMs(parseStatus({ state: st, poll_after_ms: 30000 }), () => 1)).toBeLessThanOrEqual(37500);
    expect(queueView(parseStatus({ state: 'full', reason: 'room' }), fmt).heading).toBe('The waiting room is full');
    expect(queueView(parseStatus({ state: 'full', reason: 'network' }), fmt).detail).toContain('your network');
    // Signed in already (too new an account for a seat): no sign-in offer, just the retry.
    const signedIn = queueView(parseStatus({ state: 'full', reason: 'room', signed_in: true }), fmt);
    expect(signedIn.heading).toBe('The line is full right now');
    expect(signedIn.detail).toContain("We'll keep trying");
    expect(signedIn.detail).not.toMatch(/sign in/i);
    expect(queueView(parseStatus({ state: 'full', reason: 'room' }), fmt).detail).toMatch(/Sign in to get a place/);
    expect(nextPollMs(parseStatus({ state: 'full', poll_after_ms: 60000 }), () => 0.5)).toBe(60000);
    expect(waitWords(90)).toBe('about 1.5 hours');
    expect(waitWords(12)).toBe('about 12 minutes');
  });
});

describe('RPC wrappers', () => {
  it('join keeps a new token; off clears it; poll without a token joins', async () => {
    h.rpc.mockResolvedValueOnce({ data: { state: 'lobby', token: T1, on_sale_at: '2026-11-20T17:00:00Z' }, error: null });
    const s = await joinRoom('e1');
    expect(s.state).toBe('lobby');
    expect(h.rpc).toHaveBeenLastCalledWith('exos_wroom_join', { p_event_id: 'e1', p_token: null });
    expect(readToken('e1')).toBe(T1);
    h.rpc.mockResolvedValueOnce({ data: { state: 'waiting', position: 5 }, error: null });
    await pollRoom('e1');
    expect(h.rpc).toHaveBeenLastCalledWith('exos_wroom_status', { p_event_id: 'e1', p_token: T1 });
    h.rpc.mockResolvedValueOnce({ data: { state: 'unknown' }, error: null });
    await pollRoom('e1');
    expect(readToken('e1')).toBeNull();
    h.rpc.mockResolvedValueOnce({ data: { state: 'off' }, error: null });
    await pollRoom('e1');
    expect(h.rpc).toHaveBeenLastCalledWith('exos_wroom_join', { p_event_id: 'e1', p_token: null });
  });
});

describe('organizer settings', () => {
  it('summary parse and the same bounds as SQL', () => {
    const s = parseSummary({ enabled: true, phase: 'live', admit_per_minute: 300, counts: { waiting: 10, admitted: 2, checked_out: 5, expired: 1, total: 18 }, can_manage: true });
    expect(s).toMatchObject({ enabled: true, phase: 'live', admitPerMinute: 300, canManage: true,
      counts: { waiting: 10, admitted: 2, checkedOut: 5, expired: 1, total: 18 } });
    expect(parseSummary({ phase: 'nope' }).phase).toBe('off');
    const ok = { windowMinutes: 15, admitPerMinute: 200, admissionMinutes: 10, idleCloseMinutes: 10 };
    expect(settingsProblem(ok)).toBeNull();
    expect(settingsProblem({ ...ok, admitPerMinute: 0 })).toMatch(/per minute/);
    expect(settingsProblem({ ...ok, admissionMinutes: 1 })).toMatch(/check out/);
    expect(settingsProblem({ ...ok, windowMinutes: 241 })).toMatch(/before the on-sale/);
    expect(settingsProblem({ ...ok, idleCloseMinutes: 1.5 })).toMatch(/nobody waits/);
    expect(settingsProblem({ ...ok, maxEntries: 0 })).toBeNull();
    expect(settingsProblem({ ...ok, maxEntries: 50 })).toMatch(/Most people in line/);
    expect(parseSummary({ max_entries: 5000, cap: 5000 })).toMatchObject({ maxEntries: 5000, cap: 5000 });
    expect(parseSummary({ cap: 1000 }).maxEntries).toBeNull();
    expect(parseSummary({ warnings: [{ code: 'live_now', message: 'Pin the on-sale time.' }, { code: 1 }, 'x'] }).warnings)
      .toEqual([{ code: 'live_now', message: 'Pin the on-sale time.' }]);
    expect(parseSummary({}).warnings).toEqual([]);
  });
});
