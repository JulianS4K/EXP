// Printed tickets: the page and the PDF for one-time print codes
// (docs/wallet.md "Printed tickets", mig 20261105120000).
//
// A print code (`P-{ticket}:{22 random characters}`) is minted in SQL
// (_exos_print_mint, behind exos_ticket_print / exos_order_print and the
// API's _exos_api_print) and shown once: only its SHA-256 is stored. This
// file turns the minted rows into something a printer takes:
//   * printHtml(): one ticket per printed page, the code as an inline SVG QR
//     (./qr.ts), no scripts, no external images, every field escaped.
//   * printPdf(): the same layout as a PDF 1.4 file, one 4 × 8 in page per
//     ticket (the size of common box-office ticket stock; a letter printer
//     prints it at the top of the sheet), built-in Helvetica, the QR drawn as
//     filled squares.
// Any printer prints either one through its own driver, a Boca included, so
// Exos sends no printer language (FGL) of its own.
//
// Pure TypeScript, imported by vitest.

import { encodeWinAnsi } from '../finance/pdf.ts';
import { qrMatrix, qrSvg } from './qr.ts';

/** One minted print code and what goes on the paper (exos_ticket_print's answer). */
export interface PrintTicket {
  ticket_id: string;
  print_code: string;
  event_name: string;
  starts_at: string | null;
  doors_at?: string | null;
  timezone?: string | null;
  occurs_at_local?: string | null;
  venue_name?: string | null;
  venue_location?: string | null;
  tier_name?: string | null;
  attendee_name?: string | null;
  seat_label?: string | null;
  org_name?: string | null;
  order_ref?: string | null;
  printed_at?: string | null;
}

export const PRINT_FORMATS = ['json', 'html', 'pdf'] as const;
export type PrintFormat = (typeof PRINT_FORMATS)[number];

/** ?format= (default json); null for anything else. */
export function printFormat(v: string | null | undefined): PrintFormat | null {
  if (v === null || v === undefined || v === '') return 'json';
  const f = v.trim().toLowerCase();
  return (PRINT_FORMATS as readonly string[]).includes(f) ? (f as PrintFormat) : null;
}

/** A print code's shape (the SQL checks the same, then the hash). */
export const PRINT_CODE_RE = /^P-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[A-Za-z0-9_-]{22}$/;

/** The ticket id inside a print code, or null. */
export function printCodeTicketId(code: string): string | null {
  const c = typeof code === 'string' && /^p-/.test(code) ? 'P' + code.slice(1) : code;
  return typeof c === 'string' && PRINT_CODE_RE.test(c) ? c.slice(2, 38) : null;
}

/** "Saturday, November 7, 2026 at 8:00 PM" in the event's zone (or the stored local text). */
export function whenText(t: Pick<PrintTicket, 'starts_at' | 'timezone' | 'occurs_at_local'>): string {
  if (t.starts_at) {
    const d = new Date(t.starts_at);
    if (!Number.isNaN(d.getTime())) {
      try {
        return new Intl.DateTimeFormat('en-US', {
          timeZone: t.timezone || 'UTC', weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
          hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
        }).format(d);
      } catch {
        return d.toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
      }
    }
  }
  return t.occurs_at_local?.trim() || 'Date to be announced';
}

/** The lines printed under the event name, in order, blanks dropped. */
export function ticketLines(t: PrintTicket): string[] {
  const venue = [t.venue_name, t.venue_location].map((s) => s?.trim()).filter(Boolean).join(', ');
  return [
    whenText(t),
    venue,
    [t.tier_name?.trim(), t.seat_label?.trim() ? `Seat ${t.seat_label.trim()}` : ''].filter(Boolean).join(' · '),
    t.attendee_name?.trim() ? `Admit: ${t.attendee_name.trim()}` : '',
  ].filter((s) => !!s);
}

const FOOTER = 'One entry. Reprinting, transferring or refunding this ticket cancels this paper.';

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

