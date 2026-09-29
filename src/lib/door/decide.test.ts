import { describe, it, expect } from 'vitest';
import {
  DUPLICATE_READ_MS,
  SAME_TICKET_HOLD_MS,
  decideScan,
  parseDoorCode,
  type DoorCachedTicket,
  type ScanDecisionInput,
} from './decide';

const EVENT = 'eeeeeeee-0000-4000-8000-000000000001';
const OTHER = 'eeeeeeee-0000-4000-8000-000000000002';
const T1 = '11111111-2222-3333-4444-555555555555';
const CODE = `T-${T1}:owner-1:12345:sig`;
const NOW = Date.UTC(2026, 8, 29, 22, 0, 0);
const HOUR = 60 * 60 * 1000;

const fresh: DoorCachedTicket = { used: false, voided: false, pendingTransferId: null };
const ok = { ok: true };
const doorsOpen = { opensAt: NOW - HOUR, testUntil: null };

function input(over: Partial<ScanDecisionInput> = {}): ScanDecisionInput {
  const source = over.source ?? 'camera';
  return {
    code: parseDoorCode(CODE, source),
    source,
    eventId: EVENT,
    entry: fresh,
    queued: false,
    verify: ok,
    network: 'online',
    gate: doorsOpen,
    now: NOW,
    canOverride: false,
    recent: null,
    ...over,
  };
}

describe('parseDoorCode', () => {
  it('reads the ticket id from signed, wallet and bare codes', () => {
    expect(parseDoorCode(CODE, 'camera')).toEqual({ raw: CODE, ticketId: T1, bare: false });
    expect(parseDoorCode(`W-${T1}:o:a1:mac`, 'manual').bare).toBe(false);
    expect(parseDoorCode(` ${T1} `, 'manual')).toEqual({ raw: T1, ticketId: T1, bare: true });
  });
  it('never treats a camera read as a typed override', () => {
    expect(parseDoorCode(T1, 'camera').bare).toBe(false);
  });
  it('drops ids that cannot be ticket ids', () => {
    expect(parseDoorCode('x'.repeat(200), 'manual').ticketId).toBeNull();
    expect(parseDoorCode('', 'manual').ticketId).toBeNull();
  });
});

describe('decideScan: offline and flaky network', () => {
  it('offline + fresh ticket → admit and queue', () => {
    expect(decideScan(input({ network: 'offline' }))).toEqual({ action: 'admit', ticketId: T1, test: false, queue: true });
  });

  it('offline + used → reject used', () => {
    expect(decideScan(input({ network: 'offline', entry: { ...fresh, used: true } }))).toMatchObject({ action: 'reject', reason: 'used' });
  });

  it('flaky network (request failed / timed out) + used → reject used, never admit', () => {
    const d = decideScan(input({ network: 'unreachable', entry: { ...fresh, used: true } }));
    expect(d).toMatchObject({ action: 'reject', reason: 'used' });
  });

  it('flaky network applies every local rule: voided, mid-transfer, bad signature', () => {
    expect(decideScan(input({ network: 'unreachable', entry: { ...fresh, voided: true } }))).toMatchObject({ reason: 'voided' });
    expect(decideScan(input({ network: 'unreachable', entry: { ...fresh, pendingTransferId: 'tr-1' } }))).toMatchObject({ reason: 'in-transfer' });
    expect(decideScan(input({ network: 'unreachable', verify: { ok: false, reason: 'signature-mismatch' } }))).toMatchObject({ reason: 'invalid-barcode' });
  });

  it('a ticket queued on this device counts as used, online too', () => {
    expect(decideScan(input({ network: 'offline', queued: true }))).toMatchObject({ action: 'reject', reason: 'used' });
    expect(decideScan(input({ network: 'online', queued: true }))).toMatchObject({ action: 'reject', reason: 'used' });
  });

  it('unknown code offline → reject (cannot be checked), not admitted', () => {
    expect(decideScan(input({ network: 'offline', entry: undefined, verify: null }))).toEqual({
      action: 'reject', ticketId: T1, reason: 'unknown-offline',
    });
    expect(decideScan(input({ network: 'unreachable', entry: null, verify: null }))).toMatchObject({ reason: 'unknown-offline' });
  });

  it('cancelled event offline → reject', () => {
    expect(decideScan(input({ network: 'offline', gate: { ...doorsOpen, cancelled: true } }))).toMatchObject({ reason: 'event-cancelled' });
  });
});

