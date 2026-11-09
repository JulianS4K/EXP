import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('./supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));

import { ADDON_UNDO_TEXT, ADDON_UNDO_WINDOW_MINUTES, addonUndoAccess, queuedAddonUndo, undoAddonCheckIn } from './addonUndo';
import { hasQueuedScan, parseQueue, type QueuedScan } from './offlineCheckins';
import { checkInOffline } from './tickets';

const migration = readFileSync(resolve(__dirname, '../../supabase/migrations/20261108110000_exos_dice_leftovers.sql'), 'utf8');
const PASS = '11111111-2222-4333-8444-555555555555';
const EVENT = '66666666-7777-4888-8999-000000000000';

describe('undo an add-on scan (mig 20261108110000)', () => {
  beforeEach(() => rpc.mockReset());

  it('the window is the SQL one', () => {
    expect(migration).toContain(`v_window  CONSTANT interval := interval '${ADDON_UNDO_WINDOW_MINUTES} minutes'`);
  });
  it('the scanner within the window; a manager always; anyone else not', () => {
    const now = Date.parse('2026-11-08T22:00:00Z');
    expect(addonUndoAccess({ manager: true, scannedByMe: false, scannedAt: now - 3_600_000, now })).toBe('allowed');
    expect(addonUndoAccess({ manager: false, scannedByMe: true, scannedAt: now - 9 * 60_000, now })).toBe('allowed');
    expect(addonUndoAccess({ manager: false, scannedByMe: true, scannedAt: now - 10 * 60_000, now })).toBe('allowed');
    expect(addonUndoAccess({ manager: false, scannedByMe: true, scannedAt: now - 11 * 60_000, now })).toBe('window-passed');
    expect(addonUndoAccess({ manager: false, scannedByMe: false, scannedAt: now, now })).toBe('needs-manager');
  });
  it('every refusal the SQL answers has a message', () => {
    const fn = migration.slice(migration.indexOf('FUNCTION public.exos_undo_addon_check_in'), migration.indexOf('REVOKE ALL ON FUNCTION public.exos_undo_addon_check_in'));
    const reasons = [...fn.matchAll(/'reason', '([a-z-]+)'/g)].map((m) => m[1]).filter((r) => r !== 'undone');
    expect(reasons.length).toBeGreaterThan(5);
    for (const r of reasons) expect(ADDON_UNDO_TEXT[r], r).toBeTruthy();
  });
  it('online: the RPC with no ref', async () => {
    rpc.mockResolvedValue({ data: { ok: true, reason: 'undone', status: 'active', removed: 1 }, error: null });
    const r = await undoAddonCheckIn(PASS, EVENT, 'wrong guest', { device: 'Door 7F3A' });
    expect(r.ok).toBe(true);
    expect(rpc).toHaveBeenCalledWith('exos_undo_addon_check_in', {
      p_pass_id: PASS, p_event_id: EVENT, p_reason: 'wrong guest', p_client_ref: null, p_undone_at: null, p_device: 'Door 7F3A',
    });
  });
  it('offline: queued with a ref and the time, kept across a reload, replayed by the merge', async () => {
    const at = Date.parse('2026-11-08T21:55:00Z');
    const q = queuedAddonUndo(PASS, 'scanned the wrong wristband', at, () => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
    expect(q).toMatchObject({ kind: 'addon-undo', ticketId: PASS, scannedAt: at, payload: null, reason: 'scanned the wrong wristband' });
    const back = parseQueue(JSON.stringify([q]), Date.now());
    expect(back).toEqual([q]);
    // A queued undo isn't a scan: the pass may be scanned again.
    expect(hasQueuedScan(back, PASS)).toBe(false);
    const scan: QueuedScan = { ref: 'bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee', ticketId: PASS, payload: 'A-x', scannedAt: at + 1, source: 'camera' };
    expect(hasQueuedScan([...back, scan], PASS)).toBe(true);
    rpc.mockResolvedValue({ data: { ok: true, reason: 'undone', duplicate: true }, error: null });
    const r = await checkInOffline(back[0], EVENT, 'Door 7F3A');
    expect(r.ok).toBe(true);
    expect(rpc).toHaveBeenCalledWith('exos_undo_addon_check_in', {
      p_pass_id: PASS, p_event_id: EVENT, p_reason: 'scanned the wrong wristband',
      p_client_ref: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', p_undone_at: new Date(at).toISOString(), p_device: 'Door 7F3A',
    });
  });
  it('a network error keeps it queued (the merge retries)', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'fetch failed' } });
    await expect(checkInOffline(queuedAddonUndo(PASS, 'why', Date.now()), EVENT)).rejects.toBeTruthy();
  });
});
