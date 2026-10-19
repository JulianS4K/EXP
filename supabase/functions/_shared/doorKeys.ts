// Per-day door keys (mig 20261019100000_exos_door_day_keys).
//
// The door used to download every ticket's barcode_secret, so a lost or dumped
// door phone could mint a valid code for any ticket of the event, forever.
// Now the T- code is signed with a key derived from the secret for one UTC day:
//
//   day     = floor(bucket / 2880)                   (2880 30-second buckets a day)
//   day_key = base64url(HMAC-SHA256(barcode_secret, "door-day:{ticket}:{day}"))
//   mac     = base64url(HMAC-SHA256(day_key, "{ticket}:{owner}:{bucket}"))
//   code    = T-{ticket}:{owner}:{bucket}:{mac}
//
// The holder's phone has the secret and derives the key; the server derives it
// too; the door gets only yesterday's, today's and tomorrow's keys, plus, for a
// live wallet pass, the SHA-256 of its Apple code and its Google TOTP key (both
// already bound to one pass epoch). The SQL functions _exos_door_day_key /
// _exos_door_code_mac / _exos_door_keys are the source of truth; this file
// mirrors them and doorKeys.test.ts pins both to the same vectors.

import {
  appleWalletCode, googleTotpKey, parseWalletCode, totp, totpStep, TOTP_WINDOW, type WalletVerifyResult,
} from "./wallet/codes.ts";
import { fromHex, hmac, sha256, timingSafeEqual, toBase64Url, toHex, utf8 } from "./wallet/bytes.ts";

export const BUCKET_MS = 30_000;
export const BUCKETS_PER_DAY = 2880;

/** The UTC day a 30-second bucket falls in. */
export const doorDay = (bucket: number): number => Math.floor(bucket / BUCKETS_PER_DAY);

export async function doorDayKey(ticketId: string, secret: string, day: number): Promise<string> {
  if (!secret) throw new Error("doorDayKey: empty secret");
  return toBase64Url(await hmac("SHA-256", utf8(secret), utf8(`door-day:${ticketId}:${day}`)));
}

export async function doorCodeMac(ticketId: string, ownerId: string, bucket: number, dayKey: string): Promise<string> {
  return toBase64Url(await hmac("SHA-256", utf8(dayKey), utf8(`${ticketId}:${ownerId}:${bucket}`)));
}

/** What the door holds for one ticket. `d` maps a day number to its key. */
export interface DoorKeys {
  d: Record<string, string>;
  /** SHA-256 hex of the live Apple Wallet code. */
  wa?: string;
  /** Hex of the live Google Wallet TOTP key. */
  wg?: string;
  /** The live pass epoch. */
  we?: number;
}

export function parseDoorKeys(v: unknown): DoorKeys | null {
  const o = typeof v === "string" ? safeJson(v) : v;
  if (!o || typeof o !== "object") return null;
  const r = o as Record<string, unknown>;
  const d: Record<string, string> = {};
  if (r.d && typeof r.d === "object") {
    for (const [k, val] of Object.entries(r.d as Record<string, unknown>)) {
      if (/^[0-9]{1,7}$/.test(k) && typeof val === "string" && val) d[k] = val;
    }
  }
  const out: DoorKeys = { d };
  if (typeof r.wa === "string" && /^[0-9a-f]{64}$/.test(r.wa)) out.wa = r.wa;
  if (typeof r.wg === "string" && /^[0-9a-f]{40}$/.test(r.wg)) out.wg = r.wg;
  if (typeof r.we === "number" && Number.isInteger(r.we)) out.we = r.we;
  return out;
}

function safeJson(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

/** The keys a door gets at `nowMs`, derived from the secret. Used by the
 *  door when it talks to a database without the per-day roster (it still
 *  receives the raw secret there) and by the tests. */
export async function doorKeysFromSecret(
  ticketId: string,
  ownerId: string,
  secret: string,
  nowMs: number,
  walletEpoch?: number | null,
): Promise<DoorKeys> {
  const today = doorDay(Math.floor(nowMs / BUCKET_MS));
  const d: Record<string, string> = {};
  for (const day of [today - 1, today, today + 1]) d[String(day)] = await doorDayKey(ticketId, secret, day);
  const out: DoorKeys = { d };
  if (walletEpoch != null) {
    out.we = walletEpoch;
    out.wa = toHex(await sha256(utf8(await appleWalletCode(ticketId, ownerId, secret, walletEpoch))));
    out.wg = toHex(await googleTotpKey(ticketId, ownerId, secret, walletEpoch));
  }
  return out;
}

/** The door's local check of a W- wallet code against the keys it holds. The
 *  server also checks the pass is still live (a reissued pass is a conflict). */
export async function verifyWalletWithKeys(
  payload: string,
  keys: DoorKeys | null,
  opts: { now?: number } = {},
): Promise<WalletVerifyResult & { noKey?: boolean }> {
  const code = parseWalletCode(payload);
  if (!code) return { ok: false, reason: "malformed" };
  if (!keys || keys.we == null || keys.we !== code.epoch) return { ok: false, reason: "signature-mismatch", code, noKey: keys?.we == null };
  if (code.kind === "apple") {
    if (!keys.wa) return { ok: false, reason: "signature-mismatch", code, noKey: true };
    const got = toHex(await sha256(utf8(payload)));
    return timingSafeEqual(got, keys.wa) ? { ok: true, code } : { ok: false, reason: "signature-mismatch", code };
  }
  if (!keys.wg) return { ok: false, reason: "signature-mismatch", code, noKey: true };
  const key = fromHex(keys.wg);
  const cur = totpStep(opts.now ?? Date.now());
  let hit = false;
  for (let s = cur - TOTP_WINDOW; s <= cur + TOTP_WINDOW; s++) {
    if (timingSafeEqual(await totp(key, s), code.totp)) hit = true;
  }
  return hit ? { ok: true, code } : { ok: false, reason: "signature-mismatch", code };
}
