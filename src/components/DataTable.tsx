// The dashboard's one sortable, searchable, filterable, paged table: the
// finance screens (ledger rows, imported entries, brackets) and the
// templates / rental invoices / booking requests lists. The logic is
// src/lib/dataTable.ts; this only renders it. Row actions come from the
// caller, which hides the ones the viewer's role can't do.
//
// State is the caller's (`state` + `onState`, e.g. to keep it across tabs) or
// the table's own, started from `defaultSort` / `defaultStatus` / `perPage`.

import { ReactNode, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight } from 'lucide-react';
import {
  applyTable, initialTable, pageLabel, PER_PAGE_CHOICES, setFilter, setPerPage, setQuery, setStatus, statusCounts,
  toggleSort, type SortState, type TableColumn, type TableState,
} from '../lib/dataTable';
import { BTN, FLD, LABEL } from './finance/ui';

export interface DataColumn<T> extends TableColumn<T> {
  header: string;
  /** The cell (omit: the column's value as text). */
  render?: (row: T) => ReactNode;
  align?: 'left' | 'right';
  className?: string;
}

/** A select over one column's values (exact match). */
export interface DataFilter {
  key: string;
  label: string;
  options: { value: string; label: string }[];
}

export interface DataTableProps<T> {
  rows: readonly T[];
  rowKey: (row: T) => string;
  columns: readonly DataColumn<T>[];
  /** The table's accessible name. */
  label: string;
  /** Controlled state; omit both for the table's own. */
  state?: TableState;
  onState?: (s: TableState) => void;
  defaultSort?: SortState;
  defaultStatus?: string;
  perPage?: number;
  filters?: readonly DataFilter[];
  /** Status filter chips with counts (needs `status`). */
  statuses?: readonly string[];
  status?: (row: T) => string;
  /** Text searched besides the searchable columns. */
  searchFields?: (row: T) => (string | null | undefined)[];
  searchPlaceholder?: string;
  actions?: (row: T) => ReactNode;
  onRowClick?: (row: T) => void;
  toolbar?: ReactNode;
  empty?: string;
  /** Compact cells, no card, a row count and a per-page choice (the finance screens). */
  dense?: boolean;
}

