// A small PDF writer for offers and settlements (docs/offers-settlements.md).
//
// The documents are text and simple rules: headings, wrapped paragraphs,
// label / amount rows and tables. That needs none of a PDF library's weight,
// so this writes PDF 1.4 directly: US Letter pages, the built-in Helvetica and
// Helvetica-Bold fonts (every reader has them, nothing is embedded) in
// WinAnsi encoding, one content stream per page (uncompressed, so this stays
// dependency-free and synchronous in the browser and in Deno), and a
// cross-reference table. Text outside WinAnsi (Latin-1 plus a few
// typographic marks) prints as "?"; the HTML views show it correctly.
//
// Usage:
//   const pdf = createPdf({ title: 'Offer' });
//   pdf.heading('Offer'); pdf.paragraph('…'); pdf.row([['Guarantee'], ['$1,000.00', { align: 'right' }]]);
//   const bytes: Uint8Array = pdf.toBytes();

const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 54;
const CONTENT_W = PAGE_W - MARGIN * 2;

// Helvetica advance widths (1/1000 em) for ASCII 32..126 (Adobe metrics).
// Bold is close enough at +5 %.
const HELVETICA = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

// Unicode → WinAnsi (cp1252) for the marks the documents use.
const WIN_ANSI: Record<string, number> = {
  '€': 0x80, '‚': 0x82, '„': 0x84, '…': 0x85, '‘': 0x91, '’': 0x92, '“': 0x93, '”': 0x94, '•': 0x95, '–': 0x96,
  '—': 0x97, '™': 0x99,
};

/** Text as WinAnsi byte values. */
export function encodeWinAnsi(s: string): number[] {
  const out: number[] = [];
  for (const ch of s.normalize('NFC')) {
    if (ch === '−') out.push(0x2d);
    else if (ch === ' ' || ch === ' ') out.push(0x20);
    else if (WIN_ANSI[ch] !== undefined) out.push(WIN_ANSI[ch]);
    else {
      const c = ch.codePointAt(0) ?? 63;
      out.push(c >= 32 && c <= 255 && !(c >= 127 && c < 160) ? c : 63);
    }
  }
  return out;
}

function widthOf(s: string, size: number, bold = false): number {
  let w = 0;
  for (const b of encodeWinAnsi(s)) w += b >= 32 && b <= 126 ? HELVETICA[b - 32] : 556;
  return (w * size * (bold ? 1.05 : 1)) / 1000;
}

function pdfString(s: string): string {
  return '(' + encodeWinAnsi(s).map((b) => {
    if (b === 0x28 || b === 0x29 || b === 0x5c) return '\\' + String.fromCharCode(b);
    if (b < 32 || b > 126) return '\\' + b.toString(8).padStart(3, '0');
    return String.fromCharCode(b);
  }).join('') + ')';
}

/** Splits text into lines no wider than `width`. */
export function wrap(text: string, width: number, size: number, bold = false): string[] {
  const lines: string[] = [];
  for (const para of text.replace(/\r\n?/g, '\n').split('\n')) {
    const words = para.split(/\s+/).filter(Boolean);
    if (words.length === 0) {
      lines.push('');
      continue;
    }
    let line = '';
    for (const word of words) {
      const next = line ? `${line} ${word}` : word;
      if (widthOf(next, size, bold) <= width || !line) {
        if (!line && widthOf(word, size, bold) > width) {
          // A single word wider than the line is cut hard.
          let piece = '';
          for (const ch of word) {
            if (widthOf(piece + ch, size, bold) > width && piece) {
              lines.push(piece);
              piece = '';
            }
            piece += ch;
          }
          line = piece;
        } else {
          line = next;
        }
      } else {
        lines.push(line);
        line = word;
      }
    }
    lines.push(line);
  }
  return lines;
}

export interface TextOpts {
  size?: number;
  bold?: boolean;
  align?: 'left' | 'right';
  /** Grey 0 (black) .. 1 (white). */
  gray?: number;
}

export type Cell = [string, TextOpts?];

export interface PdfBuilder {
  heading(text: string, size?: number): void;
  subheading(text: string): void;
  paragraph(text: string, opts?: TextOpts): void;
  /** One line of cells across the page; widths are fractions of the content width (default: equal). */
  row(cells: Cell[], widths?: number[], opts?: { rule?: boolean }): void;
  /** Header row + rows, with rules. */
  table(head: string[], rows: string[][], widths?: number[], alignRight?: number[]): void;
  rule(): void;
  space(points: number): void;
  toBytes(): Uint8Array;
}

const latin1 = (s: string): Uint8Array => {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
};

