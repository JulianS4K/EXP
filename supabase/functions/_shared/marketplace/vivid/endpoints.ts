// Every Vivid Seats Broker Portal endpoint Exos knows about
// (docs/marketplace/vivid/), tagged by what it does to Vivid Seats.
//
//   read       changes nothing.
//   write      changes Vivid Seats state. Built, dry-run; sending one needs an
//              operator WriteAuthorization.
//   forbidden  never sent, even with an authorization.
//
// The Broker Portal has no account-wide or bulk-destructive endpoint (no
// inventory snapshot, no delete-by-event). The risk is the same as on the
// other marketplaces, though: the broker account can also carry Terminal-2
// inventory. So Exos addresses its listings only by its own id (ticketId /
// internalTicketId = the "ex…" listing id), never by Vivid's listingId, and
// the writer checks that on every call.
//
// Two API generations:
//   * v2 listings and events: JSON, `Api-token` header.
//   * v1 orders (and the deprecated v1 listings): XML, `apiToken` as a query
//     parameter (GET) or a form field (POST). The transport adds it at the
//     last moment; it's redacted from every URL, error and plan.
// Every call may also carry `X-Integrator-Token` (VIVID_INTEGRATOR_TOKEN).
//
// Forbidden: the deprecated v1 listing writes. deleteListing is a delete sent
// as a GET, and both overlap v2; keeping one write path (v2, by our id) keeps
// the checks in one place.

export type Access = 'read' | 'write' | 'forbidden';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';
/** header: Api-token header. param: apiToken query (GET) or form field (POST). */
export type AuthStyle = 'header' | 'param';
export type BodyKind = 'json' | 'form' | 'none';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
  auth: AuthStyle;
  body: BodyKind;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A, auth: AuthStyle, body: BodyKind = 'none') =>
  ({ method, path, access, auth, body });

export const VIVID_API_HOST = 'https://brokers.vividseats.com/webservices';

export const VIVID_ENDPOINTS = {
  // Events (JSON; one request every 5 seconds)
  searchEvents: e('GET', '/events/search', 'read', 'header'),
  searchInventoryEvents: e('GET', '/events/inventory/search', 'read', 'header'),

  // Listings v2 (JSON). Exos: by internalTicketId (its own id) only.
  createListing: e('POST', '/listings/v2/create', 'write', 'header', 'json'),
  getListings: e('GET', '/listings/v2/get', 'read', 'header'),
  /** A full replace, keyed by Vivid's id inside the body: the writer reads it back by our ticketId first. */
  updateListing: e('PUT', '/listings/v2/update', 'write', 'header', 'json'),
  /** By internalTicketId only; the listingId form of this call is refused. */
  deleteListing: e('DELETE', '/listings/v2/delete', 'write', 'header'),

  // Listings v1 (deprecated; XML). Exos uses v2.
  getListingsV1: e('GET', '/listings/v1/getListings', 'read', 'param'),
  updateListingV1: e('POST', '/listings/v1/updateListing', 'forbidden', 'param', 'form'),
  // A delete sent as a GET: kept out of the reader and the writer.
  deleteListingV1: e('GET', '/listings/v1/deleteListing', 'forbidden', 'param'),

  // Orders v1 (XML)
  getOrders: e('GET', '/v1/getOrders', 'read', 'param'),
  getOrder: e('GET', '/v1/getOrder', 'read', 'param'),
  getCompletedOrders: e('GET', '/v1/getCompletedOrders', 'read', 'param'),
  getPendingRetransferOrders: e('GET', '/v1/getPendingRetransferOrders', 'read', 'param'),
  confirmOrder: e('POST', '/v1/confirmOrder', 'write', 'param', 'form'),
  rejectOrder: e('POST', '/v1/rejectOrder', 'write', 'param', 'form'),
  transferOrderViaURL: e('POST', '/v1/transferOrderViaURL', 'write', 'param', 'form'),
  transferOrder: e('POST', '/v1/transferOrder', 'write', 'param', 'form'),
  transferOrderWithMobileQR: e('POST', '/v1/transferOrderWithMobileQR', 'write', 'param', 'form'),
  moveMobileOrderToElectronicTransfer: e('POST', '/v1/moveMobileOrderToElectronicTransfer', 'write', 'param', 'form'),
  shipOrder: e('POST', '/v1/shipOrder', 'write', 'param', 'form'),
  integratedTransfer: e('POST', '/v1/orders/{orderId}/integratedTransfer', 'write', 'header', 'json'),
  getPurchaseOrder: e('GET', '/v1/getPurchaseOrder', 'read', 'param'),
  getAirbill: e('GET', '/v1/getAirbill', 'read', 'param'),

  // Payments
  getPayments: e('GET', '/v1/payments', 'read', 'param'),
  getPayment: e('GET', '/v1/payments/{id}', 'read', 'param'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof VIVID_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`vivid: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
