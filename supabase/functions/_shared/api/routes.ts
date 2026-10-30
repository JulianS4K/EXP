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
// `auth`: `api_key` is a bearer credential of the organization: an org API
// key (sk_live_…), a personal access token (exos_pat_…) or an OAuth access
// token (exos_oat_…), held to `scope` (docs/developer-platform.md).
// `partner_key` is a distribution partner's key (dk_live_…, ?shared_key= or
// X-Shared-Key, docs/partner-sales.md): the Opendate partner contract under
// /public/…, which needs no scope but the partner's own (inventory / comps).
// `paged`: true for the API's { data, meta } lists, 'opendate' for
// Opendate's { current_page, per_page, total_entries, total_pages,
// collection } envelope.
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export type ApiMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
export type ApiAuth = 'api_key' | 'partner_key';

export interface ApiRoute {
  id: string;
  method: ApiMethod;
  path: string;
  auth: ApiAuth;
  /** null: any valid key (GET /me, the team roles, every partner-key route). */
  scope: Scope | null;
  paged: boolean | 'opendate';
}

const K = 'api_key' as const;
const P = 'partner_key' as const;

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

  // Distribution partners and their keys (mig 20261031130000, docs/partner-sales.md).
  { id: 'list-distribution-partners', method: 'GET', auth: K, path: '/distribution-partners', scope: 'org:admin', paged: false },
  { id: 'create-distribution-partner', method: 'POST', auth: K, path: '/distribution-partners', scope: 'org:admin', paged: false },
  { id: 'update-distribution-partner', method: 'PATCH', auth: K, path: '/distribution-partners/:id', scope: 'org:admin', paged: false },
  { id: 'revoke-distribution-partner', method: 'DELETE', auth: K, path: '/distribution-partners/:id', scope: 'org:admin', paged: false },
  { id: 'get-event-distribution', method: 'GET', auth: K, path: '/events/:id/distribution', scope: 'events:read', paged: false },
  { id: 'set-event-distribution', method: 'PUT', auth: K, path: '/events/:id/distribution', scope: 'events:write', paged: false },
  // Reservations of an event (partner and organizer), and organizer
  // reservations made with this credential (a box office, a kiosk).
  { id: 'list-ticket-reservations', method: 'GET', auth: K, path: '/events/:id/ticket-reservations', scope: 'orders:read', paged: true },
  { id: 'get-ticket-reservation', method: 'GET', auth: K, path: '/events/:id/ticket-reservations/:token', scope: 'orders:read', paged: false },
  { id: 'build-organizer-reservation', method: 'POST', auth: K, path: '/events/:id/organizer-reservations/build', scope: 'tickets:write', paged: false },
  { id: 'create-organizer-reservation', method: 'POST', auth: K, path: '/events/:id/organizer-reservations', scope: 'tickets:write', paged: false },
  { id: 'update-organizer-reservation', method: 'PUT', auth: K, path: '/events/:id/organizer-reservations/:token', scope: 'tickets:write', paged: false },
  { id: 'cancel-organizer-reservation', method: 'DELETE', auth: K, path: '/events/:id/organizer-reservations/:token', scope: 'tickets:write', paged: false },
  { id: 'complete-organizer-reservation', method: 'POST', auth: K, path: '/events/:id/organizer-reservations/:token/complete', scope: 'tickets:write', paged: false },

  // The team: the organization, its members, invitations and roles
  // (mig 20261031130500, docs/developer-platform.md).
  { id: 'get-team', method: 'GET', auth: K, path: '/team', scope: 'org:admin', paged: false },
  { id: 'update-team', method: 'PATCH', auth: K, path: '/team', scope: 'org:admin', paged: false },
  { id: 'list-team-members', method: 'GET', auth: K, path: '/team/members', scope: 'org:admin', paged: false },
  { id: 'update-team-member', method: 'PATCH', auth: K, path: '/team/members/:id', scope: 'org:admin', paged: false },
  { id: 'remove-team-member', method: 'DELETE', auth: K, path: '/team/members/:id', scope: 'org:admin', paged: false },
  { id: 'list-team-invitations', method: 'GET', auth: K, path: '/team/invitations', scope: 'org:admin', paged: false },
  { id: 'create-team-invitation', method: 'POST', auth: K, path: '/team/invitations', scope: 'org:admin', paged: false },
  { id: 'cancel-team-invitation', method: 'DELETE', auth: K, path: '/team/invitations/:id', scope: 'org:admin', paged: false },
  { id: 'list-team-roles', method: 'GET', auth: K, path: '/team/roles', scope: null, paged: false },
  { id: 'list-my-memberships', method: 'GET', auth: K, path: '/me/memberships', scope: null, paged: false },
  { id: 'revoke-current-token', method: 'DELETE', auth: K, path: '/personal-access-tokens/current', scope: null, paged: false },

  // The Opendate partner contract (partner key).
  { id: 'public-list-ticket-types', method: 'GET', auth: P, path: '/public/confirms/:id/ticket_types', scope: null, paged: false },
  { id: 'public-create-reservation', method: 'POST', auth: P, path: '/public/confirms/:id/ticket_reservations', scope: null, paged: false },
  { id: 'public-get-reservation', method: 'GET', auth: P, path: '/public/confirms/:id/ticket_reservations/:token', scope: null, paged: false },
  { id: 'public-update-reservation', method: 'PUT', auth: P, path: '/public/confirms/:id/ticket_reservations/:token', scope: null, paged: false },
  { id: 'public-cancel-reservation', method: 'DELETE', auth: P, path: '/public/confirms/:id/ticket_reservations/:token', scope: null, paged: false },
  { id: 'public-complete-reservation', method: 'POST', auth: P, path: '/public/confirms/:id/ticket_reservations/:token/complete', scope: null, paged: false },
  { id: 'public-create-comp', method: 'POST', auth: P, path: '/public/confirms/:id/comps', scope: null, paged: false },
  { id: 'public-list-orders', method: 'GET', auth: P, path: '/public/orders', scope: null, paged: 'opendate' },
  { id: 'public-get-order', method: 'GET', auth: P, path: '/public/orders/:id', scope: null, paged: false },
  { id: 'public-list-ticket-links', method: 'GET', auth: P, path: '/public/orders/:id/ticket_pdfs', scope: null, paged: false },
  { id: 'public-get-ticket-link', method: 'GET', auth: P, path: '/public/orders/:id/ticket_pdfs/:ticket', scope: null, paged: false },
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

/** True for a path of the partner contract (/public/…). */
export function isPartnerPath(path: string): boolean {
  return path === '/public' || path.startsWith('/public/');
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

/** The methods some route answers at this path (for 405 Allow). */
export function methodsAt(path: string): ApiMethod[] {
  return API_METHODS.filter((m) => matchRoute(m, path) !== null);
}
