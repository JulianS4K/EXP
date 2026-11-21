import { crc32 as zlibCrc32 } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { buildXlsx, columnName, columnsNamed, crc32, sheetNames, xlsxFileName, xmlText, zipStored } from './xlsx';

// A small reader, written independently of the writer: walk the ZIP's central
// directory, check each entry against its local header and a CRC from Node's
// zlib, then read cells back out of the sheet XML.
function unzip(bytes: Uint8Array): Map<string, string> {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= 0; i--) if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  expect(eocd).toBeGreaterThanOrEqual(0);
  const count = v.getUint16(eocd + 10, true);
  let p = v.getUint32(eocd + 16, true);
  const out = new Map<string, string>();
  const dec = new TextDecoder('utf-8', { fatal: true });
  for (let n = 0; n < count; n++) {
    expect(v.getUint32(p, true)).toBe(0x02014b50);
    const method = v.getUint16(p + 10, true);
    const crc = v.getUint32(p + 16, true);
    const size = v.getUint32(p + 20, true);
    const nameLen = v.getUint16(p + 28, true);
    const extraLen = v.getUint16(p + 30, true);
    const commentLen = v.getUint16(p + 32, true);
    const local = v.getUint32(p + 42, true);
    const name = dec.decode(bytes.subarray(p + 46, p + 46 + nameLen));
    expect(method).toBe(0);
    expect(v.getUint32(local, true)).toBe(0x04034b50);
    const lName = v.getUint16(local + 26, true);
    const lExtra = v.getUint16(local + 28, true);
    const data = bytes.subarray(local + 30 + lName + lExtra, local + 30 + lName + lExtra + size);
    expect(zlibCrc32(data) >>> 0).toBe(crc);
    out.set(name, dec.decode(data));
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

const unescape = (s: string) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');

interface Cell { ref: string; type: string | null; style: string | null; value: string }
function cells(xml: string): Cell[] {
  const out: Cell[] = [];
  const re = /<c r="([A-Z]+\d+)"( t="([a-zA-Z]+)")?( s="(\d+)")?>(?:<v>([^<]*)<\/v>|<is><t xml:space="preserve">([\s\S]*?)<\/t><\/is>)<\/c>/g;
  for (const m of xml.matchAll(re)) out.push({ ref: m[1], type: m[3] ?? null, style: m[5] ?? null, value: unescape(m[6] ?? m[7] ?? '') });
  return out;
}
const at = (cs: Cell[], ref: string) => cs.find((c) => c.ref === ref);

describe('xlsx writer', () => {
  it('computes CRC-32 like zlib', () => {
    const data = new TextEncoder().encode('The quick brown fox jumps over the lazy dog');
    expect(crc32(data)).toBe(0x414fa339);
    expect(crc32(new Uint8Array(0))).toBe(0);
    const big = new Uint8Array(70000).map((_, i) => (i * 31) & 0xff);
    expect(crc32(big)).toBe(zlibCrc32(big) >>> 0);
  });

  it('writes a valid stored ZIP', () => {
    const files = [{ name: 'a.txt', data: new TextEncoder().encode('hello') }, { name: 'dir/é.xml', data: new TextEncoder().encode('<x/>') }];
    const z = unzip(zipStored(files));
    expect([...z.keys()]).toEqual(['a.txt', 'dir/é.xml']);
    expect(z.get('a.txt')).toBe('hello');
  });

  it('round-trips a multi-sheet workbook', () => {
    const bytes = buildXlsx([
      { name: 'Orders', header: ['id', 'note', 'gross', 'tickets', 'ok'], moneyColumns: [2],
        rows: [
          ['cs_1', '=HYPERLINK("http://x")', '40.00', 2, true],
          ['cs_2', 'Tom & "Jerry" <b>', 12.5, 1, false],
          ['cs_3', null, 'n/a', undefined, ''],
        ] },
      { name: 'Postal codes', header: ['country', 'postal_code'], rows: [['US', '01234']] },
    ]);
    const z = unzip(bytes);
    for (const part of ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml',
      'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml']) {
      expect(z.has(part), part).toBe(true);
    }
    expect(z.get('xl/workbook.xml')).toContain('<sheet name="Orders" sheetId="1" r:id="rId1"/>');
    expect(z.get('xl/workbook.xml')).toContain('<sheet name="Postal codes" sheetId="2" r:id="rId2"/>');
    expect(z.get('xl/_rels/workbook.xml.rels')).toContain('Target="worksheets/sheet2.xml"');
    expect(z.get('[Content_Types].xml')).toContain('/xl/worksheets/sheet2.xml');

    const s1 = z.get('xl/worksheets/sheet1.xml')!;
    const c = cells(s1);
    // Header: bold, frozen.
    expect(at(c, 'A1')).toEqual({ ref: 'A1', type: 'inlineStr', style: '1', value: 'id' });
    expect(s1).toContain('state="frozen"');
    // Formula-looking text stays text; nothing is ever a formula.
    expect(at(c, 'B2')).toMatchObject({ type: 'inlineStr', value: '=HYPERLINK("http://x")' });
    expect(s1).not.toContain('<f>');
    // Money: a decimal string and a number both become numbers with the 0.00 format.
    expect(at(c, 'C2')).toMatchObject({ type: null, style: '2', value: '40' });
    expect(at(c, 'C3')).toMatchObject({ type: null, style: '2', value: '12.5' });
    // ... but text in a money column stays text.
    expect(at(c, 'C4')).toMatchObject({ type: 'inlineStr', value: 'n/a' });
    expect(at(c, 'D2')).toMatchObject({ type: null, style: null, value: '2' });
    expect(at(c, 'E2')).toMatchObject({ type: 'b', value: '1' });
    expect(at(c, 'E3')).toMatchObject({ type: 'b', value: '0' });
    expect(at(c, 'B3')!.value).toBe('Tom & "Jerry" <b>');
    // Empty cells are left out.
    expect(at(c, 'B4')).toBeUndefined();
    expect(at(c, 'E4')).toBeUndefined();
    // A leading zero survives (text, not a number).
    expect(at(cells(z.get('xl/worksheets/sheet2.xml')!), 'B2')).toMatchObject({ type: 'inlineStr', value: '01234' });
  });

  it('keeps the XML well formed', () => {
    expect(xmlText('a\u0000b\u0007c\td\ne')).toBe('abc\td\ne');
    expect(xmlText('x\uD800y')).toBe('xy');
    expect(xmlText('😀')).toBe('😀');
    const z = unzip(buildXlsx([{ name: 'S', rows: [['bad\u0001char', 'x'.repeat(40000)]] }]));
    const c = cells(z.get('xl/worksheets/sheet1.xml')!);
    expect(at(c, 'A1')!.value).toBe('badchar');
    expect(at(c, 'B1')!.value.length).toBe(32767);
  });

  it('names sheets the way Excel accepts', () => {
    expect(sheetNames(['Sales tax: 2026/Q1', 'Sales tax: 2026/Q1', '', 'x'.repeat(40), "'quoted'"]))
      .toEqual(['Sales tax 2026 Q1', 'Sales tax 2026 Q1 (2)', 'Sheet3', 'x'.repeat(31), 'quoted']);
    expect(sheetNames(['A', 'a'])).toEqual(['A', 'a (2)']);
    expect(sheetNames(['y'.repeat(31), 'y'.repeat(31)])[1]).toBe('y'.repeat(27) + ' (2)');
  });

  it('names columns and files', () => {
    expect([0, 1, 25, 26, 27, 51, 52, 701, 702].map(columnName)).toEqual(['A', 'B', 'Z', 'AA', 'AB', 'AZ', 'BA', 'ZZ', 'AAA']);
    expect(columnsNamed(['a', 'gross', 'b', 'tax'], ['tax', 'gross', 'nope'])).toEqual([3, 1]);
    expect(xlsxFileName(['Attendance', 'Fall Party!'], new Date('2026-11-10T12:00:00Z'))).toBe('attendance-fall-party-2026-11-10.xlsx');
    expect(xlsxFileName([], new Date('2026-11-10T12:00:00Z'))).toBe('export-2026-11-10.xlsx');
  });

  it('writes one empty sheet for no sheets', () => {
    const z = unzip(buildXlsx([]));
    expect(z.get('xl/workbook.xml')).toContain('name="Sheet1"');
    expect(z.get('xl/worksheets/sheet1.xml')).toContain('<sheetData></sheetData>');
  });
});
