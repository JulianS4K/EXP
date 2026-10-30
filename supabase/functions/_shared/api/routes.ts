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
// `scope`). Writes (POST / PUT / PATCH / DELETE) need a `:write` scope
// (apiRoutes.test.ts) and run through exos_api_write (mig 20261031110000).
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export type ApiMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface ApiRoute {
  id: string;
  method: ApiMethod;
  path: string;
  auth: 'api_key';
  /** null: any valid key (GET /me). */
  scope: Scope | null;
  paged: boolean;
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
  // -- The core API (mig 20261031110000): writes go through exos_api_write. --
  // Events
  { id: 'create-event', method: 'POST', auth: K, path: '/events', scope: 'events:write', paged: false },
  { id: 'update-event', method: 'PATCH', auth: K, path: '/events/:id', scope: 'events:write', paged: false },
  { id: 'get-publish-blockers', method: 'GET', auth: K, path: '/events/:id/publish-blockers', scope: 'events:read', paged: false },
  { id: 'publish-event', method: 'POST', auth: K, path: '/events/:id/publish', scope: 'events:write', paged: false },
  { id: 'unpublish-event', method: 'POST', auth: K, path: '/events/:id/unpublish', scope: 'events:write', paged: false },
  { id: 'get-ticketing-configuration', method: 'GET', auth: K, path: '/events/:id/ticketing-configuration', scope: 'events:read', paged: false },
  { id: 'list-event-fee-rules', method: 'GET', auth: K, path: '/events/:id/fee-rules', scope: 'events:read', paged: false },
  // Ticket types
  { id: 'get-ticket-type', method: 'GET', auth: K, path: '/events/:id/ticket-types/:tier', scope: 'events:read', paged: false },
  { id: 'create-ticket-type', method: 'POST', auth: K, path: '/events/:id/ticket-types', scope: 'events:write', paged: false },
  { id: 'update-ticket-type', method: 'PATCH', auth: K, path: '/events/:id/ticket-types/:tier', scope: 'events:write', paged: false },
  { id: 'delete-ticket-type', method: 'DELETE', auth: K, path: '/events/:id/ticket-types/:tier', scope: 'events:write', paged: false },
  // Add-ons
  { id: 'get-add-on', method: 'GET', auth: K, path: '/events/:id/add-ons/:addon', scope: 'events:read', paged: false },
  { id: 'create-add-on', method: 'POST', auth: K, path: '/events/:id/add-ons', scope: 'events:write', paged: false },
  { id: 'update-add-on', method: 'PATCH', auth: K, path: '/events/:id/add-ons/:addon', scope: 'events:write', paged: false },
  { id: 'delete-add-on', method: 'DELETE', auth: K, path: '/events/:id/add-ons/:addon', scope: 'events:write', paged: false },
  // Promo codes
  { id: 'get-promo-code', method: 'GET', auth: K, path: '/events/:id/promo-codes/:code', scope: 'events:read', paged: false },
  { id: 'create-promo-code', method: 'POST', auth: K, path: '/events/:id/promo-codes', scope: 'events:write', paged: false },
  { id: 'update-promo-code', method: 'PATCH', auth: K, path: '/events/:id/promo-codes/:code', scope: 'events:write', paged: false },
  { id: 'delete-promo-code', method: 'DELETE', auth: K, path: '/events/:id/promo-codes/:code', scope: 'events:write', paged: false },
  // Tickets and the door
  { id: 'list-tickets', method: 'GET', auth: K, path: '/tickets', scope: 'tickets:read', paged: true },
  { id: 'get-ticket', method: 'GET', auth: K, path: '/tickets/:id', scope: 'tickets:read', paged: false },
  { id: 'scan-lookup', method: 'GET', auth: K, path: '/scan-lookups/:code', scope: 'tickets:read', paged: false },
  { id: 'check-in-ticket', method: 'POST', auth: K, path: '/tickets/:id/check-in', scope: 'checkin:write', paged: false },
  { id: 'check-out-ticket', method: 'POST', auth: K, path: '/tickets/:id/check-out', scope: 'checkin:write', paged: false },
  { id: 'undo-check-in', method: 'POST', auth: K, path: '/tickets/:id/undo-check-in', scope: 'checkin:write', paged: false },
  { id: 'check-in-order', method: 'POST', auth: K, path: '/orders/:id/check-in', scope: 'checkin:write', paged: false },
  { id: 'submit-offline-check-ins', method: 'POST', auth: K, path: '/events/:id/offline-check-ins', scope: 'checkin:write', paged: false },
  // Comps (money-moving: always logged)
  { id: 'issue-comps', method: 'POST', auth: K, path: '/events/:id/comps', scope: 'tickets:write', paged: false },
  // Refunds (money-moving: Idempotency-Key required, refunds:write only)
  { id: 'get-refund-preview', method: 'GET', auth: K, path: '/orders/:id/refund-preview', scope: 'orders:read', paged: false },
  { id: 'create-refund', method: 'POST', auth: K, path: '/orders/:id/refunds', scope: 'refunds:write', paged: false },
  { id: 'get-refund', method: 'GET', auth: K, path: '/refunds/:id', scope: 'orders:read', paged: false },
  { id: 'get-refund-request', method: 'GET', auth: K, path: '/refund-requests/:id', scope: 'orders:read', paged: false },
  { id: 'list-disputes', method: 'GET', auth: K, path: '/disputes', scope: 'finance:read', paged: true },
  { id: 'get-dispute', method: 'GET', auth: K, path: '/disputes/:id', scope: 'finance:read', paged: false },
  { id: 'list-payouts', method: 'GET', auth: K, path: '/payouts', scope: 'finance:read', paged: true },
  { id: 'get-payout', method: 'GET', auth: K, path: '/payouts/:id', scope: 'finance:read', paged: false },
  // Guest lists
  { id: 'create-guest-list', method: 'POST', auth: K, path: '/events/:id/guest-lists', scope: 'tickets:write', paged: false },
  { id: 'update-guest-list', method: 'PATCH', auth: K, path: '/guest-lists/:id', scope: 'tickets:write', paged: false },
  { id: 'delete-guest-list', method: 'DELETE', auth: K, path: '/guest-lists/:id', scope: 'tickets:write', paged: false },
  { id: 'list-guests', method: 'GET', auth: K, path: '/guest-lists/:id/guests', scope: 'tickets:read', paged: true },
  { id: 'add-guests', method: 'POST', auth: K, path: '/guest-lists/:id/guests', scope: 'tickets:write', paged: false },
  { id: 'update-guest', method: 'PATCH', auth: K, path: '/guests/:id', scope: 'tickets:write', paged: false },
  { id: 'remove-guest', method: 'DELETE', auth: K, path: '/guests/:id', scope: 'tickets:write', paged: false },
  { id: 'check-in-guest', method: 'POST', auth: K, path: '/guests/:id/check-in', scope: 'checkin:write', paged: false },
  // Food and beverage (POS catalog) and door devices
  { id: 'list-pos-items', method: 'GET', auth: K, path: '/pos/items', scope: 'events:read', paged: true },
  { id: 'get-pos-item', method: 'GET', auth: K, path: '/pos/items/:id', scope: 'events:read', paged: false },
  { id: 'create-pos-item', method: 'POST', auth: K, path: '/pos/items', scope: 'events:write', paged: false },
  { id: 'update-pos-item', method: 'PATCH', auth: K, path: '/pos/items/:id', scope: 'events:write', paged: false },
  { id: 'list-pos-devices', method: 'GET', auth: K, path: '/pos/devices', scope: 'events:read', paged: false },
  // The API's own write log
  { id: 'list-api-writes', method: 'GET', auth: K, path: '/api-writes', scope: 'org:admin', paged: true },
];

/** Methods the API answers (anything else is 405). */
export const API_METHODS: readonly ApiMethod[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

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
