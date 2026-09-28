// Solid-colour PNGs for the pass's required icon / logo images, generated so
// the bundle has no binary assets in the repo. Stored (uncompressed) deflate
// blocks inside zlib; tiny images, so size doesn't matter. Swap in brand art
// later by passing your own images to buildPkpass.

import { concat } from "./bytes.ts";
import { crc32 } from "./zip.ts";

function be32(n: number): Uint8Array {
  return Uint8Array.of((n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const t = new TextEncoder().encode(type);
  const body = concat([t, data]);
  return concat([be32(data.length), body, be32(crc32(body))]);
}

function adler32(data: Uint8Array): number {
  let a = 1, b = 0;
  for (let i = 0; i < data.length; i++) {
    a = (a + data[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

function zlibStored(raw: Uint8Array): Uint8Array {
  const blocks: Uint8Array[] = [Uint8Array.of(0x78, 0x01)];
  for (let o = 0; o < raw.length || o === 0; o += 65535) {
    const part = raw.slice(o, o + 65535);
    const last = o + 65535 >= raw.length ? 1 : 0;
    blocks.push(Uint8Array.of(last, part.length & 0xff, part.length >>> 8, ~part.length & 0xff, (~part.length >>> 8) & 0xff));
    blocks.push(part);
    if (last) break;
  }
  blocks.push(be32(adler32(raw)));
  return concat(blocks);
}

/** A w×h PNG of one RGB colour ("#rrggbb"). */
export function solidPng(w: number, h: number, hex: string): Uint8Array {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  const [r, g, b] = m ? [1, 2, 3].map((i) => parseInt(m[i], 16)) : [0, 0, 0];
  const row = new Uint8Array(1 + w * 3);
  for (let x = 0; x < w; x++) row.set([r, g, b], 1 + x * 3);
  const raw = new Uint8Array(row.length * h);
  for (let y = 0; y < h; y++) raw.set(row, y * row.length);
  const ihdr = concat([be32(w), be32(h), Uint8Array.of(8, 2, 0, 0, 0)]);
  return concat([
    Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlibStored(raw)),
    chunk("IEND", new Uint8Array(0)),
  ]);
}
