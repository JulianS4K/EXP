import { describe, expect, it } from 'vitest';
import {
  clearKioskCredential, KIOSK_DONE_MS, KIOSK_FAILED_MS, KIOSK_IDLE_MS, KIOSK_PAY_IDLE_MS, KIOSK_PAY_MAX_MS, KIOSK_STORAGE_KEY,
  kioskExitText, kioskMaxQuantity, kioskRedirect, kioskReducer, kioskSecondsLeft, kioskStart, kioskTimer, parseKioskCredential,
  readKioskCredential, saveKioskCredential, wipeBuyerStorage, type KioskState,
} from './kiosk';

const TOKEN = 'exk_' + 'ab'.repeat(32);
const ID = '11111111-1111-4111-8111-111111111111';
const CRED = { token: TOKEN, device_id: ID, event_id: ID, session_id: ID };

/** A Storage stand-in (vitest runs in node). */
function memStorage(init: Record<string, string> = {}) {
  const m = new Map(Object.entries(init));
  return {
    get length() { return m.size; },
    key: (i: number) => [...m.keys()][i] ?? null,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => { m.set(k, String(v)); },
    removeItem: (k: string) => { m.delete(k); },
    keys: () => [...m.keys()],
  };
}

describe('kiosk state machine', () => {
  const s0 = kioskStart('key-1', 0);

  it('picks a type and a quantity within the limit', () => {
    let s = kioskReducer(s0, { type: 'pick', tierId: 't1', at: 1 });
    expect(s).toMatchObject({ step: 'pick', tierId: 't1', quantity: 1, lastInputAt: 1 });
    s = kioskReducer(s, { type: 'quantity', quantity: 9, max: 4, at: 2 });
    expect(s.quantity).toBe(4);
    s = kioskReducer(s, { type: 'quantity', quantity: 0, max: 4, at: 3 });
    expect(s.quantity).toBe(1);
    // Another type starts its quantity again.
    s = kioskReducer(kioskReducer(s, { type: 'quantity', quantity: 3, max: 4, at: 4 }), { type: 'pick', tierId: 't2', at: 5 });
    expect(s).toMatchObject({ tierId: 't2', quantity: 1 });
  });

  it('asks the questions only when the event has them, and can go back', () => {
    const picked = kioskReducer(s0, { type: 'pick', tierId: 't1', at: 1 });
    expect(kioskReducer(s0, { type: 'next', asksQuestions: false, at: 2 }).step).toBe('pick'); // nothing picked
    expect(kioskReducer(picked, { type: 'next', asksQuestions: false, at: 2 })).toMatchObject({ step: 'paying', card: 'starting' });
    const q = kioskReducer(picked, { type: 'next', asksQuestions: true, at: 2 });
    expect(q.step).toBe('questions');
    expect(kioskReducer(q, { type: 'back', at: 3 }).step).toBe('pick');
    expect(kioskReducer(q, { type: 'next', asksQuestions: true, at: 3 })).toMatchObject({ step: 'paying', card: 'starting' });
  });

  it('pays on the reader: waiting, then done or failed', () => {
    const paying = kioskReducer(kioskReducer(s0, { type: 'pick', tierId: 't1', at: 1 }), { type: 'next', asksQuestions: false, at: 2 });
    const waiting = kioskReducer(paying, { type: 'charging', orderId: 'o1', at: 3 });
    expect(waiting).toMatchObject({ step: 'paying', orderId: 'o1', card: 'waiting' });
    expect(kioskReducer(waiting, { type: 'card', state: 'waiting', at: 4 }).step).toBe('paying');
    expect(kioskReducer(waiting, { type: 'card', state: 'succeeded', at: 5 })).toMatchObject({ step: 'done', card: 'succeeded', stepAt: 5 });
    expect(kioskReducer(waiting, { type: 'card', state: 'declined', declineCode: 'insufficient_funds', at: 5 }))
      .toMatchObject({ step: 'failed', card: 'declined', declineCode: 'insufficient_funds' });
    // A late card answer after a reset changes nothing.
    const reset = kioskReducer(waiting, { type: 'reset', orderKey: 'key-2', at: 6 });
    expect(kioskReducer(reset, { type: 'card', state: 'succeeded', at: 7 })).toEqual(reset);
    // No picking while paying.
    expect(kioskReducer(waiting, { type: 'pick', tierId: 't2', at: 8 })).toEqual(waiting);
  });

  it('a reset clears every buyer field and takes a new order key', () => {
    let s = kioskReducer(s0, { type: 'pick', tierId: 't1', at: 1 });
    s = kioskReducer(s, { type: 'quantity', quantity: 3, max: 4, at: 2 });
    s = kioskReducer(kioskReducer(s, { type: 'next', asksQuestions: false, at: 3 }), { type: 'charging', orderId: 'o1', at: 4 });
    s = kioskReducer(s, { type: 'card', state: 'succeeded', at: 5 });
    const r = kioskReducer(s, { type: 'reset', orderKey: 'key-2', at: 6 });
    expect(r).toEqual(kioskStart('key-2', 6));
    expect(r.orderKey).not.toBe(s.orderKey);
  });

  it('caps the quantity at the max per order and what is left', () => {
    expect(kioskMaxQuantity(4, null)).toBe(4);
    expect(kioskMaxQuantity(4, 2)).toBe(2);
    expect(kioskMaxQuantity(4, 0)).toBe(0);
    expect(kioskMaxQuantity(50, null)).toBe(10);
    expect(kioskMaxQuantity(0, null)).toBe(1);
  });
});

