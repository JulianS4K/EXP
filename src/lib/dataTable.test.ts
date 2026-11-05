import { describe, expect, it } from 'vitest';
import {
  applyTable, compareValues, filterOptions, initialTable, nextSort, pageLabel, setFilter, setPerPage, setQuery, setStatus,
  sortValue, statusCounts, toggleSort, type TableColumn,
} from './dataTable';

// The finance screens' use: column values, searchable columns, column filters.
describe('applyTable: columns, search, filters', () => {
  interface R { id: string; name: string; amount: number | null; kind: string }
  const rows: R[] = [
    { id: 'a', name: 'Row 10', amount: 300, kind: 'bar' },
    { id: 'b', name: 'row 2', amount: null, kind: 'tickets' },
    { id: 'c', name: 'Row 1', amount: -50, kind: 'bar' },
    { id: 'd', name: 'Beer night', amount: 300, kind: 'bar' },
  ];
  const cols: TableColumn<R>[] = [
    { key: 'name', value: (r) => r.name, searchable: true },
    { key: 'amount', value: (r) => r.amount },
    { key: 'kind', value: (r) => r.kind, searchable: true },
  ];
  const ids = (v: { rows: R[] }) => v.rows.map((r) => r.id);

  it('sorts text naturally and case-insensitively, either way', () => {
    const s = initialTable('name');
    expect(ids(applyTable(rows, s, cols))).toEqual(['d', 'c', 'b', 'a']);
    expect(ids(applyTable(rows, toggleSort(s, 'name'), cols))).toEqual(['a', 'b', 'c', 'd']);
  });
  it('sorts numbers, keeps ties in input order and blanks last both ways', () => {
    const s = toggleSort(initialTable('name'), 'amount');
    expect(s.sortDir).toBe('asc');
    expect(ids(applyTable(rows, s, cols))).toEqual(['c', 'a', 'd', 'b']);
    expect(ids(applyTable(rows, toggleSort(s, 'amount'), cols))).toEqual(['a', 'd', 'c', 'b']);
  });
  it('searches every word across searchable columns, filters exactly', () => {
    expect(ids(applyTable(rows, setQuery(initialTable('name'), 'ROW bar'), cols))).toEqual(['c', 'a']);
    expect(ids(applyTable(rows, setFilter(initialTable('name'), 'kind', 'tickets'), cols))).toEqual(['b']);
    expect(ids(applyTable(rows, setFilter(initialTable('name'), 'kind', ''), cols))).toHaveLength(4);
  });
  it('pages, and clamps a page past the end', () => {
    const s = { ...initialTable('name'), perPage: 3 };
    const p1 = applyTable(rows, s, cols);
    expect([p1.total, p1.pageCount, p1.rows.length]).toEqual([4, 2, 3]);
    const p9 = applyTable(rows, { ...s, page: 9 }, cols);
    expect([p9.page, ids(p9)]).toEqual([2, ['a']]);
    expect(applyTable([], s, cols)).toEqual({ rows: [], total: 0, page: 1, pageCount: 1, perPage: 3 });
  });
  it('a new sort, search, filter, status or page size goes back to page 1', () => {
    const s = { ...initialTable('name'), page: 3 };
    expect(toggleSort(s, 'amount').page).toBe(1);
    expect(setQuery(s, 'x').page).toBe(1);
    expect(setFilter(s, 'kind', 'bar').page).toBe(1);
    expect(setStatus(s, 'active').page).toBe(1);
    expect(setPerPage(s, 50)).toMatchObject({ page: 1, perPage: 50 });
  });
  it('filter options are distinct and sorted', () => {
    expect(filterOptions(rows, (r) => r.kind)).toEqual(['bar', 'tickets']);
  });
});

// The templates / inbound lists' use: status chips, extra search fields, dates.
describe('applyTable: status, search fields, dates', () => {
  const rows = [
    { id: 'a', name: 'Zed', n: 3, s: 'active', at: '2026-11-02T10:00:00Z' },
    { id: 'b', name: 'alpha', n: 10, s: 'archived', at: '2026-10-01T10:00:00Z' },
    { id: 'c', name: 'Beta', n: null, s: 'active', at: null },
    { id: 'd', name: 'beta', n: 3, s: 'active', at: '2026-11-03T10:00:00Z' },
  ];
  type R = (typeof rows)[number];
  const cols: TableColumn<R>[] = [
    { key: 'name', value: (r) => r.name },
    { key: 'n', value: (r) => r.n },
    { key: 'at', value: (r) => r.at },
  ];
  const ids = (v: { rows: R[] }) => v.rows.map((r) => r.id);
  const status = (r: R) => r.s;

  it('compares numbers, dates and text; empty cells last both ways', () => {
    expect(sortValue('2026-11-02')).toBe(Date.parse('2026-11-02'));
    expect(sortValue('Abc')).toBe('abc');
    expect(compareValues(2, 10)).toBeLessThan(0);
    expect(compareValues('item 2', 'item 10')).toBeLessThan(0);
    expect(compareValues(null, 1, 'asc')).toBe(1);
    expect(compareValues(null, 1, 'desc')).toBe(1);
  });

  it('sorts stably, filters by status and search, pages', () => {
    expect(ids(applyTable(rows, initialTable('n'), cols))).toEqual(['a', 'd', 'b', 'c']);
    expect(ids(applyTable(rows, initialTable('name', 'desc'), cols))).toEqual(['a', 'c', 'd', 'b']);
    expect(ids(applyTable(rows, initialTable('at', 'desc'), cols))).toEqual(['d', 'a', 'b', 'c']);
    const active = applyTable(rows, setQuery(setStatus(initialTable(), 'active'), 'BET'), cols, { status, searchFields: (r) => [r.name] });
    expect(ids(active)).toEqual(['c', 'd']);
    expect(applyTable(rows, initialTable(null, 'asc', 25, 'all'), cols, { status }).total).toBe(4);
    expect(applyTable(rows, initialTable(null, 'asc', 25, 'archived'), cols, { status }).total).toBe(1);
    const p2 = applyTable(rows, { ...initialTable(null, 'asc', 3), page: 2 }, cols);
    expect([ids(p2), p2.page, p2.pageCount]).toEqual([['d'], 2, 2]);
    expect(applyTable(rows, { ...initialTable(null, 'asc', 3), page: 99 }, cols).page).toBe(2);
    expect(pageLabel(p2)).toBe('4-4 of 4');
    expect(pageLabel({ total: 0, page: 1, perPage: 25 })).toBe('0 of 0');
  });

  it('no sort key keeps the rows in their own order; page size is capped', () => {
    expect(ids(applyTable(rows, initialTable(), cols))).toEqual(['a', 'b', 'c', 'd']);
    expect(applyTable(rows, initialTable(null, 'asc', 10_000), cols).perPage).toBe(200);
  });

  it('flips the sort on the same column and counts statuses', () => {
    expect(nextSort(null, 'name')).toEqual({ key: 'name', dir: 'asc' });
    expect(nextSort({ key: 'name', dir: 'asc' }, 'name')).toEqual({ key: 'name', dir: 'desc' });
    expect(nextSort({ key: 'name', dir: 'desc' }, 'n')).toEqual({ key: 'n', dir: 'asc' });
    expect(toggleSort(initialTable(), 'name')).toMatchObject({ sortKey: 'name', sortDir: 'asc' });
    expect(statusCounts(rows, (r) => r.s)).toEqual({ active: 3, archived: 1 });
  });
});
