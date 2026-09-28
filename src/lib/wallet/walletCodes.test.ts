import { describe, expect, it } from 'vitest';
import {
  appleWalletCode,
  googleTotpKey,
  googleValuePattern,
  hashAuthToken,
  newAuthToken,
  parseApplePassAuth,
  parseWalletCode,
  totp,
  totpStep,
  verifyWalletCode,
} from '../../../supabase/functions/_shared/wallet/codes.ts';
import { toHex, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { extractTicketIdFromAny, signBarcode, verifyBarcode } from '../barcode';
import { OWNER, SECRET, SQL_APPLE_CODE, SQL_GOOGLE_KEY_HEX, TICKET } from './fixtures';

describe('TOTP (RFC 6238, HMAC-SHA1, 8 digits)', () => {
  const key = utf8('12345678901234567890');
  it.each([
    [59, '94287082'],
    [1111111109, '07081804'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
  ])('T=%i → %s', async (t, code) => {
    expect(await totp(key, Math.floor(t / 30))).toBe(code);
  });
});

describe('wallet codes match the SQL derivation', () => {
  it('Apple static code', async () => {
    expect(await appleWalletCode(TICKET, OWNER, SECRET, 1)).toBe(SQL_APPLE_CODE);
  });
  it('Google TOTP key (20 bytes, never the secret)', async () => {
    const key = await googleTotpKey(TICKET, OWNER, SECRET, 1);
    expect(key.length).toBe(20);
    expect(toHex(key)).toBe(SQL_GOOGLE_KEY_HEX);
    expect(toHex(key)).not.toContain(toHex(utf8(SECRET)));
  });
  it('epoch and owner change the code', async () => {
    expect(await appleWalletCode(TICKET, OWNER, SECRET, 2)).not.toBe(SQL_APPLE_CODE);
    expect(toHex(await googleTotpKey(TICKET, 'x', SECRET, 1))).not.toBe(SQL_GOOGLE_KEY_HEX);
  });
  it('Google value pattern carries ticket, owner, epoch', () => {
    expect(googleValuePattern(TICKET, OWNER, 3)).toBe(`W-${TICKET}:${OWNER}:g3:{totp_value_0}`);
  });
});

describe('parse / verify wallet codes', () => {
  it('parses both kinds, rejects junk', () => {
    expect(parseWalletCode(SQL_APPLE_CODE)).toMatchObject({ kind: 'apple', ticketId: TICKET, ownerId: OWNER, epoch: 1 });
    expect(parseWalletCode(`W-${TICKET}:${OWNER}:g4:12345678`)).toMatchObject({ kind: 'google', epoch: 4, totp: '12345678' });
    for (const bad of ['', 'T-a:b:1:x', `W-${TICKET}:${OWNER}:g1:1234`, `W-${TICKET}:${OWNER}:x1:abc`, `W-${TICKET}:${OWNER}:a1`]) {
      expect(parseWalletCode(bad)).toBeNull();
    }
  });

  it('Apple code verifies with the secret, not without it', async () => {
    expect((await verifyWalletCode(SQL_APPLE_CODE, SECRET)).ok).toBe(true);
    expect(await verifyWalletCode(SQL_APPLE_CODE, 'other')).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    const forged = SQL_APPLE_CODE.replace(':a1:', ':a2:');
    expect((await verifyWalletCode(forged, SECRET)).ok).toBe(false);
  });

  it('Google code verifies within ±2 steps only', async () => {
    const key = await googleTotpKey(TICKET, OWNER, SECRET, 1);
    const now = Date.UTC(2026, 9, 2, 20, 0, 5);
    const at = async (dSteps: number) => `W-${TICKET}:${OWNER}:g1:${await totp(key, totpStep(now) + dSteps)}`;
    for (const d of [-2, -1, 0, 1, 2]) expect((await verifyWalletCode(await at(d), SECRET, { now })).ok).toBe(true);
    for (const d of [-4, 4]) expect((await verifyWalletCode(await at(d), SECRET, { now })).ok).toBe(false);
  });
});

describe('the door scanner accepts W- codes', () => {
  it('verifyBarcode dispatches W- and still verifies T-', async () => {
    expect(await verifyBarcode(SQL_APPLE_CODE, SECRET)).toMatchObject({ ok: true, ticketId: TICKET, ownerId: OWNER });
    expect(await verifyBarcode(SQL_APPLE_CODE, 'nope')).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    expect(await verifyBarcode('W-garbage', SECRET)).toMatchObject({ ok: false, reason: 'malformed' });
    const t = await signBarcode(TICKET, OWNER, SECRET);
    expect((await verifyBarcode(t, SECRET)).ok).toBe(true);
  });
  it('extracts the ticket id from a W- code', () => {
    expect(extractTicketIdFromAny(SQL_APPLE_CODE)).toBe(TICKET);
  });
});

describe('ApplePass authenticationToken', () => {
  it('fresh tokens are long, random and url-safe', () => {
    const a = newAuthToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newAuthToken()).not.toBe(a);
  });
  it('hash is SHA-256 hex (what the database stores)', async () => {
    expect(await hashAuthToken('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
  it('parses only "ApplePass <token>"', () => {
    const tok = 'A'.repeat(20);
    expect(parseApplePassAuth(`ApplePass ${tok}`)).toBe(tok);
    expect(parseApplePassAuth(`Bearer ${tok}`)).toBeNull();
    expect(parseApplePassAuth('ApplePass short')).toBeNull();
    expect(parseApplePassAuth(null)).toBeNull();
    expect(parseApplePassAuth(`ApplePass ${tok} extra`)).toBeNull();
  });
});