describe('kiosk auto-reset', () => {
  const picked: KioskState = kioskReducer(kioskStart('k', 0), { type: 'pick', tierId: 't1', at: 1000 });

  it('an untouched start screen never resets; a started one does after idle', () => {
    expect(kioskTimer(kioskStart('k', 0), 10 * KIOSK_IDLE_MS)).toBe('none');
    expect(kioskTimer(picked, 1000 + KIOSK_IDLE_MS - 1)).toBe('none');
    expect(kioskTimer(picked, 1000 + KIOSK_IDLE_MS)).toBe('reset');
    // A touch pushes it back.
    const touched = kioskReducer(picked, { type: 'touch', at: 50_000 });
    expect(kioskTimer(touched, 1000 + KIOSK_IDLE_MS)).toBe('none');
    const q = kioskReducer(picked, { type: 'next', asksQuestions: true, at: 2000 });
    expect(kioskTimer(q, 2000 + KIOSK_IDLE_MS)).toBe('reset');
  });

  it('an abandoned card sale is cancelled on the reader', () => {
    const paying = kioskReducer(picked, { type: 'next', asksQuestions: false, at: 2000 });
    expect(kioskTimer(paying, 2000 + KIOSK_PAY_IDLE_MS)).toBe('reset'); // never reached the reader
    const waiting = kioskReducer(paying, { type: 'charging', orderId: 'o1', at: 3000 });
    expect(kioskTimer(waiting, 2000 + KIOSK_PAY_IDLE_MS - 1)).toBe('none');
    expect(kioskTimer(waiting, 2000 + KIOSK_PAY_IDLE_MS)).toBe('cancel-and-reset');
    // Touching the screen keeps it, but never past the hold.
    const busy = kioskReducer(waiting, { type: 'touch', at: 2000 + KIOSK_PAY_MAX_MS - 1000 });
    expect(kioskTimer(busy, 2000 + KIOSK_PAY_MAX_MS)).toBe('cancel-and-reset');
    expect(KIOSK_PAY_MAX_MS).toBeLessThan(5 * 60_000);
  });

  it('after a sale: back to the start a short while after the last touch', () => {
    const done = kioskReducer(kioskReducer(kioskReducer(picked, { type: 'next', asksQuestions: false, at: 2000 }),
      { type: 'charging', orderId: 'o1', at: 3000 }), { type: 'card', state: 'succeeded', at: 10_000 });
    expect(kioskTimer(done, 10_000 + KIOSK_DONE_MS - 1)).toBe('none');
    expect(kioskSecondsLeft(done, 10_000 + KIOSK_DONE_MS - 5000)).toBe(5);
    expect(kioskTimer(done, 10_000 + KIOSK_DONE_MS)).toBe('reset');
    const typing = kioskReducer(done, { type: 'touch', at: 30_000 });
    expect(kioskTimer(typing, 10_000 + KIOSK_DONE_MS)).toBe('none');
    expect(kioskTimer(typing, 30_000 + KIOSK_DONE_MS)).toBe('reset');
  });

  it('a declined card shows its message, then starts over', () => {
    const failed = kioskReducer(kioskReducer(kioskReducer(picked, { type: 'next', asksQuestions: false, at: 2000 }),
      { type: 'charging', orderId: 'o1', at: 3000 }), { type: 'card', state: 'declined', at: 4000 });
    expect(kioskTimer(failed, 4000 + KIOSK_FAILED_MS - 1)).toBe('none');
    expect(kioskTimer(failed, 4000 + KIOSK_FAILED_MS)).toBe('reset');
    expect(kioskSecondsLeft(picked, 0)).toBeNull();
  });
});

