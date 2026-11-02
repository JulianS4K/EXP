// The dashboard's ledger tables (mig 20261102120000): sorting, filtering and
// paging for any list of rows, labels, the ledger-import CSV plan and the
// reporting-row export. Pure, no imports beyond the shared parsers; tested
// in src/lib/financeTables.test.ts.

import { parseCsv } from '../../supabase/functions/_shared/csvParse.ts';
import { toCsv } from './csv';

// ── Generic table state ──────────────────────────────────────────────────

export type SortDir = 'asc' | 'desc';

export interface TableState {
  query: string;
  sortKey: string;
  sortDir: SortDir;
  page: number;
  perPage: number;
  /** column key → selected value ('' = any). */
  filters: Record<string, string>;
}

export interface TableColumn<T> {
  key: string;
  /** The value sorted on (and searched, when searchable). */
  value: (row: T) => string | number | boolean | null | undefined;
  searchable?: boolean;
}

export const PER_PAGE_CHOICES = [25, 50, 100] as const;

export function initialTable(sortKey: string, sortDir: SortDir = 'asc', perPage = 25): TableState {
  return { query: '', sortKey, sortDir, page: 1, perPage, filters: {} };
}

/** Clicking a header: the same column flips direction, another starts ascending. Back to page 1. */
export function toggleSort(s: TableState, key: string): TableState {
  return { ...s, sortKey: key, sortDir: s.sortKey === key && s.sortDir === 'asc' ? 'desc' : 'asc', page: 1 };
}

export function setFilter(s: TableState, key: string, value: string): TableState {
  return { ...s, filters: { ...s.filters, [key]: value }, page: 1 };
}

export function setQuery(s: TableState, query: string): TableState {
  return { ...s, query, page: 1 };
}

/** Two non-blank values: numbers and booleans numerically, text naturally ("Row 2" < "Row 10"). */
function compare(a: unknown, b: unknown): number {
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  return String(a).localeCompare(String(b), 'en', { numeric: true, sensitivity: 'base' });
}

export interface TableView<T> {
  rows: T[];
  /** Rows after search and filters (before paging). */
  total: number;
  page: number;
  pageCount: number;
}

/**
 * Search (case-insensitive, every word in some searchable column), filters
 * (exact match on the column's value), a stable sort (blanks last) and the
 * page. A page past the end clamps to the last one.
 */
export function applyTable<T>(rows: readonly T[], s: TableState, columns: readonly TableColumn<T>[]): TableView<T> {
  const byKey = new Map(columns.map((c) => [c.key, c]));
  const words = s.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const searchable = columns.filter((c) => c.searchable);
  let out = rows.filter((r) => {
    for (const [k, v] of Object.entries(s.filters)) {
      if (v === '') continue;
      const col = byKey.get(k);
      if (col && String(col.value(r) ?? '') !== v) return false;
    }
    if (!words.length) return true;
    const hay = searchable.map((c) => String(c.value(r) ?? '').toLowerCase()).join(' ');
    return words.every((w) => hay.includes(w));
  });
  const col = byKey.get(s.sortKey);
  if (col) {
    const dir = s.sortDir === 'desc' ? -1 : 1;
    out = out.map((r, i) => ({ r, i })).sort((x, y) => {
      const a = col.value(x.r);
      const b = col.value(y.r);
      const blankA = a === null || a === undefined || a === '';
      const blankB = b === null || b === undefined || b === '';
      if (blankA || blankB) return blankA === blankB ? x.i - y.i : blankA ? 1 : -1;
      return compare(a, b) * dir || x.i - y.i;
    }).map((x) => x.r);
  }
  const perPage = Math.max(1, Math.floor(s.perPage));
  const pageCount = Math.max(1, Math.ceil(out.length / perPage));
  const page = Math.min(Math.max(1, Math.floor(s.page)), pageCount);
  return { rows: out.slice((page - 1) * perPage, page * perPage), total: out.length, page, pageCount };
}

/** The distinct values of a column, sorted: a filter's options. */
export function filterOptions<T>(rows: readonly T[], value: (r: T) => string | null | undefined): string[] {
  return [...new Set(rows.map(value).filter((v): v is string => !!v))].sort((a, b) => a.localeCompare(b));
}

