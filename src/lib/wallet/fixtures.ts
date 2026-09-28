// Shared test fixtures for the wallet tests: a pass payload as the database
// returns it, and throwaway RSA keys / self-signed certificates generated per
// run (never real credentials).

import type { WalletPayload } from '../../../supabase/functions/_shared/wallet/payload.ts';
import { ab, concat, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { ctx, int, nullDer, OID, oid, seq, setOf, tlv, toPem, utcTime } from '../../../supabase/functions/_shared/wallet/der.ts';

export const TICKET = '11111111-1111-1111-1111-111111111111';
export const OWNER = '22222222-2222-2222-2222-222222222222';
export const SECRET = 'sek';
/** From SQL: _exos_wallet_apple_code(TICKET, OWNER, 'sek', 1). */
export const SQL_APPLE_CODE =
  `W-${TICKET}:${OWNER}:a1:S0zzswPk5LKCbx2nEfnHYRIBNx2fzxSHq0YbSt6jrmM`;
/** From SQL: encode(_exos_wallet_google_key(TICKET, OWNER, 'sek', 1), 'hex'). */
export const SQL_GOOGLE_KEY_HEX = '133015cacf7d7a699286a00f41c09045724e85df';

export function payload(over: Partial<WalletPayload> = {}): WalletPayload {
  return {
    serial: 'exw0123456789abcdef0123456789abcdef',
    pass_type: 'pass.com.exos.test',
    status: 'active',
    void_reason: null,
    code_epoch: 1,
    updated_at: '2026-09-28T12:00:00.123456+00:00',
    ticket: {
      id: TICKET, status: 'active', tier_name: 'General Admission', section_label: 'Floor',
      attendee_name: 'Ada Lovelace', in_transfer: false, check_in_at: null,
    },
    event: {
      id: '33333333-3333-3333-3333-333333333333', name: 'Night Market', status: 'published',
      starts_at: '2026-10-03T00:00:00Z', ends_at: '2026-10-03T04:00:00Z', doors_at: '2026-10-02T23:00:00Z',
      timezone: 'America/New_York', venue_name: 'Pier 17', venue_location: '89 South St, New York, NY',
      lat: 40.7057, lng: -74.0018,
    },
    org_name: 'Test Org',
    apple_code: SQL_APPLE_CODE,
    google_key_hex: SQL_GOOGLE_KEY_HEX,
    google_pattern: `W-${TICKET}:${OWNER}:g1:{totp_value_0}`,
    ...over,
  };
}

export async function rsaKeyPair(): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
}

const cn = (s: string) => seq(setOf(seq(oid('2.5.4.3'), tlv(0x0c, utf8(s)))));

/** A self-signed certificate (DER) for a throwaway key. */
export async function selfSignedCert(keys: CryptoKeyPair, name: string, serial: number): Promise<Uint8Array> {
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', keys.publicKey));
  const alg = seq(oid(OID.sha256WithRSA), nullDer());
  const tbs = seq(
    ctx(0, int(2)),
    int(serial),
    alg,
    cn(name),
    seq(utcTime(new Date('2026-01-01T00:00:00Z')), utcTime(new Date('2027-01-01T00:00:00Z'))),
    cn(name),
    spki,
  );
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, ab(tbs)));
  return seq(tbs, alg, tlv(0x03, concat([Uint8Array.of(0), sig])));
}

export async function privateKeyPem(keys: CryptoKeyPair): Promise<string> {
  return toPem('PRIVATE KEY', new Uint8Array(await crypto.subtle.exportKey('pkcs8', keys.privateKey)));
}
