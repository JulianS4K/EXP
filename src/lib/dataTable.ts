// Client-side list logic for the dashboard's tables (templates, rental
// invoices, booking requests): search, status filter, sort and paging over
// rows already loaded. Pure: no React, no Supabase. src/components/DataTable.tsx
// renders it.

export type SortDir = 'asc' | 'desc';

export interface SortState<K extends string = string> {
  key: K;
  dir: SortDir;
}

export interface TableQuery<K extends string = string> {
  /** Free text, matched case-insensitively against `searchFields`. */
  search?: string;
  /** Only rows whose status is this ('' / 'all' / undefined: every row). */
  status?: string;
  sort?: SortState<K> | null;
  page?: number;
  perPage?: number;
}

export interface TablePage<T> {
  rows: T[];
  /** Rows matching the search and filter, before paging. */
  total: number;
  page: number;
  pages: number;
  perPage: number;
}

type Value = string | number | boolean | null | undefined | Date;

/** The comparable value of a cell: numbers as numbers, dates by time, text lowercased. */
export function sortValue(v: Value): number | string | null {
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

/** Compare two cells; empty cells always sort last, whichever the direction. */
export function compareValues(a: Value, b: Value, dir: SortDir = 'asc'): number {
  const x = sortValue(a);
  const y = sortValue(b);
  if (x === null && y === null) return 0;
  if (x === null) return 1;
  if (y === null) return -1;
  let c: number;
  if (typeof x === 'number' && typeof y === 'number') c = x - y;
  else c = String(x).localeCompare(String(y), undefined, { numeric: true });
  return dir === 'asc' ? c : -c;
}

/** Clicking a column header: a new column sorts ascending, the same one flips. */
export function nextSort<K extends string>(current: SortState<K> | null | undefined, key: K): SortState<K> {
  if (!current || current.key !== key) return { key, dir: 'asc' };
  return { key, dir: current.dir === 'asc' ? 'desc' : 'asc' };
}

/**
 * Search, filter, sort (stable: ties keep their order) and page `rows`.
 * `get` reads a column for sorting; `searchFields` names the text searched.
 */
export function queryRows<T, K extends string>(
  rows: readonly T[],
  q: TableQuery<K>,
  opts: {
    get: (row: T, key: K) => Value;
    searchFields?: (row: T) => readonly (string | null | undefined)[];
    status?: (row: T) => string | null | undefined;
  },
): TablePage<T> {
  const needle = (q.search ?? '').trim().toLowerCase();
  const status = q.status && q.status !== 'all' ? q.status : '';
  let out = rows.filter((r) => {
    if (status && opts.status && opts.status(r) !== status) return false;
    if (needle && opts.searchFields) {
      return opts.searchFields(r).some((f) => (f ?? '').toLowerCase().includes(needle));
    }
    return true;
  });
  if (q.sort) {
    const { key, dir } = q.sort;
    out = out.map((r, i) => [r, i] as const)
      .sort((a, b) => compareValues(opts.get(a[0], key), opts.get(b[0], key), dir) || a[1] - b[1])
      .map(([r]) => r);
  }
  const perPage = Math.max(1, Math.min(200, Math.floor(q.perPage ?? 25)));
  const total = out.length;
  const pages = Math.max(1, Math.ceil(total / perPage));
  const page = Math.min(pages, Math.max(1, Math.floor(q.page ?? 1)));
  return { rows: out.slice((page - 1) * perPage, page * perPage), total, page, pages, perPage };
}

/** "11-20 of 43" (or "0 of 0"). */
export function pageLabel(p: Pick<TablePage<unknown>, 'total' | 'page' | 'perPage'>): string {
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
