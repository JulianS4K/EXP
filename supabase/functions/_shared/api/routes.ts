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
// Writes (POST / PATCH / DELETE) arrived with booking (mig 20261030100000);
// each needs a `:write` scope.
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
  /** Other paths answering the same route. */
  aliases?: readonly string[];
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

  // Booking (mig 20261030100000, docs/booking.md).
  { id: 'list-venues', method: 'GET', auth: K, path: '/venues', scope: 'booking:read', paged: true, aliases: ['/venue_ownerships'] },
  { id: 'create-venue', method: 'POST', auth: K, path: '/venues', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships'] },
  { id: 'get-venue', method: 'GET', auth: K, path: '/venues/:id', scope: 'booking:read', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'update-venue', method: 'PATCH', auth: K, path: '/venues/:id', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'delete-venue', method: 'DELETE', auth: K, path: '/venues/:id', scope: 'booking:write', paged: false, aliases: ['/venue_ownerships/:id'] },
  { id: 'list-venue-rooms', method: 'GET', auth: K, path: '/venues/:id/rooms', scope: 'booking:read', paged: false },
  { id: 'create-room', method: 'POST', auth: K, path: '/venues/:id/rooms', scope: 'booking:write', paged: false },
  { id: 'list-rooms', method: 'GET', auth: K, path: '/rooms', scope: 'booking:read', paged: true },
  { id: 'get-room', method: 'GET', auth: K, path: '/rooms/:id', scope: 'booking:read', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'update-room', method: 'PATCH', auth: K, path: '/rooms/:id', scope: 'booking:write', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'delete-room', method: 'DELETE', auth: K, path: '/rooms/:id', scope: 'booking:write', paged: false, aliases: ['/venues/:vid/rooms/:id'] },
  { id: 'list-holds', method: 'GET', auth: K, path: '/holds', scope: 'booking:read', paged: true },
  { id: 'create-hold', method: 'POST', auth: K, path: '/holds', scope: 'booking:write', paged: false },
  { id: 'get-hold', method: 'GET', auth: K, path: '/holds/:id', scope: 'booking:read', paged: false },
  { id: 'update-hold', method: 'PATCH', auth: K, path: '/holds/:id', scope: 'booking:write', paged: false },
  { id: 'clear-hold', method: 'POST', auth: K, path: '/holds/:id/clear', scope: 'booking:write', paged: false },
  {
    id: 'convert-hold', method: 'POST', auth: K, path: '/holds/:id/convert-to-event', scope: 'booking:write', paged: false,
    aliases: ['/holds/:id/convert_to_event', '/holds/:id/convert_to_confirm'],
  },
  { id: 'get-calendar', method: 'GET', auth: K, path: '/calendar', scope: 'booking:read', paged: false },
  {
    id: 'list-show-activities', method: 'GET', auth: K, path: '/events/:id/show-activities', scope: 'booking:read', paged: true,
    aliases: ['/events/:id/show_activities', '/confirms/:id/show_activities'],
  },
  {
    id: 'create-show-activity', method: 'POST', auth: K, path: '/events/:id/show-activities', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities', '/confirms/:id/show_activities'],
  },
  {
    id: 'get-show-activity', method: 'GET', auth: K, path: '/events/:id/show-activities/:aid', scope: 'booking:read', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  {
    id: 'update-show-activity', method: 'PATCH', auth: K, path: '/events/:id/show-activities/:aid', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  {
    id: 'delete-show-activity', method: 'DELETE', auth: K, path: '/events/:id/show-activities/:aid', scope: 'booking:write', paged: false,
    aliases: ['/events/:id/show_activities/:aid', '/confirms/:id/show_activities/:aid'],
  },
  { id: 'list-event-notes', method: 'GET', auth: K, path: '/events/:id/notes', scope: 'booking:read', paged: true },
  { id: 'create-event-note', method: 'POST', auth: K, path: '/events/:id/notes', scope: 'booking:write', paged: false },
  { id: 'list-notes', method: 'GET', auth: K, path: '/notes', scope: 'booking:read', paged: true },
  { id: 'get-note', method: 'GET', auth: K, path: '/notes/:id', scope: 'booking:read', paged: false },
  { id: 'update-note', method: 'PATCH', auth: K, path: '/notes/:id', scope: 'booking:write', paged: false },
  { id: 'delete-note', method: 'DELETE', auth: K, path: '/notes/:id', scope: 'booking:write', paged: false },
  { id: 'list-event-contacts', method: 'GET', auth: K, path: '/events/:id/contacts', scope: 'booking:read', paged: true },
  { id: 'create-event-contact', method: 'POST', auth: K, path: '/events/:id/contacts', scope: 'booking:write', paged: false },
  { id: 'list-contacts', method: 'GET', auth: K, path: '/event-contacts', scope: 'booking:read', paged: true, aliases: ['/calendar_event_contacts'] },
  { id: 'get-contact', method: 'GET', auth: K, path: '/event-contacts/:id', scope: 'booking:read', paged: false, aliases: ['/calendar_event_contacts/:id'] },
  { id: 'update-contact', method: 'PATCH', auth: K, path: '/event-contacts/:id', scope: 'booking:write', paged: false, aliases: ['/calendar_event_contacts/:id'] },
  { id: 'delete-contact', method: 'DELETE', auth: K, path: '/event-contacts/:id', scope: 'booking:write', paged: false, aliases: ['/calendar_event_contacts/:id'] },


  // Offers, budgets, pools, templates, imports, deals (mig 20261031100000,
  // docs/offers-settlements.md). Opendate's v3 names are aliases.
  { id: 'list-offers', method: 'GET', auth: K, path: '/offers', scope: 'booking:read', paged: true, aliases: ['/v3_offers'] },
  { id: 'create-offer', method: 'POST', auth: K, path: '/offers', scope: 'booking:write', paged: false, aliases: ['/v3_offers'] },
  { id: 'get-offer', method: 'GET', auth: K, path: '/offers/:id', scope: 'booking:read', paged: false, aliases: ['/v3_offers/:id'] },
  { id: 'update-offer', method: 'PATCH', auth: K, path: '/offers/:id', scope: 'booking:write', paged: false, aliases: ['/v3_offers/:id'] },
  { id: 'delete-offer', method: 'DELETE', auth: K, path: '/offers/:id', scope: 'booking:write', paged: false, aliases: ['/v3_offers/:id'] },
  {
    id: 'send-offer', method: 'POST', auth: K, path: '/offers/:id/send', scope: 'booking:write', paged: false,
    aliases: ['/offers/:id/send_offer', '/v3_offers/:id/send_offer'],
  },
  { id: 'accept-offer', method: 'POST', auth: K, path: '/offers/:id/accept', scope: 'booking:write', paged: false, aliases: ['/v3_offers/:id/accept'] },
  { id: 'decline-offer', method: 'POST', auth: K, path: '/offers/:id/decline', scope: 'booking:write', paged: false, aliases: ['/v3_offers/:id/decline'] },
  { id: 'cancel-offer', method: 'POST', auth: K, path: '/offers/:id/cancel', scope: 'booking:write', paged: false },
  { id: 'get-offer-pdf', method: 'GET', auth: K, path: '/offers/:id/pdf', scope: 'booking:read', paged: false },
  { id: 'list-offer-templates', method: 'GET', auth: K, path: '/offer-templates', scope: 'booking:read', paged: false, aliases: ['/v3_offer_templates'] },
  { id: 'create-offer-template', method: 'POST', auth: K, path: '/offer-templates', scope: 'booking:write', paged: false, aliases: ['/v3_offer_templates'] },
  { id: 'get-offer-template', method: 'GET', auth: K, path: '/offer-templates/:id', scope: 'booking:read', paged: false, aliases: ['/v3_offer_templates/:id'] },
  { id: 'update-offer-template', method: 'PATCH', auth: K, path: '/offer-templates/:id', scope: 'booking:write', paged: false, aliases: ['/v3_offer_templates/:id'] },
  { id: 'delete-offer-template', method: 'DELETE', auth: K, path: '/offer-templates/:id', scope: 'booking:write', paged: false, aliases: ['/v3_offer_templates/:id'] },
  {
    id: 'apply-offer-template', method: 'POST', auth: K, path: '/offer-templates/:id/apply', scope: 'booking:write', paged: false,
    aliases: ['/offer-templates/:id/apply_template', '/v3_offer_templates/:id/apply_template'],
  },
  { id: 'list-budgets', method: 'GET', auth: K, path: '/budgets', scope: 'booking:read', paged: true, aliases: ['/v3_budgets'] },
  { id: 'get-budget', method: 'GET', auth: K, path: '/budgets/:id', scope: 'booking:read', paged: false, aliases: ['/v3_budgets/:id'] },
  { id: 'update-budget', method: 'PATCH', auth: K, path: '/budgets/:id', scope: 'booking:write', paged: false, aliases: ['/v3_budgets/:id'] },
  { id: 'list-budget-lines', method: 'GET', auth: K, path: '/budgets/:id/lines', scope: 'booking:read', paged: false },
  { id: 'create-budget-line', method: 'POST', auth: K, path: '/budgets/:id/lines', scope: 'booking:write', paged: false },
  { id: 'update-budget-line', method: 'PATCH', auth: K, path: '/budget-lines/:id', scope: 'booking:write', paged: false, aliases: ['/v3_budget_line_items/:id'] },
  { id: 'delete-budget-line', method: 'DELETE', auth: K, path: '/budget-lines/:id', scope: 'booking:write', paged: false, aliases: ['/v3_budget_line_items/:id'] },
  { id: 'create-offer-pool', method: 'POST', auth: K, path: '/offer-pools', scope: 'booking:write', paged: false, aliases: ['/v3_offer_pools'] },
  { id: 'get-offer-pool', method: 'GET', auth: K, path: '/offer-pools/:id', scope: 'booking:read', paged: false, aliases: ['/v3_offer_pools/:id'] },
  { id: 'update-offer-pool', method: 'PATCH', auth: K, path: '/offer-pools/:id', scope: 'booking:write', paged: false, aliases: ['/v3_offer_pools/:id'] },
  { id: 'list-offer-imports', method: 'GET', auth: K, path: '/offer-imports', scope: 'booking:read', paged: true, aliases: ['/offer_imports'] },
  { id: 'create-offer-import', method: 'POST', auth: K, path: '/offer-imports', scope: 'booking:write', paged: false, aliases: ['/offer_imports'] },
  { id: 'get-offer-import', method: 'GET', auth: K, path: '/offer-imports/:id', scope: 'booking:read', paged: false, aliases: ['/offer_imports/:id'] },
  { id: 'delete-offer-import', method: 'DELETE', auth: K, path: '/offer-imports/:id', scope: 'booking:write', paged: false, aliases: ['/offer_imports/:id'] },
  { id: 'list-deals', method: 'GET', auth: K, path: '/deals', scope: 'booking:read', paged: true },
  { id: 'create-deal', method: 'POST', auth: K, path: '/deals', scope: 'booking:write', paged: false },
  { id: 'get-deal', method: 'GET', auth: K, path: '/deals/:id', scope: 'booking:read', paged: false },
  { id: 'update-deal', method: 'PATCH', auth: K, path: '/deals/:id', scope: 'booking:write', paged: false },
  { id: 'delete-deal', method: 'DELETE', auth: K, path: '/deals/:id', scope: 'booking:write', paged: false },

  // Finance, settlements, P&L, ticket counts (mig 20261031100500).
  { id: 'list-finance-categories', method: 'GET', auth: K, path: '/finance-categories', scope: 'finance:read', paged: false, aliases: ['/finance_categories'] },
  { id: 'create-finance-category', method: 'POST', auth: K, path: '/finance-categories', scope: 'finance:write', paged: false, aliases: ['/finance_categories'] },
  { id: 'get-finance-category', method: 'GET', auth: K, path: '/finance-categories/:id', scope: 'finance:read', paged: false, aliases: ['/finance_categories/:id'] },
  { id: 'update-finance-category', method: 'PATCH', auth: K, path: '/finance-categories/:id', scope: 'finance:write', paged: false, aliases: ['/finance_categories/:id'] },
  { id: 'delete-finance-category', method: 'DELETE', auth: K, path: '/finance-categories/:id', scope: 'finance:write', paged: false, aliases: ['/finance_categories/:id'] },
  { id: 'list-gl-codes', method: 'GET', auth: K, path: '/gl-codes', scope: 'finance:read', paged: false, aliases: ['/general_ledger_codes'] },
  { id: 'create-gl-code', method: 'POST', auth: K, path: '/gl-codes', scope: 'finance:write', paged: false, aliases: ['/general_ledger_codes'] },
  { id: 'get-gl-code', method: 'GET', auth: K, path: '/gl-codes/:id', scope: 'finance:read', paged: false, aliases: ['/general_ledger_codes/:id'] },
  { id: 'update-gl-code', method: 'PATCH', auth: K, path: '/gl-codes/:id', scope: 'finance:write', paged: false, aliases: ['/general_ledger_codes/:id'] },
  { id: 'delete-gl-code', method: 'DELETE', auth: K, path: '/gl-codes/:id', scope: 'finance:write', paged: false, aliases: ['/general_ledger_codes/:id'] },
  {
    id: 'list-finance-items', method: 'GET', auth: K, path: '/events/:id/finance-items', scope: 'finance:read', paged: false,
    aliases: ['/confirms/:id/finance_items'],
  },
  {
    id: 'create-finance-item', method: 'POST', auth: K, path: '/events/:id/finance-items', scope: 'finance:write', paged: false,
    aliases: ['/confirms/:id/finance_items'],
  },
  { id: 'get-finance-item', method: 'GET', auth: K, path: '/finance-items/:id', scope: 'finance:read', paged: false, aliases: ['/confirms/:eid/finance_items/:id'] },
  { id: 'update-finance-item', method: 'PATCH', auth: K, path: '/finance-items/:id', scope: 'finance:write', paged: false, aliases: ['/confirms/:eid/finance_items/:id'] },
  { id: 'delete-finance-item', method: 'DELETE', auth: K, path: '/finance-items/:id', scope: 'finance:write', paged: false },
  {
    id: 'get-settlement', method: 'GET', auth: K, path: '/events/:id/settlement', scope: 'finance:read', paged: false,
    aliases: ['/confirms/:id/settlements/summary'],
  },
  { id: 'update-settlement', method: 'PATCH', auth: K, path: '/events/:id/settlement', scope: 'finance:write', paged: false },
  { id: 'finalize-settlement', method: 'POST', auth: K, path: '/events/:id/settlement/finalize', scope: 'finance:write', paged: false },
  { id: 'reopen-settlement', method: 'POST', auth: K, path: '/events/:id/settlement/reopen', scope: 'finance:write', paged: false },
  { id: 'get-settlement-pdf', method: 'GET', auth: K, path: '/events/:id/settlement/pdf', scope: 'finance:read', paged: false },
  { id: 'get-event-pnl', method: 'GET', auth: K, path: '/events/:id/profit-and-loss', scope: 'finance:read', paged: false },
  { id: 'get-org-pnl', method: 'GET', auth: K, path: '/profit-and-loss', scope: 'finance:read', paged: false },
  { id: 'get-ticket-counts', method: 'GET', auth: K, path: '/events/:id/ticket-counts', scope: 'finance:read', paged: false },
  { id: 'update-ticket-counts', method: 'PATCH', auth: K, path: '/events/:id/ticket-counts', scope: 'finance:write', paged: false },
  { id: 'send-ticket-counts', method: 'POST', auth: K, path: '/events/:id/ticket-counts/send', scope: 'finance:write', paged: false },

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