// ── Labels ───────────────────────────────────────────────────────────────

export const REVENUE_TYPE_LABEL: Record<string, string> = {
  tickets: 'Tickets', fees: 'Buyer fees', tax: 'Tax', donations: 'Donations', refunds: 'Refunds', platform_fees: 'Platform fees',
  pos: 'POS sales', payouts: 'Payouts', box_office: 'Box office', bar: 'Bar / F&B', merchandise: 'Merchandise',
  membership: 'Memberships', delivery: 'Delivery', ticket_insurance: 'Ticket insurance', gift_cards: 'Gift cards', other: 'Other',
};
export const REVENUE_TYPES = Object.keys(REVENUE_TYPE_LABEL);

export const PAYMENT_METHOD_LABEL: Record<string, string> = {
  card: 'Card', cashapp: 'Cash App', paypal: 'PayPal', venmo: 'Venmo', gift_card: 'Gift card', cash: 'Cash (POS)',
  pos_card: 'Card (POS)', comp: 'Comps', split: 'Split (POS)',
};

export const SOURCE_TYPE_LABEL: Record<string, string> = {
  order: 'Order', refund: 'Refund', pos: 'POS', payout: 'Payout', imported: 'Imported',
};

export const IMPORT_SOURCES = ['box_office', 'bar', 'merchandise', 'donations', 'membership', 'delivery', 'ticket_insurance', 'gift_cards', 'other'];

export const label = (map: Record<string, string>, v: string | null | undefined) => (v ? map[v] ?? v : '');

// ── Ledger import (CSV) ──────────────────────────────────────────────────

/** "4.80" → 480, "-12" → -1200, "1,234.5" → 123450; null when it is not money. Exact (no floats). */
export function centsFromMajor(v: string): number | null {
  const s = v.trim().replace(/[\s,$€£]/g, '');
  const m = /^(-|\+)?(\d+)(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) return null;
  const n = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0') || '0');
  if (!Number.isSafeInteger(n) || n > 100_000_000_000) return null;
  return m[1] === '-' ? -n : n;
}

export interface LedgerImportPlan {
  rows: Record<string, unknown>[];
  errors: { row: number; error: string }[];
}

const COLUMN_ALIASES: Record<string, string> = {
  amount: 'amount', amount_cents: 'amount_cents', tax: 'tax_amount', tax_amount: 'tax_amount', tax_amount_cents: 'tax_amount_cents',
  source: 'source', description: 'description', memo: 'description', currency: 'currency', gl_code: 'gl_code',
  general_ledger_code: 'gl_code', tax_gl_code: 'tax_gl_code', tax_general_ledger_code: 'tax_gl_code', tax_name: 'tax_name',
  posted_at: 'posted_at', date: 'posted_at', source_system: 'source_system', source_line_id: 'source_line_id', line_id: 'source_line_id',
  source_order_id: 'source_order_id', order_id: 'source_order_id', import_run_id: 'import_run_id', event_id: 'event_id',
};

/**
 * A ledger CSV (one header row) to import rows. Amounts in major units
 * (amount, tax_amount) or cents (amount_cents, tax_amount_cents).
 * `defaults` fill blanks (the event chosen in the dialog, the system name).
 * At most 500 rows go in one import.
 */
