// A small QR Code encoder for printed tickets (docs/wallet.md "Printed
// tickets"). The printed page and PDF draw the code themselves, so the edge
// function needs no QR library and no image service sees a door code.
//
// Scope: byte mode, error correction level M (15 % of the symbol can be
// damaged or smudged), versions 1-6 (up to 106 bytes; a print code is 61).
// Versions 7+ need version-information blocks, which a print code never
// reaches, so they are refused rather than half supported.
//
// Written from ISO/IEC 18004: data bits, Reed-Solomon over GF(256) with the
// 0x11D polynomial, block interleaving, the function patterns, the zigzag
// data placement, the eight masks scored by the four penalty rules, and the
// BCH-coded format bits. src/lib/printQr.test.ts decodes the output with
// zxing (a separate implementation) to prove it scans.
//
// Pure TypeScript, imported by vitest.

/** modules[y][x], true = dark. Square, (17 + 4 × version) a side, no quiet zone. */
export type QrMatrix = boolean[][];

// Level M, versions 1-6: ECC codewords per block, and the number of blocks.
const ECC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16];
const BLOCKS = [0, 1, 1, 1, 2, 2, 4];
const MAX_VERSION = 6;

function rawDataModules(ver: number): number {
  let n = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const align = Math.floor(ver / 7) + 2;
    n -= (25 * align - 10) * align - 55;
  }
  return n;
}

const dataCodewords = (ver: number) => Math.floor(rawDataModules(ver) / 8) - ECC_PER_BLOCK[ver] * BLOCKS[ver];

/** The most bytes a level-M symbol up to version 6 holds (byte mode). */
export const QR_MAX_BYTES = dataCodewords(MAX_VERSION) - 2;

// -- Reed-Solomon ----------------------------------------------------------------

function gfMul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z & 0xff;
}

function rsDivisor(degree: number): number[] {
  const out = new Array<number>(degree).fill(0);
  out[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      out[j] = gfMul(out[j], root);
      if (j + 1 < degree) out[j] ^= out[j + 1];
    }
    root = gfMul(root, 0x02);
  }
  return out;
}

function rsRemainder(data: number[], divisor: number[]): number[] {
  const out = new Array<number>(divisor.length).fill(0);
  for (const b of data) {
    const factor = b ^ (out.shift() as number);
    out.push(0);
    divisor.forEach((coef, i) => {
      out[i] ^= gfMul(coef, factor);
    });
  }
  return out;
}

// -- Codewords -----------------------------------------------------------------------

function codewords(bytes: Uint8Array, ver: number): number[] {
  const capacityBits = dataCodewords(ver) * 8;
  const bits: number[] = [];
  const put = (v: number, n: number) => {
    for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1);
  };
  put(0b0100, 4); // byte mode
  put(bytes.length, 8); // character count (8 bits up to version 9)
  for (const b of bytes) put(b, 8);
  put(0, Math.min(4, capacityBits - bits.length)); // terminator
  put(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < capacityBits; pad ^= 0xec ^ 0x11) put(pad, 8);
  const data: number[] = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));

  // Split into blocks, add each block's ECC, interleave.
  const numBlocks = BLOCKS[ver];
  const eccLen = ECC_PER_BLOCK[ver];
  const rawCodewords = Math.floor(rawDataModules(ver) / 8);
  const numShort = numBlocks - (rawCodewords % numBlocks);
  const shortLen = Math.floor(rawCodewords / numBlocks);
  const divisor = rsDivisor(eccLen);
  const blocks: number[][] = [];
  for (let i = 0, k = 0; i < numBlocks; i++) {
    const len = shortLen - eccLen + (i < numShort ? 0 : 1);
    const dat = data.slice(k, k + len);
    k += len;
    const ecc = rsRemainder(dat, divisor);
    if (i < numShort) dat.push(-1); // placeholder so every block has the same length
    blocks.push(dat.concat(ecc));
  }
  const out: number[] = [];
  for (let i = 0; i < blocks[0].length; i++) {
    blocks.forEach((b, j) => {
      if (i !== shortLen - eccLen || j >= numShort) out.push(b[i]);
    });
  }
  return out;
}

// -- The symbol --------------------------------------------------------------------------

class Symbol {
  readonly size: number;
  readonly mods: boolean[][];
  readonly fn: boolean[][];

  constructor(readonly ver: number) {
    this.size = ver * 4 + 17;
    this.mods = Array.from({ length: this.size }, () => new Array<boolean>(this.size).fill(false));
    this.fn = Array.from({ length: this.size }, () => new Array<boolean>(this.size).fill(false));
    this.drawFunctionPatterns();
  }

  private set(x: number, y: number, dark: boolean): void {
    this.mods[y][x] = dark;
    this.fn[y][x] = true;
  }

  private drawFunctionPatterns(): void {
    const n = this.size;
    for (let i = 0; i < n; i++) {
      this.set(6, i, i % 2 === 0);
      this.set(i, 6, i % 2 === 0);
    }
    this.finder(3, 3);
    this.finder(n - 4, 3);
    this.finder(3, n - 4);
    const pos = this.alignmentPositions();
    for (let i = 0; i < pos.length; i++) {
      for (let j = 0; j < pos.length; j++) {
        const corner = (i === 0 && j === 0) || (i === 0 && j === pos.length - 1) || (i === pos.length - 1 && j === 0);
        if (!corner) this.alignment(pos[i], pos[j]);
      }
    }
    this.formatBits(0); // reserve the format areas; redrawn with the real mask
  }

