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
// ones the first release documented). `aliases` are extra spellings of the
// same route (Opendate-style underscores, e.g. /holds/:id/convert_to_confirm);
// they are matched but documented on the route, not as endpoints of their own.
//
// Writes (POST / PUT / PATCH / DELETE) arrived with the sales counts (mig
// 20261030120000) and booking (mig 20261030100000); each needs a `:write`
// scope.
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export type ApiMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface ApiRoute {
  id: string;
  method: ApiMethod;
  path: string;
  /** null: any valid key (GET /me). */
  scope: Scope | null;
  paged: boolean;
  /** Other paths answering the same route. */
  aliases?: readonly string[];
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
  // Reserved seating (mig 20261030140000).
  { id: 'list-seats', method: 'GET', path: '/events/:id/seats', scope: 'tickets:read', paged: false },
  { id: 'get-seat-reconciliation', method: 'GET', path: '/events/:id/seat-reconciliation', scope: 'tickets:read', paged: false },
  { id: 'list-waitlist', method: 'GET', path: '/events/:id/waitlist', scope: 'orders:read', paged: true },
  { id: 'list-orders', method: 'GET', path: '/orders', scope: 'orders:read', paged: true },
  { id: 'get-order', method: 'GET', path: '/orders/:id', scope: 'orders:read', paged: false },
  { id: 'list-invoices', method: 'GET', path: '/invoices', scope: 'orders:read', paged: true },
  { id: 'list-refunds', method: 'GET', path: '/refunds', scope: 'orders:read', paged: true },
  { id: 'list-webhooks', method: 'GET', path: '/webhooks', scope: 'webhooks:read', paged: false },
  // Tickets sold on other platforms (mig 20261030120000). The first write
  // routes: each needs a :write scope (apiRoutes.test.ts).
  { id: 'list-sales-counts', method: 'GET', path: '/sales-counts', scope: 'finance:read', paged: true },
  { id: 'get-sales-count', method: 'GET', path: '/sales-counts/:id', scope: 'finance:read', paged: false },
  { id: 'create-sales-count', method: 'POST', path: '/sales-counts', scope: 'finance:write', paged: false },
  { id: 'update-sales-count', method: 'PUT', path: '/sales-counts/:id', scope: 'finance:write', paged: false },
  { id: 'delete-sales-count', method: 'DELETE', path: '/sales-counts/:id', scope: 'finance:write', paged: false },
  { id: 'list-event-sales-counts', method: 'GET', path: '/events/:id/sales-counts', scope: 'finance:read', paged: false },
  { id: 'import-sales-counts', method: 'POST', path: '/events/:id/sales-counts/import', scope: 'finance:write', paged: false },
  { id: 'find-eventbrite-event', method: 'GET', path: '/eventbrite-events/:id', scope: 'events:read', paged: false },

  // Booking (mig 20261030100000, docs/booking.md).
  { id: 'list-venues', method: 'GET', path: '/venues', scope: 'booking:read', paged: true, aliases: ['/venue_ownerships'] },
  { id: 'create-venue', method: 'POST', path: '/venues', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships'] },
  { id: 'get-venue', method: 'GET', path: '/venues/:id', scope: 'booking:read', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'update-venue', method: 'PATCH', path: '/venues/:id', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'delete-venue', method: 'DELETE', path: '/venues/:id', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'list-venue-rooms', method: 'GET', path: '/venues/:id/rooms', scope: 'booking:read', paged: false },
  { id: 'create-room', method: 'POST', path: '/venues/:id/rooms', scope: 'booking:write', paged: false },
  { id: 'list-rooms', method: 'GET', path: '/rooms', scope: 'booking:read', paged: true },
  { id: 'get-room', method: 'GET', path: '/rooms/:id', scope: 'booking:read', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'update-room', method: 'PATCH', path: '/rooms/:id', scope: 'booking:write', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'delete-room', method: 'DELETE', path: '/rooms/:id', scope: 'booking:write', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'list-holds', method: 'GET', path: '/holds', scope: 'booking:read', paged: true },
  { id: 'create-hold', method: 'POST', path: '/holds', scope: 'booking:write', paged: false },
  { id: 'get-hold', method: 'GET', path: '/holds/:id', scope: 'booking:read', paged: false },
  { id: 'update-hold', method: 'PATCH', path: '/holds/:id', scope: 'booking:write', paged: false },
  { id: 'clear-hold', method: 'POST', path: '/holds/:id/clear', scope: 'booking:write', paged: false },
  {
    id: 'convert-hold', method: 'POST', path: '/holds/:id/convert-to-event', scope: 'booking:write', paged: false,
    aliases: ['/holds/:id/convert_to_event', '/holds/:id/convert_to_confirm'],
  },
  { id: 'get-calendar', method: 'GET', path: '/calendar', scope: 'booking:read', paged: false },
  {
    id: 'list-show-activities', method: 'GET', path: '/events/:id/show-activities', scope: 'booking:read', paged: true,
    aliases: ['/events/:id/show_activities', '/confirms/:id/show_activities'],
  },
  {
    id: 'create-show-activity', method: 'POST', path: '/events/:id/show-activities', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities', '/confirms/:id/show_activities'],
  },
  {
    id: 'get-show-activity', method: 'GET', path: '/events/:id/show-activities/:aid', scope: 'booking:read', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  {
    id: 'update-show-activity', method: 'PATCH', path: '/events/:id/show-activities/:aid', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  {
    id: 'delete-show-activity', method: 'DELETE', path: '/events/:id/show-activities/:aid', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  { id: 'list-event-notes', method: 'GET', path: '/events/:id/notes', scope: 'booking:read', paged: true },
  { id: 'create-event-note', method: 'POST', path: '/events/:id/notes', scope: 'booking:write', paged: false },
  { id: 'list-notes', method: 'GET', path: '/notes', scope: 'booking:read', paged: true },
  { id: 'get-note', method: 'GET', path: '/notes/:id', scope: 'booking:read', paged: false },
  { id: 'update-note', method: 'PATCH', path: '/notes/:id', scope: 'booking:write', paged: false },
  { id: 'delete-note', method: 'DELETE', path: '/notes/:id', scope: 'booking:write', paged: false },
  { id: 'list-event-contacts', method: 'GET', path: '/events/:id/contacts', scope: 'booking:read', paged: true },
  { id: 'create-event-contact', method: 'POST', path: '/events/:id/contacts', scope: 'booking:write', paged: false },
  { id: 'list-contacts', method: 'GET', path: '/event-contacts', scope: 'booking:read', paged: true, aliases: ['/calendar_event_contacts'] },
  { id: 'get-contact', method: 'GET', path: '/event-contacts/:id', scope: 'booking:read', paged: false, aliases: ['/calendar_event_contacts/:id'] },
  { id: 'update-contact', method: 'PATCH', path: '/event-contacts/:id', scope: 'booking:write', paged: false, aliases: ['/calendar_event_contacts/:id'] },
  { id: 'delete-contact', method: 'DELETE', path: '/event-contacts/:id', scope: 'booking:write', paged: false, aliases: ['/calendar_event_contacts/:id'] },
];

/** Methods exos-api answers. */
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
    for (const pattern of [route.path, ...(route.aliases ?? [])]) {
      const want = pattern.split('/').filter(Boolean);
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
  }
  return null;
}

/** The methods some route answers on this path: a known path asked with another method is a 405. */
export function allowedMethods(path: string): ApiMethod[] {
  return API_METHODS.filter((x) => matchRoute(x, path) !== null);
}