export function createPdf(meta: { title: string; author?: string }): PdfBuilder {
  const pages: string[][] = [[]];
  let y = PAGE_H - MARGIN;
  const ops = () => pages[pages.length - 1];

  const ensure = (h: number) => {
    if (y - h < MARGIN) {
      pages.push([]);
      y = PAGE_H - MARGIN;
    }
  };
  const textAt = (x: number, baseline: number, s: string, o: TextOpts = {}) => {
    const size = o.size ?? 10;
    const gray = o.gray ?? 0;
    ops().push(`${gray.toFixed(2)} g BT /${o.bold ? 'F2' : 'F1'} ${size} Tf ${x.toFixed(2)} ${baseline.toFixed(2)} Td ${pdfString(s)} Tj ET`);
  };
  const line = (x1: number, y1: number, x2: number, y2: number, gray = 0.8) => {
    ops().push(`${gray.toFixed(2)} G 0.5 w ${x1.toFixed(2)} ${y1.toFixed(2)} m ${x2.toFixed(2)} ${y2.toFixed(2)} l S`);
  };

  const builder: PdfBuilder = {
    heading(text, size = 20) {
      for (const l of wrap(text, CONTENT_W, size, true)) {
        ensure(size * 1.3);
        y -= size;
        textAt(MARGIN, y, l, { size, bold: true });
        y -= size * 0.3;
      }
      y -= 4;
    },
    subheading(text) {
      ensure(30);
      y -= 10;
      builder.paragraph(text.toUpperCase(), { size: 9, bold: true, gray: 0.35 });
      line(MARGIN, y + 2, PAGE_W - MARGIN, y + 2, 0.6);
      y -= 4;
    },
    paragraph(text, o = {}) {
      const size = o.size ?? 10;
      for (const l of wrap(text, CONTENT_W, size, o.bold)) {
        ensure(size * 1.45);
        y -= size * 1.2;
        textAt(MARGIN, y, l, o);
        y -= size * 0.25;
      }
    },
    row(cells, widths, opts = {}) {
      const fr = widths ?? cells.map(() => 1 / cells.length);
      const wrapped = cells.map(([text, o], i) => wrap(text, fr[i] * CONTENT_W - 6, o?.size ?? 10, o?.bold));
      const lines = Math.max(1, ...wrapped.map((w) => w.length));
      const size = Math.max(...cells.map(([, o]) => o?.size ?? 10));
      const h = lines * size * 1.25 + 4;
      ensure(h);
      let x = MARGIN;
      cells.forEach(([, o], i) => {
        const w = fr[i] * CONTENT_W;
        wrapped[i].forEach((l, j) => {
          const baseline = y - (j + 1) * size * 1.25 + 2;
          const tx = o?.align === 'right' ? x + w - widthOf(l, o?.size ?? 10, o?.bold) : x;
          textAt(tx, baseline, l, o);
        });
        x += w;
      });
      y -= h;
      if (opts.rule) line(MARGIN, y + 1, PAGE_W - MARGIN, y + 1);
    },
    table(head, rows, widths, alignRight = []) {
      const right = new Set(alignRight);
      builder.row(head.map((h, i): Cell => [h, { bold: true, size: 9, gray: 0.35, align: right.has(i) ? 'right' : 'left' }]), widths, { rule: true });
      for (const r of rows) builder.row(r.map((c, i): Cell => [c, { align: right.has(i) ? 'right' : 'left' }]), widths, { rule: true });
    },
    rule() {
      ensure(8);
      y -= 4;
      line(MARGIN, y, PAGE_W - MARGIN, y, 0.6);
      y -= 4;
    },
    space(points) {
      y -= points;
      if (y < MARGIN) ensure(PAGE_H);
    },
    toBytes() {
      const objects: string[] = [];
      const add = (body: string) => {
        objects.push(body);
        return objects.length;
      };
      const catalog = add('');
      const pagesObj = add('');
      const f1 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
      const f2 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
      const info = add(`<< /Title ${pdfString(meta.title)} /Producer (Exos)${meta.author ? ` /Author ${pdfString(meta.author)}` : ''} >>`);
      const kids: number[] = [];
      pages.forEach((p, i) => {
        const footer = `0.50 g BT /F1 8 Tf ${MARGIN} ${MARGIN / 2} Td ${pdfString(`${meta.title} — page ${i + 1} of ${pages.length}`)} Tj ET`;
        const stream = [...p, footer].join('\n');
        const content = add(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
        kids.push(add(`<< /Type /Page /Parent ${pagesObj} 0 R /MediaBox [0 0 ${PAGE_W} ${PAGE_H}] /Resources << /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >> >> /Contents ${content} 0 R >>`));
      });
      objects[catalog - 1] = `<< /Type /Catalog /Pages ${pagesObj} 0 R >>`;
      objects[pagesObj - 1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(' ')}] /Count ${kids.length} >>`;

      // Every string above is already single-byte (pdfString escapes the rest).
      let out = '%PDF-1.4\n%\xE2\xE3\xCF\xD3\n';
      const offsets: number[] = [];
      objects.forEach((body, i) => {
        offsets.push(out.length);
        out += `${i + 1} 0 obj\n${body}\nendobj\n`;
      });
      const xrefAt = out.length;
      out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
      for (const o of offsets) out += `${String(o).padStart(10, '0')} 00000 n \n`;
      out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalog} 0 R /Info ${info} 0 R >>\nstartxref\n${xrefAt}\n%%EOF\n`;
      return latin1(out);
    },
  };
  return builder;
}
