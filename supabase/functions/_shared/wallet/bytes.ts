// Byte helpers for the wallet builders. Pure, WebCrypto only, so the same file
// runs in Deno (edge functions), Node (vitest) and the browser (door scanner).

export const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

export function concat(parts: Uint8Array[]): Uint8Array {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** A standalone ArrayBuffer copy (WebCrypto's BufferSource typing wants one). */
export function ab(u8: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(u8.length);
  new Uint8Array(out).set(u8);
  return out;
}

export function toHex(u8: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u8.length; i++) s += u8[i].toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || /[^0-9a-f]/i.test(hex)) throw new Error("bad hex");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function toBase64(u8: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin);
}

export function fromBase64(b64: string): Uint8Array {
  const bin = atob(b64.replace(/\s+/g, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export const toBase64Url = (u8: Uint8Array): string =>
  toBase64(u8).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export function fromBase64Url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  return fromBase64(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

export async function sha1(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-1", ab(data)));
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", ab(data)));
}

export async function hmac(hash: "SHA-1" | "SHA-256", key: Uint8Array, msg: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", ab(key), { name: "HMAC", hash }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, ab(msg)));
}

/** Compare without an early exit on the first differing byte. */
export function timingSafeEqual(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export function randomBytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  crypto.getRandomValues(out);
  return out;
}
