// Guest-list import preview (mig 20261102140000): turn what an organizer
// pastes or uploads into the rows the Door import would send
// (exos_import_guests), so the database can say what would happen without
// writing anything (_exos_guest_list_preview). Three inputs:
//   text  pasted names, one per line ("Maya Chen +2", "2. Tessa (+1)")
//   csv   an attendee export, read with the Door import's own parser
//   rows  JSON rows { name, email?, phone?, code?, ticket?, note?, plus_ones? }
// Pure, no imports beyond the shared parsers.

import { parseCsv } from './csvParse.ts';
import { detectColumns, MAX_IMPORT_ROWS, planImport, type ImportRow } from './guestImport.ts';

export const MAX_PASTE_WORDS = 6;

export interface PreviewRow extends ImportRow {
  plus_ones?: number;
}

export interface SkippedLine {
  line: number;
  text: string;
  reason: 'empty' | 'not_a_name' | 'too_long' | 'over_limit';
}

export interface PreviewInput {
  source: 'text' | 'csv' | 'rows';
  rows: PreviewRow[];
  skipped: SkippedLine[];
  /** CSV only: what the Door import's planner dropped before upload. */
  plan?: { noName: number; nameIsEmail: number; repeatedCodes: number; sharedCodes: number; overLimit: number };
}

export class PreviewError extends Error {}

// "+2", "(+2)", "plus 2", "x2" at the end of a line.
const PLUS_RE = /\s*(?:\(\s*\+\s*(\d{1,3})\s*\)|\+\s*(\d{1,3})|plus\s+(\d{1,3})|x\s*(\d{1,3}))\s*$/i;
// Bullets and numbering at the start: "-", "*", "•", "1.", "2)".
const BULLET_RE = /^\s*(?:[-*•·]+|\d{1,4}[.)])\s*/;

/** One pasted line as a guest, or why it isn't one. */
export function parsePastedLine(raw: string): { name: string; plus_ones: number } | SkippedLine['reason'] {
  let s = raw.replace(BULLET_RE, '').trim().replace(/[,;]+$/, '').trim();
  if (!s) return 'empty';
  let plus = 0;
  const m = PLUS_RE.exec(s);
  if (m) {
    plus = Number(m[1] ?? m[2] ?? m[3] ?? m[4]);
    s = s.slice(0, m.index).trim();
  }
  s = s.replace(/\s+/g, ' ').replace(/[,;]+$/, '').trim();
  if (!s) return 'empty';
  // A greeting or a heading ("Hey team:", "Thanks!", "Who's in?") is not a guest.
  if (/[:!?]$/.test(s) || s.includes('@')) return 'not_a_name';
  if (!/\p{L}/u.test(s)) return 'not_a_name';
  if (s.split(' ').length > MAX_PASTE_WORDS) return 'too_long';
  if (s.length > 80) return 'too_long';
  return { name: s, plus_ones: plus };
}

/** Pasted names, one per line. */
export function parsePastedNames(text: string): { rows: PreviewRow[]; skipped: SkippedLine[] } {
  const rows: PreviewRow[] = [];
  const skipped: SkippedLine[] = [];
  text.split(/\r?\n/).forEach((line, i) => {
    const r = parsePastedLine(line);
    if (typeof r === 'string') {
      if (r !== 'empty') skipped.push({ line: i + 1, text: line.trim().slice(0, 80), reason: r });
      return;
    }
    if (rows.length >= MAX_IMPORT_ROWS) {
      skipped.push({ line: i + 1, text: r.name, reason: 'over_limit' });
      return;
    }
    rows.push({ name: r.name, plus_ones: r.plus_ones });
  });
  return { rows, skipped };
}

const ROW_KEYS = ['name', 'email', 'phone', 'code', 'ticket', 'note'] as const;

/** JSON rows as the import takes them (strings only; plus_ones a whole number). */
export function normalizeRows(input: unknown): PreviewRow[] {
  if (!Array.isArray(input)) throw new PreviewError('rows must be a list of { name, email?, phone?, code?, plus_ones? }.');
  if (input.length > MAX_IMPORT_ROWS) throw new PreviewError(`at most ${MAX_IMPORT_ROWS} rows per import.`);
  return input.map((r) => {
    const o = (r && typeof r === 'object' && !Array.isArray(r) ? r : {}) as Record<string, unknown>;
    const out: PreviewRow = { name: '' };
    for (const k of ROW_KEYS) {
      const v = o[k] ?? (k === 'name' ? o.guest_name ?? [o.first_name, o.last_name].filter(Boolean).join(' ') : undefined);
      if (typeof v === 'string' || typeof v === 'number') out[k] = String(v);
    }
    const p = o.plus_ones;
    if (typeof p === 'number' && Number.isInteger(p) && p >= 0) out.plus_ones = p;
    else if (typeof p === 'string' && /^\d{1,3}$/.test(p)) out.plus_ones = Number(p);
    return out;
  });
}

/**
 * The request body as preview rows: { text } (pasted names), { csv } (an
 * export) or { rows }. Exactly one of them.
 */
export function previewInput(body: Record<string, unknown>): PreviewInput {
  const given = (['text', 'csv', 'rows'] as const).filter((k) => body[k] !== undefined && body[k] !== null);
  if (given.length !== 1) throw new PreviewError('send one of text (pasted names), csv (an attendee export) or rows.');
  const k = given[0];
  if (k === 'rows') return { source: 'rows', rows: normalizeRows(body.rows), skipped: [] };
  if (typeof body[k] !== 'string') throw new PreviewError(`${k} must be a string.`);
  if (k === 'text') return { source: 'text', ...parsePastedNames(body.text as string) };
  const table = parseCsv(body.csv as string);
  if (table.length < 2) throw new PreviewError('the CSV has no rows (a header line, then one row per guest).');
  const header = table[0] ?? [];
  const plan = planImport(table, detectColumns(header), typeof body.source === 'string' ? body.source.slice(0, 40) : 'Import');
  return {
    source: 'csv', rows: plan.rows, skipped: [],
    plan: { noName: plan.noName, nameIsEmail: plan.nameIsEmail, repeatedCodes: plan.repeatedCodes, sharedCodes: plan.sharedCodes, overLimit: plan.overLimit },
  };
}
