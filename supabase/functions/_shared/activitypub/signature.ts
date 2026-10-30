// HTTP Signatures (draft-cavage-http-signatures-12, RSA-SHA256) for
// ActivityPub delivery and inbox verification (docs/federation.md).
//
// Pure WebCrypto: no Deno or Supabase imports, so vitest loads it too
// (src/lib/activitypub.test.ts).
//
// Outbound: signRequest() adds Host, Date, Digest (SHA-256 of the body) and a
// Signature over "(request-target) host date digest" (GET: no digest), with
// algorithm="rsa-sha256", which is what Mastodon and Lemmy both accept.
//
// Inbound: verifyRequest() requires (request-target), host and date to be
// signed (plus digest on POST), the Date within maxSkewSeconds of now, the
// Digest to match the body, and the RSA signature to verify against the key
// the caller fetched for keyId. "hs2019" is accepted as a label for the same
// RSA-SHA256 (Lemmy's signer sends it); every other algorithm is refused.

export type HeaderBag = Record<string, string>;

export interface ParsedSignature {
  keyId: string;
  algorithm: string | null;
  headers: string[];
  signature: string;
}

const enc = new TextEncoder();

function subtle(): SubtleCrypto {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (!c?.subtle) throw new Error("WebCrypto is not available");
  return c.subtle;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

export function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/\s+/g, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toBytes(body: string | Uint8Array | null | undefined): Uint8Array {
  if (body == null) return new Uint8Array(0);
  return typeof body === "string" ? enc.encode(body) : body;
}

/** "SHA-256=<base64>" for a body. */
export async function digestHeader(body: string | Uint8Array | null | undefined): Promise<string> {
  const hash = new Uint8Array(await subtle().digest("SHA-256", toBytes(body) as BufferSource));
  return `SHA-256=${bytesToBase64(hash)}`;
}

// ── PEM ─────────────────────────────────────────────────────────────────────

function pemBody(pem: string, label: string): Uint8Array {
  const m = pem.match(new RegExp(`-----BEGIN ${label}-----([\\s\\S]+?)-----END ${label}-----`));
  if (!m) throw new Error(`expected a ${label} PEM`);
  return base64ToBytes(m[1]);
}

function toPem(der: ArrayBuffer, label: string): string {
  const b64 = bytesToBase64(new Uint8Array(der));
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

const RSA = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;

export function importPublicKeyPem(pem: string): Promise<CryptoKey> {
  return subtle().importKey("spki", pemBody(pem, "PUBLIC KEY") as BufferSource, RSA, false, ["verify"]);
}

export function importPrivateKeyPem(pem: string): Promise<CryptoKey> {
  return subtle().importKey("pkcs8", pemBody(pem, "PRIVATE KEY") as BufferSource, RSA, false, ["sign"]);
}

/** A new RSA-2048 key pair for an actor: SPKI and PKCS#8 PEM. */
export async function generateActorKeyPair(): Promise<{ publicPem: string; privatePem: string }> {
  const pair = await subtle().generateKey(
    { ...RSA, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const spki = await subtle().exportKey("spki", pair.publicKey);
  const pkcs8 = await subtle().exportKey("pkcs8", pair.privateKey);
  return { publicPem: toPem(spki, "PUBLIC KEY"), privatePem: toPem(pkcs8, "PRIVATE KEY") };
}

// ── signing string ──────────────────────────────────────────────────────────

/** The draft-cavage signing string for these (lowercase) header names. */
export function signingString(method: string, pathWithQuery: string, headers: HeaderBag, names: string[]): string {
  const lower: HeaderBag = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  return names.map((n) => {
    const name = n.toLowerCase();
    if (name === "(request-target)") return `(request-target): ${method.toLowerCase()} ${pathWithQuery}`;
    const v = lower[name];
    if (v === undefined) throw new Error(`header ${name} is not present`);
    return `${name}: ${v.trim()}`;
  }).join("\n");
}

/** Parse a Signature header (or the params of "Authorization: Signature …"). */
export function parseSignatureHeader(raw: string | null | undefined): ParsedSignature | null {
  if (!raw || raw.length > 4096) return null;
  const s = raw.replace(/^Signature\s+/i, "");
  const out: Record<string, string> = {};
  const re = /([a-zA-Z]+)="([^"]*)"\s*(?:,\s*|$)/gy;
  let m: RegExpExecArray | null;
  let last = 0;
  while ((m = re.exec(s)) !== null) {
    out[m[1].toLowerCase()] = m[2];
    last = re.lastIndex;
  }
  if (last !== s.length || !out.keyid || !out.signature) return null;
  return {
    keyId: out.keyid,
    algorithm: out.algorithm ?? null,
    headers: (out.headers ?? "date").toLowerCase().split(/\s+/).filter(Boolean),
    signature: out.signature,
  };
}

// ── outbound ────────────────────────────────────────────────────────────────

export interface SignOptions {
  method: "GET" | "POST";
  url: string;
  body?: string | null;
  keyId: string;
  privateKey: CryptoKey | string;
  headers?: HeaderBag;
  date?: Date;
}

/** Headers to send: the given ones + Host, Date, Digest (POST) and Signature. */
export async function signRequest(o: SignOptions): Promise<HeaderBag> {
  const u = new URL(o.url);
  const key = typeof o.privateKey === "string" ? await importPrivateKeyPem(o.privateKey) : o.privateKey;
  const headers: HeaderBag = { ...(o.headers ?? {}) };
  headers.host = u.host;
  headers.date = (o.date ?? new Date()).toUTCString();
  const names = ["(request-target)", "host", "date"];
  if (o.method === "POST") {
    headers.digest = await digestHeader(o.body ?? "");
    names.push("digest");
    if (headers["content-type"]) names.push("content-type");
  }
  const str = signingString(o.method, u.pathname + u.search, headers, names);
  const sig = new Uint8Array(await subtle().sign(RSA, key, enc.encode(str) as BufferSource));
  headers.signature =
    `keyId="${o.keyId}",algorithm="rsa-sha256",headers="${names.join(" ")}",signature="${bytesToBase64(sig)}"`;
  return headers;
}

// ── inbound ─────────────────────────────────────────────────────────────────

export interface VerifyInput {
  method: string;
  /** Path + query as the sender addressed it (behind a proxy: the public path). */
  pathWithQuery: string;
  headers: HeaderBag;
  body: string | Uint8Array | null;
  publicKey: CryptoKey | string;
  now?: Date;
  maxSkewSeconds?: number;
  /** Already parsed (the caller needs keyId first to fetch the key). */
  parsed?: ParsedSignature | null;
}

// One flat shape: the Node build is not strict, so a discriminated union would not narrow there.
export type VerifyResult = { ok: boolean; keyId?: string; reason?: string };

export async function verifyRequest(v: VerifyInput): Promise<VerifyResult> {
  const lower: HeaderBag = {};
  for (const [k, val] of Object.entries(v.headers)) lower[k.toLowerCase()] = val;
  const sig = v.parsed ?? parseSignatureHeader(lower.signature ?? lower.authorization);
  if (!sig) return { ok: false, reason: "no signature" };
  const alg = (sig.algorithm ?? "hs2019").toLowerCase();
  if (alg !== "rsa-sha256" && alg !== "hs2019") return { ok: false, reason: `algorithm ${alg} not accepted` };

  const need = ["(request-target)", "host", "date"];
  if (v.method.toUpperCase() === "POST") need.push("digest");
  for (const n of need) {
    if (!sig.headers.includes(n)) return { ok: false, reason: `${n} not signed` };
  }

  const date = Date.parse(lower.date ?? "");
  if (!Number.isFinite(date)) return { ok: false, reason: "bad date" };
  const skew = Math.abs((v.now ?? new Date()).getTime() - date) / 1000;
  if (skew > (v.maxSkewSeconds ?? 3600)) return { ok: false, reason: "date out of range" };

  if (v.method.toUpperCase() === "POST") {
    const want = await digestHeader(v.body);
    // A Digest header may list several algorithms; ours must match exactly.
    const got = (lower.digest ?? "").split(",").map((x) => x.trim()).find((x) => /^sha-256=/i.test(x));
    if (!got || got.replace(/^sha-256=/i, "SHA-256=") !== want) return { ok: false, reason: "digest mismatch" };
  }

  let str: string;
  try {
    str = signingString(v.method, v.pathWithQuery, lower, sig.headers);
  } catch (e) {
    return { ok: false, reason: String((e as Error).message) };
  }
  let key: CryptoKey;
  try {
    key = typeof v.publicKey === "string" ? await importPublicKeyPem(v.publicKey) : v.publicKey;
  } catch {
    return { ok: false, reason: "bad public key" };
  }
  let sigBytes: Uint8Array;
  try {
    sigBytes = base64ToBytes(sig.signature);
  } catch {
    return { ok: false, reason: "bad signature encoding" };
  }
  const ok = await subtle().verify(RSA, key, sigBytes as BufferSource, enc.encode(str) as BufferSource);
  return ok ? { ok: true, keyId: sig.keyId } : { ok: false, reason: "signature does not verify" };
}
