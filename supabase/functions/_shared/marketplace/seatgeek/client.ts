// SeatGeek Seller Direct reader: GET endpoints only (Hard Rule #2). Any
// endpoint not tagged `read` in endpoints.ts is refused before a request
// is built.

import { SEATGEEK_ENDPOINTS, type EndpointName } from './endpoints.ts';
import {
  RETRY_TRANSIENT,
  SeatGeekError,
  execute,
  transportConfig,
  type FetchLike,
  type QueryValue,
  type AuthScheme,
  type TokenSource,
  type TransportConfig,
} from './transport.ts';
import type {
  CurrentRemittance,
  ListingsPage,
  OrdersPage,
  PurgeStatus,
  SeatGeekCustomer,
  SeatGeekDetailedInvoice,
  SeatGeekInvoice,
  SeatGeekListing,
  SeatGeekOrder,
} from './types.ts';

export { SeatGeekError };

export interface SeatGeekClientOptions {
  /** The seller API token (SEATGEEK_API_TOKEN). */
  token: TokenSource;
  /** 'Bearer' (API spec, default) or 'token' (listing guide examples). */
  authScheme?: AuthScheme;
  baseUrl?: string;
  userAgent?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

export class SeatGeekClient {
  private readonly cfg: TransportConfig;

  constructor(opts: SeatGeekClientOptions) {
    this.cfg = transportConfig(opts);
  }

  private async get<T>(name: EndpointName, path?: Record<string, string | number>, query?: Record<string, QueryValue>): Promise<T> {
    const ep = SEATGEEK_ENDPOINTS[name];
    if (ep.access !== 'read') throw new Error(`seatgeek client: "${name}" is not a read endpoint (Hard Rule #2)`);
    const res = await execute(this.cfg, ep, { path, query }, RETRY_TRANSIENT);
    return (await res.json()) as T;
  }

  /** GET /listings: every listing on the account (broker inventory too), cursor-paged. */
  listListings(q: { seller_listing_ids?: string[]; event_id?: number; only_barcode?: 0 | 1; per_page?: number; page_cursor?: string } = {}) {
    return this.get<ListingsPage>('listListings', undefined, {
      seller_listing_ids: q.seller_listing_ids?.join(','),
      event_id: q.event_id,
      only_barcode: q.only_barcode,
      per_page: q.per_page,
      page_cursor: q.page_cursor,
    });
  }

  /** The guide's response is { listing: {...} }; the API spec shows the bare listing. Both are accepted. */
  async getListing(sellerListingId: string): Promise<SeatGeekListing> {
    const r = await this.get<SeatGeekListing | { listing: SeatGeekListing }>('getListing', { sellerListingId });
    return 'listing' in r && r.listing && typeof r.listing === 'object' ? r.listing : (r as SeatGeekListing);
  }

  getPurgeStatus() {
    return this.get<PurgeStatus>('getPurgeStatus');
  }

  getOrder(orderId: string) {
    return this.get<SeatGeekOrder>('getOrder', undefined, { order_id: orderId });
  }

  /** GET /orders, page-numbered (default 200 per page). Dates are "placed at or after / before". */
  listOrders(q: { status?: string; start_date?: Date | string; end_date?: Date | string; page?: number; per_page?: number } = {}) {
    return this.get<OrdersPage>('listOrders', undefined, {
      status: q.status,
      start_date: q.start_date,
      end_date: q.end_date,
      page: q.page,
      per_page: q.per_page,
    });
  }

  /**
   * GET /orders/customer: the buyer (email, name, phone). The guide wraps it
   * as { customer: {...} }; the API spec shows it bare. Not available after
   * the event.
   */
  async getOrderCustomer(orderId: string): Promise<SeatGeekCustomer> {
    const r = await this.get<SeatGeekCustomer | { customer: SeatGeekCustomer }>('getOrderCustomer', undefined, { order_id: orderId });
    return 'customer' in r && r.customer && typeof r.customer === 'object' ? r.customer : (r as SeatGeekCustomer);
  }

  listRemittances(q: { page?: number; per_page?: number } = {}) {
    return this.get<{ invoices: SeatGeekInvoice[] }>('listRemittances', undefined, q);
  }

  getCurrentRemittance() {
    return this.get<CurrentRemittance>('getCurrentRemittance');
  }

  getRemittance(invoiceId: string) {
    return this.get<SeatGeekDetailedInvoice>('getRemittance', { invoiceId });
  }
}

/** The buyer's email from GET /orders/customer, trimmed and lower-cased, or null. */
export function customerEmail(c: SeatGeekCustomer | null | undefined): string | null {
  const e = (c?.email ?? '').trim().toLowerCase();
  return e && e.includes('@') ? e : null;
}