describe('kiosk storage', () => {
  it('keeps the credential and the cookie choice, wipes everything else', () => {
    const st = memStorage({
      [KIOSK_STORAGE_KEY]: JSON.stringify(CRED), 'exos.consent.v2': '{}',
      'sb-mock-auth-token': '{"access_token":"x"}', 'exos.checkout.draft': '{"email":"fan@example.com"}', other: '1',
    });
    expect(wipeBuyerStorage(st)).toBe(3);
    expect(st.keys().sort()).toEqual([KIOSK_STORAGE_KEY, 'exos.consent.v2'].sort());
    expect(wipeBuyerStorage(st)).toBe(0);
    expect(wipeBuyerStorage(null)).toBe(0);
  });

  it('never throws when storage is blocked', () => {
    const blocked = {
      get length(): number { throw new Error('SecurityError'); },
      key: () => { throw new Error('SecurityError'); },
      getItem: () => { throw new Error('SecurityError'); },
      setItem: () => { throw new Error('SecurityError'); },
      removeItem: () => { throw new Error('SecurityError'); },
    };
    expect(wipeBuyerStorage(blocked)).toBe(0);
    expect(readKioskCredential(blocked)).toBeNull();
    expect(() => clearKioskCredential(blocked)).not.toThrow();
  });

  it('reads back only a well-formed credential', () => {
    const st = memStorage();
    saveKioskCredential(st, CRED);
    expect(readKioskCredential(st)).toEqual(CRED);
    clearKioskCredential(st);
    expect(readKioskCredential(st)).toBeNull();
    expect(parseKioskCredential('not json')).toBeNull();
    expect(parseKioskCredential(JSON.stringify({ ...CRED, token: 'exk_short' }))).toBeNull();
    expect(parseKioskCredential(JSON.stringify({ ...CRED, event_id: 'x' }))).toBeNull();
  });

  it('kiosk mode keeps the browser on /kiosk', () => {
    expect(kioskRedirect('/dashboard', CRED)).toBe('/kiosk');
    expect(kioskRedirect('/event/x', CRED)).toBe('/kiosk');
    expect(kioskRedirect('/kiosk', CRED)).toBeNull();
    expect(kioskRedirect('/dashboard', null)).toBeNull();
  });

  it('the PIN pad says what happened', () => {
    expect(kioskExitText({ ok: true })).toBeNull();
    expect(kioskExitText({ ok: false, error: 'wrong-pin', attempts_left: 1 })).toMatch(/1 try left/);
    expect(kioskExitText({ ok: false, error: 'locked', retry_after_seconds: 300 })).toMatch(/5 min/);
    expect(kioskExitText({ ok: false, error: 'rate' })).toMatch(/Wait a minute/);
  });
});
