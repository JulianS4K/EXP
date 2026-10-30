// Exos Door: attendee exports from other ticketing platforms (mig
// 20261013090000). Parse the CSV, guess which column is which (Eventbrite,
// Posh, DICE, Shotgun, RA, or any spreadsheet with a name column), turn rows
// into exos_import_guests rows, and match a scanned barcode against the
// imported codes. Pure, unit-tested.

export const MAX_IMPORT_ROWS = 5000;

/** Same normalization as the database's _exos_door_code: whitespace removed,
 *  upper case; null when empty or longer than 128. */
export function normalizeDoorCode(raw: unknown): string | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const c = String(raw).replace(/\s/g, '').toUpperCase();
  return c.length >= 1 && c.length <= 128 ? c : null;
}

// The CSV reader is shared with the sales-count import (src/lib/salesCounts.ts)
// and exos-api, so it lives in supabase/functions/_shared/csvParse.ts.
export { parseCsv } from '../../../supabase/functions/_shared/csvParse.ts';

export type ImportField = 'name' | 'firstName' | 'lastName' | 'email' | 'phone' | 'code' | 'ticket' | 'note';

export type ColumnMap = Partial<Record<ImportField, number>>;

const norm = (h: string) => h.toLowerCase().replace(/[^a-z0-9#]+/g, ' ').trim();

// Header patterns, most specific first. Codes: the barcode wins over a ticket
// id, which wins over an order number (an order can hold several tickets).
const PATTERNS: Array<[ImportField, RegExp[]]> = [
  ['code', [/^barcode( #| number| id)?$/, /^(ticket )?qr( code)?$/, /^ticket (code|barcode)$/, /^attendee #$/,
            /^ticket (id|#|number|no)$/, /^ticket ref(erence)?$/, /^code$/]],
  ['firstName', [/^(attendee |buyer |guest )?first( name)?$/, /^given name$/]],
  ['lastName', [/^(attendee |buyer |guest )?(last|sur)( ?name)?$/, /^family name$/]],
  ['name', [/^(attendee |buyer |guest |ticket holder |holder )?(full )?name$/, /^attendee$/, /^guest$/, /^customer$/]],
  ['email', [/^(attendee |buyer |guest )?e ?mail( address)?$/]],
  ['phone', [/^(attendee |buyer |guest )?(phone|mobile|cell)( number| #)?$/]],
  ['ticket', [/^ticket (type|tier|class|name)$/, /^tier$/, /^ticket$/, /^type$/, /^product$/]],
  ['note', [/^notes?$/, /^comments?$/]],
];

const ORDER_CODE = /^order( #| number| id| no| ref)?$/;

/** Which column holds what. When there is no barcode / ticket id column the
 *  order number is used as the code (one ticket per order, as on RA). */
export function detectColumns(header: string[]): ColumnMap {
  const map: ColumnMap = {};
  const h = header.map(norm);
  for (const [field, pats] of PATTERNS) {
    for (const p of pats) {
      const i = h.findIndex((x, idx) => p.test(x) && !Object.values(map).includes(idx));
      if (i >= 0) {
        map[field] = i;
        break;
      }
    }
  }
  if (map.code === undefined) {
    const i = h.findIndex((x) => ORDER_CODE.test(x));
    if (i >= 0) map.code = i;
  }
  return map;
}

export const IMPORT_SOURCES = ['Eventbrite', 'Posh', 'DICE', 'Shotgun', 'Resident Advisor', 'Partiful', 'Other'] as const;
export type ImportSource = (typeof IMPORT_SOURCES)[number];

/** Best guess at the platform from the file name, then the headers. */
export function guessSource(fileName: string, header: string[]): ImportSource {
  const f = fileName.toLowerCase();
  if (f.includes('eventbrite')) return 'Eventbrite';
  if (f.includes('posh')) return 'Posh';
  if (f.includes('dice')) return 'DICE';
  if (f.includes('shotgun')) return 'Shotgun';
  if (f.includes('resident') || /(^|[^a-z])ra([^a-z]|$)/.test(f)) return 'Resident Advisor';
  if (f.includes('partiful')) return 'Partiful';
  const h = header.map(norm);
  if (h.includes('attendee #') || h.includes('barcode #')) return 'Eventbrite';
  return 'Other';
}

export interface ImportRow {
  name: string;
  email?: string;
  phone?: string;
  code?: string;
  ticket?: string;
  note?: string;
  source?: string;
}

export interface ImportPlan {
  rows: ImportRow[];
  /** Data rows with no name (skipped before upload). */
  noName: number;
  /** Rows repeating an earlier row (same code, same name): kept once. */
  repeatedCodes: number;
  /** Different people sharing one code (e.g. an order number): kept,
   *  without the code, for check-in by name. */
  sharedCodes: number;
  /** Rows past MAX_IMPORT_ROWS. */
  overLimit: number;
}

/** Turn parsed CSV rows (header first) into import rows. */
export function planImport(table: string[][], map: ColumnMap, source: string): ImportPlan {
  const out: ImportRow[] = [];
  const seen = new Map<string, string>();
  let noName = 0;
  let sharedCodes = 0;
  let repeatedCodes = 0;
  let overLimit = 0;
  const cell = (r: string[], f: ImportField) => {
    const i = map[f];
    return i === undefined ? '' : (r[i] ?? '').trim();
  };
  for (const r of table.slice(1)) {
    const name = cell(r, 'name') || [cell(r, 'firstName'), cell(r, 'lastName')].filter(Boolean).join(' ');
    if (!name) {
      noName++;
      continue;
    }
    let code = normalizeDoorCode(cell(r, 'code')) ?? undefined;
    if (code) {
      const first = seen.get(code);
      if (first !== undefined) {
        // The same row twice: skip it. A different person sharing the code
        // (an order number used as the code, several tickets per order):
        // keep them, checked in by name.
        if (first === name.toLowerCase()) {
          repeatedCodes++;
          continue;
        }
        sharedCodes++;
        code = undefined;
      } else seen.set(code, name.toLowerCase());
    }
    if (out.length >= MAX_IMPORT_ROWS) {
      overLimit++;
      continue;
    }
    const row: ImportRow = { name: name.slice(0, 80), source };
    const email = cell(r, 'email');
    const phone = cell(r, 'phone');
    const ticket = cell(r, 'ticket');
    const note = cell(r, 'note');
    if (email) row.email = email;
    if (phone) row.phone = phone;
    if (code) row.code = code;
    if (ticket) row.ticket = ticket.slice(0, 80);
    if (note) row.note = note.slice(0, 200);
    out.push(row);
  }
  return { rows: out, noName, repeatedCodes, sharedCodes, overLimit };
}

/** Candidate codes in what the camera read: the whole text, and for a link
 *  its last path segment and its query values (some platforms put the
 *  ticket id in a URL). */
export function scanCandidates(scanned: string): string[] {
  const out: string[] = [];
  const add = (s: string | null | undefined) => {
    const c = normalizeDoorCode(s ?? '');
    if (c && !out.includes(c)) out.push(c);
  };
  add(scanned);
  const t = scanned.trim();
  if (/^https?:\/\//i.test(t)) {
    try {
      const u = new URL(t);
      const segs = u.pathname.split('/').filter(Boolean);
      add(segs[segs.length - 1]);
      for (const v of u.searchParams.values()) add(v);
    } catch {
      /* not a URL after all */
    }
  }
  return out;
}

/** Index imported guests by code. */
export function codeIndex<T extends { code?: string | null }>(guests: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const g of guests) {
    const c = normalizeDoorCode(g.code ?? '');
    if (c) m.set(c, g);
  }
  return m;
}

/** The imported guest a scan belongs to, or null. */
export function matchImported<T>(scanned: string, index: Map<string, T>): T | null {
  if (index.size === 0) return null;
  for (const c of scanCandidates(scanned)) {
    const g = index.get(c);
    if (g) return g;
  }
  return null;
}

/** Exos's own signed codes (rotating T- / wallet W-): never looked up among
 *  imported codes. A bare uuid is not on this list: another platform may use
 *  uuids as ticket ids, so it is matched against the imported codes first. */
export const isExosCode = (scanned: string): boolean => /^(T-|W-)/.test(scanned.trim());
