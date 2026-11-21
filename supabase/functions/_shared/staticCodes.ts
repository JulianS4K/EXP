// Static door codes (mig 20261121153000, docs/wallet.md "Static codes").
//
// A ticket issued with code_mode 'static' (the free tier: an event whose size
// is at or under the free-tier cutoff when the ticket is issued) shows one
// code that never changes, so it can be printed or attached as a PDF:
//
//   code = S-{ticket}:{32 base32 characters}
//   tail = base32(HMAC-SHA256(barcode_secret, "static:{ticket}:{owner}")[0..20])
//
// 160 bits of the MAC, RFC 4648 base32 (A-Z, 2-7), no padding. Nothing new is
// stored: the code is derived from the ticket's barcode_secret (already read-
// gated, mig 20260702123000) and its holder, so it changes when the ticket is
// transferred (new owner, and the claim rotates the secret) or its secret is
// reissued, and dies with the ticket on a refund / void (status). The door's
// offline roster gets only the code's SHA-256 (door_keys.s), so a leaked
// roster can't make a code: same property as the Apple wallet code (`wa`)
// and the print code (`p`).
//
// The "static:" prefix keeps this MAC apart from every other one made with
// the secret (T- "{ticket}:{owner}:{bucket}", "door-day:", "wallet-a:",
// "wallet-g:"). The S- prefix and the two-part shape keep it apart from the
// four-part T- / A- codes: neither parses as the other (barcode.test.ts).
//
// The SQL functions _exos_static_code / _exos_static_code_canon are the
// source of truth; this file mirrors them for the holder's app, the door's
// local check and the tests (staticCodes.test.ts pins both to one vector).
// Pure TypeScript: Deno and vitest both load it.

import { hmac, sha256, toHex, utf8 } from "./wallet/bytes.ts";
import { constantTimeEqual } from "./constantTime.ts";

/** The two ways a ticket's door code can work, fixed per ticket at issuance. */
export type CodeMode = "static" | "rotating";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** A canonical static code: upper-case S, lower-case ticket id, upper-case tail. */
export const STATIC_CODE_RE = /^S-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([A-Z2-7]{32})$/;

/** RFC 4648 base32, no padding (the input is a multiple of 5 bytes here). */
export function base32(bytes: Uint8Array): string {
  let out = "";
  let buf = 0;
  let bits = 0;
  for (const b of bytes) {
    buf = (buf << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += ALPHABET[(buf >>> (bits - 5)) & 31];
      bits -= 5;
    }
    buf &= (1 << bits) - 1;
  }
  if (bits > 0) out += ALPHABET[(buf << (5 - bits)) & 31];
  return out;
}

/** The ticket's static code for its current holder. */
export async function staticCode(ticketId: string, ownerId: string | null | undefined, secret: string): Promise<string> {
  if (!secret) throw new Error("staticCode: empty secret");
  const id = ticketId.toLowerCase();
  const mac = await hmac("SHA-256", utf8(secret), utf8(`static:${id}:${(ownerId ?? "").toLowerCase()}`));
  return `S-${id}:${base32(mac.slice(0, 20))}`;
}

/** A read code in canonical form (scanners that change case, stray spaces), or null. */
export function canonicalStaticCode(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const m = /^[Ss]-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}):([A-Za-z2-7]{32})$/.exec(raw.trim());
  return m ? `S-${m[1].toLowerCase()}:${m[2].toUpperCase()}` : null;
}

/** Is this a static code's shape (either case)? */
export const isStaticCode = (raw: string | null | undefined): boolean => canonicalStaticCode(raw) !== null;

/** The ticket id inside a static code, or null. */
export function staticCodeTicketId(raw: string | null | undefined): string | null {
  const c = canonicalStaticCode(raw);
  return c ? c.slice(2, 38) : null;
}

/** What the door roster holds: SHA-256 hex of the canonical code (door_keys.s). */
export async function staticCodeHash(raw: string): Promise<string | null> {
  const c = canonicalStaticCode(raw);
  return c ? toHex(await sha256(utf8(c))) : null;
}

/** The door's local check: the code's hash against the roster's `s`. */
export async function verifyStaticWithKeys(raw: string, keys: { s?: string } | null | undefined): Promise<{ ok: boolean; noKey?: boolean }> {
  if (!keys?.s) return { ok: false, noKey: true };
  const h = await staticCodeHash(raw);
  return { ok: !!h && constantTimeEqual(h, keys.s) };
}
