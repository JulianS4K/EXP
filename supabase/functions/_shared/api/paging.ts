// Page / per_page for the partner API's list routes. docs/api-reference.md.
//
// Every list takes ?page=1&per_page=50 (per_page 1-200) and answers
//   { data: [...], meta: { page, per_page, total, total_pages } }
// so a client can walk the list with page until page >= total_pages. The
// envelope keeps `data` where the unpaged API had it, so old clients that
// only read `data` keep working (they now get the first 50 rows).
//
// Pure TypeScript, imported by vitest.

export const PER_PAGE_DEFAULT = 50;
export const PER_PAGE_MAX = 200;
export const PAGE_MAX = 10_000;

export interface Page {
  page: number;
  perPage: number;
  /** Inclusive row range for PostgREST .range(from, to). */
  from: number;
  to: number;
}

export class PagingError extends Error {}

function int(raw: string, name: string, min: number, max: number): number {
  if (!/^\d{1,7}$/.test(raw)) throw new PagingError(`${name} must be a whole number.`);
  const n = Number(raw);
  if (n < min || n > max) throw new PagingError(`${name} must be between ${min} and ${max}.`);
  return n;
}

export function parsePage(q: URLSearchParams): Page {
  const pageRaw = q.get('page');
  const perRaw = q.get('per_page');
  const page = pageRaw === null ? 1 : int(pageRaw, 'page', 1, PAGE_MAX);
  const perPage = perRaw === null ? PER_PAGE_DEFAULT : int(perRaw, 'per_page', 1, PER_PAGE_MAX);
  const from = (page - 1) * perPage;
  return { page, perPage, from, to: from + perPage - 1 };
}

export interface PageMeta {
  page: number;
  per_page: number;
  total: number;
  total_pages: number;
}

export function pageEnvelope<T>(data: T[], page: Page, total: number | null): { data: T[]; meta: PageMeta } {
  const t = total ?? data.length;
  return {
    data,
    meta: { page: page.page, per_page: page.perPage, total: t, total_pages: Math.max(1, Math.ceil(t / page.perPage)) },
  };
}
