// A minimal XLSX (Office Open XML spreadsheet) writer for organizer exports,
// built in the browser. No dependency: an .xlsx file is a ZIP of a few XML
// parts, and this writes them uncompressed ("stored" entries), which every
// spreadsheet app reads. About 7 KB minified (3 KB gzipped); the panels load it with a
// dynamic import (src/lib/xlsxDownload.ts) only when someone clicks a
// download, so it never ships in a page's first load.
//
// What it writes: one worksheet per sheet, a bold, frozen header row, inline
// strings (no shared-string table), numbers, booleans, and an optional money
// format (#,##0.00) on chosen columns. Dates are written as ISO text.
//
// Formula injection: every text cell is an inline string, which a
// spreadsheet never evaluates (a formula needs an <f> element, which this
// never writes). So text is kept exactly as given, unlike the CSV path
// (src/lib/csv.ts), which has to prefix a quote.
//
// Pure (vitest: xlsx.test.ts reads the bytes back).

export type XlsxCell = string | number | boolean | null | undefined | Date;

export interface XlsxSheet {
  /** Tab name: cleaned to Excel's rules (31 characters, no []:*?/\) and made unique. */
  name: string;
  /** Optional header row, bold and frozen. */
  header?: string[];
  rows: XlsxCell[][];
  /**
   * Column indexes (0-based) shown as money (#,##0.00). A number there is
   * written as is; a decimal string ("12.34", what the CSV builders emit)
   * becomes that number. Anything else stays text.
   */
  moneyColumns?: number[];
}

const MAX_CELL = 32767; // Excel's limit on a cell's text
const MONEY_STYLE = 2;
const HEADER_STYLE = 1;
const DECIMAL_RE = /^-?\d+(\.\d+)?$/;

// ── ZIP (stored) ─────────────────────────────────────────────────────────

let CRC_TABLE: Uint32Array | null = null;