/** A printable HTML page, one ticket per printed page. No scripts or remote assets. */
export function printHtml(tickets: PrintTicket[], title = 'Tickets'): string {
  const pages = tickets.map((t) => `
<section class="ticket">
  <p class="org">${esc(t.org_name ?? '')}</p>
  <h1>${esc(t.event_name)}</h1>
  ${ticketLines(t).map((l) => `<p>${esc(l)}</p>`).join('\n  ')}
  <div class="qr">${qrSvg(t.print_code, 240)}</div>
  <p class="code">${esc(t.print_code)}</p>
  <p class="small">${esc(FOOTER)}</p>
</section>`).join('\n');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(title)}</title>
<style>
  body{margin:0;font-family:Helvetica,Arial,sans-serif;color:#000;background:#fff}
  .ticket{width:4in;min-height:7.5in;margin:0 auto;padding:.25in;box-sizing:border-box;page-break-after:always;break-after:page;text-align:center}
  .ticket:last-child{page-break-after:auto;break-after:auto}
  h1{font-size:20pt;margin:.1in 0}
  p{margin:.04in 0;font-size:11pt}
  .org{font-size:9pt;text-transform:uppercase;letter-spacing:.05em}
  .qr{margin:.2in auto}
  .qr svg{width:2.4in;height:2.4in}
  .code{font-family:Menlo,Consolas,monospace;font-size:7pt;word-break:break-all}
  .small{font-size:8pt}
  @page{size:4in 8in;margin:0}
</style></head><body>
${pages}
</body></html>
`;
}

// -- PDF ------------------------------------------------------------------------------

const PT = 72;
const W = 4 * PT;
const H = 8 * PT;

function pdfText(s: string): string {
  return '(' + encodeWinAnsi(s).map((b) => {
    if (b === 0x28 || b === 0x29 || b === 0x5c) return '\\' + String.fromCharCode(b);
    if (b < 32 || b > 126) return '\\' + b.toString(8).padStart(3, '0');
    return String.fromCharCode(b);
  }).join('') + ')';
}

/** Cuts a line to about `max` characters (Helvetica is roughly 0.5 em a character). */
function clip(s: string, size: number, width = W - 36): string {
  const max = Math.max(4, Math.floor(width / (size * 0.52)));
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
}

function centered(s: string, y: number, size: number, bold = false): string {
  const t = clip(s, size);
  const x = Math.max(18, (W - t.length * size * 0.5) / 2);
  return `0 g BT /${bold ? 'F2' : 'F1'} ${size} Tf ${x.toFixed(2)} ${y.toFixed(2)} Td ${pdfText(t)} Tj ET`;
}

function ticketPage(t: PrintTicket): string {
  const ops: string[] = [];
  let y = H - 36;
  if (t.org_name) {
    ops.push(centered(t.org_name.toUpperCase(), y, 8));
    y -= 22;
  }
  for (const part of splitTitle(t.event_name)) {
    ops.push(centered(part, y, 16, true));
    y -= 20;
  }
  y -= 4;
  for (const l of ticketLines(t)) {
    ops.push(centered(l, y, 10));
    y -= 14;
  }
  // The QR: 2.6 in square, centred, below the text.
  const m = qrMatrix(t.print_code);
  const side = 2.6 * PT;
  const cell = side / m.length;
  const x0 = (W - side) / 2;
  const y0 = Math.min(y - 12, H - 3.3 * PT) - side;
  const rects: string[] = [];
  m.forEach((row, r) => row.forEach((dark, c) => {
    if (dark) rects.push(`${(x0 + c * cell).toFixed(3)} ${(y0 + (m.length - 1 - r) * cell).toFixed(3)} ${cell.toFixed(3)} ${cell.toFixed(3)} re`);
  }));
  ops.push('0 g', rects.join('\n'), 'f');
  let fy = y0 - 18;
  for (const piece of [t.print_code.slice(0, 39), t.print_code.slice(39)]) {
    if (!piece) continue;
    ops.push(`0 g BT /F1 7 Tf ${((W - piece.length * 7 * 0.55) / 2).toFixed(2)} ${fy.toFixed(2)} Td ${pdfText(piece)} Tj ET`);
    fy -= 10;
  }
  ops.push(centered('One entry. Reprinting, transferring or refunding', fy - 8, 7));
  ops.push(centered('this ticket cancels this paper.', fy - 17, 7));
  return ops.join('\n');
}

function splitTitle(name: string): string[] {
  const words = name.trim().split(/\s+/);
  const lines: string[] = [];
  let line = '';
  for (const w of words) {
    const next = line ? `${line} ${w}` : w;
    if (next.length > 24 && line) {
      lines.push(line);
      line = w;
    } else line = next;
  }
  if (line) lines.push(line);
  return lines.slice(0, 3);
}

/** The tickets as a PDF, one 4 × 8 in page each. */
export function printPdf(tickets: PrintTicket[], title = 'Tickets'): Uint8Array {
  const objects: string[] = [];
  const add = (body: string) => objects.push(body);
  add(''); // 1 catalog
  add(''); // 2 pages
  add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'); // 3
  add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'); // 4
  add(`<< /Title ${pdfText(title)} /Producer (Exos) >>`); // 5
  const kids: number[] = [];
  for (const t of tickets) {
    const stream = ticketPage(t);
    add(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
    const content = objects.length;
    add(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${content} 0 R >>`);
    kids.push(objects.length);
  }
  objects[0] = '<< /Type /Catalog /Pages 2 0 R >>';
  objects[1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(' ')}] /Count ${kids.length} >>`;
  let out = '%PDF-1.4\n%\xE2\xE3\xCF\xD3\n';
  const offsets: number[] = [];
  objects.forEach((body, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) out += `${String(o).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Info 5 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  const bytes = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i) & 0xff;
  return bytes;
}
