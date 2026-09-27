// Every SeatGeek Seller Direct API endpoint (docs/marketplace/seatgeek/),
// tagged by what it does to SeatGeek. Mirrors the table in
// docs/marketplace/seatgeek/README.md.
//
//   read       GET, changes nothing.
//   write      changes SeatGeek state (a listing, an order). Built, dry-run;
//              sending one needs an operator WriteAuthorization.
//   forbidden  never sent, even with an authorization: these act on the
//              seller's WHOLE inventory, and the seller account also carries
//              broker listings (Terminal-2). The CSV sync adds, updates and
//              DELETES every listing not in the file; the purge deletes all.
//
// CLAUDE.md Hard Rule #2: upstream ticketing APIs are read-only. The client
// refuses anything but `read`; the writer refuses `forbidden` always and
// `write` without an authorization naming the endpoint.

export type Access = 'read' | 'write' | 'forbidden';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A) => ({ method, path, access });

export const SEATGEEK_API_HOST = 'https://sellerdirect-api.seatgeek.com';

export const SEATGEEK_ENDPOINTS = {
  // Listings
  listListings: e('GET', '/listings', 'read'),
  getListing: e('GET', '/listings/single/{sellerListingId}', 'read'),
  createListing: e('PUT', '/listings/single/{sellerListingId}', 'write'),
  updateListing: e('PATCH', '/listings/single/{sellerListingId}', 'write'),
  deleteListing: e('DELETE', '/listing', 'write'),
  /** Deprecated in favour of bulkDeleteListings (listing guide). */
  deleteListings: e('DELETE', '/listings', 'write'),
  /** Current, recommended bulk delete: body { seller_listing_ids: [...] }. */
  bulkDeleteListings: e('POST', '/listings/bulk-delete', 'write'),
  syncListingsCsvPost: e('POST', '/listings', 'forbidden'),
  syncListingsCsvPut: e('PUT', '/listings', 'forbidden'),
  getPurgeStatus: e('GET', '/listings/purge', 'read'),
  purgeListings: e('POST', '/listings/purge', 'forbidden'),

  // Orders
  getOrder: e('GET', '/order', 'read'),
  updateOrder: e('PATCH', '/order', 'write'),
  fulfilOrder: e('PUT', '/v3/order', 'write'),
  fulfilOrderV1: e('PUT', '/v1/order', 'write'),
  fulfilOrderV2: e('PUT', '/v2/order', 'write'),
  initOrderProofs: e('POST', '/v3/order/proofs', 'write'),
  listOrders: e('GET', '/orders', 'read'),
  getOrderCustomer: e('GET', '/orders/customer', 'read'),
  getOrderLabel: e('GET', '/orders/label', 'read'),

  // Remittances
  listRemittances: e('GET', '/remittances', 'read'),
  getCurrentRemittance: e('GET', '/remittances/current', 'read'),
  getRemittance: e('GET', '/remittances/{invoiceId}', 'read'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof SEATGEEK_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`seatgeek: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
