// The partner API's route table (exos-api). docs/api-reference.md.
//
// One row per route: the scope it needs and whether it is a paged list. The
// edge function dispatches on `id`; src/lib/apiReference.test.ts checks that
// every row has a docs/api/*.json entry and every documented exos-api path a
// row, so a route can't ship undocumented or unscoped. The matcher itself is
// tested in src/lib/apiRoutes.test.ts.
//
// Paths are relative to the function (…/functions/v1/exos-api). Each is
// reachable with or without a leading /v1 (the unversioned paths are the
// ones the first release documented).
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export interface ApiRoute {
  id: string;
  method: 'GET';
  path: string;
  /** null: any valid key (GET /me). */
  scope: Scope | null;
  paged: boolean;
}

export const ROUTES: readonly ApiRoute[] = [
  { id: 'me', method: 'GET', path: '/me', scope: null, paged: false },
  { id: 'list-events', method: 'GET', path: '/events', scope: 'events:read', paged: true },
  { id: 'get-event', method: 'GET', path: '/events/:id', scope: 'events:read', paged: false },
  { id: 'list-ticket-types', method: 'GET', path: '/events/:id/ticket-types', scope: 'events:read', paged: false },
  { id: 'list-add-ons', method: 'GET', path: '/events/:id/add-ons', scope: 'events:read', paged: false },
  { id: 'list-promo-codes', method: 'GET', path: '/events/:id/promo-codes', scope: 'events:read', paged: true },
  { id: 'list-attendees', method: 'GET', path: '/events/:id/attendees', scope: 'tickets:read', paged: true },
  { id: 'list-check-ins', method: 'GET', path: '/events/:id/check-ins', scope: 'tickets:read', paged: true },
  { id: 'list-check-in-lists', method: 'GET', path: '/events/:id/check-in-lists', scope: 'tickets:read', paged: false },
  { id: 'list-guest-lists', method: 'GET', path: '/events/:id/guest-lists', scope: 'tickets:read', paged: false },
  { id: 'list-waitlist', method: 'GET', path: '/events/:id/waitlist', scope: 'orders:read', paged: true },
  { id: 'list-orders', method: 'GET', path: '/orders', scope: 'orders:read', paged: true },
  { id: 'get-order', method: 'GET', path: '/orders/:id', scope: 'orders:read', paged: false },
  { id: 'list-invoices', method: 'GET', path: '/invoices', scope: 'orders:read', paged: true },
  { id: 'list-refunds', method: 'GET', path: '/refunds', scope: 'orders:read', paged: true },
  { id: 'list-webhooks', method: 'GET', path: '/webhooks', scope: 'webhooks:read', paged: false },
];

export interface RouteMatch {
  route: ApiRoute;
  params: Record<string, string>;
}

/**
 * The function-relative path of a request URL path: everything after
 * `/exos-api`, without a leading `/v1` or a trailing slash.
 */
export function apiPath(urlPath: string): string {
  const p = urlPath.replace(/^.*?\/exos-api(?=\/|$)/, '').replace(/\/+$/, '');
  return p.replace(/^\/v1(?=\/|$)/, '') || '/';
}

/** The route for a method and function-relative path, or null. */
export function matchRoute(method: string, path: string): RouteMatch | null {
  const m = method.toUpperCase();
  const segs = path.split('/').filter(Boolean);
  for (const route of ROUTES) {
    if (route.method !== m) continue;
    const want = route.path.split('/').filter(Boolean);
    if (want.length !== segs.length) continue;
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < want.length; i++) {
      if (want[i].startsWith(':')) {
        try { params[want[i].slice(1)] = decodeURIComponent(segs[i]); }
        catch { return null; } // malformed %-escape: no route can match it
      } else if (want[i] !== segs[i]) { ok = false; break; }
    }
    if (ok) return { route, params };
  }
  return null;
}
