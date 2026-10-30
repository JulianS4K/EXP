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
// `auth`: `api_key` (an org API key, Authorization: Bearer sk_live_…, held to
// `scope`) or `shared_key` (a listing-feed shared key, ?shared_key=sh_live_…
// or X-Shared-Key; it reads the public feed of one org and nothing else).
// `paged`: true for the API's { data, meta } lists, 'opendate' for the
// listing feed's { current_page, per_page, total_entries, total_pages,
// collection } envelope.
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export type ApiMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface ApiRoute {
  id: string;
  method: ApiMethod;
  path: string;
  auth: 'api_key' | 'shared_key';
  /** null: any valid key (GET /me, and every shared-key route). */
  scope: Scope | null;
  paged: boolean | 'opendate';
}

const K = 'api_key' as const;

export const ROUTES: readonly ApiRoute[] = [
  { id: 'me', method: 'GET', auth: K, path: '/me', scope: null, paged: false },
  { id: 'list-events', method: 'GET', auth: K, path: '/events', scope: 'events:read', paged: true },
  { id: 'get-event', method: 'GET', auth: K, path: '/events/:id', scope: 'events:read', paged: false },
  { id: 'list-ticket-types', method: 'GET', auth: K, path: '/events/:id/ticket-types', scope: 'events:read', paged: false },
  { id: 'list-add-ons', method: 'GET', auth: K, path: '/events/:id/add-ons', scope: 'events:read', paged: false },
  { id: 'list-promo-codes', method: 'GET', auth: K, path: '/events/:id/promo-codes', scope: 'events:read', paged: true },
  { id: 'list-attendees', method: 'GET', auth: K, path: '/events/:id/attendees', scope: 'tickets:read', paged: true },
  { id: 'list-check-ins', method: 'GET', auth: K, path: '/events/:id/check-ins', scope: 'tickets:read', paged: true },
  { id: 'list-check-in-lists', method: 'GET', auth: K, path: '/events/:id/check-in-lists', scope: 'tickets:read', paged: false },
  { id: 'list-guest-lists', method: 'GET', auth: K, path: '/events/:id/guest-lists', scope: 'tickets:read', paged: false },
  { id: 'list-waitlist', method: 'GET', auth: K, path: '/events/:id/waitlist', scope: 'orders:read', paged: true },
  { id: 'list-orders', method: 'GET', auth: K, path: '/orders', scope: 'orders:read', paged: true },
  { id: 'get-order', method: 'GET', auth: K, path: '/orders/:id', scope: 'orders:read', paged: false },
  { id: 'list-invoices', method: 'GET', auth: K, path: '/invoices', scope: 'orders:read', paged: true },
  { id: 'list-refunds', method: 'GET', auth: K, path: '/refunds', scope: 'orders:read', paged: true },
  { id: 'list-webhooks', method: 'GET', auth: K, path: '/webhooks', scope: 'webhooks:read', paged: false },
  // Artists and lineups (mig 20261030110000, docs/listing-feed.md).
  { id: 'list-artists', method: 'GET', auth: K, path: '/artists', scope: 'events:read', paged: true },
  { id: 'create-artist', method: 'POST', auth: K, path: '/artists', scope: 'events:write', paged: false },
  { id: 'get-artist', method: 'GET', auth: K, path: '/artists/:id', scope: 'events:read', paged: false },
  { id: 'update-artist', method: 'PATCH', auth: K, path: '/artists/:id', scope: 'events:write', paged: false },
  { id: 'merge-artist', method: 'POST', auth: K, path: '/artists/:id/merge', scope: 'events:write', paged: false },
  { id: 'list-artist-events', method: 'GET', auth: K, path: '/artists/:id/events', scope: 'events:read', paged: true },
  { id: 'get-lineup', method: 'GET', auth: K, path: '/events/:id/lineup', scope: 'events:read', paged: false },
  { id: 'set-lineup', method: 'PUT', auth: K, path: '/events/:id/lineup', scope: 'events:write', paged: false },
  // Listing-feed shared keys: minting one publishes the org's feed to a partner.
  { id: 'list-listing-keys', method: 'GET', auth: K, path: '/listing-keys', scope: 'org:admin', paged: false },
  { id: 'create-listing-key', method: 'POST', auth: K, path: '/listing-keys', scope: 'org:admin', paged: false },
  { id: 'revoke-listing-key', method: 'DELETE', auth: K, path: '/listing-keys/:id', scope: 'org:admin', paged: false },
  // The public listing feed (shared key). /public/confirms is the same feed
  // under Opendate's name, for partners that already read Opendate.
  { id: 'public-list-events', method: 'GET', auth: 'shared_key', path: '/public/events', scope: null, paged: 'opendate' },
  { id: 'public-get-event', method: 'GET', auth: 'shared_key', path: '/public/events/:id', scope: null, paged: false },
  { id: 'public-list-confirms', method: 'GET', auth: 'shared_key', path: '/public/confirms', scope: null, paged: 'opendate' },
  { id: 'public-get-confirm', method: 'GET', auth: 'shared_key', path: '/public/confirms/:id', scope: null, paged: false },
];

/** Methods the API answers (anything else is 405). */
export const API_METHODS: readonly ApiMethod[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

/** True for a path under the shared-key family (/public/…). */
export function isSharedKeyPath(path: string): boolean {
  return path === '/public' || path.startsWith('/public/');
}

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
