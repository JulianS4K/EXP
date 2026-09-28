// The .pkpass "signature" file: a detached PKCS#7 (CMS SignedData) signature
// over manifest.json, made with the Pass Type ID certificate's key and
// carrying that certificate plus Apple's WWDR intermediate.
//
// Signing sits behind PassSigner so the pass builder is testable without
// certificates. createPkcs7Signer is the real one; with no certificates
// configured the edge function answers 503 and never makes up a signature.

import { concat, sha256 } from "./bytes.ts";
import { certIssuerAndSerial, contentOf, ctx, int, nullDer, OID, octets, oid, pemBlocks, read, seq, setOf, tlv, utcTime } from "./der.ts";
import { importRsaSigningKey, rsaSign, WalletKeyError } from "./keys.ts";

export interface PassSigner {
  /** DER PKCS#7 detached signature of `manifest`. */
  sign(manifest: Uint8Array): Promise<Uint8Array>;
}

export interface Pkcs7Parts {
  certDer: Uint8Array;
  chainDer: Uint8Array[];
  sign: (data: Uint8Array) => Promise<Uint8Array>;
  now?: () => Date;
}

/** The signed attributes (as a DER SET) that the RSA signature covers. */
export async function signedAttributes(content: Uint8Array, at: Date): Promise<Uint8Array> {
  return setOf(
    seq(oid(OID.contentType), setOf(oid(OID.data))),
    seq(oid(OID.signingTime), setOf(utcTime(at))),
    seq(oid(OID.messageDigest), setOf(octets(await sha256(content)))),
  );
}

export async function pkcs7DetachedSignature(content: Uint8Array, parts: Pkcs7Parts): Promise<Uint8Array> {
  const at = parts.now ? parts.now() : new Date();
  const attrs = await signedAttributes(content, at);
  const signature = await parts.sign(attrs);
  const { issuer, serial } = certIssuerAndSerial(parts.certDer);
  const sha256Alg = seq(oid(OID.sha256));
  const signerInfo = seq(
    int(1),
    seq(issuer, serial),
    sha256Alg,
    tlv(0xa0, contentOf(attrs, read(attrs))), // [0] IMPLICIT: same content, new tag
    seq(oid(OID.rsaEncryption), nullDer()),
    octets(signature),
  );
  const signedData = seq(
    int(1),
    setOf(sha256Alg),
    seq(oid(OID.data)), // detached: no eContent
    tlv(0xa0, concat([parts.certDer, ...parts.chainDer])),
    setOf(signerInfo),
  );
  return seq(oid(OID.signedData), ctx(0, signedData));
}

export interface AppleSigningConfig {
  certPem: string;
  keyPem: string;
  wwdrPem: string;
}

/** The real signer. Throws WalletKeyError on unusable material (never echoes it). */
export async function createPkcs7Signer(cfg: AppleSigningConfig, now?: () => Date): Promise<PassSigner> {
  const [cert] = pemBlocks(cfg.certPem, ["CERTIFICATE"]);
  const wwdr = pemBlocks(cfg.wwdrPem, ["CERTIFICATE"]);
  if (!cert) throw new WalletKeyError("pass certificate PEM missing");
  if (!wwdr.length) throw new WalletKeyError("WWDR certificate PEM missing");
  try {
    certIssuerAndSerial(cert.der);
  } catch {
    throw new WalletKeyError("pass certificate is not a valid X.509 certificate");
  }
  const key = await importRsaSigningKey(cfg.keyPem);
  return {
    sign: (manifest) =>
      pkcs7DetachedSignature(manifest, {
        certDer: cert.der,
        chainDer: wwdr.map((b) => b.der),
        sign: (data) => rsaSign(key, data),
        now,
      }),
  };
}