/** CRC-32 (IEEE 802.3), as ZIP uses it. */
export function crc32(data: Uint8Array): number {
  if (!CRC_TABLE) {
    CRC_TABLE = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) crc = CRC_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function dosTime(d: Date): { time: number; date: number } {
  const y = Math.min(Math.max(d.getUTCFullYear(), 1980), 2107);
  return {
    time: (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | Math.floor(d.getUTCSeconds() / 2),
    date: ((y - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate(),
  };
}

/** A ZIP archive of `files`, each stored (no compression), UTF-8 names. */
export function zipStored(files: { name: string; data: Uint8Array }[], when = new Date(Date.UTC(1980, 0, 1))): Uint8Array {
  const enc = new TextEncoder();
  const { time, date } = dosTime(when);
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const f of files) {
    const name = enc.encode(f.name);
    const crc = crc32(f.data);
    const size = f.data.length;
    const local = new Uint8Array(30 + name.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true); // version needed
    lv.setUint16(6, 0x0800, true); // UTF-8 names
    lv.setUint16(8, 0, true); // stored
    lv.setUint16(10, time, true);
    lv.setUint16(12, date, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, size, true);
    lv.setUint32(22, size, true);
    lv.setUint16(26, name.length, true);
    lv.setUint16(28, 0, true);
    local.set(name, 30);
    const central = new Uint8Array(46 + name.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true); // made by
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint16(10, 0, true);
    cv.setUint16(12, time, true);
    cv.setUint16(14, date, true);
    cv.setUint32(16, crc, true);
    cv.setUint32(20, size, true);
    cv.setUint32(24, size, true);
    cv.setUint16(28, name.length, true);
    cv.setUint32(42, offset, true);
    central.set(name, 46);
    locals.push(local, f.data);
    centrals.push(central);
    offset += local.length + size;
  }
  const cdSize = centrals.reduce((n, c) => n + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, files.length, true);
  ev.setUint16(10, files.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, offset, true);
  const out = new Uint8Array(offset + cdSize + end.length);
  let p = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

// ── Sheets ───────────────────────────────────────────────────────────────

/** Text safe inside XML: escaped, and without the control characters XML 1.0 forbids. */
export function xmlText(s: string): string {
  return s
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
    .replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** "A", "B", … "Z", "AA" for a 0-based column. */
export function columnName(i: number): string {
  let n = i + 1;
  let s = '';
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

/** Tab names Excel accepts: no []:*?/\, not quoted, 1-31 characters, unique (ignoring case). */
export function sheetNames(names: string[]): string[] {
  const seen = new Set<string>();
  return names.map((raw, i) => {
    let base = String(raw ?? '').replace(/[[\]:*?/\\]/g, ' ').replace(/\s+/g, ' ').trim().replace(/^'+|'+$/g, '');
    if (!base) base = `Sheet${i + 1}`;
    base = base.slice(0, 31).trim();
    let name = base;
    for (let k = 2; seen.has(name.toLowerCase()); k++) {
      const suffix = ` (${k})`;
      name = base.slice(0, 31 - suffix.length).trim() + suffix;
    }
    seen.add(name.toLowerCase());
    return name;
  });
}

function cellXml(ref: string, v: XlsxCell, money: boolean, style: number): string {
  const s = style ? ` s="${style}"` : '';
  if (v === null || v === undefined || v === '') return '';
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) return '';
    return `<c r="${ref}"${money ? ` s="${MONEY_STYLE}"` : s}><v>${v}</v></c>`;
  }
  if (typeof v === 'boolean') return `<c r="${ref}" t="b"${s}><v>${v ? 1 : 0}</v></c>`;
  let text: string;
  if (v instanceof Date) {
    if (Number.isNaN(v.getTime())) return '';
    text = v.toISOString();
  } else {
    text = String(v);
    if (money && DECIMAL_RE.test(text.trim())) {
      return `<c r="${ref}" s="${MONEY_STYLE}"><v>${Number(text.trim())}</v></c>`;
    }
  }
  if (text.length > MAX_CELL) text = text.slice(0, MAX_CELL);
  return `<c r="${ref}" t="inlineStr"${s}><is><t xml:space="preserve">${xmlText(text)}</t></is></c>`;
}

function widthOf(v: XlsxCell): number {
  if (v === null || v === undefined) return 0;
  if (v instanceof Date) return 24;
  return Math.min(String(v).length, 60);
}

/** One worksheet part. */
export function sheetXml(sheet: XlsxSheet): string {
  const money = new Set(sheet.moneyColumns ?? []);
  const all: XlsxCell[][] = sheet.header ? [sheet.header, ...sheet.rows] : sheet.rows;
  const cols = all.reduce((n, r) => Math.max(n, r.length), 0);
  const widths: number[] = Array.from({ length: cols }, (_, c) =>
    Math.max(8, Math.min(60, all.reduce((w, r) => Math.max(w, widthOf(r[c])), 0) + 2)));
  const rows = all.map((r, i) => {
    const isHeader = !!sheet.header && i === 0;
    const cells = r.map((v, c) => cellXml(`${columnName(c)}${i + 1}`, v, !isHeader && money.has(c), isHeader ? HEADER_STYLE : 0)).join('');
    return `<row r="${i + 1}">${cells}</row>`;
  }).join('');
  const view = sheet.header
    ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
    : '<sheetViews><sheetView workbookViewId="0"/></sheetViews>';
  const colXml = cols ? `<cols>${widths.map((w, c) => `<col min="${c + 1}" max="${c + 1}" width="${w}" customWidth="1"/>`).join('')}</cols>` : '';
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    + view + colXml + `<sheetData>${rows}</sheetData></worksheet>`;
}

const STYLES = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
  + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
  + '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'
  + '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
  + '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
  + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
  + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
  + '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
  + '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
  + '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
  + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
  + '</styleSheet>';

/** The workbook's bytes (an .xlsx file). At least one sheet; an empty list gets one empty sheet. */
export function buildXlsx(sheets: XlsxSheet[], when?: Date): Uint8Array {
  const list = sheets.length ? sheets : [{ name: 'Sheet1', rows: [] }];
  const names = sheetNames(list.map((s) => s.name));
  const enc = new TextEncoder();
  const xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  const files: { name: string; data: Uint8Array }[] = [];
  const add = (name: string, text: string) => files.push({ name, data: enc.encode(text) });
  add('[Content_Types].xml', xml
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    + list.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')
    + '</Types>');
  add('_rels/.rels', xml
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    + '</Relationships>');
  add('xl/workbook.xml', xml
    + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<sheets>${names.map((n, i) => `<sheet name="${xmlText(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets>`
    + '</workbook>');
  add('xl/_rels/workbook.xml.rels', xml
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + list.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')
    + `<Relationship Id="rId${list.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`
    + '</Relationships>');
  add('xl/styles.xml', STYLES);
  list.forEach((s, i) => add(`xl/worksheets/sheet${i + 1}.xml`, sheetXml(s)));
  return zipStored(files, when);
}

/** Column indexes of `names` in `header` (for moneyColumns). */
export function columnsNamed(header: readonly string[], names: readonly string[]): number[] {
  return names.map((n) => header.indexOf(n)).filter((i) => i >= 0);
}

/** Filesystem-safe, lower-case download name ending in .xlsx. */
export function xlsxFileName(parts: Array<string | undefined | null>, date = new Date()): string {
  const slug = parts
    .filter((p): p is string => !!p)
    .map((p) => p.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''))
    .filter(Boolean)
    .join('-');
  return `${slug || 'export'}-${date.toISOString().slice(0, 10)}.xlsx`;
}

export const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/** Trigger a browser download of the workbook. No-op outside a DOM. */
export function downloadXlsx(fileName: string, sheets: XlsxSheet[]): void {
  if (typeof document === 'undefined' || typeof URL === 'undefined') return;
  const bytes = buildXlsx(sheets, new Date());
  const blob = new Blob([bytes as BlobPart], { type: XLSX_MIME });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
