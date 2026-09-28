// Wallet door codes (mig 20260929072000, docs/wallet.md).
//
// The app shows a rotating T- code (src/lib/barcode.ts). A wallet pass can't
// run that, so it carries a W- code the door (exos_check_in_ticket) accepts:
//
//   W-{ticket}:{owner}:a{epoch}:{mac}    Apple Wallet, static until the pass updates
//     mac = base64url(HMAC-SHA256(barcode_secret, "wallet-a:{ticket}:{owner}:{epoch}"))
//   W-{ticket}:{owner}:g{epoch}:{totp}   Google Wallet rotatingBarcode
//     key = HMAC-SHA256(barcode_secret, "wallet-g:{ticket}:{owner}:{epoch}")[0..20]
//     totp = RFC 6238 (HMAC-SHA1, 30 s, 8 digits), ±2 steps at the door
//
// The SQL functions _exos_wallet_apple_code / _exos_wallet_google_key /
// _exos_wallet_totp are the source of truth (the edge function gets the code
// and key from the database, never barcode_secret). This file mirrors them for
// the door scanner's local (offline) check and for tests; walletCodes.test.ts
// pins both to the same vectors.
//
// The "wallet-a:" / "wallet-g:" prefixes keep these MACs apart from the T-
// code's HMAC over "{ticket}:{owner}:{bucket}".

import { fromHex, hmac, sha256, timingSafeEqual, toBase64Url, toHex, utf8 } from "./bytes.ts";

export const TOTP_PERIOD_MS = 30_000;
export const TOTP_DIGITS = 8;
/** Steps accepted either side of now, same as the T- code's bucket tolerance. */
export const TOTP_WINDOW = 2;

export async function appleWalletCode(ticketId: string, ownerId: string, secret: string, epoch: number): Promise<string> {
  const mac = await hmac("SHA-256", utf8(secret), utf8(`wallet-a:${ticketId}:${ownerId}:${epoch}`));
  return `W-${ticketId}:${ownerId}:a${epoch}:${toBase64Url(mac)}`;
}

export async function googleTotpKey(ticketId: string, ownerId: string, secret: string, epoch: number): Promise<Uint8Array> {
  const full = await hmac("SHA-256", utf8(secret), utf8(`wallet-g:${ticketId}:${ownerId}:${epoch}`));
  return full.slice(0, 20);
}

/** What Google Wallet renders: its {totp_value_0} is the TOTP of the key. */
export function googleValuePattern(ticketId: string, ownerId: string, epoch: number): string {
  return `W-${ticketId}:${ownerId}:g${epoch}:{totp_value_0}`;
}

/** RFC 6238 TOTP (HMAC-SHA1) for one time step. */
export async function totp(key: Uint8Array, step: number, digits = TOTP_DIGITS): Promise<string> {
  const counter = new Uint8Array(8);
  let v = step;
  for (let i = 7; i >= 0; i--) {
    counter[i] = v % 256;
    v = Math.floor(v / 256);
  }
  const h = await hmac("SHA-1", key, counter);
  const o = h[19] & 15;
  const bin = ((h[o] & 0x7f) * 2 ** 24) + (h[o + 1] << 16) + (h[o + 2] << 8) + h[o + 3];
  return String(bin % 10 ** digits).padStart(digits, "0");
}

export const totpStep = (nowMs: number): number => Math.floor(nowMs / TOTP_PERIOD_MS);

export type WalletCode =
  | { kind: "apple"; ticketId: string; ownerId: string; epoch: number; mac: string }
  | { kind: "google"; ticketId: string; ownerId: string; epoch: number; totp: string };

export function parseWalletCode(payload: string): WalletCode | null {
  if (typeof payload !== "string" || payload.slice(0, 2).toUpperCase() !== "W-") return null;
  const parts = payload.slice(2).split(":");
  if (parts.length !== 4) return null;
  const [ticketId, ownerId, tag, proof] = parts;
  const m = /^([ag])([0-9]{1,9})$/.exec(tag);
  if (!m || !ticketId || !ownerId || !proof) return null;
  const epoch = Number(m[2]);
  if (m[1] === "a") return { kind: "apple", ticketId, ownerId, epoch, mac: proof };
  if (!/^[0-9]{8}$/.test(proof)) return null;
  return { kind: "google", ticketId, ownerId, epoch, totp: proof };
}

export interface WalletVerifyResult {
  ok: boolean;
  reason?: "malformed" | "signature-mismatch";
  code?: WalletCode;
}

/**
 * The signature half of the door check, for the scanner's local list. The
 * server additionally requires the pass to be live at that epoch (a reissued
 * or voided pass is refused there, and an offline replay of it is a conflict).
 */
export async function verifyWalletCode(
  payload: string,
  secret: string,
  opts: { now?: number } = {},
): Promise<WalletVerifyResult> {
  const code = parseWalletCode(payload);
  if (!code) return { ok: false, reason: "malformed" };
  if (!secret) return { ok: false, reason: "signature-mismatch", code };
  if (code.kind === "apple") {
    const expected = await appleWalletCode(code.ticketId, code.ownerId, secret, code.epoch);
    return timingSafeEqual(expected, payload) ? { ok: true, code } : { ok: false, reason: "signature-mismatch", code };
  }
  const key = await googleTotpKey(code.ticketId, code.ownerId, secret, code.epoch);
  const cur = totpStep(opts.now ?? Date.now());
  let hit = false;
  for (let s = cur - TOTP_WINDOW; s <= cur + TOTP_WINDOW; s++) {
    if (timingSafeEqual(await totp(key, s), code.totp)) hit = true;
  }
  return hit ? { ok: true, code } : { ok: false, reason: "signature-mismatch", code };
}

// ── Apple authenticationToken ──────────────────────────────────────────────

/** A fresh pass authenticationToken (Apple wants at least 16 characters). */
export function newAuthToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return toBase64Url(b);
}

/** SHA-256 hex, as stored in exos_wallet_passes.auth_token_hash. */
export async function hashAuthToken(token: string): Promise<string> {
  return toHex(await sha256(utf8(token)));
}

/** The token from an "Authorization: ApplePass <token>" header, or null. */
export function parseApplePassAuth(header: string | null | undefined): string | null {
  if (!header) return null;
  const m = /^ApplePass ([A-Za-z0-9_\-+/=.]{16,256})$/.exec(header.trim());
  return m ? m[1] : null;
}

export { fromHex, toHex };
