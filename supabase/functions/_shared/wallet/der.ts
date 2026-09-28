// Just enough ASN.1 DER to write a PKCS#7 / CMS SignedData and read the
// issuer + serial out of an X.509 certificate. No dependencies.

import { concat, fromBase64, toBase64 } from "./bytes.ts";

export function tlv(tag: number, content: Uint8Array): Uint8Array {
  const n = content.length;
  let len: Uint8Array;
  if (n < 0x80) len = Uint8Array.of(n);
  else {
    const bytes: number[] = [];
    for (let v = n; v > 0; v = Math.floor(v / 256)) bytes.unshift(v & 0xff);
    len = Uint8Array.of(0x80 | bytes.length, ...bytes);
  }
  return concat([Uint8Array.of(tag), len, content]);
}

export const seq = (...parts: Uint8Array[]): Uint8Array => tlv(0x30, concat(parts));

/** DER SET OF: members sorted by their encodings. */
export function setOf(...parts: Uint8Array[]): Uint8Array {
  const sorted = [...parts].sort((a, b) => {
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i];
    return a.length - b.length;
  });
  return tlv(0x31, concat(sorted));
}

export const nullDer = (): Uint8Array => Uint8Array.of(0x05, 0x00);
export const octets = (b: Uint8Array): Uint8Array => tlv(0x04, b);
/** [n] EXPLICIT / constructed context tag. */
export const ctx = (n: number, content: Uint8Array): Uint8Array => tlv(0xa0 | n, content);

export function int(v: number | Uint8Array): Uint8Array {
  let bytes: number[];
  if (typeof v === "number") {
    bytes = [];
    let x = v;
    do {
      bytes.unshift(x & 0xff);
      x = Math.floor(x / 256);
    } while (x > 0);
  } else {
    bytes = [...v];
    while (bytes.length > 1 && bytes[0] === 0 && (bytes[1] & 0x80) === 0) bytes.shift();
  }
  if (bytes[0] & 0x80) bytes.unshift(0);
  return tlv(0x02, Uint8Array.from(bytes));
}

export function oid(dotted: string): Uint8Array {
  const arcs = dotted.split(".").map(Number);
  const out: number[] = [arcs[0] * 40 + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const chunk: number[] = [];
    let v = arc;
    do {
      chunk.unshift(v & 0x7f);
      v = Math.floor(v / 128);
    } while (v > 0);
    for (let i = 0; i < chunk.length - 1; i++) chunk[i] |= 0x80;
    out.push(...chunk);
  }
  return tlv(0x06, Uint8Array.from(out));
}

/** UTCTime (years 1950–2049), as CMS signingTime requires. */
export function utcTime(d: Date): Uint8Array {
  const p = (n: number) => String(n).padStart(2, "0");
  const s = p(d.getUTCFullYear() % 100) + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) +
    p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z";
  return tlv(0x17, new TextEncoder().encode(s));
}

export interface Node {
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset of the first content byte. */
  body: number;
  /** Offset just past the content. */
  end: number;
}

export function read(buf: Uint8Array, at = 0): Node {
  const tag = buf[at];
  let i = at + 1;
  let len = buf[i++];
  if (len === undefined || tag === undefined) throw new Error("der: truncated");
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new Error("der: bad length");
    len = 0;
    for (let k = 0; k < n; k++) len = len * 256 + buf[i++];
  }
  if (i + len > buf.length) throw new Error("der: truncated");
  return { tag, start: at, body: i, end: i + len };
}

export function children(buf: Uint8Array, node: Node): Node[] {
  const out: Node[] = [];
  for (let at = node.body; at < node.end;) {
    const c = read(buf, at);
    out.push(c);
    at = c.end;
  }
  return out;
}

export const bytesOf = (buf: Uint8Array, n: Node): Uint8Array => buf.slice(n.start, n.end);
export const contentOf = (buf: Uint8Array, n: Node): Uint8Array => buf.slice(n.body, n.end);

/** The issuer Name and serialNumber (both as whole DER elements) of a certificate. */
export function certIssuerAndSerial(cert: Uint8Array): { issuer: Uint8Array; serial: Uint8Array } {
  const root = read(cert);
  const tbs = children(cert, root)[0];
  const f = children(cert, tbs);
  const k = f[0].tag === 0xa0 ? 1 : 0; // optional [0] version
  return { serial: bytesOf(cert, f[k]), issuer: bytesOf(cert, f[k + 2]) };
}

/** Every PEM block with the given label(s), as DER. */
export function pemBlocks(pem: string, labels?: string[]): { label: string; der: Uint8Array }[] {
  const out: { label: string; der: Uint8Array }[] = [];
  const re = /-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----/g;
  for (let m = re.exec(pem); m; m = re.exec(pem)) {
    if (!labels || labels.includes(m[1])) out.push({ label: m[1], der: fromBase64(m[2]) });
  }
  return out;
}

export function toPem(label: string, der: Uint8Array): string {
  const b64 = toBase64(der).replace(/(.{64})/g, "$1\n").replace(/\n$/, "");
  return `-----BEGIN ${label}-----\n${b64}\n-----END ${label}-----\n`;
}

export const OID = {
  rsaEncryption: "1.2.840.113549.1.1.1",
  sha256WithRSA: "1.2.840.113549.1.1.11",
  sha256: "2.16.840.1.101.3.4.2.1",
  data: "1.2.840.113549.1.7.1",
  signedData: "1.2.840.113549.1.7.2",
  contentType: "1.2.840.113549.1.9.3",
  messageDigest: "1.2.840.113549.1.9.4",
  signingTime: "1.2.840.113549.1.9.5",
};
