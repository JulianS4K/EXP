import { describe, expect, it } from 'vitest';
import {
  buildEventTicketClass,
  buildEventTicketObject,
  buildSaveUrl,
  createRs256Signer,
  decodeJwt,
  googleRotatingBarcode,
  googleSaveLink,
  type Rs256Signer,
  saveJwtClaims,
  signJwt,
  WALLET_API,
} from '../../../supabase/functions/_shared/wallet/google.ts';
import { ab, fromBase64Url, fromHex, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { totp, totpStep, verifyWalletCode } from '../../../supabase/functions/_shared/wallet/codes.ts';
import { OWNER, payload, privateKeyPem, rsaKeyPair, SECRET, SQL_GOOGLE_KEY_HEX, TICKET } from './fixtures';

const ISSUER = '3388000000012345678';
const fakeSigner: Rs256Signer = { email: 'wallet@exos-test.iam.gserviceaccount.com', sign: async () => utf8('sig') };

// deno-lint-ignore no-explicit-any
type Json = any;

describe('EventTicketClass', () => {
  it('event name, venue, local times, location, ids', () => {
    const c: Json = buildEventTicketClass(payload(), ISSUER);
    expect(c.id).toBe(`${ISSUER}.exos-event-33333333-3333-3333-3333-333333333333`);
    expect(c.eventName.defaultValue.value).toBe('Night Market');
    expect(c.venue.name.defaultValue.value).toBe('Pier 17');
    expect(c.dateTime).toEqual({
      start: '2026-10-02T20:00:00-04:00', end: '2026-10-03T00:00:00-04:00', doorsOpen: '2026-10-02T19:00:00-04:00',
    });
    expect(c.issuerName).toBe('Test Org');
  });
  it('issuer id must be numeric', () => {
    expect(() => buildEventTicketClass(payload(), 'abc')).toThrow();
  });
});

describe('EventTicketObject + rotatingBarcode', () => {
  it('TOTP rotating barcode with the derived key', () => {
    const o: Json = buildEventTicketObject(payload(), ISSUER);
    expect(o.id).toBe(`${ISSUER}.exos-pass-${payload().serial}`);
    expect(o.classId).toBe(`${ISSUER}.exos-event-33333333-3333-3333-3333-333333333333`);
    expect(o.state).toBe('ACTIVE');
    expect(o.ticketHolderName).toBe('Ada Lovelace');
    expect(o.seatInfo.section.defaultValue.value).toBe('Floor');
    expect(o.rotatingBarcode).toEqual({
      type: 'QR_CODE',
      renderEncoding: 'UTF_8',
      valuePattern: `W-${TICKET}:${OWNER}:g1:{totp_value_0}`,
      totpDetails: { periodMillis: '30000', algorithm: 'TOTP_SHA1', parameters: [{ key: SQL_GOOGLE_KEY_HEX, valueLength: 8 }] },
      alternateText: '11111111',
    });
    expect(o.barcode).toBeUndefined();
    expect(JSON.stringify(o)).not.toContain(SECRET);
  });

  it('what Google renders is a code the door accepts', async () => {
    const o: Json = buildEventTicketObject(payload(), ISSUER);
    const now = Date.UTC(2026, 9, 2, 20, 0, 0);
    const value = o.rotatingBarcode.valuePattern.replace(
      '{totp_value_0}', await totp(fromHex(o.rotatingBarcode.totpDetails.parameters[0].key), totpStep(now)),
    );
    expect((await verifyWalletCode(value, SECRET, { now })).ok).toBe(true);
  });

  it('voided object is INACTIVE with no barcode; checked in is COMPLETED', () => {
    const v: Json = buildEventTicketObject(payload({ status: 'voided', void_reason: 'ticket-voided', apple_code: null, google_key_hex: null }), ISSUER);
    expect(v.state).toBe('INACTIVE');
    expect(v.rotatingBarcode).toBeUndefined();
    expect(v.textModulesData[0].body).toMatch(/cancelled or refunded/);
    const u: Json = buildEventTicketObject(payload({ ticket: { ...payload().ticket, status: 'used' } }), ISSUER);
    expect(u.state).toBe('COMPLETED');
  });

  it('rejects a bad key or pattern', () => {
    expect(() => googleRotatingBarcode('W-x:{totp_value_0}', 'abcd')).toThrow();
    expect(() => googleRotatingBarcode('no-placeholder', SQL_GOOGLE_KEY_HEX)).toThrow();
  });
});

describe('Save to Google Wallet JWT', () => {
  it('claims: iss, aud google, typ savetowallet, objects by id only', async () => {
    const url = await buildSaveUrl(fakeSigner, ['1.a'], ['https://exos.example'], 1_800_000_000);
    expect(url.startsWith('https://pay.google.com/gp/v/save/')).toBe(true);
    const { header, claims, signature } = decodeJwt(url.split('/').pop()!);
    expect(header).toEqual({ alg: 'RS256', typ: 'JWT' });
    expect(claims).toEqual({
      iss: fakeSigner.email, aud: 'google', typ: 'savetowallet', iat: 1_800_000_000,
      origins: ['https://exos.example'], payload: { eventTicketObjects: [{ id: '1.a' }] },
    });
    expect(new TextDecoder().decode(fromBase64Url(signature))).toBe('sig');
  });

  it('the TOTP key never goes into the save link', async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const fetchFn = async (url: string, init?: RequestInit) => {
      calls.push({ url, init });
      if (url.includes('oauth2')) return new Response(JSON.stringify({ access_token: 'at' }), { status: 200 });
      if (init?.method === 'POST' && url.endsWith('/eventTicketObject')) return new Response('{}', { status: 409 });
      return new Response('{}', { status: 200 });
    };
    const link = await googleSaveLink(payload(), { issuerId: ISSUER }, fakeSigner, fetchFn);
    expect(link).not.toContain(SQL_GOOGLE_KEY_HEX);
    expect(JSON.stringify(decodeJwt(link.split('/').pop()!).claims)).not.toContain(SQL_GOOGLE_KEY_HEX);
    // oauth, class insert, object insert (409) → object PUT
    expect(calls.map((c) => `${c.init?.method} ${c.url.replace(WALLET_API, '')}`)).toEqual([
      'POST https://oauth2.googleapis.com/token',
      'POST /eventTicketClass',
      'POST /eventTicketObject',
      `PUT /eventTicketObject/${encodeURIComponent(`${ISSUER}.exos-pass-${payload().serial}`)}`,
    ]);
    expect(calls[3].init?.headers).toMatchObject({ authorization: 'Bearer at' });
    // The server-to-server object carries the key (Google needs it).
    expect(String(calls[3].init?.body)).toContain(SQL_GOOGLE_KEY_HEX);
  });

  it('a real RS256 signer (throwaway key) produces a verifiable JWT', async () => {
    const keys = await rsaKeyPair();
    const sa = JSON.stringify({ client_email: 'sa@test.iam.gserviceaccount.com', private_key: await privateKeyPem(keys) });
    const signer = await createRs256Signer(sa);
    const jwt = await signJwt(saveJwtClaims({ issuerEmail: signer.email, objectIds: ['1.b'], iat: 1 }), signer);
    const [h, c, s] = jwt.split('.');
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', keys.publicKey, ab(fromBase64Url(s)), ab(utf8(`${h}.${c}`)));
    expect(ok).toBe(true);
    await expect(createRs256Signer('{"client_email":"x"}')).rejects.toThrow();
    await expect(createRs256Signer('not json')).rejects.toThrow();
  });
});
