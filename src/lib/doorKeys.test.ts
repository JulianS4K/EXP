import { describe, expect, it } from 'vitest';
import { currentBucket, signBarcode, verifyBarcode } from './barcode';
import { upgradeLegacySecrets } from './door/roster';
import {
  doorCodeMac, doorDay, doorDayKey, doorKeysFromSecret, parseDoorKeys,
} from '../../supabase/functions/_shared/doorKeys.ts';
import { appleWalletCode, googleTotpKey, totp, totpStep } from '../../supabase/functions/_shared/wallet/codes.ts';

const TICKET = '11111111-2222-3333-4444-555555555555';
const OWNER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const SECRET = 'per-ticket-secret-minted-at-fulfillment';
const NOW = Date.UTC(2026, 9, 19, 19, 0, 0);
const BUCKET = currentBucket(NOW);
const DAY = doorDay(BUCKET);

// Pinned against the SQL functions (tests/exos/test_door_day_keys.sql).
const VECTOR_DAY = 20745;
const VECTOR_BUCKET = 59745600;
const VECTOR_KEY = 'Q8rqdCNy6LtJFyJy7sLh1LD4hNYqu4qNzn7k6s0ajXs';
const VECTOR_MAC = 'fE-2zQxd3t7ygpBwIdDVCq0zlc6V5JL9rK1Aspdmolk';
const VECTOR_WA = '3f2e7820181bdb370b180ef5115c271091e6acb3e827f2f50f918ab9a3bca55b';
const VECTOR_WG = '8a59a0c916387a0565275cefa7d2c5a56466510b';

describe('door day keys', () => {
  it('a day is 2880 buckets, UTC', () => {
    expect(doorDay(VECTOR_BUCKET)).toBe(VECTOR_DAY);
    expect(DAY).toBe(VECTOR_DAY);
    expect(doorDay(VECTOR_DAY * 2880 - 1)).toBe(VECTOR_DAY - 1);
  });

  it('matches the SQL vectors', async () => {
    const key = await doorDayKey(TICKET, SECRET, VECTOR_DAY);
    expect(key).toBe(VECTOR_KEY);
    expect(await doorDayKey(TICKET, SECRET, VECTOR_DAY + 1)).not.toBe(key);
    expect(await doorCodeMac(TICKET, OWNER, VECTOR_BUCKET, key)).toBe(VECTOR_MAC);
    expect(await signBarcode(TICKET, OWNER, SECRET, VECTOR_BUCKET)).toBe(`T-${TICKET}:${OWNER}:${VECTOR_BUCKET}:${VECTOR_MAC}`);
    const w = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, 3);
    expect([w.wa, w.wg]).toEqual([VECTOR_WA, VECTOR_WG]);
  });

  it('the door verifies with three days of keys, never the secret', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    expect(Object.keys(keys.d).sort()).toEqual([String(DAY - 1), String(DAY), String(DAY + 1)]);
    expect(JSON.stringify(keys)).not.toContain(SECRET);
    const code = await signBarcode(TICKET, OWNER, SECRET, BUCKET);
    expect(await verifyBarcode(code, keys, { now: NOW })).toMatchObject({ ok: true, ticketId: TICKET });
  });

  it('a code whose day the door has no key for is not checked (no-key), not passed', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const later = NOW + 3 * 86_400_000;
    const code = await signBarcode(TICKET, OWNER, SECRET, currentBucket(later));
    expect(await verifyBarcode(code, keys, { now: later })).toMatchObject({ ok: false, reason: 'no-key' });
  });

  it('a forged or other-ticket code fails', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    const other = await signBarcode(TICKET, OWNER, 'another-secret', BUCKET);
    expect(await verifyBarcode(other, keys, { now: NOW })).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    // A code signed with the raw secret (an app that hasn't reloaded) can't be
    // checked offline any more: the server still takes it.
    const legacyMac = await doorCodeMac(TICKET, OWNER, BUCKET, SECRET);
    expect(await verifyBarcode(`T-${TICKET}:${OWNER}:${BUCKET}:${legacyMac}`, keys, { now: NOW }))
      .toMatchObject({ ok: false, reason: 'signature-mismatch' });
  });

  it('wallet codes check against the pass keys', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, 3);
    const apple = await appleWalletCode(TICKET, OWNER, SECRET, 3);
    expect(await verifyBarcode(apple, keys, { now: NOW })).toMatchObject({ ok: true });
    expect(await verifyBarcode(await appleWalletCode(TICKET, OWNER, SECRET, 2), keys, { now: NOW }))
      .toMatchObject({ ok: false, reason: 'signature-mismatch' });
    const g = await totp(await googleTotpKey(TICKET, OWNER, SECRET, 3), totpStep(NOW));
    expect(await verifyBarcode(`W-${TICKET}:${OWNER}:g3:${g}`, keys, { now: NOW })).toMatchObject({ ok: true });
    const noPass = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    expect(await verifyBarcode(apple, noPass, { now: NOW })).toMatchObject({ ok: false, reason: 'no-key' });
  });

  it('parseDoorKeys keeps only well-formed fields', () => {
    expect(parseDoorKeys('{"d":{"20745":"k","x":"y"},"wa":"zz","we":2}')).toEqual({ d: { 20745: 'k' }, we: 2 });
    expect(parseDoorKeys(null)).toBeNull();
  });

  it('a roster saved by an older build trades its secrets for keys', async () => {
    const { data, changed } = await upgradeLegacySecrets(
      { [TICKET]: { used: false, name: 'A', tier: 'GA', ownerId: OWNER, barcodeSecret: SECRET } }, NOW);
    expect(changed).toBe(true);
    expect(data[TICKET].barcodeSecret).toBeUndefined();
    expect(data[TICKET].doorKeys).toEqual(await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW));
  });
});
