// A minimal ZIP writer (stored entries, no compression) for .pkpass bundles.
// Passes are a few KB, so compression buys nothing and keeps this dependency-free.

import { concat, utf8 } from "./bytes.ts";

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function le(n: number, bytes: 2 | 4): Uint8Array {
  const out = new Uint8Array(bytes);
  for (let i = 0; i < bytes; i++) out[i] = (n >>> (8 * i)) & 0xff;
  return out;
}

function dosTime(d: Date): { time: number; date: number } {
  return {
    time: (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | Math.floor(d.getUTCSeconds() / 2),
    date: ((Math.max(1980, d.getUTCFullYear()) - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate(),
  };
}

export interface ZipEntry {
  name: string;
  data: Uint8Array;
}

export function zipStore(entries: ZipEntry[], at: Date = new Date()): Uint8Array {
  const { time, date } = dosTime(at);
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = utf8(e.name);
    const crc = crc32(e.data);
    const common = [
      le(20, 2), le(0x0800, 2), le(0, 2), le(time, 2), le(date, 2),
      le(crc, 4), le(e.data.length, 4), le(e.data.length, 4), le(name.length, 2), le(0, 2),
    ];
    const local = concat([le(0x04034b50, 4), ...common, name, e.data]);
    centrals.push(concat([
      le(0x02014b50, 4), le(20, 2), ...common,
      le(0, 2), le(0, 2), le(0, 2), le(0, 4), le(offset, 4), name,
    ]));
    locals.push(local);
    offset += local.length;
  }
  const cd = concat(centrals);
  const end = concat([
    le(0x06054b50, 4), le(0, 2), le(0, 2), le(entries.length, 2), le(entries.length, 2),
    le(cd.length, 4), le(offset, 4), le(0, 2),
  ]);
  return concat([...locals, cd, end]);
}

/** Read back a stored-only zip (tests, and a sanity check before sending). */
export function unzipStore(buf: Uint8Array): ZipEntry[] {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) {
    if (dv.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("zip: no end record");
  const n = dv.getUint16(eocd + 10, true);
  let p = dv.getUint32(eocd + 16, true);
  const out: ZipEntry[] = [];
  for (let k = 0; k < n; k++) {
    if (dv.getUint32(p, true) !== 0x02014b50) throw new Error("zip: bad central header");
    const method = dv.getUint16(p + 10, true);
    const size = dv.getUint32(p + 20, true);
    const nameLen = dv.getUint16(p + 28, true);
    const extraLen = dv.getUint16(p + 30, true);
    const commentLen = dv.getUint16(p + 32, true);
    const localAt = dv.getUint32(p + 42, true);
    const name = new TextDecoder().decode(buf.slice(p + 46, p + 46 + nameLen));
    if (method !== 0) throw new Error("zip: only stored entries");
    const lNameLen = dv.getUint16(localAt + 26, true);
    const lExtraLen = dv.getUint16(localAt + 28, true);
    const start = localAt + 30 + lNameLen + lExtraLen;
    out.push({ name, data: buf.slice(start, start + size) });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}
