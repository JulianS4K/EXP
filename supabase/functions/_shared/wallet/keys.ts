// RSA private keys from PEM for WebCrypto (RSASSA-PKCS1-v1_5 / SHA-256).
// Accepts PKCS#8 ("PRIVATE KEY") and PKCS#1 ("RSA PRIVATE KEY"). Encrypted
// keys are refused: decrypt once when setting the secret (docs/wallet.md).

import { ab } from "./bytes.ts";
import { int, nullDer, OID, octets, oid, pemBlocks, seq } from "./der.ts";

export class WalletKeyError extends Error {}

export function pkcs1ToPkcs8(pkcs1: Uint8Array): Uint8Array {
  return seq(int(0), seq(oid(OID.rsaEncryption), nullDer()), octets(pkcs1));
}

export async function importRsaSigningKey(pem: string): Promise<CryptoKey> {
  const [block] = pemBlocks(pem, ["PRIVATE KEY", "RSA PRIVATE KEY", "ENCRYPTED PRIVATE KEY"]);
  if (!block) throw new WalletKeyError("no private key PEM block");
  if (block.label === "ENCRYPTED PRIVATE KEY") throw new WalletKeyError("encrypted private keys are not supported");
  const der = block.label === "RSA PRIVATE KEY" ? pkcs1ToPkcs8(block.der) : block.der;
  try {
    return await crypto.subtle.importKey(
      "pkcs8",
      ab(der),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } catch {
    // Never echo key material or the underlying parser message.
    throw new WalletKeyError("private key could not be imported (RSA expected)");
  }
}

export async function rsaSign(key: CryptoKey, data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, ab(data)));
}
