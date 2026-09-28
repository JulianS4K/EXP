// GoTickets reader: GET endpoints only (Hard Rule #2).

import { GOTICKETS_ENDPOINTS, type EndpointName } from './endpoints.ts';
import { GoTicketsError, RETRY_TRANSIENT, execute, transportConfig, type FetchLike, type GoTicketsCredentials, type QueryValue, type TransportConfig } from './transport.ts';
import type { GoTicketsListing, GoTicketsSale } from './types.ts';

export { GoTicketsError };

export interface GoTicketsClientOptions {
  credentials: () => GoTicketsCredentials | Promise<GoTicketsCredentials>;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

/** "2023-01-01T00:00:00": the format GET /rest/sales documents for orderTimeFrom / To (UTC here). */
export function goTicketsTime(d: Date): string {
  return d.toISOString().slice(0, 19);
}

export class GoTicketsClient {
  private readonly cfg: TransportConfig;

  constructor(opts: GoTicketsClientOptions) {
    this.cfg = transportConfig(opts);
  }

  private async get<T>(name: EndpointName, path?: Record<string, string | number>, query?: Record<string, QueryValue>): Promise<T> {
    const ep = GOTICKETS_ENDPOINTS[name];
    if (ep.access !== 'read') throw new Error(`gotickets client: "${name}" is not a read endpoint (Hard Rule #2)`);
    const res = await execute(this.cfg, ep, { path, query }, RETRY_TRANSIENT);
    return (await res.json()) as T;
  }

  /** GET /rest/sales: sales placed since `from` (the account may carry broker sales too). */
  searchSales(q: { orderTimeFrom?: Date; orderTimeTo?: Date; sellerStatuses?: string; externalTicketId?: string } = {}) {
    return this.get<GoTicketsSale[]>('searchSales', undefined, {
      orderTimeFrom: q.orderTimeFrom ? goTicketsTime(q.orderTimeFrom) : undefined,
      orderTimeTo: q.orderTimeTo ? goTicketsTime(q.orderTimeTo) : undefined,
      sellerStatuses: q.sellerStatuses,
      externalTicketId: q.externalTicketId,
    });
  }

  /** Every sale waiting to be confirmed. */
  unconfirmedSales() {
    return this.get<GoTicketsSale[]>('unconfirmedSales');
  }

  getSale(orderId: string | number) {
    return this.get<GoTicketsSale>('getSale', { orderId });
  }

  getListingByExternalId(externalId: string) {
    return this.get<GoTicketsListing>('getListingByExternalId', { externalId });
  }
}

/** The customer's email from a sale, trimmed and lower-cased, or null. */
export function saleEmail(s: GoTicketsSale | null | undefined): string | null {
  const e = (s?.customerEmailAddress ?? '').trim().toLowerCase();
  return e && e.includes('@') ? e : null;
}
