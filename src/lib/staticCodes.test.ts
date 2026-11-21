// Static door codes (mig 20261121153000): the TypeScript side matches the SQL
// derivation (tests/exos/test_static_codes.sql ST3 pins the same vector), and
// the door's parsing can never read an S- code as a rotating T- / A- code, or
// the reverse.
import { describe, expect, it } from 'vitest';
import {
  base32, canonicalStaticCode, isStaticCode, staticCode, staticCodeHash, staticCodeTicketId, verifyStaticWithKeys,
} from '../../supabase/functions/_shared/staticCodes.ts';
import { doorKeysFromSecret, parseDoorKeys } from '../../supabase/functions/_shared/doorKeys.ts';
import { extractTicketIdFromAny, normalizeCodePrefix, signBarcode, verifyBarcode } from './barcode';
import { parseDoorCode } from './door/decide';

const TICKET = '0b5e1c2a-0000-4000-8000-000000000001';
const OWNER = '0b5e1c2a-0000-4000-8000-0000000000c1';
const SECRET = 'sek-vector';
const VECTOR = 'S-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE2T';
const NOW = Date.UTC(2026, 10, 21, 20, 0, 0);

describe('static codes', () => {
  it('derives the same code as the SQL (_exos_static_code)', async () => {
    expect(await staticCode(TICKET, OWNER, SECRET)).toBe(VECTOR);
    expect(await staticCodeHash(VECTOR)).toBe('f4b68b536b94a59b7929f2022006fc21c2b018e7d8fcb75bfeca00a76d721e31');
    // Upper-case ids hash the same (Postgres prints uuids lower-case).
    expect(await staticCode(TICKET.toUpperCase(), OWNER.toUpperCase(), SECRET)).toBe(VECTOR);
    await expect(staticCode(TICKET, OWNER, '')).rejects.toThrow();
  });

  it('base32 is RFC 4648 (no padding)', () => {
    const b = (s: string) => base32(new TextEncoder().encode(s));
    expect([b(''), b('f'), b('fo'), b('foo'), b('foob'), b('fooba'), b('foobar')])
      .toEqual(['', 'MY', 'MZXQ', 'MZXW6', 'MZXW6YQ', 'MZXW6YTB', 'MZXW6YTBOI']);
  });

  it('a code depends on the holder and the secret (a transfer gives a new one)', async () => {
    expect(await staticCode(TICKET, '0b5e1c2a-0000-4000-8000-0000000000c2', SECRET)).not.toBe(VECTOR);
    expect(await staticCode(TICKET, OWNER, 'sek-rotated')).not.toBe(VECTOR);
    expect(VECTOR.length).toBe(2 + 36 + 1 + 32);
  });

  it('reads case-changed codes canonically and refuses other shapes', () => {
    expect(canonicalStaticCode(` ${VECTOR.toLowerCase()} `)).toBe(VECTOR);
    expect(staticCodeTicketId(VECTOR)).toBe(TICKET);
    for (const bad of [
      VECTOR.slice(0, -1), VECTOR + 'A', VECTOR.replace(/E2T$/, 'E21'), 'T' + VECTOR.slice(1),
      `S-${TICKET}:${OWNER}:123:abc`, `S-${TICKET}`, '', 'S-',
    ]) expect(isStaticCode(bad)).toBe(false);
  });

  it('checks a code against the roster hash only', async () => {
    const s = (await staticCodeHash(VECTOR))!;
    expect(await verifyStaticWithKeys(VECTOR, { s })).toEqual({ ok: true });
    expect((await verifyStaticWithKeys(VECTOR.replace('ZW5X', 'ZW5Y'), { s })).ok).toBe(false);
    expect(await verifyStaticWithKeys(VECTOR, {})).toEqual({ ok: false, noKey: true });
    // The hash itself is no code.
    expect((await verifyStaticWithKeys(`S-${TICKET}:${s.slice(0, 32).toUpperCase()}`, { s })).ok).toBe(false);
  });
});

describe('door parsing: static and rotating codes never cross', () => {
  it('an S- code is verified only by keys.s, as a static code', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, null, 'static');
    expect(keys.s).toBe(await staticCodeHash(VECTOR));
    const ok = await verifyBarcode(VECTOR, keys, { now: NOW });
    expect(ok).toMatchObject({ ok: true, ticketId: TICKET, legacy: false });
    expect(ok.bucket).toBeUndefined();
    expect(await verifyBarcode(VECTOR.toLowerCase(), keys, { now: NOW })).toMatchObject({ ok: true });
    expect(await verifyBarcode(VECTOR.replace('ZW5X', 'ZW5Y'), keys, { now: NOW })).toMatchObject({ ok: false, reason: 'signature-mismatch' });
  });

  it('a rotating ticket (no keys.s) never admits an S- code', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW);
    expect(keys.s).toBeUndefined();
    expect(await verifyBarcode(VECTOR, keys, { now: NOW })).toMatchObject({ ok: false, reason: 'no-key' });
    // Holder-side tools (the bare secret) can't vouch for one either.
    expect(await verifyBarcode(VECTOR, SECRET, { now: NOW })).toMatchObject({ ok: false, reason: 'no-key' });
  });

  it('a T- code is never read as static, and keeps working for a static ticket', async () => {
    const keys = await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, null, 'static');
    const t = await signBarcode(TICKET, OWNER, SECRET, Math.floor(NOW / 30_000));
    expect(isStaticCode(t)).toBe(false);
    expect(canonicalStaticCode('S' + t.slice(1))).toBeNull();
    expect(await verifyBarcode(t, keys, { now: NOW })).toMatchObject({ ok: true, bucket: Math.floor(NOW / 30_000) });
    // An S- code relabelled T- is a malformed rotating code, not a static one.
    expect(await verifyBarcode('T' + VECTOR.slice(1), keys, { now: NOW })).toMatchObject({ ok: false, reason: 'malformed' });
    // A static tail relabelled A- (add-on) is malformed too.
    expect(await verifyBarcode('A' + VECTOR.slice(1), keys, { now: NOW })).toMatchObject({ ok: false, reason: 'malformed' });
  });

  it('a printed ticket refuses its static code', async () => {
    const keys = { ...(await doorKeysFromSecret(TICKET, OWNER, SECRET, NOW, null, 'static')), p: 'a'.repeat(64) };
    expect(await verifyBarcode(VECTOR, keys, { now: NOW })).toMatchObject({ ok: false, reason: 'printed', ticketId: TICKET });
  });

  it('the roster parser keeps a valid s and drops a bad one', async () => {
    const s = (await staticCodeHash(VECTOR))!;
    expect(parseDoorKeys({ d: {}, s })?.s).toBe(s);
    expect(parseDoorKeys({ d: {}, s: VECTOR })?.s).toBeUndefined();
    expect(parseDoorKeys(JSON.stringify({ d: {}, s: s.toUpperCase() }))?.s).toBeUndefined();
  });

  it('prefix and ticket id helpers know S-', () => {
    expect(normalizeCodePrefix(VECTOR.toLowerCase()).startsWith('S-')).toBe(true);
    expect(extractTicketIdFromAny(VECTOR)).toBe(TICKET);
    const typed = parseDoorCode(VECTOR.toLowerCase(), 'manual');
    expect(typed).toMatchObject({ ticketId: TICKET, bare: false });
    expect(parseDoorCode(VECTOR, 'camera')).toMatchObject({ ticketId: TICKET, bare: false });
  });
});