  private finder(cx: number, cy: number): void {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        const x = cx + dx;
        const y = cy + dy;
        if (x >= 0 && x < this.size && y >= 0 && y < this.size) this.set(x, y, d !== 2 && d !== 4);
      }
    }
  }

  private alignment(cx: number, cy: number): void {
    for (let dy = -2; dy <= 2; dy++) {
      for (let dx = -2; dx <= 2; dx++) this.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  }

  private alignmentPositions(): number[] {
    if (this.ver === 1) return [];
    const count = Math.floor(this.ver / 7) + 2;
    const step = Math.ceil((this.ver * 4 + 4) / (count * 2 - 2)) * 2;
    const out = [6];
    for (let p = this.size - 7; out.length < count; p -= step) out.splice(1, 0, p);
    return out;
  }

  /** Level M (format bits 00) and the mask, BCH(15,5), XOR 0x5412. */
  formatBits(mask: number): void {
    const data = (0 << 3) | mask;
    let rem = data;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const bits = ((data << 10) | rem) ^ 0x5412;
    const bit = (i: number) => ((bits >>> i) & 1) !== 0;
    const n = this.size;
    for (let i = 0; i <= 5; i++) this.set(8, i, bit(i));
    this.set(8, 7, bit(6));
    this.set(8, 8, bit(7));
    this.set(7, 8, bit(8));
    for (let i = 9; i < 15; i++) this.set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) this.set(n - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) this.set(8, n - 15 + i, bit(i));
    this.set(8, n - 8, true); // the dark module
  }

  placeData(cw: number[]): void {
    let i = 0;
    const n = this.size;
    for (let right = n - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let vert = 0; vert < n; vert++) {
        for (let j = 0; j < 2; j++) {
          const x = right - j;
          const upward = ((right + 1) & 2) === 0;
          const y = upward ? n - 1 - vert : vert;
          if (!this.fn[y][x] && i < cw.length * 8) {
            this.mods[y][x] = ((cw[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0;
            i++;
          }
        }
      }
    }
  }

  applyMask(mask: number): void {
    for (let y = 0; y < this.size; y++) {
      for (let x = 0; x < this.size; x++) {
        if (this.fn[y][x]) continue;
        let flip: boolean;
        switch (mask) {
          case 0: flip = (x + y) % 2 === 0; break;
          case 1: flip = y % 2 === 0; break;
          case 2: flip = x % 3 === 0; break;
          case 3: flip = (x + y) % 3 === 0; break;
          case 4: flip = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
          case 5: flip = ((x * y) % 2) + ((x * y) % 3) === 0; break;
          case 6: flip = (((x * y) % 2) + ((x * y) % 3)) % 2 === 0; break;
          default: flip = (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
        }
        if (flip) this.mods[y][x] = !this.mods[y][x];
      }
    }
  }

  /** The four penalty rules (lower scans better). */
  penalty(): number {
    const n = this.size;
    const m = this.mods;
    let score = 0;
    const lines: boolean[][] = [];
    for (let y = 0; y < n; y++) lines.push(m[y]);
    for (let x = 0; x < n; x++) lines.push(m.map((row) => row[x]));
    const finderLike = [true, false, true, true, true, false, true];
    for (const line of lines) {
      // Rule 1: runs of five or more.
      let run = 1;
      for (let i = 1; i <= n; i++) {
        if (i < n && line[i] === line[i - 1]) run++;
        else {
          if (run >= 5) score += 3 + (run - 5);
          run = 1;
        }
      }
      // Rule 3: 1:1:3:1:1 with four light modules on one side.
      for (let i = 0; i + 7 <= n; i++) {
        if (!finderLike.every((v, k) => line[i + k] === v)) continue;
        const lightBefore = i >= 4 && [1, 2, 3, 4].every((k) => !line[i - k]);
        const lightAfter = i + 11 <= n && [7, 8, 9, 10].every((k) => !line[i + k]);
        if (lightBefore || lightAfter) score += 40;
      }
    }
    // Rule 2: 2×2 blocks of one colour.
    for (let y = 0; y < n - 1; y++) {
      for (let x = 0; x < n - 1; x++) {
        const c = m[y][x];
        if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) score += 3;
      }
    }
    // Rule 4: balance of dark and light.
    let dark = 0;
    for (const row of m) for (const v of row) if (v) dark++;
    const total = n * n;
    score += (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
    return score;
  }
}

/** The QR symbol for `text` (UTF-8, byte mode, level M). Throws past QR_MAX_BYTES. */
export function qrMatrix(text: string): QrMatrix {
  const bytes = new TextEncoder().encode(text);
  let ver = 1;
  while (ver <= MAX_VERSION && bytes.length + 2 > dataCodewords(ver)) ver++;
  if (ver > MAX_VERSION) throw new Error(`qrMatrix: at most ${QR_MAX_BYTES} bytes`);
  const cw = codewords(bytes, ver);
  let best: Symbol | null = null;
  let bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    const s = new Symbol(ver);
    s.placeData(cw);
    s.applyMask(mask);
    s.formatBits(mask);
    const p = s.penalty();
    if (p < bestScore) {
      best = s;
      bestScore = p;
    }
  }
  return (best as Symbol).mods.map((row) => row.slice());
}

/** The symbol as an SVG (a 4-module quiet zone, one path, crisp edges). */
export function qrSvg(text: string, sizePx = 220): string {
  const m = qrMatrix(text);
  const quiet = 4;
  const dim = m.length + quiet * 2;
  let d = '';
  m.forEach((row, y) => {
    row.forEach((dark, x) => {
      if (dark) d += `M${x + quiet} ${y + quiet}h1v1h-1z`;
    });
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${dim} ${dim}" width="${sizePx}" height="${sizePx}" ` +
    `shape-rendering="crispEdges" role="img" aria-label="Ticket code"><rect width="${dim}" height="${dim}" fill="#fff"/>` +
    `<path d="${d}" fill="#000"/></svg>`;
}