describe('decideScan: online, the cache is only a hint', () => {
  it('fresh ticket → ask the server', () => {
    expect(decideScan(input())).toEqual({ action: 'ask-server', ticketId: T1 });
  });

  it('cache says transferred (signature no longer matches) → ask the server', () => {
    expect(decideScan(input({ verify: { ok: false, reason: 'signature-mismatch' } }))).toEqual({ action: 'ask-server', ticketId: T1 });
  });

  it('cache says mid-transfer (transfer since cancelled or claimed) → ask the server', () => {
    expect(decideScan(input({ entry: { ...fresh, pendingTransferId: 'tr-1' } }))).toEqual({ action: 'ask-server', ticketId: T1 });
  });

  it('cache says used or voided → ask the server (it knows when and where)', () => {
    expect(decideScan(input({ entry: { ...fresh, used: true } })).action).toBe('ask-server');
    expect(decideScan(input({ entry: { ...fresh, voided: true } })).action).toBe('ask-server');
  });

  it('not on the saved list → ask the server', () => {
    expect(decideScan(input({ entry: undefined, verify: null })).action).toBe('ask-server');
  });

  it('an expired or malformed code is refused locally (the server would too)', () => {
    expect(decideScan(input({ verify: { ok: false, reason: 'bucket-expired' } }))).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
  });

  it('doors and test window are left to the server online', () => {
    expect(decideScan(input({ gate: { opensAt: NOW + HOUR, testUntil: null } })).action).toBe('ask-server');
  });
});

describe('decideScan: doors and test window (offline)', () => {
  it('doors not open → reject with the opening time', () => {
    const d = decideScan(input({ network: 'offline', gate: { opensAt: NOW + HOUR, testUntil: null } }));
    expect(d).toEqual({ action: 'reject', ticketId: T1, reason: 'doors-not-open', opensAt: NOW + HOUR });
  });

  it('pre-doors inside the test window → test OK, never queued', () => {
    const d = decideScan(input({ network: 'unreachable', gate: { opensAt: NOW + HOUR, testUntil: NOW + 2 * HOUR } }));
    expect(d).toEqual({ action: 'admit', ticketId: T1, test: true, queue: false });
  });

  it('an expired test window no longer lifts the gate', () => {
    const d = decideScan(input({ network: 'offline', gate: { opensAt: NOW + HOUR, testUntil: NOW - 1 } }));
    expect(d).toMatchObject({ action: 'reject', reason: 'doors-not-open' });
  });

  it('after doors, a scan is real even with a test window set', () => {
    const d = decideScan(input({ network: 'offline', gate: { opensAt: NOW - 1, testUntil: NOW + HOUR } }));
    expect(d).toEqual({ action: 'admit', ticketId: T1, test: false, queue: true });
  });

  it('no doors time at all → admit', () => {
    expect(decideScan(input({ network: 'offline', gate: { opensAt: null, testUntil: null } })).action).toBe('admit');
  });
});

describe('decideScan: wrong event, overrides, garbage', () => {
  it('a ticket known to belong to another event → wrong-event, online or not', () => {
    const entry = { ...fresh, eventId: OTHER };
    expect(decideScan(input({ entry }))).toMatchObject({ action: 'reject', reason: 'wrong-event' });
    expect(decideScan(input({ entry, network: 'offline' }))).toMatchObject({ action: 'reject', reason: 'wrong-event' });
  });

  it('typed id: a manager is asked for a reason, a scanner is refused', () => {
    const code = parseDoorCode(T1, 'manual');
    expect(decideScan(input({ source: 'manual', code, verify: null, canOverride: true }))).toEqual({ action: 'needs-reason', ticketId: T1 });
    expect(decideScan(input({ source: 'manual', code, verify: null, canOverride: false }))).toMatchObject({ reason: 'needs-manager' });
  });

  it('typed id with a reason: server online, local rules offline', () => {
    const code = parseDoorCode(T1, 'manual');
    const base = { source: 'manual' as const, code, verify: null, canOverride: true, reason: 'phone died, ID checked' };
    expect(decideScan(input(base)).action).toBe('ask-server');
    expect(decideScan(input({ ...base, network: 'offline' }))).toMatchObject({ action: 'admit', queue: true });
    expect(decideScan(input({ ...base, network: 'offline', entry: { ...fresh, used: true } }))).toMatchObject({ reason: 'used' });
  });

  it('empty or unreadable input → not-found', () => {
    expect(decideScan(input({ code: parseDoorCode('', 'manual') }))).toMatchObject({ reason: 'not-found' });
    expect(decideScan(input({ code: parseDoorCode('y'.repeat(300), 'camera') }))).toMatchObject({ reason: 'not-found' });
  });
});

describe('decideScan: duplicate reads', () => {
  const recent = { raw: CODE, ticketId: T1, at: NOW - 500, source: 'camera' as const, admitted: false };

  it('the same code within the window is ignored', () => {
    expect(decideScan(input({ recent }))).toEqual({ action: 'ignore' });
  });

  it('the same code after the window is decided again', () => {
    expect(decideScan(input({ recent: { ...recent, at: NOW - DUPLICATE_READ_MS - 1 } })).action).toBe('ask-server');
  });

  it('a camera re-read of the ticket just admitted is held (new rotating code, same ticket)', () => {
    const r = { ...recent, raw: `T-${T1}:owner-1:12344:old`, admitted: true, at: NOW - 3_000 };
    expect(decideScan(input({ recent: r }))).toEqual({ action: 'ignore' });
    expect(decideScan(input({ recent: { ...r, at: NOW - SAME_TICKET_HOLD_MS - 1 } })).action).toBe('ask-server');
    // Not held after a refusal, or for a typed entry.
    expect(decideScan(input({ recent: { ...r, admitted: false } })).action).toBe('ask-server');
  });

  it('an override with a reason is never swallowed as a duplicate', () => {
    const code = parseDoorCode(T1, 'manual');
    const d = decideScan(input({
      source: 'manual', code, verify: null, canOverride: true, reason: 'ID checked',
      recent: { raw: T1, ticketId: T1, at: NOW - 100, source: 'manual', admitted: false },
    }));
    expect(d.action).toBe('ask-server');
  });
});

