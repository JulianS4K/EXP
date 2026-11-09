import { describe, expect, it } from 'vitest';
import {
  buildSeasonPassAppleJson, buildSeasonPassGoogle, coverage, creditsLeft, passNumber, seasonPassSaveUrl, seasonRange,
  type SeasonPassPayload,
} from '../../../supabase/functions/_shared/wallet/seasonPass.ts';
import { decodeJwt, type Rs256Signer } from '../../../supabase/functions/_shared/wallet/google.ts';
import { utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { routeWallet } from '../../../supabase/functions/_shared/wallet/routes.ts';

const PASS_ID = '44444444-4444-4444-4444-444444444444';
const pass = (o: Partial<SeasonPassPayload> = {}): SeasonPassPayload => ({
  serial: `sp-${PASS_ID}`, pass_id: PASS_ID, kind: 'season', name: 'Fall season', org_name: 'The Room',
  credits_total: 4, credits_used: 1, per_event_limit: 1, valid_until: '2026-12-31T23:59:59Z', date_from: null, date_to: null,
  events: [{ name: 'One', starts_at: null }, { name: 'Two', starts_at: null }], updated_at: '2026-11-02T10:00:00Z', ...o,
});
const ID = { passTypeIdentifier: 'pass.com.exos.test', teamIdentifier: 'ABCDE12345' };
const ISSUER = '3388000000012345678';
const fakeSigner: Rs256Signer = { email: 'wallet@exos-test.iam.gserviceaccount.com', sign: async () => utf8('sig') };
// deno-lint-ignore no-explicit-any
type Json = any;

describe('season-pass wallet card (mig 20261102100000)', () => {
  it('admissions left, coverage, number', () => {
    expect(creditsLeft(pass())).toBe(3);
    expect(creditsLeft(pass({ credits_total: null }))).toBeNull();
    expect(creditsLeft(pass({ credits_used: 9 }))).toBe(0);
    expect(coverage(pass())).toBe('One, Two');
    expect(coverage(pass({ events: ['a', 'b', 'c', 'd', 'e'].map((name) => ({ name, starts_at: null })) }))).toBe('a, b, c and 2 more');
    expect(coverage(pass({ events: [], date_from: '2026-10-02T00:00:00Z', date_to: '2026-12-20T00:00:00Z' }))).toBe('Oct 2, 2026 – Dec 20, 2026');
    expect(coverage(pass({ events: [] }))).toBe('Any event of the organizer');
    expect(seasonRange(null, '2026-12-20T00:00:00Z')).toBe('Until Dec 20, 2026');
    expect(passNumber(PASS_ID)).toBe('44444444');
  });
  it('Apple: a generic pass with no barcode and no web service', () => {
    const j: Json = buildSeasonPassAppleJson(pass(), ID);
    expect(j.generic.primaryFields[0]).toMatchObject({ label: 'SEASON PASS', value: 'Fall season' });
    expect(j.generic.headerFields[0]).toMatchObject({ key: 'left', value: 3 });
    expect(j.barcodes).toBeUndefined();
    expect(j.webServiceURL).toBeUndefined();
    expect(j.authenticationToken).toBeUndefined();
    expect(j.serialNumber).toBe(`sp-${PASS_ID}`);
    expect(j.organizationName).toBe('The Room');
    expect(j.expirationDate).toBe('2026-12-31T23:59:59Z');
    expect(JSON.stringify(j)).not.toMatch(/@/);
    const flex: Json = buildSeasonPassAppleJson(pass({ kind: 'flex', credits_total: null, valid_until: null, per_event_limit: null }), ID);
    expect(flex.generic.headerFields).toEqual([]);
    expect(flex.expirationDate).toBeUndefined();
  });
  it('Google: generic class + object inside the save JWT', async () => {
    const { cls, obj }: Json = buildSeasonPassGoogle(pass(), ISSUER);
    expect(cls.id).toBe(`${ISSUER}.exos-season-pass`);
    expect(obj).toMatchObject({ id: `${ISSUER}.exos-sp-${PASS_ID}`, classId: cls.id, state: 'ACTIVE' });
    expect(obj.textModulesData[0]).toEqual({ id: 'left', header: 'Admissions left', body: '3' });
    expect(obj.barcode).toBeUndefined();
    const url = await seasonPassSaveUrl(pass(), ISSUER, fakeSigner, ['https://exos.example'], 1700000000);
    expect(url.startsWith('https://pay.google.com/gp/v/save/')).toBe(true);
    const { claims }: Json = decodeJwt(url.split('/').pop()!);
    expect(claims).toMatchObject({ iss: fakeSigner.email, aud: 'google', typ: 'savetowallet', iat: 1700000000, origins: ['https://exos.example'] });
    expect(claims.payload.genericObjects[0].id).toBe(obj.id);
    expect(() => buildSeasonPassGoogle(pass(), 'abc')).toThrow(/numeric/);
  });
  it('exos-wallet routes POST /season-pass', () => {
    expect(routeWallet('POST', '/functions/v1/exos-wallet/season-pass')).toEqual({ kind: 'season-pass' });
    expect(routeWallet('GET', '/functions/v1/exos-wallet/season-pass')).toEqual({ kind: 'not-found' });
  });
});
