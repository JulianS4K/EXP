// Exos Door imports (mig 20261013090000): which column of an attendee export
// is which, and the rows the import uploads. Moved here unchanged from
// src/lib/door/imports.ts so exos-api's guest-list preview (POST
// /v1/events/:id/guest-list-preview) parses exactly like the dashboard.
// Pure, no imports.

export const MAX_IMPORT_ROWS = 5000;

/** Same normalization as the database's _exos_door_code: whitespace removed,
 *  upper case; null when empty or longer than 128. */
export function normalizeDoorCode(raw: unknown): string | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const c = String(raw).replace(/\s/g, '').toUpperCase();
  return c.length >= 1 && c.length <= 128 ? c : null;
}



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
