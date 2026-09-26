// Every StubHub endpoint in the vendor reference (the printed PDFs and the
// OpenAPI specs in docs/marketplace/stubhub/), tagged by what it does to
// StubHub. Mirrors the R / W / R* table in docs/marketplace/stubhub/README.md.
// Paths are relative to the API root: transport.ts adds `/v2` for every API
// except Catalog.
//
//   read   — GET, changes nothing.
//   lookup — PUT/POST verb but changes nothing (batch get, previews, mapping).
//   write  — mutates StubHub state (listings, sales, account, webhooks).
//
// CLAUDE.md Hard Rule #2: upstream ticketing APIs are read-only. The client
// refuses any `write` entry at request time, so adding a write method is a
// deliberate, reviewable change to this table (plus operator sign-off), not
// an accident.

export type Access = 'read' | 'lookup' | 'write';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A) => ({ method, path, access });

export const STUBHUB_ENDPOINTS = {
  // Catalog
  listEvents: e('GET', '/catalog/events', 'read'),
  getEventsByIds: e('PUT', '/catalog/events', 'lookup'),
  getEvent: e('GET', '/catalog/events/{eventId}', 'read'),
  searchEvents: e('GET', '/catalog/events/search', 'read'),
  getEventByExternalId: e('GET', '/catalog/events/external_mappings/{platform}/{externalEventId}', 'read'),
  searchCategories: e('GET', '/catalog/categories/map', 'read'),
  listCategoryEvents: e('GET', '/catalog/categories/{categoryId}/events', 'read'),
  listAllCategoryEvents: e('GET', '/catalog/categories/{categoryId}/allevents', 'read'),
  mapEvent: e('POST', '/catalog/mapevent', 'lookup'),
  listVenues: e('GET', '/catalog/venues', 'read'),
  getVenue: e('GET', '/catalog/venues/{venueId}', 'read'),

  // Inventory
  listSellerListings: e('GET', '/sellerlistings', 'read'),
  listSellerListingUpdates: e('GET', '/sellerlistings/recentupdates', 'read'),
  getSellerListing: e('GET', '/sellerlistings/{listingId}', 'read'),
  getSellerListingByExternalId: e('GET', '/externalsellerlistings/{externalId}', 'read'),
  createSellerListing: e('POST', '/events/{eventId}/sellerlistings', 'write'),
  createSellerListingForRequestedEvent: e('POST', '/sellerlistings', 'write'),
  updateSellerListing: e('PATCH', '/sellerlistings/{listingId}', 'write'),
  updateSellerListingByExternalId: e('PATCH', '/externalsellerlistings/{externalId}', 'write'),
  deleteSellerListing: e('DELETE', '/sellerlistings/{listingId}', 'write'),
  deleteSellerListingByExternalId: e('DELETE', '/externalsellerlistings/{externalId}', 'write'),
  previewSellerListing: e('POST', '/events/{eventId}/sellerlistingpreview', 'lookup'),
  previewSellerListingForRequestedEvent: e('POST', '/sellerlistingpreview', 'lookup'),
  previewSellerListingUpdate: e('POST', '/sellerlistings/{listingId}/updatepreview', 'lookup'),
  listEventListingConstraints: e('GET', '/events/{eventId}/listingconstraints', 'read'),
  getSellerListingConstraints: e('GET', '/sellerlistings/{listingId}/constraints', 'read'),
  getRequestedEventListingConstraints: e('PUT', '/listingconstraints', 'lookup'),
  listSellerEvents: e('GET', '/sellerevents', 'read'),
  getSellerEvent: e('GET', '/sellerevents/{eventIdOrRequestedEventId}', 'read'),
  createSellerEvent: e('PUT', '/sellerevents', 'write'),
  uploadListingETickets: e('POST', '/sellerlistings/{listingId}/eticketuploads', 'write'),
  listListingETicketUploads: e('GET', '/sellerlistings/{listingId}/eticketuploads', 'read'),
  uploadEventETickets: e('POST', '/events/{eventId}/eticketuploads', 'write'),
  listEventETicketUploads: e('GET', '/events/{eventId}/eticketuploads', 'read'),
  listListingETickets: e('GET', '/sellerlistings/{listingId}/etickets', 'read'),
  saveListingETickets: e('POST', '/sellerlistings/{listingId}/etickets', 'write'),
  markBackListingETickets: e('PATCH', '/sellerlistings/{listingId}/etickets', 'write'),
  deleteListingETicket: e('DELETE', '/sellerlistings/{listingId}/etickets/{eticketId}', 'write'),
  deleteEventETicket: e('DELETE', '/events/{eventId}/etickets/{eticketId}', 'write'),
  getMarkedBackETicketDocument: e('GET', '/sellerlistings/{listingId}/markedbacketickets/{markedBackETicketId}/document', 'read'),
  listListingShipments: e('GET', '/sellerlistings/{listingId}/shipments', 'read'),
  getListingShipmentLabel: e('GET', '/sellerlistings/{listingId}/shipments/{shipmentId}/label', 'read'),
  printListingShipmentLabel: e('PUT', '/sellerlistings/{listingId}/shipments', 'write'),
  updateListingShipment: e('PATCH', '/sellerlistings/{listingId}/shipments/{shipmentId}', 'write'),

  // Sales
  listSales: e('GET', '/sales', 'read'),
  listSaleUpdates: e('GET', '/sales/recentupdates', 'read'),
  getSale: e('GET', '/sales/{saleId}', 'read'),
  updateSale: e('PATCH', '/sales/{saleId}', 'write'),
  rejectSale: e('DELETE', '/sales/{saleId}', 'write'),
  uploadSaleETickets: e('POST', '/sales/{saleId}/eticketuploads', 'write'),
  listSaleETicketUploads: e('GET', '/sales/{saleId}/eticketuploads', 'read'),
  listSaleETickets: e('GET', '/sales/{saleId}/etickets', 'read'),
  saveSaleETickets: e('POST', '/sales/{saleId}/etickets', 'write'),
  deleteSaleETicket: e('DELETE', '/sales/{saleId}/etickets/{eticketId}', 'write'),
  getETicketDocument: e('GET', '/etickets/{eticketId}/document', 'read'),
  getETicketThumbnail: e('GET', '/etickets/{eticketId}/thumbnail', 'read'),
  getETicketUploadDocument: e('GET', '/eticketuploads/{eticketUploadId}/document', 'read'),
  listSaleShipments: e('GET', '/sales/{saleId}/shipments', 'read'),
  getSaleShipmentLabel: e('GET', '/sales/{saleId}/shipments/{shipmentId}/label', 'read'),
  printSaleShipmentLabel: e('PUT', '/sales/{saleId}/shipments', 'write'),
  updateSaleShipment: e('PATCH', '/sales/{saleId}/shipments/{shipmentId}', 'write'),
  listSaleTicketHolders: e('GET', '/sales/{saleId}/ticketholders', 'read'),
  // In the OpenAPI spec, not in the printed PDFs.
  uploadSaleTransferProof: e('POST', '/sales/{saleId}/transferuploads/{transferType}', 'write'),
  uploadSaleTransferStatusProof: e('POST', '/sales/{saleId}/transferstatusproof', 'write'),
  listPayments: e('GET', '/payments', 'read'),
  getPayment: e('GET', '/payments/{paymentId}', 'read'),
  getNextPayment: e('GET', '/payments/next', 'read'),

  // Account
  getUser: e('GET', '/user', 'read'),
  updateUser: e('PATCH', '/user', 'write'),
  listAddresses: e('GET', '/addresses', 'read'),
  getAddress: e('GET', '/addresses/{addressId}', 'read'),
  createAddress: e('POST', '/addresses', 'write'),
  updateAddress: e('PATCH', '/addresses/{addressId}', 'write'),
  deleteAddress: e('DELETE', '/addresses/{addressId}', 'write'),
  // In the printed PDFs, not in the OpenAPI spec.
  listPaymentMethods: e('GET', '/paymentmethods', 'read'),
  getPaymentMethod: e('GET', '/paymentmethods/{paymentMethodId}', 'read'),
  listListingPaymentMethods: e('PUT', '/listings/{listingId}/paymentmethods', 'lookup'),

  // Webhooks
  listWebhooks: e('GET', '/webhooks', 'read'),
  getWebhook: e('GET', '/webhooks/{webhookId}', 'read'),
  createWebhook: e('POST', '/webhooks', 'write'),
  updateWebhook: e('PATCH', '/webhooks/{webhookId}', 'write'),
  deleteWebhook: e('DELETE', '/webhooks/{webhookId}', 'write'),
  pingWebhook: e('POST', '/webhooks/{webhookId}/ping', 'write'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof STUBHUB_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`stubhub: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
