// SIM-DOOR (pure half): door staff and scanner phones making mistakes,
// against the scanner's offline logic. The server half (the RPCs, replays,
// conflicts) is tests/exos/sim_door.sql; the ids match where a scenario has
// both halves.
import { afterEach, describe, expect, it } from 'vitest';
import { currentBucket, extractTicketIdFromAny, signBarcode, verifyBarcode } from '../barcode';
import { decideScan, parseDoorCode, type DoorCachedTicket, type ScanDecisionInput } from '../door/decide';
import { classifyReplayError } from '../door/health';
import { isExosCode, matchImported, codeIndex } from '../door/imports';
import type { DoorCheckinList } from '../door/lists';
import { applyArrival, type GuestEntry } from '../guestLists';
import {
  CLOCK_OFFSET_KEY,
  CLOCK_OFFSET_TTL_MS,
  resetClockOffset,
  restoreClockOffset,
  saveClockOffset,
  serverNow,
  setClockOffset,
} from '../serverClock';
import { doorDay, doorKeysFromSecret, type DoorKeys } from '../../../supabase/functions/_shared/doorKeys.ts';
import { appleWalletCode, googleTotpKey, totp, totpStep } from '../../../supabase/functions/_shared/wallet/codes.ts';

const TICKET = '7d000000-0000-4000-8000-0000000c0001';
const OWNER = '7d000000-0000-4000-8000-0000000000a5';
const NEW_OWNER = '7d000000-0000-4000-8000-0000000000a7';
const SECRET = 'sim-door-secret';
const EVENT = '7d000000-0000-4000-8000-0000000000e1';
// 21:00 UTC on 2026-11-04: doors at 20:00.
const NOW = Date.UTC(2026, 10, 4, 21, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY_MS = 24 * HOUR;

const GA = 'tier-ga';
const VIP_DECK: DoorCheckinList = { id: 'vip', name: 'VIP deck', tierIds: ['tier-vip'], allowReentry: true, validFrom: null, validUntil: null, sortOrder: 1 };
const PASS_OUT: DoorCheckinList = { id: 'pass', name: 'Pass-out', tierIds: null, allowReentry: true, validFrom: null, validUntil: null, sortOrder: 2 };
const MAIN: DoorCheckinList = { id: 'main', name: 'Main door', tierIds: null, allowReentry: false, validFrom: null, validUntil: null, sortOrder: 0 };

function input(over: Partial<ScanDecisionInput> & { raw?: string }): ScanDecisionInput {
  const raw = over.raw ?? `T-${TICKET}:${OWNER}:1:x`;
  const source = over.source ?? 'camera';
  return {
    code: parseDoorCode(raw, source),
    source,
    eventId: EVENT,
    entry: { used: false, tierId: GA },
    verify: { ok: true },
    network: 'offline',
    gate: { opensAt: NOW - HOUR, testUntil: null },
    now: NOW,
    canOverride: false,
    ...over,
  };
}

afterEach(() => resetClockOffset());

/** A Storage stand-in. */
function memStore(): Storage {
  const m = new Map<string, string>();
  return {
    get length() { return m.size; },
    key: (i: number) => [...m.keys()][i] ?? null,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
    clear: () => m.clear(),
  };
}

describe('SIM-DOOR-1 the same ticket twice', () => {
  it('a camera double decode is ignored, a re-read of who just got in too', () => {
    const raw = `T-${TICKET}:${OWNER}:1:x`;
    const recent = { raw, ticketId: TICKET, at: NOW - 500, source: 'camera' as const, admitted: true };
    expect(decideScan(input({ raw, recent })).action).toBe('ignore');
    // A fresh code (next window) of the same ticket 5 s later: still the same person.
    expect(decideScan(input({ raw: `T-${TICKET}:${OWNER}:2:y`, recent: { ...recent, at: NOW - 5_000 } })).action).toBe('ignore');
  });
  it('after the hold, the ticket this phone admitted is used, online or not', () => {
    const recent = { raw: 'x', ticketId: TICKET, at: NOW - 20_000, source: 'camera' as const, admitted: true };
    for (const network of ['online', 'offline', 'unreachable'] as const) {
      expect(decideScan(input({ queued: true, network, recent }))).toMatchObject({ action: 'reject', reason: 'used' });
    }
  });
  it('the second phone, online, asks the server (which says used, and where)', () => {
    expect(decideScan(input({ network: 'online' }))).toMatchObject({ action: 'ask-server' });
  });
});

describe('SIM-DOOR-2 two offline phones, one ticket', () => {
  it('both admit and queue: only the server can pick (first upload wins)', () => {
    const a = decideScan(input({}));
    const b = decideScan(input({}));
    expect(a).toMatchObject({ action: 'admit', queue: true });
    expect(b).toMatchObject({ action: 'admit', queue: true });
  });
});

describe('SIM-DOOR-3 clocks off by 5 minutes, 1 hour, 1 day', () => {
  it('the holder phone off: the code is refused as expired, and the door can say it is the clock', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    for (const off of [5 * MIN, HOUR, -5 * MIN, -HOUR]) {
      const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW + off));
      const v = await verifyBarcode(code, keys, { now: NOW });
      expect(v).toMatchObject({ ok: false, reason: 'bucket-expired', signatureValid: true });
    }
    // A day off: the door doesn't even hold that day's key.
    const dayOff = await verifyBarcode(await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW + 2 * DAY_MS)), keys, { now: NOW });
    expect(dayOff).toMatchObject({ ok: false, reason: 'bucket-expired', signatureValid: false });
    // 50 s off is inside the window.
    expect((await verifyBarcode(await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW - 50_000)), keys, { now: NOW })).ok).toBe(true);
  });

  it('the door phone off: a measured offset fixes the check', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    const deviceNow = NOW + 5 * MIN; // the door phone is 5 minutes fast
    expect((await verifyBarcode(code, keys, { now: serverNow(deviceNow) })).ok).toBe(false);
    setClockOffset(-5 * MIN);
    expect((await verifyBarcode(code, keys, { now: serverNow(deviceNow) })).ok).toBe(true);
  });

  it('FIXED: the offset survives a reload while offline (kept for a day)', async () => {
    const store = memStore();
    const deviceNow = NOW + HOUR; // an hour fast
    setClockOffset(-HOUR);
    saveClockOffset(store, -HOUR, deviceNow);
    // The page reloads with no network: nothing measured yet.
    resetClockOffset();
    expect(serverNow(deviceNow)).toBe(deviceNow);
    expect(restoreClockOffset(store, deviceNow + 10 * MIN)).toBe(-HOUR);
    expect(serverNow(deviceNow)).toBe(NOW);
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    expect((await verifyBarcode(code, keys, { now: serverNow(deviceNow) })).ok).toBe(true);
  });

  it('a kept offset is not used when stale, saved "in the future", or after a fresh measurement', () => {
    const store = memStore();
    saveClockOffset(store, 90_000, NOW);
    resetClockOffset();
    expect(restoreClockOffset(store, NOW + CLOCK_OFFSET_TTL_MS + 1)).toBeNull();
    expect(restoreClockOffset(store, NOW - 10 * MIN)).toBeNull(); // the device clock moved back
    setClockOffset(2_000);
    expect(restoreClockOffset(store, NOW)).toBeNull(); // measured this load: keep that
    store.setItem(CLOCK_OFFSET_KEY, 'not json');
    resetClockOffset();
    expect(restoreClockOffset(store, NOW)).toBeNull();
    expect(restoreClockOffset(null, NOW)).toBeNull();
  });

  it('wallet codes: Apple is static (no clock), Google TOTP follows the holder clock', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, 1);
    const apple = await appleWalletCode(TICKET, OWNER, SECRET, 1);
    expect((await verifyBarcode(apple, keys, { now: NOW + DAY_MS })).ok).toBe(true);
    const key = await googleTotpKey(TICKET, OWNER, SECRET, 1);
    const googleAt = async (at: number) => `W-${TICKET}:${OWNER}:g1:${await totp(key, totpStep(at))}`;
    expect((await verifyBarcode(await googleAt(NOW), keys, { now: NOW })).ok).toBe(true);
    expect((await verifyBarcode(await googleAt(NOW + 5 * MIN), keys, { now: NOW }))).toMatchObject({ ok: false, reason: 'signature-mismatch' });
  });

  it('offline, a code the door phone calls expired is refused, never admitted unchecked', () => {
    expect(decideScan(input({ verify: { ok: false, reason: 'bucket-expired' } }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    // Online the door refuses it locally too (the server would say expired).
    expect(decideScan(input({ network: 'online', verify: { ok: false, reason: 'bucket-expired' } })))
      .toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
  });
});

describe('SIM-DOOR-4 the roster was downloaded yesterday', () => {
  it('yesterday\'s download still holds today\'s key', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW - DAY_MS + HOUR);
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    expect((await verifyBarcode(code, keys, { now: NOW })).ok).toBe(true);
  });

  it('transferred since: the new holder fails the stale keys; online the server decides, offline it is refused', async () => {
    const stale = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW - 12 * HOUR);
    const fresh = await signBarcode(TICKET, NEW_OWNER, 'rotated-secret', currentBucket(NOW));
    const v = await verifyBarcode(fresh, stale, { now: NOW });
    expect(v).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    expect(decideScan(input({ raw: fresh, verify: v, network: 'online' }))).toMatchObject({ action: 'ask-server' });
    // KNOWN (inherent to an offline list): the rightful new holder is refused
    // until the phone is back online, while the old holder's code is admitted.
    expect(decideScan(input({ raw: fresh, verify: v }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    const old = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    expect(decideScan(input({ raw: old, verify: await verifyBarcode(old, stale, { now: NOW }) })))
      .toMatchObject({ action: 'admit', queue: true });
  });

  it('refunded since: the stale entry admits offline (the upload is a forced conflict)', () => {
    expect(decideScan(input({ entry: { used: false, voided: false, tierId: GA } }))).toMatchObject({ action: 'admit', queue: true });
    // Once the list knows, it refuses.
    expect(decideScan(input({ entry: { used: false, voided: true, tierId: GA } }))).toMatchObject({ action: 'reject', reason: 'voided' });
  });
});

describe('SIM-DOOR-5 wrong event, wrong list', () => {
  it('a ticket of another event is refused before anything else', () => {
    const entry: DoorCachedTicket = { used: false, eventId: 'another-event', tierId: GA };
    expect(decideScan(input({ entry, network: 'online' }))).toMatchObject({ action: 'reject', reason: 'wrong-event' });
  });
  it('GA at the VIP deck is wrong-list offline', () => {
    expect(decideScan(input({ list: VIP_DECK }))).toMatchObject({ action: 'reject', reason: 'wrong-list' });
  });
});

describe('SIM-DOOR-6 re-entry on a list that does not allow it', () => {
  it('exit refused; back in is used', () => {
    expect(decideScan(input({ list: MAIN, direction: 'exit', entry: { used: true, tierId: GA } })))
      .toMatchObject({ action: 'reject', reason: 'exit-not-allowed' });
    expect(decideScan(input({ list: MAIN, entry: { used: true, tierId: GA } }))).toMatchObject({ action: 'reject', reason: 'used' });
    expect(decideScan(input({ direction: 'exit' }))).toMatchObject({ action: 'reject', reason: 'exit-not-allowed' });
  });
});

describe('SIM-DOOR-7 check-out without check-in (phone left in Exit mode)', () => {
  it('FIXED: offline, an exit for a ticket never admitted is refused', () => {
    expect(decideScan(input({ list: PASS_OUT, direction: 'exit' }))).toMatchObject({ action: 'reject', reason: 'not-inside' });
  });
  it('an exit after an entry (on the roster, or by this phone) still works', () => {
    expect(decideScan(input({ list: PASS_OUT, direction: 'exit', entry: { used: true, tierId: GA } })))
      .toMatchObject({ action: 'admit', direction: 'exit', queue: true });
    expect(decideScan(input({ list: PASS_OUT, direction: 'exit', entry: { used: false, tierId: GA, lists: { pass: 'entry' } } })))
      .toMatchObject({ action: 'admit', direction: 'exit' });
  });
  it('in the pre-doors test window an exit is still only a test', () => {
    const gate = { opensAt: NOW + HOUR, testUntil: NOW + 30 * MIN };
    expect(decideScan(input({ list: PASS_OUT, direction: 'exit', gate }))).toMatchObject({ action: 'admit', test: true, queue: false });
  });
});

describe('SIM-DOOR-9 imported codes typed badly', () => {
  const index = codeIndex([{ code: 'EB-1234 5678', name: 'Eb One' }, { code: 'gst-AbC9', name: 'Luma Two' }]);
  it('spaces, case and a keyboard wedge tab match', () => {
    expect(matchImported('  eb-12345678 ', index)?.name).toBe('Eb One');
    expect(matchImported('eb-1234\t5678', index)?.name).toBe('Eb One');
    expect(matchImported('GST-abc9', index)?.name).toBe('Luma Two');
    expect(matchImported('https://www.eventbrite.com/checkin?code=EB-12345678', index)?.name).toBe('Eb One');
  });
  it('a typo matches nobody', () => {
    expect(matchImported('EB-12345679', index)).toBeNull();
    expect(matchImported('EB1234567', index)).toBeNull();
  });
  it('a dropped hyphen / space matches (was KNOWN; mig 20261105100000): the punctuation-stripped fallback', () => {
    expect(matchImported('EB12345678', index)?.name).toBe('Eb One');
    expect(matchImported('eb 1234-5678', index)?.name).toBe('Eb One');
    expect(matchImported('GSTABC9', index)?.name).toBe('Luma Two');
  });
  it('the fallback never guesses between two guests', () => {
    const two = codeIndex([{ code: 'AB-12', name: 'One' }, { code: 'A-B12', name: 'Two' }, { code: 'AB12', name: 'Exact' }]);
    expect(matchImported('AB12', two)?.name).toBe('Exact');  // an exact hit wins
    const amb = codeIndex([{ code: 'AB-12', name: 'One' }, { code: 'A-B12', name: 'Two' }]);
    expect(matchImported('AB12', amb)).toBeNull();
  });
  it('Exos codes are never looked up among imported codes', () => {
    expect(isExosCode(' T-abc:def:1:x')).toBe(true);
    expect(isExosCode('EB-12345678')).toBe(false);
  });
});

describe('SIM-DOOR-12/13 imported and guest-list arrivals offline', () => {
  const guest = (over: Partial<GuestEntry> = {}): GuestEntry => ({
    id: 'g1', listId: 'l1', guestName: 'Eb Refunded', plusOnes: 0, arrived: 0, arrivedAt: null, note: null,
    code: 'EB-REF-1', source: 'Eventbrite', ...over,
  });
  it('a list from before the void admits offline (the upload is refused and logged, sim_door.sql)', () => {
    expect(applyArrival(guest(), 1).ok).toBe(true);
    expect(applyArrival(guest({ voided: true }), 1)).toMatchObject({ ok: false, reason: 'voided' });
  });
  it('one phone can\'t admit a party twice; two phones each can (the server keeps one)', () => {
    const after = applyArrival(guest(), 1).entry!;
    expect(applyArrival(after, 1)).toMatchObject({ ok: false, reason: 'used' });
    expect(applyArrival(guest(), 1).ok).toBe(true); // the other phone's copy
  });
  it('a typed bare ticket id offline that is not on the saved list is unknown, not admitted', () => {
    expect(decideScan(input({ raw: TICKET, source: 'manual', entry: null, canOverride: true, reason: 'lost phone' })))
      .toMatchObject({ action: 'reject', reason: 'unknown-offline' });
  });
});

describe('SIM-DOOR-14 doors not open; test window', () => {
  it('before doors offline: refused with the time; inside the test window: a test, never queued', () => {
    expect(decideScan(input({ gate: { opensAt: NOW + HOUR, testUntil: null } })))
      .toMatchObject({ action: 'reject', reason: 'doors-not-open', opensAt: NOW + HOUR });
    expect(decideScan(input({ gate: { opensAt: NOW + HOUR, testUntil: NOW + 10 * MIN } })))
      .toMatchObject({ action: 'admit', test: true, queue: false });
  });
  it('a cancelled event refuses offline', () => {
    expect(decideScan(input({ gate: { opensAt: NOW - HOUR, testUntil: null, cancelled: true } })))
      .toMatchObject({ action: 'reject', reason: 'event-cancelled' });
  });
});

describe('SIM-DOOR-15 removed / re-scoped / signed-out staff', () => {
  it('the server\'s answers keep the scans queued (auth), not dropped', () => {
    expect(classifyReplayError({ code: '42501', message: 'exos_check_in_offline: not assigned to this event' })).toBe('auth');
    expect(classifyReplayError({ code: '42501', message: 'exos_check_in_offline: not authorized' })).toBe('auth');
    expect(classifyReplayError({ code: 'PGRST301', message: 'JWT expired' })).toBe('session');
  });
});

describe('SIM-DOOR-17 a wallet pass from before the latest epoch', () => {
  it('the door holds the live epoch only: the old pass is refused, the new one passes', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, 2);
    const old = await appleWalletCode(TICKET, OWNER, SECRET, 1);
    const live = await appleWalletCode(TICKET, OWNER, SECRET, 2);
    const v = await verifyBarcode(old, keys, { now: NOW });
    expect(v).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    expect(decideScan(input({ raw: old, verify: v }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    expect((await verifyBarcode(live, keys, { now: NOW })).ok).toBe(true);
  });
  it('a list downloaded before the pass existed has no wallet key: no-key, refused offline', async () => {
    const keys: DoorKeys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const v = await verifyBarcode(await appleWalletCode(TICKET, OWNER, SECRET, 1), keys, { now: NOW });
    expect(v).toMatchObject({ ok: false, reason: 'no-key' });
    expect(decideScan(input({ verify: v }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
    expect(decideScan(input({ verify: v, network: 'online' }))).toMatchObject({ action: 'ask-server' });
  });
});

describe('SIM-DOOR-18 yesterday\'s day key around midnight', () => {
  const utcMidnight = Date.UTC(2026, 10, 5, 0, 0, 0);
  it('a code signed 15 s before UTC midnight verifies 15 s after, with a list from either day', async () => {
    const before = currentBucket(utcMidnight - 15_000);
    expect(doorDay(before)).toBe(doorDay(currentBucket(utcMidnight)) - 1);
    const code = await signBarcode(TICKET, OWNER, SECRET, before);
    for (const downloadedAt of [utcMidnight - 6 * HOUR, utcMidnight + 2 * HOUR]) {
      const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, downloadedAt);
      expect((await verifyBarcode(code, keys, { now: utcMidnight + 15_000 })).ok).toBe(true);
    }
  });
  it('the event\'s local midnight (New York) is not a key boundary', async () => {
    const nyMidnight = Date.UTC(2026, 10, 5, 5, 0, 0); // 00:00 EST
    expect(doorDay(currentBucket(nyMidnight - 15_000))).toBe(doorDay(currentBucket(nyMidnight + 15_000)));
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, nyMidnight - 3 * HOUR);
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(nyMidnight - 15_000));
    expect((await verifyBarcode(code, keys, { now: nyMidnight + 15_000 })).ok).toBe(true);
  });
  it('a list downloaded two days earlier has no key for today: refused, not admitted', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, utcMidnight - 2 * DAY_MS);
    const v = await verifyBarcode(await signBarcode(TICKET, OWNER, SECRET, currentBucket(utcMidnight + HOUR)), keys, { now: utcMidnight + HOUR });
    expect(v).toMatchObject({ ok: false, reason: 'no-key' });
    expect(decideScan(input({ verify: v }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
  });
});

describe('SIM-DOOR-21 typed and odd codes', () => {
  it('a camera read of a bare id is not an override', () => {
    expect(parseDoorCode(TICKET, 'camera').bare).toBe(false);
    expect(parseDoorCode(TICKET, 'manual').bare).toBe(true);
    expect(decideScan(input({ raw: TICKET, source: 'manual' }))).toMatchObject({ action: 'reject', reason: 'needs-manager' });
  });
  it('FIXED: a reader that lower-cases the prefix ("t-…") is read like the server reads it', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW));
    const lower = 't' + code.slice(1);
    expect(extractTicketIdFromAny(lower)).toBe(TICKET);
    expect(parseDoorCode(lower, 'camera')).toMatchObject({ ticketId: TICKET, bare: false });
    expect((await verifyBarcode(lower, keys, { now: NOW })).ok).toBe(true);
    const apple = await appleWalletCode(TICKET, OWNER, SECRET, 1);
    expect((await verifyBarcode('w' + apple.slice(1), await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, 1), { now: NOW })).ok).toBe(true);
  });
  it('an edited owner segment fails the signature', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const code = (await signBarcode(TICKET, OWNER, SECRET, currentBucket(NOW))).replace(OWNER, NEW_OWNER);
    expect(await verifyBarcode(code, keys, { now: NOW })).toMatchObject({ ok: false, reason: 'signature-mismatch' });
  });
});
