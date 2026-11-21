import { describe, expect, it } from 'vitest';
import {
  addonGoogleSaveLink, addonTitle, buildAddonAppleJson, buildAddonGoogleObject, shortPass, type AddonWalletPayload,
} from '../../../supabase/functions/_shared/wallet/addonPass.ts';
import {
  appleAddonWalletCode, googleAddonValuePattern, googleTotpKey, parseAddonWalletCode, totp,
} from '../../../supabase/functions/_shared/wallet/codes.ts';
import { addonDoorKeysFromSecret, verifyAddonWalletWithKeys } from '../../../supabase/functions/_shared/doorKeys.ts';
import { decodeJwt, type Rs256Signer } from '../../../supabase/functions/_shared/wallet/google.ts';
import { toHex, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { routeWallet } from '../../../supabase/functions/_shared/wallet/routes.ts';
import { verifyBarcode } from '../barcode';

// The same vectors as tests/exos/test_dice_leftovers.sql DL5 (SQL
// _exos_addon_wallet_apple_code / _exos_wallet_google_key / _exos_wallet_totp).
const PASS = '11111111-2222-4333-8444-555555555555';
const OWNER = '66666666-7777-4888-8999-000000000000';
const SECRET = 'vector-secret';
const SQL_APPLE = `A-${PASS}:${OWNER}:a3:rYCAPorA6t4ek-4LcOG5D7xjTJsvYFsdU5QpaAkwEI0`;
const SQL_KEY = '7beafda181d04e474166c4ed466b67c97832c28f';
const SQL_TOTP_STEP = 59_000_000;
const SQL_TOTP = '11095586';

const ID = { passTypeIdentifier: 'pass.com.exos.test', teamIdentifier: 'ABCDE12345' };
const ISSUER = '3388000000012345678';
const fakeSigner: Rs256Signer = { email: 'wallet@exos-test.iam.gserviceaccount.com', sign: async () => utf8('sig') };
// deno-lint-ignore no-explicit-any
type Json = any;

const payload = (o: Partial<AddonWalletPayload> = {}): AddonWalletPayload => ({
  serial: `addon-${PASS}`, pass_id: PASS, addon_name: 'VIP lounge', unit_index: 2, unit_count: 3, status: 'active', code_epoch: 3,
  updated_at: '2026-11-08T12:00:00Z',
  event: {
    id: '33333333-3333-3333-3333-333333333333', name: 'Night Market', status: 'published', starts_at: '2026-11-21T01:00:00Z',
    ends_at: '2026-11-21T05:00:00Z', doors_at: '2026-11-21T00:00:00Z', timezone: 'America/New_York', venue_name: 'Pier 17',
    venue_location: '89 South St, New York, NY', lat: 40.7, lng: -74.0,
  },
  org_name: 'Test Org', apple_code: SQL_APPLE, google_key_hex: SQL_KEY, google_pattern: googleAddonValuePattern(PASS, OWNER, 3), ...o,
});

describe('add-on wallet codes (mig 20261108110000)', () => {
  it('match the SQL derivations', async () => {
    expect(await appleAddonWalletCode(PASS, OWNER, SECRET, 3)).toBe(SQL_APPLE);
    expect(toHex(await googleTotpKey(PASS, OWNER, SECRET, 3))).toBe(SQL_KEY);
    expect(await totp(await googleTotpKey(PASS, OWNER, SECRET, 3), SQL_TOTP_STEP)).toBe(SQL_TOTP);
    expect(googleAddonValuePattern(PASS, OWNER, 3)).toBe(`A-${PASS}:${OWNER}:g3:{totp_value_0}`);
  });
  it('parse as add-on codes only', () => {
    expect(parseAddonWalletCode(SQL_APPLE)).toMatchObject({ kind: 'apple', ticketId: PASS, ownerId: OWNER, epoch: 3 });
    expect(parseAddonWalletCode(`A-${PASS}:${OWNER}:g3:${SQL_TOTP}`)).toMatchObject({ kind: 'google', epoch: 3, totp: SQL_TOTP });
    expect(parseAddonWalletCode('W' + SQL_APPLE.slice(1))).toBeNull();
    expect(parseAddonWalletCode(`A-${PASS}:${OWNER}:123:mac`)).toBeNull();
  });
  it('the door checks them with the pass keys (no secret), offline', async () => {
    const now = SQL_TOTP_STEP * 30_000 + 5_000;
    const keys = await addonDoorKeysFromSecret(PASS, OWNER, SECRET, now, 3);
    expect(keys.we).toBe(3);
    expect(keys.wg).toBe(SQL_KEY);
    expect((await verifyAddonWalletWithKeys(SQL_APPLE, keys)).ok).toBe(true);
    expect((await verifyAddonWalletWithKeys(SQL_APPLE.slice(0, -2) + 'xx', keys)).ok).toBe(false);
    expect((await verifyAddonWalletWithKeys(`A-${PASS}:${OWNER}:g3:${SQL_TOTP}`, keys, { now })).ok).toBe(true);
    expect((await verifyAddonWalletWithKeys(`A-${PASS}:${OWNER}:g3:${SQL_TOTP}`, keys, { now: now + 10 * 60_000 })).ok).toBe(false);
    // Another epoch, or keys without a wallet pass: refused / not checkable here.
    expect((await verifyAddonWalletWithKeys(SQL_APPLE.replace(':a3:', ':a4:'), keys)).ok).toBe(false);
    const noWallet = await addonDoorKeysFromSecret(PASS, OWNER, SECRET, now);
    expect(await verifyAddonWalletWithKeys(SQL_APPLE, noWallet)).toMatchObject({ ok: false, noKey: true });
    // Through the scanner's verifyBarcode.
    expect(await verifyBarcode(SQL_APPLE, keys)).toMatchObject({ ok: true, ticketId: PASS, ownerId: OWNER });
    expect(await verifyBarcode(`a-${PASS}:${OWNER}:g3:${SQL_TOTP}`, keys, { now })).toMatchObject({ ok: true, ticketId: PASS });
    expect(await verifyBarcode(SQL_APPLE, noWallet)).toMatchObject({ ok: false, reason: 'no-key', ticketId: PASS });
    expect(await verifyBarcode(SQL_APPLE.replace(':a3:', ':a4:'), keys)).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    // Holder-side tools with the secret.
    expect((await verifyBarcode(SQL_APPLE, SECRET)).ok).toBe(true);
    expect((await verifyBarcode(SQL_APPLE, 'other')).ok).toBe(false);
    expect((await verifyBarcode(`A-${PASS}:${OWNER}:g3:${SQL_TOTP}`, SECRET, { now })).ok).toBe(true);
  });
  it('Apple: one pass per unit, the add-on code as its only barcode, no web service', () => {
    const j: Json = buildAddonAppleJson(payload(), ID);
    expect(j.barcodes).toEqual([{ format: 'PKBarcodeFormatQR', message: SQL_APPLE, messageEncoding: 'iso-8859-1', altText: shortPass(PASS) }]);
    expect(j.eventTicket.primaryFields[0]).toMatchObject({ label: 'ADD-ON', value: 'VIP lounge · 2 of 3' });
    expect(j.serialNumber).toBe(`addon-${PASS}`);
    expect(j.webServiceURL).toBeUndefined();
    expect(j.authenticationToken).toBeUndefined();
    expect(j.sharingProhibited).toBe(true);
    expect(JSON.stringify(j)).not.toContain(SQL_KEY);
    const v: Json = buildAddonAppleJson(payload({ status: 'voided', apple_code: null }), ID);
    expect(v.voided).toBe(true);
    expect(v.barcodes).toBeUndefined();
    expect(addonTitle({ addon_name: 'Poster', unit_index: 1, unit_count: 1 })).toBe('Poster');
  });
  it('Google: a rotating code under the event class, stored, the link names only the id', async () => {
    const o: Json = buildAddonGoogleObject(payload(), ISSUER);
    expect(o.id).toBe(`${ISSUER}.exos-pass-addon-${PASS}`);
    expect(o.classId).toBe(`${ISSUER}.exos-event-33333333-3333-3333-3333-333333333333`);
    expect(o.rotatingBarcode.valuePattern).toBe(`A-${PASS}:${OWNER}:g3:{totp_value_0}`);
    expect(o.rotatingBarcode.totpDetails.parameters[0].key).toBe(SQL_KEY);
    expect(buildAddonGoogleObject(payload({ status: 'voided' }), ISSUER)).toMatchObject({ state: 'INACTIVE' });
    expect((buildAddonGoogleObject(payload({ status: 'voided' }), ISSUER) as Json).rotatingBarcode).toBeUndefined();
    const calls: { url: string; body: Json }[] = [];
    const fakeFetch = async (url: string, init?: RequestInit) => {
      calls.push({ url, body: init?.body ? (String(init.body).startsWith('{') ? JSON.parse(String(init.body)) : String(init.body)) : null });
      if (url.includes('oauth2')) return new Response(JSON.stringify({ access_token: 't' }), { status: 200 });
      return new Response('{}', { status: 200 });
    };
    const url = await addonGoogleSaveLink(payload(), { issuerId: ISSUER }, fakeSigner, fakeFetch);
    expect(calls.map((c) => c.url.replace(/^https:\/\/[^/]+/, ''))).toEqual([
      '/token', '/walletobjects/v1/eventTicketClass', '/walletobjects/v1/eventTicketObject',
    ]);
    expect(url.startsWith('https://pay.google.com/gp/v/save/')).toBe(true);
    const jwt = decodeJwt(url.split('/').pop()!);
    expect(jwt.claims.payload).toEqual({ eventTicketObjects: [{ id: `${ISSUER}.exos-pass-addon-${PASS}` }] });
    expect(url).not.toContain(SQL_KEY);
  });
  it('routes POST /addon-pass', () => {
    expect(routeWallet('POST', '/functions/v1/exos-wallet/addon-pass')).toEqual({ kind: 'addon-pass' });
    expect(routeWallet('GET', '/functions/v1/exos-wallet/addon-pass')).toEqual({ kind: 'not-found' });
  });
});
