import { describe, it, expect } from 'vitest';
import {
  CLOCK_WARN_MS,
  classifyReplayError,
  conflictText,
  formatAge,
  formatOffset,
  signOutWarning,
  syncHealth,
  type SyncHealthInput,
} from './health';
import { DoorTimeoutError } from './net';
import { pendingScanCount } from '../offlineCheckins';

const NOW = Date.UTC(2026, 8, 29, 22, 0, 0);
const MIN = 60_000;

const base: SyncHealthInput = {
  now: NOW,
  online: true,
  rosterSavedAt: NOW - 2 * MIN,
  rosterCount: 480,
  ticketsSold: 500,
  pending: [],
  lastSyncAt: NOW - MIN,
  clockOffsetMs: 0,
  conflicts: 0,
  authBlocked: false,
};

describe('classifyReplayError', () => {
  it('network failures keep retrying', () => {
    expect(classifyReplayError(new TypeError('Failed to fetch'))).toBe('network');
    expect(classifyReplayError(new DoorTimeoutError(10_000))).toBe('network');
    expect(classifyReplayError({ code: '', message: 'aborted' })).toBe('network');
  });
  it('an expired sign-in refreshes the session', () => {
    expect(classifyReplayError({ code: 'PGRST301', message: 'JWT expired' })).toBe('session');
  });
  it('not authorized stops the uploads', () => {
    expect(classifyReplayError({ code: '42501', message: 'exos_check_in_offline: not authorized' })).toBe('auth');
  });
  it('other server errors retry later', () => {
    expect(classifyReplayError({ code: '22023', message: 'bad input' })).toBe('server');
  });
});

describe('formatting', () => {
  it('ages', () => {
    expect(formatAge(10_000)).toBe('just now');
    expect(formatAge(4 * MIN)).toBe('4 min');
    expect(formatAge(125 * MIN)).toBe('2 h 5 min');
    expect(formatAge(120 * MIN)).toBe('2 h');
    expect(formatAge(72 * 60 * MIN)).toBe('3 d');
  });
  it('clock offsets', () => {
    expect(formatOffset(null)).toBe('not measured');
    expect(formatOffset(40)).toBe('in sync');
    expect(formatOffset(2100)).toBe('+2.1 s');
    expect(formatOffset(-400)).toBe('−0.4 s');
    expect(formatOffset(185_000)).toBe('+185 s');
  });
  it('conflicts', () => {
    expect(conflictText({ reason: 'voided', forced: true })).toBe('refunded / voided · admission recorded');
    expect(conflictText({ reason: 'used', forced: false })).toBe('already checked in');
    expect(conflictText({ reason: 'mystery', forced: false })).toBe('mystery');
  });
});

describe('syncHealth', () => {
  it('all good', () => {
    const h = syncHealth(base);
    expect(h.level).toBe('ok');
    expect(h.lines.map((l) => l.label)).toEqual(['Offline list', 'Waiting to upload', 'Last upload', 'Clock vs server', 'Conflicts']);
    expect(h.lines[0].value).toBe('480 / 500 tickets · 2 min old');
    expect(h.lines[1].value).toBe('nothing');
    expect(h.lines[2].value).toBe('1 min ago');
  });
  it('no list on the device is bad; an old or unencrypted one is a warning', () => {
    expect(syncHealth({ ...base, rosterSavedAt: null }).level).toBe('bad');
    expect(syncHealth({ ...base, rosterSavedAt: NOW - 60 * MIN }).lines[0].level).toBe('warn');
    const plain = syncHealth({ ...base, plaintextRoster: true });
    expect(plain.lines[0].value).toContain('not encrypted');
    expect(plain.level).toBe('warn');
  });
  it('pending scans: count and oldest; blocked uploads are bad', () => {
    const h = syncHealth({ ...base, pending: [{ scannedAt: NOW - 3 * MIN }, { scannedAt: NOW - 20 * MIN }] });
    expect(h.lines[1].value).toBe('2 scans · oldest 20 min');
    expect(h.lines[1].level).toBe('warn');
    const b = syncHealth({ ...base, pending: [{ scannedAt: NOW - MIN }], authBlocked: true });
    expect(b.lines[1].value).toContain('not authorized to upload');
    expect(b.level).toBe('bad');
  });
  it('clock and conflicts', () => {
    expect(syncHealth({ ...base, clockOffsetMs: CLOCK_WARN_MS + 1 }).lines[3].level).toBe('warn');
    expect(syncHealth({ ...base, conflicts: 2 }).lines[4].value).toBe('2 refused on upload');
    expect(syncHealth({ ...base, lastSyncAt: null }).lines[2].value).toBe('none this session');
  });
  it('offline is at least a warning', () => {
    expect(syncHealth({ ...base, online: false }).level).toBe('warn');
  });
});

describe('sign-out warning', () => {
  it('counts every queued scan on the device', () => {
    const m = new Map<string, string>([
      ['pending_updates_e1', JSON.stringify([
        { ref: '11111111-1111-4111-8111-111111111111', ticketId: '22222222-2222-4222-8222-222222222222', payload: null, scannedAt: NOW, source: 'manual' },
      ])],
      ['pending_updates_e2', JSON.stringify(['33333333-3333-4333-8333-333333333333', 'not-a-uuid'])],
      ['registry_x', '{}'],
    ]);
    const storage = {
      get length() { return m.size; },
      key: (i: number) => [...m.keys()][i] ?? null,
      getItem: (k: string) => m.get(k) ?? null,
    };
    expect(pendingScanCount(storage, NOW)).toBe(2);
    expect(pendingScanCount(null)).toBe(0);
  });
  it('asks only when something is waiting', () => {
    expect(signOutWarning(0)).toBeNull();
    expect(signOutWarning(1)).toMatch(/^1 door check-in hasn't uploaded yet/);
    expect(signOutWarning(3)).toMatch(/^3 door check-ins haven't/);
  });
});
