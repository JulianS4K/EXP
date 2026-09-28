import { describe, expect, it } from 'vitest';
import { createPkcs7Signer } from '../../../supabase/functions/_shared/wallet/pkcs7.ts';
import { ab, sha256, toHex, utf8 } from '../../../supabase/functions/_shared/wallet/bytes.ts';
import { bytesOf, children, contentOf, OID, oid, read, tlv, toPem } from '../../../supabase/functions/_shared/wallet/der.ts';
import { WalletKeyError } from '../../../supabase/functions/_shared/wallet/keys.ts';
import { privateKeyPem, rsaKeyPair, selfSignedCert } from './fixtures';

const eq = (a: Uint8Array, b: Uint8Array) => toHex(a) === toHex(b);

describe('PKCS#7 detached signature (throwaway keys)', () => {
  it('SignedData over the manifest, verifiable with the cert key', async () => {
    const keys = await rsaKeyPair();
    const cert = await selfSignedCert(keys, 'Exos Test Pass', 4242);
    const wwdrKeys = await rsaKeyPair();
    const wwdr = await selfSignedCert(wwdrKeys, 'Test WWDR', 7);
    const signer = await createPkcs7Signer(
      { certPem: toPem('CERTIFICATE', cert), keyPem: await privateKeyPem(keys), wwdrPem: toPem('CERTIFICATE', wwdr) },
      () => new Date('2026-09-28T12:00:00Z'),
    );
    const manifest = utf8('{"pass.json":"00"}');
    const der = await signer.sign(manifest);

    // ContentInfo { signedData, [0] SignedData }
    const root = read(der);
    const [ctype, wrapped] = children(der, root);
    expect(eq(bytesOf(der, ctype), oid(OID.signedData))).toBe(true);
    const sd = children(der, wrapped)[0];
    const [version, digestAlgs, encap, certs, signerInfos] = children(der, sd);
    expect(contentOf(der, version)).toEqual(Uint8Array.of(1));
    expect(eq(bytesOf(der, children(der, children(der, digestAlgs)[0])[0]), oid(OID.sha256))).toBe(true);
    // Detached: eContentType only, no content.
    expect(children(der, encap)).toHaveLength(1);
    // Both certificates travel with it.
    const certList = children(der, certs).map((c) => bytesOf(der, c));
    expect(certList.map(toHex)).toEqual([toHex(cert), toHex(wwdr)]);

    const si = children(der, signerInfos)[0];
    const [, sid, , attrs, sigAlg, sig] = children(der, si);
    expect(eq(bytesOf(der, children(der, sigAlg)[0]), oid(OID.rsaEncryption))).toBe(true);
    // sid serial = the cert's serial (4242 = 0x1092)
    expect(toHex(contentOf(der, children(der, sid)[1]))).toBe('1092');

    // messageDigest attribute = SHA-256(manifest)
    const attrList = children(der, attrs);
    const md = attrList.find((a) => eq(bytesOf(der, children(der, a)[0]), oid(OID.messageDigest)))!;
    const mdValue = children(der, children(der, md)[1])[0];
    expect(toHex(contentOf(der, mdValue))).toBe(toHex(await sha256(manifest)));

    // The signature covers the attributes re-tagged as a SET.
    const signedAttrs = tlv(0x31, contentOf(der, attrs));
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', keys.publicKey, ab(contentOf(der, sig)), ab(signedAttrs));
    expect(ok).toBe(true);
    const wrongKey = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', wwdrKeys.publicKey, ab(contentOf(der, sig)), ab(signedAttrs));
    expect(wrongKey).toBe(false);
  });

  it('refuses missing or unusable material instead of signing', async () => {
    const keys = await rsaKeyPair();
    const cert = toPem('CERTIFICATE', await selfSignedCert(keys, 'x', 1));
    const key = await privateKeyPem(keys);
    await expect(createPkcs7Signer({ certPem: '', keyPem: key, wwdrPem: cert })).rejects.toBeInstanceOf(WalletKeyError);
    await expect(createPkcs7Signer({ certPem: cert, keyPem: key, wwdrPem: '' })).rejects.toBeInstanceOf(WalletKeyError);
    await expect(createPkcs7Signer({ certPem: cert, keyPem: '-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----', wwdrPem: cert }))
      .rejects.toThrow('encrypted');
    // A key error never echoes the PEM.
    try {
      await createPkcs7Signer({ certPem: cert, keyPem: '-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----', wwdrPem: cert });
      expect.unreachable();
    } catch (e) {
      expect(String((e as Error).message)).not.toContain('QUJD');
    }
  });
});
