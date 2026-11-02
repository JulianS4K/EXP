// A sortable, filterable, paged table for the finance screens (ledger rows,
// imported entries, brackets). The logic is src/lib/financeTables.ts; this
// only draws it, in the finance screens' style (./ui.tsx).

import { ReactNode, useMemo } from 'react';
import { ArrowDown, ArrowUp } from 'lucide-react';
import {
  applyTable, PER_PAGE_CHOICES, setFilter, setQuery, toggleSort, type TableColumn, type TableState,
} from '../../lib/financeTables';
import { BTN, FLD, LABEL } from './ui';

export interface DataColumn<T> extends TableColumn<T> {
  header: string;
  render?: (row: T) => ReactNode;
  align?: 'left' | 'right';
  sortable?: boolean;
}

export interface DataFilter {
  key: string;
  label: string;
  options: { value: string; label: string }[];
}

interface Props<T> {
  rows: readonly T[];
  rowKey: (row: T) => string;
  columns: readonly DataColumn<T>[];
  state: TableState;
  onState: (s: TableState) => void;
  filters?: readonly DataFilter[];
  /** Row actions; omit (or return null) for roles that can't act. */
  actions?: (row: T) => ReactNode;
  searchPlaceholder?: string;
  empty?: string;
  toolbar?: ReactNode;
  caption: string;
}

export default function DataTable<T>({ rows, rowKey, columns, state, onState, filters = [], actions, searchPlaceholder, empty, toolbar, caption }: Props<T>) {
  const view = useMemo(() => applyTable(rows, state, columns), [rows, state, columns]);
  const searchable = columns.some((c) => c.searchable);
  return (
    <div>
      <div className="flex flex-wrap gap-2 items-end mb-3">
        {searchable && (
          <label className="flex-1 min-w-[180px]"><span className={LABEL}>Search</span>
            <input className={FLD} type="search" value={state.query} placeholder={searchPlaceholder} onChange={(e) => onState(setQuery(state, e.target.value))} /></label>
        )}
        {filters.map((f) => (
          <label key={f.key}><span className={LABEL}>{f.label}</span>
            <select className={FLD} value={state.filters[f.key] ?? ''} onChange={(e) => onState(setFilter(state, f.key, e.target.value))}>
              <option value="">All</option>
              {f.options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select></label>
        ))}
        {toolbar}
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <caption className="sr-only">{caption}</caption>
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-slate-400">
              {columns.map((c) => {
                const active = state.sortKey === c.key;
                const align = c.align === 'right' ? 'text-right' : 'text-left';
                return (
                  <th key={c.key} scope="col" className={`py-1 px-1 ${align}`}
                    aria-sort={active ? (state.sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                    {c.sortable === false ? c.header : (
                      <button type="button" className="inline-flex items-center gap-1 uppercase tracking-widest hover:text-slate-700"
                        onClick={() => onState(toggleSort(state, c.key))}>
                        {c.header}
                        {active && (state.sortDir === 'asc' ? <ArrowUp size={10} /> : <ArrowDown size={10} />)}
                      </button>
                    )}
                  </th>
                );
              })}
              {actions && <th scope="col" className="py-1 px-1"><span className="sr-only">Actions</span></th>}
            </tr>
          </thead>
          <tbody>
            {view.rows.map((r) => (
              <tr key={rowKey(r)} className="border-t border-slate-100">
                {columns.map((c) => (
                  <td key={c.key} className={`py-1.5 px-1 ${c.align === 'right' ? 'text-right tabular-nums' : ''}`}>
                    {c.render ? c.render(r) : String(c.value(r) ?? '')}
                  </td>
                ))}
                {actions && <td className="py-1.5 px-1 text-right whitespace-nowrap">{actions(r)}</td>}
              </tr>
            ))}
            {!view.rows.length && (
              <tr><td colSpan={columns.length + (actions ? 1 : 0)} className="p-6 text-center text-slate-400">{empty ?? 'Nothing here.'}</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <div className="flex flex-wrap items-center justify-between gap-2 mt-3 text-xs text-slate-500">
        <span>{view.total} row{view.total === 1 ? '' : 's'}</span>
        <div className="flex items-center gap-2">
          <label className="flex items-center gap-1">Per page
            <select className="border border-slate-200 rounded px-1 py-0.5" value={state.perPage}
              onChange={(e) => onState({ ...state, perPage: Number(e.target.value), page: 1 })}>
              {PER_PAGE_CHOICES.map((n) => <option key={n} value={n}>{n}</option>)}
            </select></label>
          <button className={BTN} disabled={view.page <= 1} onClick={() => onState({ ...state, page: view.page - 1 })}>Prev</button>
          <span>Page {view.page} of {view.pageCount}</span>
          <button className={BTN} disabled={view.page >= view.pageCount} onClick={() => onState({ ...state, page: view.page + 1 })}>Next</button>
        </div>
      </div>
    </div>
  );
}