export default function DataTable<T>(p: DataTableProps<T>) {
  const [own, setOwn] = useState<TableState>(() =>
    initialTable(p.defaultSort?.key ?? null, p.defaultSort?.dir ?? 'asc', p.perPage ?? 25, p.defaultStatus ?? 'all'));
  const state = p.state ?? own;
  const onState = p.onState ?? setOwn;
  const { rows, columns, searchFields, status } = p;
  const view = useMemo(() => applyTable(rows, state, columns, { searchFields, status }), [rows, state, columns, searchFields, status]);
  const counts = useMemo(() => (status ? statusCounts(rows, status) : {}), [rows, status]);
  const searchable = !!searchFields || columns.some((c) => c.searchable);
  const filters = p.filters ?? [];
  const span = columns.length + (p.actions ? 1 : 0);
  const cell = p.dense ? 'py-1.5 px-1' : 'p-3';
  const sortOf: SortState | null = state.sortKey === null ? null : { key: state.sortKey, dir: state.sortDir };

  return (
    <div>
      {(searchable || filters.length > 0 || (p.statuses && status) || p.toolbar) && (
        <div className={`flex flex-wrap gap-2 mb-3 ${p.dense ? 'items-end' : 'items-center'}`}>
          {searchable && (p.dense ? (
            <label className="flex-1 min-w-[180px]"><span className={LABEL}>Search</span>
              <input className={FLD} type="search" value={state.query} placeholder={p.searchPlaceholder}
                onChange={(e) => onState(setQuery(state, e.target.value))} /></label>
          ) : (
            <input className={`${FLD} max-w-xs`} type="search" aria-label={`Search ${p.label}`} placeholder={p.searchPlaceholder ?? 'Search'}
              value={state.query} onChange={(e) => onState(setQuery(state, e.target.value))} />
          ))}
          {filters.map((f) => (
            <label key={f.key}><span className={LABEL}>{f.label}</span>
              <select className={FLD} value={state.filters[f.key] ?? ''} onChange={(e) => onState(setFilter(state, f.key, e.target.value))}>
                <option value="">All</option>
                {f.options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </select></label>
          ))}
          {p.statuses && status && ['all', ...p.statuses].map((s) => (
            <button key={s} type="button" aria-pressed={state.status === s}
              className={`${BTN} ${state.status === s ? 'border-slate-900 text-slate-900' : ''}`}
              onClick={() => onState(setStatus(state, s))}>
              {s}{s !== 'all' && counts[s] ? ` ${counts[s]}` : ''}
            </button>
          ))}
          {p.toolbar}
        </div>
      )}
      <div className={p.dense ? 'overflow-x-auto' : 'bg-white border border-slate-200 rounded overflow-x-auto'}>
        <table className="w-full text-sm">
          <caption className="sr-only">{p.label}</caption>
          <thead>
            <tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
              {columns.map((c) => {
                const active = sortOf?.key === c.key;
                const sortable = !!c.value && c.sortable !== false;
                return (
                  <th key={c.key} scope="col" className={`${p.dense ? 'py-1 px-1' : 'p-3'} ${c.align === 'right' ? 'text-right' : ''}`}
                    aria-sort={active ? (sortOf!.dir === 'asc' ? 'ascending' : 'descending') : undefined}>
                    {sortable ? (
                      <button type="button" className="inline-flex items-center gap-1 uppercase tracking-widest hover:text-slate-900"
                        onClick={() => onState(toggleSort(state, c.key))}>
                        {c.header}
                        {active && (sortOf!.dir === 'asc' ? <ArrowUp size={10} /> : <ArrowDown size={10} />)}
                      </button>
                    ) : c.header}
                  </th>
                );
              })}
              {p.actions && <th scope="col" className={cell}><span className="sr-only">Actions</span></th>}
            </tr>
          </thead>
          <tbody>
            {view.rows.map((r) => (
              <tr key={p.rowKey(r)} className={`border-t border-slate-100 ${p.onRowClick ? 'hover:bg-slate-50 cursor-pointer' : ''}`}
                onClick={p.onRowClick ? () => p.onRowClick!(r) : undefined}>
                {columns.map((c) => (
                  <td key={c.key} className={`${cell} ${c.align === 'right' ? 'text-right tabular-nums' : ''} ${c.className ?? ''}`}>
                    {c.render ? c.render(r) : String(c.value?.(r) ?? '')}
                  </td>
                ))}
                {p.actions && (
                  <td className={`${cell} text-right whitespace-nowrap`} onClick={(e) => e.stopPropagation()}>
                    <div className="inline-flex gap-1">{p.actions(r)}</div>
                  </td>
                )}
              </tr>
            ))}
            {!view.rows.length && <tr><td colSpan={span} className="p-6 text-center text-slate-400">{p.empty ?? 'Nothing here.'}</td></tr>}
          </tbody>
        </table>
      </div>
      {p.dense ? (
        <div className="flex flex-wrap items-center justify-between gap-2 mt-3 text-xs text-slate-500">
          <span>{view.total} row{view.total === 1 ? '' : 's'}</span>
          <div className="flex items-center gap-2">
            <label className="flex items-center gap-1">Per page
              <select className="border border-slate-200 rounded px-1 py-0.5" value={state.perPage}
                onChange={(e) => onState(setPerPage(state, Number(e.target.value)))}>
                {PER_PAGE_CHOICES.map((n) => <option key={n} value={n}>{n}</option>)}
              </select></label>
            <button type="button" className={BTN} disabled={view.page <= 1} onClick={() => onState({ ...state, page: view.page - 1 })}>Prev</button>
            <span>Page {view.page} of {view.pageCount}</span>
            <button type="button" className={BTN} disabled={view.page >= view.pageCount} onClick={() => onState({ ...state, page: view.page + 1 })}>Next</button>
          </div>
        </div>
      ) : view.pageCount > 1 && (
        <div className="flex items-center justify-end gap-2 mt-2 text-xs text-slate-500">
          <span>{pageLabel(view)}</span>
          <button type="button" className={BTN} aria-label="Previous page" disabled={view.page <= 1} onClick={() => onState({ ...state, page: view.page - 1 })}><ChevronLeft size={12} /></button>
          <button type="button" className={BTN} aria-label="Next page" disabled={view.page >= view.pageCount} onClick={() => onState({ ...state, page: view.page + 1 })}><ChevronRight size={12} /></button>
        </div>
      )}
    </div>
  );
}
