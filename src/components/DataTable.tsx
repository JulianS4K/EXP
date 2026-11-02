// A sortable, searchable, paged table for the dashboard's lists (templates,
// rental invoices, booking requests), styled like the offers tables. The
// logic is src/lib/dataTable.ts; this only renders it. Row actions come from
// the caller, which hides the ones the viewer's role can't do.

import { ReactNode, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight } from 'lucide-react';
import { nextSort, pageLabel, queryRows, statusCounts, type SortState } from '../lib/dataTable';
import { BTN, FLD } from './finance/ui';

export interface Column<T> {
  key: string;
  label: string;
  /** The value sorted on (omit: the column isn't sortable). */
  sortValue?: (row: T) => string | number | boolean | null | undefined;
  render: (row: T) => ReactNode;
  align?: 'left' | 'right';
  className?: string;
}

export interface DataTableProps<T> {
  rows: readonly T[];
  columns: Column<T>[];
  rowKey: (row: T) => string;
  /** Text searched by the search box (omit: no search box). */
  searchFields?: (row: T) => (string | null | undefined)[];
  searchPlaceholder?: string;
  /** Status filter chips (omit: none). */
  statuses?: readonly string[];
  status?: (row: T) => string;
  defaultStatus?: string;
  defaultSort?: SortState;
  perPage?: number;
  actions?: (row: T) => ReactNode;
  onRowClick?: (row: T) => void;
  empty?: string;
  label: string;
}

export default function DataTable<T>(p: DataTableProps<T>) {
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState(p.defaultStatus ?? 'all');
  const [sort, setSort] = useState<SortState | null>(p.defaultSort ?? null);
  const [page, setPage] = useState(1);
  const cols = p.columns;
  const counts = useMemo(() => (p.status ? statusCounts(p.rows, p.status) : {}), [p.rows, p.status]);
  const result = useMemo(() => queryRows(p.rows, { search, status, sort, page, perPage: p.perPage ?? 25 }, {
    get: (r, key) => cols.find((c) => c.key === key)?.sortValue?.(r),
    searchFields: p.searchFields,
    status: p.status,
  }), [p.rows, search, status, sort, page, p.perPage, cols, p.searchFields, p.status]);
  const span = cols.length + (p.actions ? 1 : 0);

  return (
    <div>
      {(p.searchFields || p.statuses) && (
        <div className="flex flex-wrap gap-2 items-center mb-3">
          {p.searchFields && (
            <input className={`${FLD} max-w-xs`} type="search" aria-label={`Search ${p.label}`} placeholder={p.searchPlaceholder ?? 'Search'}
              value={search} onChange={(e) => { setSearch(e.target.value); setPage(1); }} />
          )}
          {p.statuses && ['all', ...p.statuses].map((s) => (
            <button key={s} type="button" aria-pressed={status === s}
              className={`${BTN} ${status === s ? 'border-slate-900 text-slate-900' : ''}`}
              onClick={() => { setStatus(s); setPage(1); }}>
              {s}{s !== 'all' && counts[s] ? ` ${counts[s]}` : ''}
            </button>
          ))}
        </div>
      )}
      <div className="bg-white border border-slate-200 rounded overflow-x-auto">
        <table className="w-full text-sm" aria-label={p.label}>
          <thead>
            <tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
              {cols.map((c) => {
                const active = sort?.key === c.key;
                return (
                  <th key={c.key} className={`p-3 ${c.align === 'right' ? 'text-right' : ''}`}
                    aria-sort={active ? (sort!.dir === 'asc' ? 'ascending' : 'descending') : undefined}>
                    {c.sortValue ? (
                      <button type="button" className="inline-flex items-center gap-1 uppercase tracking-widest hover:text-slate-900"
                        onClick={() => { setSort(nextSort(sort, c.key)); setPage(1); }}>
                        {c.label}
                        {active && (sort!.dir === 'asc' ? <ArrowUp size={10} /> : <ArrowDown size={10} />)}
                      </button>
                    ) : c.label}
                  </th>
                );
              })}
              {p.actions && <th className="p-3" />}
            </tr>
          </thead>
          <tbody>
            {result.rows.map((r) => (
              <tr key={p.rowKey(r)} className={`border-t border-slate-100 ${p.onRowClick ? 'hover:bg-slate-50 cursor-pointer' : ''}`}
                onClick={p.onRowClick ? () => p.onRowClick!(r) : undefined}>
                {cols.map((c) => (
                  <td key={c.key} className={`p-3 ${c.align === 'right' ? 'text-right tabular-nums' : ''} ${c.className ?? ''}`}>{c.render(r)}</td>
                ))}
                {p.actions && (
                  <td className="p-3 text-right whitespace-nowrap" onClick={(e) => e.stopPropagation()}>
                    <div className="inline-flex gap-1">{p.actions(r)}</div>
                  </td>
                )}
              </tr>
            ))}
            {!result.rows.length && <tr><td colSpan={span} className="p-6 text-center text-slate-400">{p.empty ?? 'Nothing here.'}</td></tr>}
          </tbody>
        </table>
      </div>
      {result.pages > 1 && (
        <div className="flex items-center justify-end gap-2 mt-2 text-xs text-slate-500">
          <span>{pageLabel(result)}</span>
          <button type="button" className={BTN} aria-label="Previous page" disabled={result.page <= 1} onClick={() => setPage(result.page - 1)}><ChevronLeft size={12} /></button>
          <button type="button" className={BTN} aria-label="Next page" disabled={result.page >= result.pages} onClick={() => setPage(result.page + 1)}><ChevronRight size={12} /></button>
        </div>
      )}
    </div>
  );
}
