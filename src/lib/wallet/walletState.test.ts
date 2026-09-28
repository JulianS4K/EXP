import { describe, expect, it } from 'vitest';
import {
  applyEffect,
  doorAcceptsEpoch,
  type PassSnap,
  type TicketSnap,
  walletEffect,
} from '../../../supabase/functions/_shared/wallet/state.ts';
import { httpDate, notModified, routeWallet } from '../../../supabase/functions/_shared/wallet/routes.ts';
import { apnsPusher, dryRunPusher } from '../../../supabase/functions/_shared/wallet/apns.ts';

const base: TicketSnap = { status: 'active', ownerId: 'u1', barcodeSecret: 's1', pendingTransferId: null, attendeeName: null };
const live: PassSnap = { status: 'active', codeEpoch: 1, pushPending: false, voidReason: null };

describe('void / transfer invalidates the pass (mirrors the SQL trigger)', () => {
  it('refund / organizer void → void, epoch + 1, push', () => {
    const e = walletEffect(base, { ...base, status: 'voided' });
    expect(e).toEqual({ action: 'void', reason: 'ticket-voided' });
    const p = applyEffect(live, e);
    expect(p).toEqual({ status: 'voided', codeEpoch: 2, pushPending: true, voidReason: 'ticket-voided' });
    expect(doorAcceptsEpoch(p, 1)).toBe(false);
    expect(doorAcceptsEpoch(p, 2)).toBe(false);
  });

  it('release → void (released)', () => {
    expect(walletEffect(base, { ...base, status: 'voided', releasedAt: '2026-10-01T00:00:00Z' }))
      .toEqual({ action: 'void', reason: 'released' });
  });

  it('transfer claimed (owner + secret change) → void as transferred', () => {
    const e = walletEffect(base, { ...base, ownerId: 'u2', barcodeSecret: 's2' });
    expect(e).toEqual({ action: 'void', reason: 'transferred' });
    expect(applyEffect(live, e).status).toBe('voided');
  });

  it('check-in, transfer started, secret rotation, name → refresh only', () => {
    for (const next of [
      { ...base, status: 'used' },
      { ...base, pendingTransferId: 't1' },
      { ...base, barcodeSecret: 's9' },
      { ...base, attendeeName: 'Ada' },
    ]) {
      const e = walletEffect(base, next);
      expect(e).toEqual({ action: 'refresh' });
      expect(applyEffect(live, e)).toEqual({ ...live, pushPending: true });
    }
  });

  it('unrelated change → nothing; a voided pass never comes back', () => {
    expect(walletEffect(base, { ...base })).toEqual({ action: 'none' });
    const dead: PassSnap = { status: 'voided', codeEpoch: 3, pushPending: false, voidReason: 'transferred' };
    expect(applyEffect(dead, { action: 'refresh' })).toBe(dead);
    expect(applyEffect(dead, { action: 'void', reason: 'ticket-voided' })).toBe(dead);
  });

  it('the door wants the live epoch', () => {
    expect(doorAcceptsEpoch(live, 1)).toBe(true);
    expect(doorAcceptsEpoch({ ...live, codeEpoch: 2 }, 1)).toBe(false);
    expect(doorAcceptsEpoch(null, 1)).toBe(false);
  });
});

describe('PassKit web service routes', () => {
  const P = '/exos-wallet/apple/v1';
  it('routes Apple endpoints', () => {
    expect(routeWallet('POST', `${P}/devices/dev1/registrations/pass.com.exos.t/exwabc`))
      .toEqual({ kind: 'register', device: 'dev1', passType: 'pass.com.exos.t', serial: 'exwabc' });
    expect(routeWallet('DELETE', `${P}/devices/dev1/registrations/pass.com.exos.t/exwabc`).kind).toBe('unregister');
    expect(routeWallet('GET', `${P}/devices/dev1/registrations/pass.com.exos.t`))
      .toEqual({ kind: 'serials', device: 'dev1', passType: 'pass.com.exos.t' });
    expect(routeWallet('GET', `${P}/passes/pass.com.exos.t/exwabc`)).toEqual({ kind: 'latest', passType: 'pass.com.exos.t', serial: 'exwabc' });
    expect(routeWallet('POST', `${P}/log`).kind).toBe('log');
    expect(routeWallet('POST', '/functions/v1/exos-wallet/pass').kind).toBe('issue');
    expect(routeWallet('POST', '/exos-wallet/push').kind).toBe('push');
  });
  it('refuses odd paths and methods', () => {
    expect(routeWallet('GET', '/exos-wallet/pass').kind).toBe('not-found');
    expect(routeWallet('PUT', `${P}/passes/pt/s`).kind).toBe('not-found');
    expect(routeWallet('GET', `${P}/passes/pt/..%2F..`).kind).toBe('not-found');
    expect(routeWallet('GET', `${P}/passes/pt/a%2Fb`).kind).toBe('not-found');
  });
  it('If-Modified-Since → 304 only when unchanged', () => {
    const at = '2026-09-28T12:00:00.900Z';
    expect(notModified(at, httpDate(at))).toBe(true);
    expect(notModified('2026-09-28T12:00:01.000Z', httpDate(at))).toBe(false);
    expect(notModified(at, null)).toBe(false);
    expect(notModified(at, 'garbage')).toBe(false);
  });
});

describe('APNs pusher', () => {
  it('dry run sends nothing', async () => {
    expect(dryRunPusher.live).toBe(false);
    expect(await dryRunPusher.push('pass.t', ['aa'.repeat(32)])).toEqual({ sent: 0, failed: 0, unregistered: [] });
  });
  it('live: one empty push per token, topic = pass type, 410 → unregistered', async () => {
    const calls: string[] = [];
    const good = 'ab'.repeat(32);
    const gone = 'cd'.repeat(32);
    const p = apnsPusher(async (url, init) => {
      calls.push(`${url} ${(init?.headers as Record<string, string>)['apns-topic']} ${init?.body}`);
      return new Response(null, { status: url.endsWith(gone) ? 410 : 200 });
    }, 'https://apns.test');
    const r = await p.push('pass.com.exos.t', [good, gone, 'not hex!']);
    expect(r).toEqual({ sent: 1, failed: 1, unregistered: [gone] });
    expect(calls).toEqual([
      `https://apns.test/3/device/${good} pass.com.exos.t {}`,
      `https://apns.test/3/device/${gone} pass.com.exos.t {}`,
    ]);
  });
});
