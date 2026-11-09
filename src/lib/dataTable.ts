// Client-side list logic for the dashboard's tables: the finance screens
// (ledger rows, imported entries, brackets; mig 20261102120000) and the
// templates / rental invoices / booking requests lists (mig 20261102130000).
// Search, column filters, a status filter, sort and paging over rows already
// loaded. Pure: no React, no Supabase. src/components/DataTable.tsx renders
// it; tested in src/lib/dataTable.test.ts.

export type SortDir = 'asc' | 'desc';

export interface SortState<K extends string = string> {
  key: K;
  dir: SortDir;
}

export type CellValue = string | number | boolean | null | undefined | Date;

export interface TableState {
  /** Free text: every word must appear in the row's searchable text. */
  query: string;
  /** The column sorted on (null: the rows' own order). */
  sortKey: string | null;
  sortDir: SortDir;
  page: number;
  perPage: number;
  /** column key → selected value ('' = any). */
  filters: Record<string, string>;
  /** Only rows with this status ('all' = every row). */
  status: string;
}

export interface TableColumn<T> {
  key: string;
  /** The value sorted on, filtered on and (when searchable) searched. Omit: not sortable. */
  value?: (row: T) => CellValue;
  searchable?: boolean;
  /** false: the header doesn't sort even though the column has a value. */
  sortable?: boolean;
}

export interface TableOptions<T> {
  /** Extra text searched besides the searchable columns. */
  searchFields?: (row: T) => readonly (string | null | undefined)[];
  /** A row's status, for `TableState.status`. */
  status?: (row: T) => string | null | undefined;
}

export interface TableView<T> {
  rows: T[];
  /** Rows after search and filters (before paging). */
  total: number;
  page: number;
  pageCount: number;
  perPage: number;
}

export const PER_PAGE_CHOICES = [25, 50, 100] as const;
const MAX_PER_PAGE = 200;

export function initialTable(
  sortKey: string | null = null, sortDir: SortDir = 'asc', perPage = 25, status = 'all',
): TableState {
  return { query: '', sortKey, sortDir, page: 1, perPage, filters: {}, status };
}

/** Clicking a column header: a new column sorts ascending, the same one flips. */
export function nextSort<K extends string>(current: SortState<K> | null | undefined, key: K): SortState<K> {
  if (!current || current.key !== key) return { key, dir: 'asc' };
  return { key, dir: current.dir === 'asc' ? 'desc' : 'asc' };
}

/** nextSort on a table state, back to page 1. */
export function toggleSort(s: TableState, key: string): TableState {
  const n = nextSort(s.sortKey === null ? null : { key: s.sortKey, dir: s.sortDir }, key);
  return { ...s, sortKey: n.key, sortDir: n.dir, page: 1 };
}

export function setFilter(s: TableState, key: string, value: string): TableState {
  return { ...s, filters: { ...s.filters, [key]: value }, page: 1 };
}

export function setQuery(s: TableState, query: string): TableState {
  return { ...s, query, page: 1 };
}

export function setStatus(s: TableState, status: string): TableState {
  return { ...s, status, page: 1 };
}

export function setPerPage(s: TableState, perPage: number): TableState {
  return { ...s, perPage, page: 1 };
}

/** The comparable value of a cell: numbers as numbers, dates by time, text lowercased. */
export function sortValue(v: CellValue): number | string | null {
  if (v === null || v === undefined || v === '') return null;
  if (v instanceof Date) return v.getTime();
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (/^\d{4}-\d{2}-\d{2}([T ][\d:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v)) {
    const t = Date.parse(v);
    if (!Number.isNaN(t)) return t;
  }
  return v.toLowerCase();
}

/** Compare two cells; empty cells always sort last, whichever the direction. Text sorts naturally ("Row 2" < "Row 10"). */
export function compareValues(a: CellValue, b: CellValue, dir: SortDir = 'asc'): number {
  const x = sortValue(a);
  const y = sortValue(b);
  if (x === null && y === null) return 0;
  if (x === null) return 1;
  if (y === null) return -1;
  let c: number;
  if (typeof x === 'number' && typeof y === 'number') c = x - y;
  else c = String(x).localeCompare(String(y), 'en', { numeric: true, sensitivity: 'base' });
  return dir === 'asc' ? c : -c;
}

/**
 * Status, column filters (exact match on the column's value), search
 * (case-insensitive; every word in the row's searchable columns and
 * searchFields), a stable sort (ties keep their order, blanks last) and the
 * page. A page past the end clamps to the last one.
 */
export function applyTable<T>(
  rows: readonly T[], s: TableState, columns: readonly TableColumn<T>[], opts: TableOptions<T> = {},
): TableView<T> {
  const byKey = new Map(columns.map((c) => [c.key, c]));
  const words = s.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const searchable = columns.filter((c) => c.searchable && c.value);
  const status = s.status && s.status !== 'all' ? s.status : '';
  let out = rows.filter((r) => {
    if (status && opts.status && opts.status(r) !== status) return false;
    for (const [k, v] of Object.entries(s.filters)) {
      if (v === '') continue;
      const col = byKey.get(k);
      if (col?.value && String(col.value(r) ?? '') !== v) return false;
    }
    if (!words.length) return true;
    const hay = [
      ...searchable.map((c) => String(c.value!(r) ?? '')),
      ...(opts.searchFields ? opts.searchFields(r).map((f) => f ?? '') : []),
    ].join(' ').toLowerCase();
    return words.every((w) => hay.includes(w));
  });
  const col = s.sortKey === null ? undefined : byKey.get(s.sortKey);
  if (col?.value) {
    const get = col.value;
    out = out.map((r, i) => [r, i] as const)
      .sort((a, b) => compareValues(get(a[0]), get(b[0]), s.sortDir) || a[1] - b[1])
      .map(([r]) => r);
  }
  const perPage = Math.max(1, Math.min(MAX_PER_PAGE, Math.floor(s.perPage)));
  const total = out.length;
  const pageCount = Math.max(1, Math.ceil(total / perPage));
  const page = Math.min(pageCount, Math.max(1, Math.floor(s.page)));
  return { rows: out.slice((page - 1) * perPage, page * perPage), total, page, pageCount, perPage };
}

/** "11-20 of 43" (or "0 of 0"). */
export function pageLabel(p: Pick<TableView<unknown>, 'total' | 'page' | 'perPage'>): string {
  if (p.total === 0) return '0 of 0';
  const from = (p.page - 1) * p.perPage + 1;
  const to = Math.min(p.total, p.page * p.perPage);
  return `${from}-${to} of ${p.total}`;
}

/** Counts per status, for the filter chips ("new 4 · reviewing 1"). */
export function statusCounts<T>(rows: readonly T[], status: (row: T) => string | null | undefined): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of rows) {
    const s = status(r) ?? '';
    out[s] = (out[s] ?? 0) + 1;
  }
  return out;
}

/** The distinct values of a column, sorted: a filter's options. */
export function filterOptions<T>(rows: readonly T[], value: (r: T) => string | null | undefined): string[] {
  return [...new Set(rows.map(value).filter((v): v is string => !!v))].sort((a, b) => a.localeCompare(b));
}
