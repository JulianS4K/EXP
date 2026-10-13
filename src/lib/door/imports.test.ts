import { describe, it, expect } from 'vitest';
import {
  MAX_IMPORT_ROWS, codeIndex, detectColumns, guessSource, isExosCode, matchImported, normalizeDoorCode,
  parseCsv, planImport, scanCandidates,
} from './imports';

describe('normalizeDoorCode', () => {
  it('matches the database rule', () => {
    expect(normalizeDoorCode(' ab 12\t3 ')).toBe('AB123');
    expect(normalizeDoorCode(1234)).toBe('1234');
    expect(normalizeDoorCode('')).toBeNull();
    expect(normalizeDoorCode('x'.repeat(129))).toBeNull();
    expect(normalizeDoorCode(null)).toBeNull();
  });
});

describe('parseCsv', () => {
  it('quotes, doubled quotes, CRLF, BOM, blank lines', () => {
    const t = '﻿Name,Note\r\n"Lovelace, Ada","said ""hi"""\r\n\r\nBo,\n';
    expect(parseCsv(t)).toEqual([['Name', 'Note'], ['Lovelace, Ada', 'said "hi"'], ['Bo', '']]);
  });
  it('semicolon and tab files', () => {
    expect(parseCsv('a;b\n1;2')).toEqual([['a', 'b'], ['1', '2']]);
    expect(parseCsv('a\tb\n1\t2')).toEqual([['a', 'b'], ['1', '2']]);
  });
  it('newlines inside quotes', () => {
    expect(parseCsv('n,c\n"two\nlines",x')).toEqual([['n', 'c'], ['two\nlines', 'x']]);
  });
});

describe('detectColumns', () => {
  it('Eventbrite attendee report', () => {
    const h = ['Order #', 'Order Date', 'First Name', 'Last Name', 'Email', 'Quantity', 'Ticket Type', 'Attendee #', 'Barcode #'];
    expect(detectColumns(h)).toEqual({ code: 8, firstName: 2, lastName: 3, email: 4, ticket: 6 });
    expect(guessSource('report.csv', h)).toBe('Eventbrite');
  });
  it('a ticket id without a barcode column', () => {
    expect(detectColumns(['Name', 'Email', 'Phone Number', 'Ticket Type', 'Ticket ID'])).toEqual({
      name: 0, email: 1, phone: 2, ticket: 3, code: 4,
    });
  });
  it('falls back to the order number, then nothing', () => {
    expect(detectColumns(['Guest', 'Order Number']).code).toBe(1);
    expect(detectColumns(['Full name', 'Notes'])).toEqual({ name: 0, note: 1 });
  });
  it('guesses the platform from the file name', () => {
    expect(guessSource('posh-export.csv', [])).toBe('Posh');
    expect(guessSource('DICE_guestlist.csv', [])).toBe('DICE');
    expect(guessSource('RA tickets.csv', [])).toBe('Resident Advisor');
    expect(guessSource('guests.csv', ['Name'])).toBe('Other');
  });
});

describe('planImport', () => {
  const table = [
    ['First Name', 'Last Name', 'Email', 'Ticket Type', 'Barcode #'],
    ['Ada', 'Lovelace', 'ada@x.com', 'GA', '1234 5678'],
    ['', '', 'ghost@x.com', 'GA', '999'],
    ['Bo', '', '', 'VIP', ''],
    ['Ada', 'Lovelace', 'ada@x.com', 'GA', '12345678'],
  ];
  it('builds rows, joins first + last, drops no-name rows and repeated codes', () => {
    const p = planImport(table, detectColumns(table[0]), 'Eventbrite');
    expect(p.rows).toEqual([
      { name: 'Ada Lovelace', email: 'ada@x.com', ticket: 'GA', code: '12345678', source: 'Eventbrite' },
      { name: 'Bo', ticket: 'VIP', source: 'Eventbrite' },
    ]);
    expect([p.noName, p.repeatedCodes, p.sharedCodes, p.overLimit]).toEqual([1, 1, 0, 0]);
  });
  it('people sharing an order number are all kept, by name', () => {
    const t = [['Name', 'Order #'], ['Ada', '1001'], ['Bo', '1001'], ['Cy', '1002'], ['Cy', '1002']];
    const p = planImport(t, detectColumns(t[0]), 'Other');
    expect(p.rows.map((r) => [r.name, r.code ?? null])).toEqual([['Ada', '1001'], ['Bo', null], ['Cy', '1002']]);
    expect([p.sharedCodes, p.repeatedCodes]).toEqual([1, 1]);
  });
  it('stops at the row limit', () => {
    const big = [['Name'], ...Array.from({ length: MAX_IMPORT_ROWS + 3 }, (_, i) => [`G${i}`])];
    const p = planImport(big, { name: 0 }, 'Other');
    expect(p.rows).toHaveLength(MAX_IMPORT_ROWS);
    expect(p.overLimit).toBe(3);
  });
});

describe('scanning imported codes', () => {
  const idx = codeIndex([{ id: 'a', code: '12345678' }, { id: 'b', code: 'TKT-9' }, { id: 'c', code: null }]);
  it('matches the whole text, any case or spacing', () => {
    expect(matchImported('1234 5678', idx)?.id).toBe('a');
    expect(matchImported('tkt-9', idx)?.id).toBe('b');
  });
  it('matches the last path segment or a query value of a link', () => {
    expect(scanCandidates('https://x.example/t/TKT-9?ref=ig')).toEqual(['HTTPS://X.EXAMPLE/T/TKT-9?REF=IG', 'TKT-9', 'IG']);
    expect(matchImported('https://x.example/t/TKT-9?ref=ig', idx)?.id).toBe('b');
    expect(matchImported('https://x.example/check?code=12345678', idx)?.id).toBe('a');
  });
  it('no match, empty index', () => {
    expect(matchImported('nope', idx)).toBeNull();
    expect(matchImported('12345678', new Map())).toBeNull();
  });
  it("Exos's own codes are never looked up", () => {
    expect(isExosCode('T-abc:def:1:sig')).toBe(true);
    expect(isExosCode('W-xyz')).toBe(true);
    expect(isExosCode('12345678')).toBe(false);
    // Another platform may use uuids as ticket ids: matched, not refused.
    expect(isExosCode('0f9e8d7c-6b5a-4c3d-9e2f-1a2b3c4d5e6f')).toBe(false);
    const u = codeIndex([{ id: 'u', code: '0f9e8d7c-6b5a-4c3d-9e2f-1a2b3c4d5e6f' }]);
    expect(matchImported('0F9E8D7C-6B5A-4C3D-9E2F-1A2B3C4D5E6F', u)?.id).toBe('u');
  });
});