describe('decideScan: will-call for parked tickets', () => {
  const parked: DoorCachedTicket = { used: false, voided: false, pendingTransferId: 'tr-1', parked: true };
  const typed = parseDoorCode(T1, 'manual');

  it('a parked ticket shows the will-call verdict, online or offline, scanned or typed', () => {
    expect(decideScan(input({ entry: parked }))).toEqual({ action: 'will-call', ticketId: T1, canAdmit: false });
    expect(decideScan(input({ entry: parked, network: 'offline' }))).toEqual({ action: 'will-call', ticketId: T1, canAdmit: false });
    expect(decideScan(input({ entry: parked, source: 'manual', code: typed, canOverride: true }))).toEqual({
      action: 'will-call', ticketId: T1, canAdmit: true,
    });
  });

  it('offline, a parked ticket is never admitted as a plain scan (it was in-transfer before)', () => {
    const d = decideScan(input({ entry: { ...parked, parked: false }, network: 'offline' }));
    expect(d).toEqual({ action: 'reject', ticketId: T1, reason: 'in-transfer' });
  });

  it('used / voided / queued parked tickets follow the normal rules', () => {
    expect(decideScan(input({ entry: { ...parked, used: true, pendingTransferId: null }, network: 'offline' }))).toMatchObject({ reason: 'used' });
    expect(decideScan(input({ entry: { ...parked, voided: true }, network: 'offline' }))).toMatchObject({ reason: 'voided' });
    expect(decideScan(input({ entry: parked, queued: true, network: 'offline' }))).toMatchObject({ reason: 'used' });
    expect(decideScan(input({ entry: { ...parked, used: true }, network: 'online' }))).toEqual({ action: 'ask-server', ticketId: T1 });
  });

  it('admit online goes to the server as will-call (owner / manager with a reason)', () => {
    const d = decideScan(input({ entry: parked, code: typed, source: 'manual', canOverride: true, willCall: true, reason: 'ID checked' }));
    expect(d).toEqual({ action: 'ask-server', ticketId: T1, willCall: true });
  });

  it('a scanner cannot admit at will-call', () => {
    const d = decideScan(input({ entry: parked, code: typed, source: 'manual', willCall: true, reason: 'ID checked' }));
    expect(d).toEqual({ action: 'reject', ticketId: T1, reason: 'needs-manager' });
  });

  it('no reason yet: stays on the will-call verdict', () => {
    const d = decideScan(input({ entry: parked, code: typed, source: 'manual', canOverride: true, willCall: true, reason: ' x ' }));
    expect(d).toEqual({ action: 'will-call', ticketId: T1, canAdmit: true });
  });

  it('offline admit is queued as will-call', () => {
    const d = decideScan(input({
      entry: parked, code: typed, source: 'manual', canOverride: true, willCall: true, reason: 'ID checked', network: 'unreachable',
    }));
    expect(d).toEqual({ action: 'admit', ticketId: T1, test: false, queue: true, willCall: true });
  });

  it('offline admit respects doors, the test window, cancellation and the list', () => {
    const base = { code: typed, source: 'manual' as const, canOverride: true, willCall: true, reason: 'ID checked', network: 'offline' as const };
    expect(decideScan(input({ ...base, entry: parked, gate: { opensAt: NOW + HOUR, testUntil: null } }))).toMatchObject({ reason: 'doors-not-open' });
    expect(decideScan(input({ ...base, entry: parked, gate: { opensAt: NOW + HOUR, testUntil: NOW + HOUR } }))).toEqual({
      action: 'admit', ticketId: T1, test: true, queue: false, willCall: true,
    });
    expect(decideScan(input({ ...base, entry: parked, gate: { ...doorsOpen, cancelled: true } }))).toMatchObject({ reason: 'event-cancelled' });
    expect(decideScan(input({ ...base, entry: null }))).toMatchObject({ reason: 'unknown-offline' });
    expect(decideScan(input({ ...base, entry: { ...parked, used: true } }))).toMatchObject({ reason: 'used' });
    expect(decideScan(input({ ...base, entry: parked, queued: true }))).toMatchObject({ reason: 'used' });
    // Claimed since the download: the list no longer shows it parked.
    expect(decideScan(input({ ...base, entry: fresh }))).toMatchObject({ reason: 'not-parked' });
  });

  it('a parked ticket for another event is not will-call here', () => {
    const d = decideScan(input({ entry: { ...parked, eventId: OTHER } }));
    expect(d).toEqual({ action: 'reject', ticketId: T1, reason: 'wrong-event' });
  });
});
