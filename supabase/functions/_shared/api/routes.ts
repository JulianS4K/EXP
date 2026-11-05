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
// `auth`: `api_key` is a bearer credential of the organization: an org API
// key (sk_live_…), a personal access token (exos_pat_…) or an OAuth access
// token (exos_oat_…), held to `scope` (docs/developer-platform.md). Writes
// (POST / PUT / PATCH / DELETE) need a `:write` scope (apiRoutes.test.ts);
// core writes run through exos_api_write (mig 20261031110000).
// `shared_key` is a listing-feed shared key (?shared_key=sh_live_… or
// X-Shared-Key): it reads the public feed of one org and nothing else
// (docs/listing-feed.md). `partner_key` is a distribution partner's key
// (dk_live_…, same transport, docs/partner-sales.md): the Opendate partner
// contract under /public/…, which needs no scope but the partner's own
// (inventory / comps). exos-api dispatches /public/* by the matched route's
// auth (publicAuthAt).
// `paged`: true for the API's { data, meta } lists, 'opendate' for
// Opendate's { current_page, per_page, total_entries, total_pages,
// collection } envelope.
//
// Pure TypeScript, imported by vitest.

import type { Scope } from './scopes.ts';

export type ApiMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
// `public` (claude/exos-fan-api, mig 20261105110000): no credential at all,
// under /public/… like the two key families: public discovery (events,
// venues, search, series) and signup forms, rate-limited per network
// (exos-api/publicApi.ts).
export type ApiAuth = 'api_key' | 'shared_key' | 'partner_key' | 'public';

export interface ApiRoute {
  id: string;
  method: ApiMethod;
  path: string;
  auth: ApiAuth;
  /** null: any valid key (GET /me, the team roles, every shared-key and partner-key route). */
  scope: Scope | null;
  paged: boolean | 'opendate';
  /** Other paths answering the same route. */
  aliases?: readonly string[];
}