export function planLedgerImport(text: string, defaults: { event_id?: string | null; source_system?: string; import_run_id?: string } = {}): LedgerImportPlan {
  const table = parseCsv(text).filter((r) => r.some((c) => c.trim() !== ''));
  const errors: LedgerImportPlan['errors'] = [];
  if (table.length < 2) return { rows: [], errors: [{ row: 0, error: 'The file needs a header row and at least one entry.' }] };
  const head = table[0].map((h) => COLUMN_ALIASES[h.trim().toLowerCase().replace(/[\s-]+/g, '_')] ?? null);
  for (const need of ['source', 'posted_at', 'source_line_id']) {
    if (!head.includes(need)) errors.push({ row: 0, error: `Missing column: ${need}.` });
  }
  if (!head.includes('amount') && !head.includes('amount_cents')) errors.push({ row: 0, error: 'Missing column: amount (or amount_cents).' });
  if (errors.length) return { rows: [], errors };
  const rows: Record<string, unknown>[] = [];
  table.slice(1).forEach((cells, i) => {
    const line = i + 2;
    const rec: Record<string, string> = {};
    head.forEach((k, j) => { if (k) rec[k] = (cells[j] ?? '').trim(); });
    const amount = rec.amount_cents !== undefined && rec.amount_cents !== '' ? (/^-?\d+$/.test(rec.amount_cents) ? Number(rec.amount_cents) : null)
      : centsFromMajor(rec.amount ?? '');
    if (amount === null) { errors.push({ row: line, error: 'amount is not a money amount.' }); return; }
    let tax = 0;
    if (rec.tax_amount_cents) {
      if (!/^-?\d+$/.test(rec.tax_amount_cents)) { errors.push({ row: line, error: 'tax_amount_cents is not whole cents.' }); return; }
      tax = Number(rec.tax_amount_cents);
    } else if (rec.tax_amount) {
      const t = centsFromMajor(rec.tax_amount);
      if (t === null) { errors.push({ row: line, error: 'tax_amount is not a money amount.' }); return; }
      tax = t;
    }
    const source = (rec.source ?? '').toLowerCase().replace(/[\s-]+/g, '_');
    if (!IMPORT_SOURCES.includes(source)) { errors.push({ row: line, error: `source must be one of ${IMPORT_SOURCES.join(', ')}.` }); return; }
    if (!rec.posted_at || Number.isNaN(Date.parse(rec.posted_at))) { errors.push({ row: line, error: 'posted_at is not a date.' }); return; }
    const system = (rec.source_system || defaults.source_system || '').toLowerCase();
    if (!system) { errors.push({ row: line, error: 'source_system is missing.' }); return; }
    if (!rec.source_line_id) { errors.push({ row: line, error: 'source_line_id is missing (it identifies the line).' }); return; }
    const out: Record<string, unknown> = {
      source, amount_cents: amount, tax_amount_cents: tax, posted_at: rec.posted_at, source_system: system, source_line_id: rec.source_line_id,
    };
    for (const k of ['description', 'currency', 'gl_code', 'tax_gl_code', 'tax_name', 'source_order_id']) if (rec[k]) out[k] = rec[k];
    const ev = rec.event_id || defaults.event_id;
    if (ev) out.event_id = ev;
    const run = rec.import_run_id || defaults.import_run_id;
    if (run) out.import_run_id = run;
    rows.push(out);
  });
  if (rows.length > 500) {
    errors.push({ row: 0, error: `${rows.length} entries: at most 500 per import (split the file).` });
    return { rows: [], errors };
  }
  return { rows, errors };
}

// ── Reporting-row export ───────────────────────────────────────────────────

export interface ReportingRowLike {
  occurred_at: string;
  event_id: string | null;
  source_type: string;
  source_id: string;
  revenue_type: string;
  currency: string;
  amount_cents: number;
  payment_method: string | null;
  gl_code: string | null;
  description: string;
  imported: boolean;
}

// A number, not text: the CSV writer quotes text that starts with "-" (formula guard).
const major = (c: number) => Math.round(c) / 100;

/** Rows as an accounting CSV (amounts in major units). */
export function reportingRowsCsv(rows: readonly ReportingRowLike[], eventName: (id: string | null) => string = () => ''): string {
  return toCsv(
    ['date', 'event', 'source', 'source_id', 'revenue_type', 'gl_code', 'currency', 'amount', 'payment_method', 'imported', 'description'],
    rows.map((r) => [r.occurred_at, eventName(r.event_id), r.source_type, r.source_id, r.revenue_type, r.gl_code ?? '', r.currency,
      major(r.amount_cents), r.payment_method ?? '', r.imported ? 'yes' : 'no', r.description]),
  );
}

/** Totals per currency (never summed across currencies). */
export function totalsByCurrency(rows: readonly { currency: string; amount_cents: number }[]): { currency: string; cents: number }[] {
  const m = new Map<string, number>();
  for (const r of rows) m.set(r.currency, (m.get(r.currency) ?? 0) + r.amount_cents);
  return [...m.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([currency, cents]) => ({ currency, cents }));
}
