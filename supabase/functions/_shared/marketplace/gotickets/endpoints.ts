// Every GoTickets Seller Central endpoint Exos knows about
// (docs/marketplace/gotickets/), tagged by what it does to GoTickets.
//
//   read       GET, changes nothing.
//   write      changes GoTickets state. Built, dry-run; sending one needs an
//              operator WriteAuthorization.
//   forbidden  never sent, even with an authorization. They act on listings
//              Exos doesn't own: the seller account can also carry broker
//              inventory (Terminal-2).
//                * POST /rest/listings/bulk/snapshot: "a snapshot of your
//                  entire inventory": everything missing from it goes.
//                * DELETE /rest/listings/by-event-id: every listing of an
//                  event, the broker's too.
//                * anything keyed by GoTickets' internal listing id: Exos
//                  addresses its listings only by externalTicketId (its own
//                  "ex…" id), which the writer checks.
//
// Auth: X-Api-Access-Id + X-Api-Access-Secret headers.

export type Access = 'read' | 'write' | 'forbidden';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A) => ({ method, path, access });

export const GOTICKETS_API_HOST = 'https://sc.gotickets.com';

export const GOTICKETS_ENDPOINTS = {
  // Listings (Exos: by externalTicketId only)
  createListings: e('POST', '/rest/listings', 'write'),
  createListing: e('POST', '/rest/listings/single', 'write'),
  getListingByExternalId: e('GET', '/rest/listings/external-id/{externalId}', 'read'),
  updateListingByExternalId: e('PUT', '/rest/listings/external-id/{externalId}', 'write'),
  deleteListingByExternalId: e('DELETE', '/rest/listings/external-id/{externalId}', 'write'),
  deleteListingsByExternalIds: e('DELETE', '/rest/listings/external-id', 'write'),
  getLastListingSyncTime: e('GET', '/rest/listings/last-success-time', 'read'),
  getUnmappedListings: e('GET', '/rest/listings/bulk/snapshot/unmapped', 'read'),
  updateListings: e('PUT', '/rest/listings', 'forbidden'),
  getListing: e('GET', '/rest/listings/{id}', 'read'),
  updateListing: e('PUT', '/rest/listings/{id}', 'forbidden'),
  deleteListing: e('DELETE', '/rest/listings/{id}', 'forbidden'),
  deleteListings: e('DELETE', '/rest/listings', 'forbidden'),
  postInventorySnapshot: e('POST', '/rest/listings/bulk/snapshot', 'forbidden'),
  deleteListingsByEventId: e('DELETE', '/rest/listings/by-event-id', 'forbidden'),

  // Sales
  searchSales: e('GET', '/rest/sales', 'read'),
  getSale: e('GET', '/rest/sales/{orderId}', 'read'),
  unconfirmedSales: e('GET', '/rest/sales/unconfirmed', 'read'),
  confirmSale: e('POST', '/rest/sales/{orderId}/confirm', 'write'),
  rejectSale: e('POST', '/rest/sales/{orderId}/reject', 'write'),
  fulfillSale: e('POST', '/rest/sales/{orderId}/fulfill', 'write'),
  reTransferSale: e('POST', '/rest/sales/{orderId}/re-transfer', 'write'),

  // Events (GoTickets maps listings to its events itself; read for reference)
  getEvents: e('GET', '/rest/events', 'read'),
  getEvent: e('GET', '/rest/events/{id}', 'read'),

  // Webhooks
  getWebhooks: e('GET', '/rest/webhooks', 'read'),
  createWebhook: e('POST', '/rest/webhooks', 'write'),
  updateWebhook: e('PUT', '/rest/webhooks/{id}', 'write'),
  deleteWebhook: e('DELETE', '/rest/webhooks/{id}', 'write'),

  // Payments
  searchPayments: e('GET', '/rest/payments', 'read'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof GOTICKETS_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`gotickets: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
