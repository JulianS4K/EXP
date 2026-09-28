import { describe, expect, it } from 'vitest';
import {
  buildApplePassJson,
  buildManifest,
  buildPkpass,
  defaultPassImages,
} from '../../../supabase/functions/_shared/wallet/apple.ts';
import type { PassSigner } from '../../../supabase/functions/_shared/wallet/pkcs7.ts';
import { localIso } from '../../../supabase/functions/_shared/wallet/payload.ts';
import { sha1, toHex, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { unzipStore } from '../../../supabase/functions/_shared/wallet/zip.ts';
import { payload, SQL_APPLE_CODE } from './fixtures';

const ID = {
  passTypeIdentifier: 'pass.com.exos.test',
  teamIdentifier: 'ABCDE12345',
  webServiceURL: 'https://example.supabase.co/functions/v1/exos-wallet/apple',
};
const TOKEN = 'tok_'.padEnd(43, 'x');

// deno-lint-ignore no-explicit-any
type Json = any;
const fields = (pass: Json, group: string) =>
  Object.fromEntries((pass.eventTicket[group] as Json[]).map((f) => [f.key, f]));

describe('localIso: event-local time with its offset', () => {
  it('New York in October is UTC-4', () => {
    expect(localIso('2026-10-03T00:00:00Z', 'America/New_York')).toBe('2026-10-02T20:00:00-04:00');
  });
  it('New York in January is UTC-5; Kolkata is +05:30', () => {
    expect(localIso('2027-01-10T01:30:00Z', 'America/New_York')).toBe('2027-01-09T20:30:00-05:00');
    expect(localIso('2026-10-03T00:00:00Z', 'Asia/Kolkata')).toBe('2026-10-03T05:30:00+05:30');
  });
  it('unknown or missing zone falls back to UTC', () => {
    expect(localIso('2026-10-03T00:00:00Z', null)).toBe('2026-10-03T00:00:00Z');
    expect(localIso('2026-10-03T00:00:00Z', 'Not/AZone')).toBe('2026-10-03T00:00:00Z');
  });
});

describe('pass.json', () => {
  const pass: Json = buildApplePassJson(payload(), ID, TOKEN);

  it('identity + web service', () => {
    expect(pass).toMatchObject({
      formatVersion: 1,
      passTypeIdentifier: ID.passTypeIdentifier,
      teamIdentifier: ID.teamIdentifier,
      serialNumber: payload().serial,
      authenticationToken: TOKEN,
      webServiceURL: ID.webServiceURL,
      organizationName: 'Test Org',
      sharingProhibited: true,
    });
    expect(pass.voided).toBeUndefined();
  });

  it('event name, local start time, venue, tier/section, holder', () => {
    expect(fields(pass, 'primaryFields').event.value).toBe('Night Market');
    const starts = fields(pass, 'secondaryFields').starts;
    expect(starts.value).toBe('2026-10-02T20:00:00-04:00');
    expect(starts.ignoresTimeZone).toBe(true);
    expect(fields(pass, 'secondaryFields').venue.value).toBe('Pier 17');
    expect(fields(pass, 'auxiliaryFields').tier.value).toBe('General Admission · Floor');
    expect(fields(pass, 'auxiliaryFields').holder.value).toBe('Ada Lovelace');
    expect(fields(pass, 'headerFields').status.value).toBe('Valid');
  });

  it('relevance: doors time, a window, an expiry, the venue location', () => {
    expect(pass.relevantDate).toBe('2026-10-02T19:00:00-04:00');
    expect(pass.relevantDates[0]).toEqual({ startDate: '2026-10-02T18:00:00-04:00', endDate: '2026-10-03T00:00:00-04:00' });
    expect(pass.expirationDate).toBe('2026-10-03T12:00:00-04:00');
    expect(pass.locations[0]).toMatchObject({ latitude: 40.7057, longitude: -74.0018 });
  });

  it('barcode is the W- code the door accepts', () => {
    expect(pass.barcodes).toEqual([{
      format: 'PKBarcodeFormatQR', message: SQL_APPLE_CODE, messageEncoding: 'iso-8859-1', altText: '11111111',
    }]);
  });

  it('holder-safe: no email, price, buyer or secret anywhere', () => {
    const s = JSON.stringify(pass);
    expect(s).not.toMatch(/\w@\w/); // no email address
    for (const bad of ['price', 'buyer', 'barcode_secret', 'sek']) expect(s).not.toContain(bad);
  });

  it('voided (transferred): voided flag, no barcode, says why', () => {
    const v: Json = buildApplePassJson(payload({ status: 'voided', void_reason: 'transferred', apple_code: null, google_key_hex: null }), ID, TOKEN);
    expect(v.voided).toBe(true);
    expect(v.barcodes).toBeUndefined();
    expect(fields(v, 'headerFields').status.value).toBe('Void');
    expect(fields(v, 'backFields').void.value).toMatch(/transferred/);
  });

  it('checked in shows it, still with the code', () => {
    const u: Json = buildApplePassJson(payload({ ticket: { ...payload().ticket, status: 'used' } }), ID, TOKEN);
    expect(fields(u, 'headerFields').status.value).toBe('Checked in');
    expect(u.barcodes[0].message).toBe(SQL_APPLE_CODE);
  });
});

describe('manifest + bundle', () => {
  it('manifest is SHA-1 hex of each file', async () => {
    const m = await buildManifest({ 'b.txt': utf8('abc'), 'a.txt': utf8('') });
    expect(m).toEqual({
      'a.txt': 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      'b.txt': 'a9993e364706816aba3e25717850c26c9cd0d89d',
    });
  });

  it('pkpass: pass.json + images + manifest + signature from the injected signer', async () => {
    const seen: Uint8Array[] = [];
    const fake: PassSigner = {
      sign: async (m) => {
        seen.push(m);
        return utf8('FAKE-SIGNATURE');
      },
    };
    const pass = buildApplePassJson(payload(), ID, TOKEN);
    const out = await buildPkpass(pass, fake);
    const entries = Object.fromEntries(unzipStore(out.bytes).map((e) => [e.name, e.data]));
    expect(Object.keys(entries).sort()).toEqual(
      ['icon.png', 'icon@2x.png', 'icon@3x.png', 'logo.png', 'logo@2x.png', 'manifest.json', 'pass.json', 'signature'],
    );
    expect(JSON.parse(new TextDecoder().decode(entries['pass.json']))).toEqual(pass);
    const manifest = JSON.parse(new TextDecoder().decode(entries['manifest.json']));
    expect(Object.keys(manifest).sort()).toEqual(Object.keys(entries).filter((n) => n !== 'manifest.json' && n !== 'signature').sort());
    for (const [name, hash] of Object.entries(manifest)) expect(toHex(await sha1(entries[name]))).toBe(hash);
    expect(seen).toHaveLength(1);
    expect(new TextDecoder().decode(seen[0])).toBe(new TextDecoder().decode(entries['manifest.json']));
    expect(new TextDecoder().decode(entries.signature)).toBe('FAKE-SIGNATURE');
  });

  it('default images are real PNGs', () => {
    const png = defaultPassImages()['icon.png'];
    expect([...png.slice(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });

  it('a failing signer fails the build (no unsigned pass)', async () => {
    const broken: PassSigner = { sign: () => Promise.reject(new Error('no certs')) };
    await expect(buildPkpass(buildApplePassJson(payload(), ID, TOKEN), broken)).rejects.toThrow('no certs');
  });
});