const K = 'api_key' as const;
const P = 'partner_key' as const;
const A = 'public' as const;

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
  // Reserved seating (mig 20261030140000).
  { id: 'list-seats', method: 'GET', auth: K, path: '/events/:id/seats', scope: 'tickets:read', paged: false },
  { id: 'get-seat-reconciliation', method: 'GET', auth: K, path: '/events/:id/seat-reconciliation', scope: 'tickets:read', paged: false },
  { id: 'list-waitlist', method: 'GET', auth: K, path: '/events/:id/waitlist', scope: 'orders:read', paged: true },
  { id: 'list-orders', method: 'GET', auth: K, path: '/orders', scope: 'orders:read', paged: true },
  { id: 'get-order', method: 'GET', auth: K, path: '/orders/:id', scope: 'orders:read', paged: false },
  { id: 'list-invoices', method: 'GET', auth: K, path: '/invoices', scope: 'orders:read', paged: true },
  { id: 'list-refunds', method: 'GET', auth: K, path: '/refunds', scope: 'orders:read', paged: true },
  { id: 'list-webhooks', method: 'GET', auth: K, path: '/webhooks', scope: 'webhooks:read', paged: false },
  // Tickets sold on other platforms (mig 20261030120000). The first write
  // routes: each needs a :write scope (apiRoutes.test.ts).
  { id: 'list-sales-counts', method: 'GET', auth: K, path: '/sales-counts', scope: 'finance:read', paged: true },
  { id: 'get-sales-count', method: 'GET', auth: K, path: '/sales-counts/:id', scope: 'finance:read', paged: false },
  { id: 'create-sales-count', method: 'POST', auth: K, path: '/sales-counts', scope: 'finance:write', paged: false },
  { id: 'update-sales-count', method: 'PUT', auth: K, path: '/sales-counts/:id', scope: 'finance:write', paged: false },
  { id: 'delete-sales-count', method: 'DELETE', auth: K, path: '/sales-counts/:id', scope: 'finance:write', paged: false },
  { id: 'list-event-sales-counts', method: 'GET', auth: K, path: '/events/:id/sales-counts', scope: 'finance:read', paged: false },
  { id: 'import-sales-counts', method: 'POST', auth: K, path: '/events/:id/sales-counts/import', scope: 'finance:write', paged: false },
  { id: 'find-eventbrite-event', method: 'GET', auth: K, path: '/eventbrite-events/:id', scope: 'events:read', paged: false },

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
  // Series, collections, timed entry (mig 20261030150000, docs/series-timed-entry.md).
  { id: 'list-series', method: 'GET', auth: K, path: '/series', scope: 'events:read', paged: true },
  { id: 'get-series', method: 'GET', auth: K, path: '/series/:id', scope: 'events:read', paged: false },
  { id: 'list-series-dates', method: 'GET', auth: K, path: '/series/:id/dates', scope: 'events:read', paged: true },
  { id: 'list-collections', method: 'GET', auth: K, path: '/collections', scope: 'events:read', paged: true },
  { id: 'get-collection', method: 'GET', auth: K, path: '/collections/:id', scope: 'events:read', paged: false },
  { id: 'get-timed-entry', method: 'GET', auth: K, path: '/events/:id/timed-entry', scope: 'events:read', paged: false },
  { id: 'list-slots', method: 'GET', auth: K, path: '/events/:id/slots', scope: 'tickets:read', paged: false },

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
  // Gift cards, giving, memberships, passes (migs 20261030130000 / 130500).
  { id: 'list-gift-card-products', method: 'GET', auth: K, path: '/gift-card-products', scope: 'commerce:read', paged: false },
  { id: 'list-gift-cards', method: 'GET', auth: K, path: '/gift-cards', scope: 'commerce:read', paged: true },
  { id: 'get-gift-card', method: 'GET', auth: K, path: '/gift-cards/:id', scope: 'commerce:read', paged: false },
  { id: 'list-giving-campaigns', method: 'GET', auth: K, path: '/giving-campaigns', scope: 'commerce:read', paged: false },
  { id: 'get-giving-campaign', method: 'GET', auth: K, path: '/giving-campaigns/:id', scope: 'commerce:read', paged: false },
  { id: 'list-donations', method: 'GET', auth: K, path: '/donations', scope: 'commerce:read', paged: true },
  { id: 'list-membership-products', method: 'GET', auth: K, path: '/membership-products', scope: 'commerce:read', paged: false },
  { id: 'get-membership-product', method: 'GET', auth: K, path: '/membership-products/:id', scope: 'commerce:read', paged: false },
  { id: 'list-memberships', method: 'GET', auth: K, path: '/memberships', scope: 'commerce:read', paged: true },
  { id: 'get-membership', method: 'GET', auth: K, path: '/memberships/:id', scope: 'commerce:read', paged: false },
  { id: 'list-pass-products', method: 'GET', auth: K, path: '/pass-products', scope: 'commerce:read', paged: false },
  { id: 'list-passes', method: 'GET', auth: K, path: '/passes', scope: 'commerce:read', paged: true },
  { id: 'get-event-member-presale', method: 'GET', auth: K, path: '/events/:id/member-presale', scope: 'commerce:read', paged: false },

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

  // Fans, tags, signup forms, refund requests (mig 20261031120000, docs/fans.md).
  // /fans/lookup sits before /fans/:id so it isn't read as an id.
  { id: 'list-fans', method: 'GET', auth: K, path: '/fans', scope: 'fans:read', paged: true },
  { id: 'lookup-fans', method: 'GET', auth: K, path: '/fans/lookup', scope: 'fans:read', paged: false },
  { id: 'get-fan', method: 'GET', auth: K, path: '/fans/:id', scope: 'fans:read', paged: false },
  { id: 'create-fan', method: 'POST', auth: K, path: '/fans', scope: 'fans:write', paged: false },
  { id: 'update-fan', method: 'PATCH', auth: K, path: '/fans/:id', scope: 'fans:write', paged: false },
  { id: 'discard-fan', method: 'DELETE', auth: K, path: '/fans/:id', scope: 'fans:write', paged: false },
  { id: 'list-signup-forms', method: 'GET', auth: K, path: '/signup-forms', scope: 'fans:read', paged: false },
  // Tags are org metadata (events:*); a fan's tags also need fans:* (checked per request).
  { id: 'list-tags', method: 'GET', auth: K, path: '/tags', scope: 'events:read', paged: false },
  { id: 'get-tag', method: 'GET', auth: K, path: '/tags/:id', scope: 'events:read', paged: false },
  { id: 'create-tag', method: 'POST', auth: K, path: '/tags', scope: 'events:write', paged: false },
  { id: 'update-tag', method: 'PATCH', auth: K, path: '/tags/:id', scope: 'events:write', paged: false },
  { id: 'delete-tag', method: 'DELETE', auth: K, path: '/tags/:id', scope: 'events:write', paged: false },
  { id: 'list-tagged-items', method: 'GET', auth: K, path: '/tagged-items', scope: 'events:read', paged: true },
  { id: 'get-tagged-item', method: 'GET', auth: K, path: '/tagged-items/:id', scope: 'events:read', paged: false },
  { id: 'create-tagged-item', method: 'POST', auth: K, path: '/tagged-items', scope: 'events:write', paged: false },
  { id: 'delete-tagged-item', method: 'DELETE', auth: K, path: '/tagged-items/:id', scope: 'events:write', paged: false },
  { id: 'list-canonical-tags', method: 'GET', auth: K, path: '/canonical-tags', scope: 'events:read', paged: false },
  { id: 'list-refund-requests', method: 'GET', auth: K, path: '/refund-requests', scope: 'orders:read', paged: true },

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

  // -- claude/exos-gap-memberships (mig 20261102100000): membership-product
  // writes and lifecycle, staff-issued memberships, imported attendees. Writes
  // go through exos_api_commerce_write (exos-api/memberships.ts).
  { id: 'create-membership-product', method: 'POST', auth: K, path: '/membership-products', scope: 'commerce:write', paged: false },
  { id: 'update-membership-product', method: 'PATCH', auth: K, path: '/membership-products/:id', scope: 'commerce:write', paged: false },
  { id: 'publish-membership-product', method: 'POST', auth: K, path: '/membership-products/:id/publish', scope: 'commerce:write', paged: false },
  { id: 'unpublish-membership-product', method: 'POST', auth: K, path: '/membership-products/:id/unpublish', scope: 'commerce:write', paged: false },
  { id: 'archive-membership-product', method: 'POST', auth: K, path: '/membership-products/:id/archive', scope: 'commerce:write', paged: false },
  { id: 'issue-membership', method: 'POST', auth: K, path: '/memberships', scope: 'commerce:write', paged: false },
  { id: 'update-membership', method: 'PATCH', auth: K, path: '/memberships/:id', scope: 'commerce:write', paged: false },
  { id: 'list-migrated-attendees', method: 'GET', auth: K, path: '/migrated-attendees', scope: 'tickets:read', paged: true, aliases: ['/migrated_attendees'] },
  { id: 'get-migrated-attendee', method: 'GET', auth: K, path: '/migrated-attendees/:id', scope: 'tickets:read', paged: false, aliases: ['/migrated_attendees/:id'] },
  { id: 'update-migrated-attendee', method: 'PATCH', auth: K, path: '/migrated-attendees/:id', scope: 'tickets:write', paged: false, aliases: ['/migrated_attendees/:id'] },
  { id: 'delete-migrated-attendee', method: 'DELETE', auth: K, path: '/migrated-attendees/:id', scope: 'tickets:write', paged: false, aliases: ['/migrated_attendees/:id'] },
  // claude/exos-gap-giving (mig 20261102110000): giving and gift card writes,
  // monthly gifts, gift cards on organizer reservations (exos-api/giving.ts).
  { id: 'create-giving-campaign', method: 'POST', auth: K, path: '/giving-campaigns', scope: 'commerce:write', paged: false },
  { id: 'update-giving-campaign', method: 'PATCH', auth: K, path: '/giving-campaigns/:id', scope: 'commerce:write', paged: false },
  { id: 'activate-giving-campaign', method: 'POST', auth: K, path: '/giving-campaigns/:id/activate', scope: 'commerce:write', paged: false },
  { id: 'complete-giving-campaign', method: 'POST', auth: K, path: '/giving-campaigns/:id/complete', scope: 'commerce:write', paged: false },
  { id: 'delete-giving-campaign', method: 'DELETE', auth: K, path: '/giving-campaigns/:id', scope: 'commerce:write', paged: false },
  { id: 'create-recurring-donation', method: 'POST', auth: K, path: '/giving-campaigns/:id/recurring-donations', scope: 'commerce:write', paged: false,
    aliases: ['/giving-campaigns/:id/recurring_donations', '/giving_campaigns/:id/recurring_donations'] },
  { id: 'list-recurring-donations', method: 'GET', auth: K, path: '/recurring-donations', scope: 'commerce:read', paged: true },
  { id: 'get-recurring-donation', method: 'GET', auth: K, path: '/recurring-donations/:id', scope: 'commerce:read', paged: false },
  { id: 'cancel-recurring-donation', method: 'DELETE', auth: K, path: '/recurring-donations/:id', scope: 'commerce:write', paged: false },
  { id: 'delete-donation', method: 'DELETE', auth: K, path: '/donations/:id', scope: 'commerce:write', paged: false },
  { id: 'offline-refund-donation', method: 'POST', auth: K, path: '/donations/:id/offline-refund', scope: 'commerce:write', paged: false,
    aliases: ['/donations/:id/offline_refund'] },
  { id: 'import-gift-cards', method: 'POST', auth: K, path: '/gift-cards/import', scope: 'commerce:write', paged: false,
    aliases: ['/gift-cards/bulk', '/gift_up_giftcards/bulk'] },
  { id: 'list-reservation-gift-cards', method: 'GET', auth: K, path: '/events/:id/organizer-reservations/:token/gift-card-redemptions', scope: 'tickets:read', paged: false },
  { id: 'create-reservation-gift-card', method: 'POST', auth: K, path: '/events/:id/organizer-reservations/:token/gift-card-redemptions', scope: 'tickets:write', paged: false,
    aliases: ['/events/:id/organizer-reservations/:token/gift_card_redemptions', '/confirms/:id/organizer_ticket_reservations/:token/gift_card_redemptions'] },
  { id: 'delete-reservation-gift-card', method: 'DELETE', auth: K, path: '/events/:id/organizer-reservations/:token/gift-card-redemptions/:rid', scope: 'tickets:write', paged: false,
    aliases: ['/events/:id/organizer-reservations/:token/gift_card_redemptions/:rid', '/confirms/:id/organizer_ticket_reservations/:token/gift_card_redemptions/:rid'] },
  // claude/exos-gap-finance: tiered deal brackets, ledger codes per revenue
  // type with per-event overrides and backfills, imported ledger entries,
  // reporting rows, the cash summary (mig 20261102120000,
  // docs/api/finance-extras.json). Brackets are deal terms (booking:*).
  { id: 'list-deal-brackets', method: 'GET', auth: K, path: '/deal-brackets', scope: 'booking:read', paged: true, aliases: ['/v3_deal_brackets'] },
  { id: 'get-deal-bracket', method: 'GET', auth: K, path: '/deal-brackets/:id', scope: 'booking:read', paged: false, aliases: ['/v3_deal_brackets/:id'] },
  { id: 'create-deal-bracket', method: 'POST', auth: K, path: '/deal-brackets', scope: 'booking:write', paged: false, aliases: ['/v3_deal_brackets'] },
  { id: 'update-deal-bracket', method: 'PATCH', auth: K, path: '/deal-brackets/:id', scope: 'booking:write', paged: false, aliases: ['/v3_deal_brackets/:id'] },
  { id: 'delete-deal-bracket', method: 'DELETE', auth: K, path: '/deal-brackets/:id', scope: 'booking:write', paged: false, aliases: ['/v3_deal_brackets/:id'] },
  { id: 'list-gl-revenue-codes', method: 'GET', auth: K, path: '/gl-revenue-codes', scope: 'finance:read', paged: false },
  { id: 'set-gl-revenue-code', method: 'PUT', auth: K, path: '/gl-revenue-codes/:type', scope: 'finance:write', paged: false },
  {
    id: 'list-gl-code-assignments', method: 'GET', auth: K, path: '/events/:id/gl-code-assignments', scope: 'finance:read', paged: false,
    aliases: ['/confirms/:id/general_ledger_code_assignments'],
  },
  {
    id: 'create-gl-code-assignment', method: 'POST', auth: K, path: '/events/:id/gl-code-assignments', scope: 'finance:write', paged: false,
    aliases: ['/confirms/:id/general_ledger_code_assignments'],
  },
  {
    id: 'update-gl-code-assignment', method: 'PATCH', auth: K, path: '/gl-code-assignments/:id', scope: 'finance:write', paged: false,
    aliases: ['/confirms/:eid/general_ledger_code_assignments/:id'],
  },
  {
    id: 'delete-gl-code-assignment', method: 'DELETE', auth: K, path: '/gl-code-assignments/:id', scope: 'finance:write', paged: false,
    aliases: ['/confirms/:eid/general_ledger_code_assignments/:id'],
  },
  {
    id: 'backfill-gl-codes', method: 'POST', auth: K, path: '/events/:id/gl-backfill', scope: 'finance:write', paged: false,
    aliases: ['/confirms/:id/general_ledger_code_backfills'],
  },
  {
    id: 'list-imported-ledger-entries', method: 'GET', auth: K, path: '/imported-ledger-entries', scope: 'finance:read', paged: true,
    aliases: ['/imported_ledger_entries'],
  },
  {
    id: 'import-ledger-entries', method: 'POST', auth: K, path: '/imported-ledger-entries/bulk', scope: 'finance:write', paged: false,
    aliases: ['/imported_ledger_entries/bulk'],
  },
  {
    id: 'delete-imported-ledger-entry', method: 'DELETE', auth: K, path: '/imported-ledger-entries/:id', scope: 'finance:write', paged: false,
    aliases: ['/imported_ledger_entries/:id'],
  },
  { id: 'list-reporting-rows', method: 'GET', auth: K, path: '/reporting-rows', scope: 'finance:read', paged: true, aliases: ['/reporting_rows'] },
  { id: 'get-reporting-row', method: 'GET', auth: K, path: '/reporting-rows/:id', scope: 'finance:read', paged: false, aliases: ['/reporting_rows/:id'] },
  {
    id: 'get-cash-summary', method: 'GET', auth: K, path: '/events/:id/cash-summary', scope: 'finance:read', paged: false,
    aliases: ['/confirms/:id/cash_summary'],
  },
  // -- claude/exos-gap-templates: templates, rental invoices, inbound
  // submissions, deleting a draft event (mig 20261102130000,
  // docs/templates-inbound.md). Opendate's underscore names are aliases.
  { id: 'list-event-templates', method: 'GET', auth: K, path: '/event-templates', scope: 'events:read', paged: true, aliases: ['/event_templates'] },
  { id: 'create-event-template', method: 'POST', auth: K, path: '/event-templates', scope: 'events:write', paged: false, aliases: ['/event_templates'] },
  { id: 'get-event-template', method: 'GET', auth: K, path: '/event-templates/:id', scope: 'events:read', paged: false, aliases: ['/event_templates/:id'] },
  { id: 'update-event-template', method: 'PATCH', auth: K, path: '/event-templates/:id', scope: 'events:write', paged: false, aliases: ['/event_templates/:id'] },
  { id: 'delete-event-template', method: 'DELETE', auth: K, path: '/event-templates/:id', scope: 'events:write', paged: false, aliases: ['/event_templates/:id'] },
  { id: 'create-event-from-template', method: 'POST', auth: K, path: '/event-templates/:id/events', scope: 'events:write', paged: false, aliases: ['/event_templates/:id/events'] },
  { id: 'list-note-templates', method: 'GET', auth: K, path: '/note-templates', scope: 'booking:read', paged: true, aliases: ['/note_templates'] },
  { id: 'create-note-template', method: 'POST', auth: K, path: '/note-templates', scope: 'booking:write', paged: false, aliases: ['/note_templates'] },
  { id: 'get-note-template', method: 'GET', auth: K, path: '/note-templates/:id', scope: 'booking:read', paged: false, aliases: ['/note_templates/:id'] },
  { id: 'update-note-template', method: 'PATCH', auth: K, path: '/note-templates/:id', scope: 'booking:write', paged: false, aliases: ['/note_templates/:id'] },
  { id: 'delete-note-template', method: 'DELETE', auth: K, path: '/note-templates/:id', scope: 'booking:write', paged: false, aliases: ['/note_templates/:id'] },
  { id: 'apply-note-template', method: 'POST', auth: K, path: '/note-templates/:id/apply', scope: 'booking:write', paged: false, aliases: ['/note_templates/:id/apply'] },
  { id: 'list-rental-invoice-templates', method: 'GET', auth: K, path: '/rental-invoice-templates', scope: 'booking:read', paged: true, aliases: ['/rental_invoice_templates'] },
  { id: 'create-rental-invoice-template', method: 'POST', auth: K, path: '/rental-invoice-templates', scope: 'booking:write', paged: false, aliases: ['/rental_invoice_templates'] },
  { id: 'get-rental-invoice-template', method: 'GET', auth: K, path: '/rental-invoice-templates/:id', scope: 'booking:read', paged: false, aliases: ['/rental_invoice_templates/:id'] },
  { id: 'update-rental-invoice-template', method: 'PATCH', auth: K, path: '/rental-invoice-templates/:id', scope: 'booking:write', paged: false, aliases: ['/rental_invoice_templates/:id'] },
  { id: 'delete-rental-invoice-template', method: 'DELETE', auth: K, path: '/rental-invoice-templates/:id', scope: 'booking:write', paged: false, aliases: ['/rental_invoice_templates/:id'] },
  { id: 'list-rental-invoices', method: 'GET', auth: K, path: '/rental-invoices', scope: 'finance:read', paged: true, aliases: ['/rental_invoices'] },
  { id: 'create-rental-invoice', method: 'POST', auth: K, path: '/rental-invoices', scope: 'finance:write', paged: false, aliases: ['/rental_invoices'] },
  { id: 'get-rental-invoice', method: 'GET', auth: K, path: '/rental-invoices/:id', scope: 'finance:read', paged: false, aliases: ['/rental_invoices/:id'] },
  { id: 'update-rental-invoice', method: 'PATCH', auth: K, path: '/rental-invoices/:id', scope: 'finance:write', paged: false, aliases: ['/rental_invoices/:id'] },
  { id: 'delete-rental-invoice', method: 'DELETE', auth: K, path: '/rental-invoices/:id', scope: 'finance:write', paged: false, aliases: ['/rental_invoices/:id'] },
  { id: 'issue-rental-invoice', method: 'POST', auth: K, path: '/rental-invoices/:id/issue', scope: 'finance:write', paged: false, aliases: ['/rental_invoices/:id/issue'] },
  { id: 'pay-rental-invoice', method: 'POST', auth: K, path: '/rental-invoices/:id/pay', scope: 'finance:write', paged: false, aliases: ['/rental_invoices/:id/pay'] },
  { id: 'void-rental-invoice', method: 'POST', auth: K, path: '/rental-invoices/:id/void', scope: 'finance:write', paged: false, aliases: ['/rental_invoices/:id/void'] },
  { id: 'list-inbound-submissions', method: 'GET', auth: K, path: '/inbound-submissions', scope: 'booking:read', paged: true, aliases: ['/inbound_submissions'] },
  { id: 'create-inbound-submission', method: 'POST', auth: K, path: '/inbound-submissions', scope: 'booking:write', paged: false, aliases: ['/inbound_submissions'] },
  { id: 'get-inbound-submission', method: 'GET', auth: K, path: '/inbound-submissions/:id', scope: 'booking:read', paged: false, aliases: ['/inbound_submissions/:id'] },
  { id: 'update-inbound-submission', method: 'PATCH', auth: K, path: '/inbound-submissions/:id', scope: 'booking:write', paged: false, aliases: ['/inbound_submissions/:id'] },
  { id: 'delete-inbound-submission', method: 'DELETE', auth: K, path: '/inbound-submissions/:id', scope: 'booking:write', paged: false, aliases: ['/inbound_submissions/:id'] },
  { id: 'create-inbound-submission-hold', method: 'POST', auth: K, path: '/inbound-submissions/:id/hold', scope: 'booking:write', paged: false, aliases: ['/inbound_submissions/:id/hold'] },
  { id: 'delete-event', method: 'DELETE', auth: K, path: '/events/:id', scope: 'events:write', paged: false },
  // claude/exos-gap-orders: order and ticket edits, receipt resends, order
  // check-out, the guest-list preview and recommendations (mig 20261102140000,
  // exos-api/orders.ts). Opendate's /confirms/:id/… paths are aliases.
  { id: 'update-order', method: 'PUT', auth: K, path: '/orders/:id', scope: 'tickets:write', paged: false, aliases: ['/confirms/:eid/orders/:id'] },
  {
    id: 'send-order-receipt', method: 'POST', auth: K, path: '/orders/:id/send-receipt', scope: 'tickets:write', paged: false,
    aliases: ['/orders/:id/send_receipt', '/confirms/:eid/orders/:id/send_receipt'],
  },
  {
    id: 'check-out-order', method: 'POST', auth: K, path: '/orders/:id/check-out', scope: 'checkin:write', paged: false,
    aliases: ['/orders/:id/check_out', '/confirms/:eid/orders/:id/check_out'],
  },
  { id: 'update-ticket', method: 'PUT', auth: K, path: '/tickets/:id', scope: 'tickets:write', paged: false, aliases: ['/confirms/:eid/tickets/:id'] },
  {
    id: 'preview-guest-list', method: 'POST', auth: K, path: '/events/:id/guest-list-preview', scope: 'tickets:write', paged: false,
    aliases: ['/events/:id/guest_list_preview', '/confirms/:id/guest_list_preview'],
  },
  {
    id: 'list-similar-events', method: 'GET', auth: K, path: '/events/:id/similar', scope: 'events:read', paged: true,
    aliases: ['/events/:id/similars', '/confirms/:id/similars'],
  },
  {
    id: 'list-fan-event-recommendations', method: 'GET', auth: K, path: '/event-recommendations', scope: 'fans:read', paged: true,
    aliases: ['/confirms/recommendations'],
  },
  {
    id: 'list-event-fan-recommendations', method: 'GET', auth: K, path: '/events/:id/fan-recommendations', scope: 'fans:read', paged: true,
    aliases: ['/confirms/:id/fans/recommendations'],
  },
  // claude/exos-org-access (mig 20261104180000, docs/org-access.md): per-role
  // API permissions, venue booking requests and event-scoped grants, the
  // partner presale setting.
  { id: 'get-role-api-scopes', method: 'GET', auth: K, path: '/role-api-scopes', scope: 'org:admin', paged: false },
  { id: 'update-role-api-scopes', method: 'PUT', auth: K, path: '/role-api-scopes/:role', scope: 'org:admin', paged: false },
  { id: 'list-venue-directory', method: 'GET', auth: K, path: '/venue-directory', scope: 'booking:read', paged: false },
  { id: 'get-venue-listing-suggestions', method: 'GET', auth: K, path: '/venues/:id/listing-suggestions', scope: 'booking:read', paged: false },
  { id: 'link-listed-venue', method: 'PUT', auth: K, path: '/venues/:id/listed-venue', scope: 'booking:write', paged: false },
  { id: 'list-venue-requests', method: 'GET', auth: K, path: '/venue-requests', scope: 'booking:read', paged: true },
  { id: 'create-venue-request', method: 'POST', auth: K, path: '/venue-requests', scope: 'booking:write', paged: false },
  { id: 'get-venue-request', method: 'GET', auth: K, path: '/venue-requests/:id', scope: 'booking:read', paged: false },
  { id: 'approve-venue-request', method: 'POST', auth: K, path: '/venue-requests/:id/approve', scope: 'booking:write', paged: false },
  { id: 'decline-venue-request', method: 'POST', auth: K, path: '/venue-requests/:id/decline', scope: 'booking:write', paged: false },
  { id: 'withdraw-venue-request', method: 'POST', auth: K, path: '/venue-requests/:id/withdraw', scope: 'booking:write', paged: false },
  { id: 'list-partner-grants', method: 'GET', auth: K, path: '/partner-grants', scope: 'booking:read', paged: false },
  { id: 'update-partner-grant', method: 'PATCH', auth: K, path: '/partner-grants/:id', scope: 'booking:write', paged: false },
  { id: 'revoke-partner-grant', method: 'DELETE', auth: K, path: '/partner-grants/:id', scope: 'booking:write', paged: false },
  { id: 'list-cohosted-events', method: 'GET', auth: K, path: '/cohosted-events', scope: 'events:read', paged: false },
  { id: 'get-cohosted-event', method: 'GET', auth: K, path: '/cohosted-events/:id', scope: 'events:read', paged: false },
  { id: 'update-cohosted-event', method: 'PATCH', auth: K, path: '/cohosted-events/:id', scope: 'events:write', paged: false },
  { id: 'get-cohosted-event-sales', method: 'GET', auth: K, path: '/cohosted-events/:id/sales', scope: 'tickets:read', paged: false },
  { id: 'get-partner-presale', method: 'GET', auth: K, path: '/partner-presale', scope: 'events:read', paged: false },
  { id: 'update-partner-presale', method: 'PUT', auth: K, path: '/partner-presale', scope: 'org:admin', paged: false },
  { id: 'get-event-partner-presale', method: 'GET', auth: K, path: '/events/:id/partner-presale', scope: 'events:read', paged: false },
  { id: 'update-event-partner-presale', method: 'PUT', auth: K, path: '/events/:id/partner-presale', scope: 'events:write', paged: false },
  // claude/exos-small-ops (mig 20261104200000): optional per-partner caps
  // (docs/partner-sales.md "Caps").
  { id: 'get-event-partner-caps', method: 'GET', auth: K, path: '/events/:id/partner-caps', scope: 'events:read', paged: false },
  { id: 'set-event-partner-caps', method: 'PUT', auth: K, path: '/events/:id/partner-caps', scope: 'events:write', paged: false },

  // -- claude/exos-fan-api (mig 20261105110000, exos-api/me.ts, docs/api/me.json):
  // the token's own user. User tokens only (personal access, account and
  // OAuth tokens); an org API key has no user and is refused. Opendate's
  // /users/current/… paths are aliases.
  { id: 'get-my-profile', method: 'GET', auth: K, path: '/me/profile', scope: 'me:read', paged: false, aliases: ['/users/current'] },
  { id: 'update-my-profile', method: 'PATCH', auth: K, path: '/me/profile', scope: 'me:write', paged: false, aliases: ['/users/current'] },
  { id: 'get-my-marketing-preferences', method: 'GET', auth: K, path: '/me/marketing-preferences', scope: 'me:read', paged: false },
  { id: 'set-my-marketing-preferences', method: 'PUT', auth: K, path: '/me/marketing-preferences', scope: 'me:write', paged: false },
  { id: 'list-my-tickets', method: 'GET', auth: K, path: '/me/tickets', scope: 'me:read', paged: true, aliases: ['/users/current/tickets'] },
  { id: 'get-my-ticket', method: 'GET', auth: K, path: '/me/tickets/:id', scope: 'me:read', paged: false, aliases: ['/users/current/tickets/:id'] },
  {
    id: 'get-my-ticket-pkpass', method: 'GET', auth: K, path: '/me/tickets/:id/pkpass', scope: 'me:read', paged: false,
    aliases: ['/users/current/tickets/:id/pkpass'],
  },
  {
    id: 'get-my-ticket-google-wallet', method: 'GET', auth: K, path: '/me/tickets/:id/google-wallet-url', scope: 'me:read', paged: false,
    aliases: ['/users/current/tickets/:id/google_wallet_url'],
  },
  {
    id: 'list-my-ticket-bundles', method: 'GET', auth: K, path: '/me/ticket-bundles', scope: 'me:read', paged: false,
    aliases: ['/users/current/ticket_bundles'],
  },
  {
    id: 'get-my-ticket-bundle', method: 'GET', auth: K, path: '/me/ticket-bundles/:id', scope: 'me:read', paged: false,
    aliases: ['/users/current/ticket_bundles/:id'],
  },
  { id: 'list-my-orders', method: 'GET', auth: K, path: '/me/orders', scope: 'me:read', paged: true, aliases: ['/users/current/orders'] },
  { id: 'get-my-order', method: 'GET', auth: K, path: '/me/orders/:id', scope: 'me:read', paged: false, aliases: ['/users/current/orders/:id'] },
  {
    id: 'list-my-order-transferable', method: 'GET', auth: K, path: '/me/orders/:id/ticket-transfers/new', scope: 'me:read', paged: false,
    aliases: ['/me/orders/:id/ticket_transfers/new'],
  },
  {
    id: 'create-my-order-transfers', method: 'POST', auth: K, path: '/me/orders/:id/ticket-transfers', scope: 'me:write', paged: false,
    aliases: ['/me/orders/:id/ticket_transfers'],
  },
  {
    id: 'get-my-order-refund-request', method: 'GET', auth: K, path: '/me/orders/:id/refund-request', scope: 'me:read', paged: false,
    aliases: ['/me/orders/:id/refund_request'],
  },
  {
    id: 'create-my-order-refund-request', method: 'POST', auth: K, path: '/me/orders/:id/refund-request', scope: 'me:write', paged: false,
    aliases: ['/me/orders/:id/refund_request'],
  },
  { id: 'list-my-transfers', method: 'GET', auth: K, path: '/me/transfers', scope: 'me:read', paged: false },
  { id: 'create-my-transfers', method: 'POST', auth: K, path: '/me/transfers', scope: 'me:write', paged: false },
  { id: 'cancel-my-transfer', method: 'DELETE', auth: K, path: '/me/transfers/:id', scope: 'me:write', paged: false },
  { id: 'claim-transfer', method: 'POST', auth: K, path: '/me/transfers/:id/claim', scope: 'me:write', paged: false },
  {
    id: 'list-my-fan-memberships', method: 'GET', auth: K, path: '/me/fan-memberships', scope: 'me:read', paged: false,
    aliases: ['/users/current/memberships'],
  },
  {
    id: 'get-my-fan-membership', method: 'GET', auth: K, path: '/me/fan-memberships/:id', scope: 'me:read', paged: false,
    aliases: ['/users/current/memberships/:id'],
  },
  {
    id: 'list-my-season-passes', method: 'GET', auth: K, path: '/me/season-passes', scope: 'me:read', paged: false,
    aliases: ['/users/current/season_passes'],
  },
  {
    id: 'get-my-season-pass', method: 'GET', auth: K, path: '/me/season-passes/:id', scope: 'me:read', paged: false,
    aliases: ['/users/current/season_passes/:id'],
  },
  {
    id: 'get-my-season-pass-pkpass', method: 'GET', auth: K, path: '/me/season-passes/:id/pkpass', scope: 'me:read', paged: false,
    aliases: ['/users/current/season_passes/:id/pkpass'],
  },
  {
    id: 'get-my-season-pass-google-wallet', method: 'GET', auth: K, path: '/me/season-passes/:id/google-wallet-url', scope: 'me:read',
    paged: false, aliases: ['/users/current/season_passes/:id/google_wallet_url'],
  },
  { id: 'list-my-passes', method: 'GET', auth: K, path: '/me/passes', scope: 'me:read', paged: false, aliases: ['/users/current/passes'] },
  { id: 'get-my-pass', method: 'GET', auth: K, path: '/me/passes/:id', scope: 'me:read', paged: false, aliases: ['/users/current/passes/:id'] },
  { id: 'list-my-refund-requests', method: 'GET', auth: K, path: '/me/refund-requests', scope: 'me:read', paged: false },
  { id: 'create-my-refund-request', method: 'POST', auth: K, path: '/me/refund-requests', scope: 'me:write', paged: false },
  { id: 'withdraw-my-refund-request', method: 'DELETE', auth: K, path: '/me/refund-requests/:id', scope: 'me:write', paged: false },
  { id: 'list-my-tokens', method: 'GET', auth: K, path: '/me/personal-access-tokens', scope: 'me:read', paged: false },
  // Minted tokens always expire (30 / 90 / 365 days, never past the maker),
  // die with the token that made them, and can't mint (mig 20261105160000).
  {
    id: 'create-my-token', method: 'POST', auth: K, path: '/me/personal-access-tokens', scope: 'me:write', paged: false,
    aliases: ['/personal-access-tokens', '/personal_access_tokens'],
  },
  { id: 'revoke-my-token', method: 'DELETE', auth: K, path: '/me/personal-access-tokens/:id', scope: 'me:write', paged: false },
  // claude/exos-fan-api: organization writes the Opendate gap list still
  // pointed at the dashboard. One exos_api_gap_write call each (runs as the
  // key's creator, Idempotency-Key, logged; exos-api/gapWrites.ts).
  { id: 'list-api-keys', method: 'GET', auth: K, path: '/api-keys', scope: 'org:admin', paged: false, aliases: ['/api_keys'] },
  { id: 'create-api-key', method: 'POST', auth: K, path: '/api-keys', scope: 'org:admin', paged: false, aliases: ['/api_keys'] },
  { id: 'revoke-api-key', method: 'DELETE', auth: K, path: '/api-keys/:id', scope: 'org:admin', paged: false, aliases: ['/api_keys/:id'] },
  { id: 'create-series', method: 'POST', auth: K, path: '/series', scope: 'events:write', paged: false, aliases: ['/event_series'] },
  { id: 'update-series', method: 'PATCH', auth: K, path: '/series/:id', scope: 'events:write', paged: false, aliases: ['/event_series/:id'] },
  { id: 'cancel-series', method: 'POST', auth: K, path: '/series/:id/cancel', scope: 'events:write', paged: false, aliases: ['/event_series/:id/cancel'] },
  { id: 'delete-series', method: 'DELETE', auth: K, path: '/series/:id', scope: 'events:write', paged: false, aliases: ['/event_series/:id'] },
  {
    id: 'attach-series-event', method: 'POST', auth: K, path: '/series/:id/events', scope: 'events:write', paged: false,
    aliases: ['/event_series/:id/event_series_events'],
  },
  {
    id: 'detach-series-event', method: 'DELETE', auth: K, path: '/series/:id/events/:eid', scope: 'events:write', paged: false,
    aliases: ['/event_series/:id/event_series_events/:eid'],
  },
  { id: 'generate-series-dates', method: 'POST', auth: K, path: '/series/:id/generate', scope: 'events:write', paged: false },
  { id: 'cancel-series-date', method: 'POST', auth: K, path: '/series/:id/cancel-date', scope: 'events:write', paged: false },
  {
    id: 'create-event-fee-rule', method: 'POST', auth: K, path: '/events/:id/fee-rules', scope: 'events:write', paged: false,
    aliases: ['/confirms/:id/organizer_fee_components'],
  },
  {
    id: 'update-event-fee-rule', method: 'PATCH', auth: K, path: '/events/:id/fee-rules/:rid', scope: 'events:write', paged: false,
    aliases: ['/confirms/:id/organizer_fee_components/:rid'],
  },
  {
    id: 'delete-event-fee-rule', method: 'DELETE', auth: K, path: '/events/:id/fee-rules/:rid', scope: 'events:write', paged: false,
    aliases: ['/confirms/:id/organizer_fee_components/:rid'],
  },
  {
    id: 'release-orphan-seats', method: 'POST', auth: K, path: '/events/:id/seat-reconciliation/release-orphans', scope: 'tickets:write',
    paged: false, aliases: ['/confirms/:id/seat_reconciliation/release_orphans'],
  },
  {
    id: 'import-migrated-attendees', method: 'POST', auth: K, path: '/migrated-attendees/bulk', scope: 'tickets:write', paged: false,
    aliases: ['/migrated_attendees/bulk'],
  },
  { id: 'create-membership-scan', method: 'POST', auth: K, path: '/membership-scans', scope: 'checkin:write', paged: false, aliases: ['/membership_scans'] },
  { id: 'gift-membership', method: 'POST', auth: K, path: '/membership-products/:id/gifts', scope: 'commerce:write', paged: false },
  { id: 'cancel-membership-gift', method: 'DELETE', auth: K, path: '/memberships/:id/gift', scope: 'commerce:write', paged: false },
  { id: 'cancel-membership', method: 'POST', auth: K, path: '/memberships/:id/cancel', scope: 'commerce:write', paged: false },
  {
    id: 'quote-gift-card-product', method: 'GET', auth: K, path: '/gift-card-products/:id/quote', scope: 'commerce:read', paged: false,
    aliases: ['/gift_card_products/:id/quote'],
  },
  {
    id: 'issue-gift-card', method: 'POST', auth: K, path: '/gift-card-products/:id/gift-card-orders', scope: 'commerce:write',
    paged: false, aliases: ['/gift_card_products/:id/gift_card_orders'],
  },
  {
    id: 'create-offline-donation', method: 'POST', auth: K, path: '/giving-campaigns/:id/offline-donations', scope: 'commerce:write',
    paged: false, aliases: ['/giving_campaigns/:id/offline_donations'],
  },
  { id: 'create-donation', method: 'POST', auth: K, path: '/donations', scope: 'commerce:write', paged: false },
  // claude/exos-fan-api: public discovery and signup forms, no credential
  // (auth `public`, exos-api/publicApi.ts). Opendate's names are aliases.
  {
    id: 'public-discovery-events', method: 'GET', auth: A, path: '/public/discovery/events', scope: null, paged: true,
    aliases: ['/public/discovery/confirms'],
  },
  {
    id: 'public-discovery-event', method: 'GET', auth: A, path: '/public/discovery/events/:id', scope: null, paged: false,
    aliases: ['/public/discovery/confirms/:id'],
  },
  { id: 'public-venues', method: 'GET', auth: A, path: '/public/venues', scope: null, paged: true },
  { id: 'public-venue', method: 'GET', auth: A, path: '/public/venues/:id', scope: null, paged: false },
  { id: 'public-search', method: 'GET', auth: A, path: '/public/search', scope: null, paged: false },
  {
    id: 'public-event-series-list', method: 'GET', auth: A, path: '/public/event-series', scope: null, paged: false,
    aliases: ['/public/website_event_series'],
  },
  {
    id: 'public-event-series', method: 'GET', auth: A, path: '/public/event-series/:id', scope: null, paged: false,
    aliases: ['/public/website_event_series/:id'],
  },
  { id: 'public-create-fan', method: 'POST', auth: A, path: '/public/fans', scope: null, paged: false },
  { id: 'public-create-form-submission', method: 'POST', auth: A, path: '/public/forms/:id/submissions', scope: null, paged: false },
  // claude/exos-na-build (mig 20261105120000, exos-api/boxOffice.ts): printed
  // tickets (one-time print codes, docs/wallet.md "Printed tickets"),
  // box-office membership reservations, staff shifts, retagging.
  {
    id: 'print-ticket', method: 'POST', auth: K, path: '/tickets/:id/print', scope: 'tickets:write', paged: false,
    aliases: ['/confirms/:eid/tickets/:id/print'],
  },
  { id: 'void-ticket-print', method: 'DELETE', auth: K, path: '/tickets/:id/print', scope: 'tickets:write', paged: false },
  {
    id: 'print-order', method: 'POST', auth: K, path: '/orders/:id/print', scope: 'tickets:write', paged: false,
    aliases: ['/confirms/:eid/orders/:id/print'],
  },
  { id: 'get-membership-capacity', method: 'GET', auth: K, path: '/membership-products/:id/capacity', scope: 'commerce:read', paged: false },
  { id: 'set-membership-capacity', method: 'PUT', auth: K, path: '/membership-products/:id/capacity', scope: 'commerce:write', paged: false },
  {
    id: 'create-membership-reservation', method: 'POST', auth: K, path: '/membership-products/:id/reservations',
    scope: 'commerce:write', paged: false, aliases: ['/membership_products/:id/membership_reservations'],
  },
  {
    id: 'cancel-membership-reservation', method: 'DELETE', auth: K, path: '/membership-products/:id/reservations/:token',
    scope: 'commerce:write', paged: false, aliases: ['/membership_products/:id/membership_reservations/:token'],
  },
  {
    id: 'complete-membership-reservation', method: 'POST', auth: K, path: '/membership-products/:id/reservations/:token/complete',
    scope: 'commerce:write', paged: false, aliases: ['/membership_products/:id/membership_reservations/:token/complete'],
  },
  { id: 'list-staff-shifts', method: 'GET', auth: K, path: '/staff-shifts', scope: 'events:read', paged: false },
  { id: 'clock-in', method: 'POST', auth: K, path: '/staff-shifts/clock-in', scope: 'checkin:write', paged: false },
  { id: 'clock-out', method: 'POST', auth: K, path: '/staff-shifts/clock-out', scope: 'checkin:write', paged: false },
  { id: 'update-tagged-item', method: 'PUT', auth: K, path: '/tagged-items/:id', scope: 'events:write', paged: false },
  // claude/exos-promoter-events (mig 20261105130000, docs/promoter-events.md):
  // an event's location mode and the "this venue is on Exos" suggestion.
  { id: 'get-event-location', method: 'GET', auth: K, path: '/events/:id/location', scope: 'events:read', paged: false },
  { id: 'set-event-location', method: 'PUT', auth: K, path: '/events/:id/location', scope: 'events:write', paged: false },
  { id: 'list-venue-matches', method: 'GET', auth: K, path: '/venue-matches', scope: 'events:read', paged: false },
  // claude/exos-capacity-pricing (migs 20261106120000 / 20261106130000,
  // exos-api/capacity.ts, docs/api/capacity.json): shared capacity pools
  // (DICE TicketPool) and a ticket type's price steps (DICE PriceTier).
  { id: 'list-capacity-pools', method: 'GET', auth: K, path: '/events/:id/capacity-pools', scope: 'events:read', paged: false },
  { id: 'create-capacity-pool', method: 'POST', auth: K, path: '/events/:id/capacity-pools', scope: 'events:write', paged: false },
  { id: 'get-capacity-pool', method: 'GET', auth: K, path: '/events/:id/capacity-pools/:pool', scope: 'events:read', paged: false },
  { id: 'update-capacity-pool', method: 'PATCH', auth: K, path: '/events/:id/capacity-pools/:pool', scope: 'events:write', paged: false },
  { id: 'delete-capacity-pool', method: 'DELETE', auth: K, path: '/events/:id/capacity-pools/:pool', scope: 'events:write', paged: false },
  { id: 'get-price-steps', method: 'GET', auth: K, path: '/events/:id/ticket-types/:tier/price-steps', scope: 'events:read', paged: false },
  { id: 'set-price-steps', method: 'PUT', auth: K, path: '/events/:id/ticket-types/:tier/price-steps', scope: 'events:write', paged: false },
  // claude/exos-checkout-questions (mig 20261106110000, exos-api/questions.ts,
  // docs/api/questions.json): checkout questions and their answers (DICE's
  // fanSurveyAnswers). Existing scopes: events:* for questions, orders:read /
  // tickets:read for answers.
  { id: 'list-event-questions', method: 'GET', auth: K, path: '/events/:id/questions', scope: 'events:read', paged: false },
  { id: 'create-event-question', method: 'POST', auth: K, path: '/events/:id/questions', scope: 'events:write', paged: false },
  { id: 'reorder-event-questions', method: 'PUT', auth: K, path: '/events/:id/questions/order', scope: 'events:write', paged: false },
  { id: 'get-question', method: 'GET', auth: K, path: '/questions/:id', scope: 'events:read', paged: false },
  { id: 'update-question', method: 'PATCH', auth: K, path: '/questions/:id', scope: 'events:write', paged: false },
  { id: 'archive-question', method: 'DELETE', auth: K, path: '/questions/:id', scope: 'events:write', paged: false },
  { id: 'list-event-question-answers', method: 'GET', auth: K, path: '/events/:id/question-answers', scope: 'orders:read', paged: true },
  { id: 'get-order-answers', method: 'GET', auth: K, path: '/orders/:id/answers', scope: 'orders:read', paged: false },
  { id: 'get-ticket-answers', method: 'GET', auth: K, path: '/tickets/:id/answers', scope: 'tickets:read', paged: false },
  // claude/exos-dice-import (mig 20261106100000, exos-api/diceImport.ts,
  // docs/dice-coverage.md): the DICE connection, its runs, and a sync now.
  { id: 'get-dice-import', method: 'GET', auth: K, path: '/dice-import', scope: 'org:admin', paged: false, aliases: ['/dice_import'] },
  { id: 'list-dice-import-runs', method: 'GET', auth: K, path: '/dice-import/runs', scope: 'org:admin', paged: true, aliases: ['/dice_import/runs'] },
  { id: 'start-dice-import-sync', method: 'POST', auth: K, path: '/dice-import/sync', scope: 'org:admin', paged: false, aliases: ['/dice_import/sync'] },
  // claude/exos-buyer-geo-genre (mig 20261106140000, exos-api/buyerGeoGenre.ts):
  // where buyers are (DICE Order.ipCity / ipCountry, from the billing
  // address, never an IP) and the genres in use (DICE genreTypes).
  { id: 'get-event-buyer-locations', method: 'GET', auth: K, path: '/events/:id/buyer-locations', scope: 'orders:read', paged: false },
  { id: 'get-buyer-locations', method: 'GET', auth: K, path: '/buyer-locations', scope: 'orders:read', paged: false },
  { id: 'list-genres', method: 'GET', auth: K, path: '/genres', scope: 'events:read', paged: false },
  { id: 'public-discovery-genres', method: 'GET', auth: A, path: '/public/discovery/genres', scope: null, paged: false },
  // claude/exos-dice-gaps-6 (mig 20261107110000, exos-api/feeAdjustments.ts,
  // docs/api/fee-adjustments.json): the fee-change log (DICE Adjustment).
  // Existing scopes: orders:read for one order's, finance:read for an event's.
  { id: 'get-order-fee-adjustments', method: 'GET', auth: K, path: '/orders/:id/adjustments', scope: 'orders:read', paged: false },
  { id: 'list-event-fee-adjustments', method: 'GET', auth: K, path: '/events/:id/fee-adjustments', scope: 'finance:read', paged: true },
];

/** Methods the API answers (anything else is 405). */
export const API_METHODS: readonly ApiMethod[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

/** True for a path under /public/… (the listing feed and the partner contract). */
export function isSharedKeyPath(path: string): boolean {
  return path === '/public' || path.startsWith('/public/');
}

/**
 * The auth of the routes answering a /public/… path under any method:
 * 'shared_key' (the listing feed, #69) or 'partner_key' (the partner
 * contract, #74); null when no route answers it. exos-api dispatches /public/…
 * on this, so the two families can share the prefix.
 */
export function publicAuthAt(path: string): ApiAuth | null {
  for (const m of API_METHODS) {
    const r = matchRoute(m, path);
    if (r) return r.route.auth;
  }
  return null;
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
