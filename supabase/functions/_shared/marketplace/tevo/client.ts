// Ticket Evolution reader: read endpoints only (Hard Rule #2).
//
// Polling is TEvo's fail-safe to webhooks (HOWTO: Automate TEvo Order
// Processing). The Orders / Index filters and page parameters aren't in the
// supplied pages, so listOrders passes the caller's query through as is.

import { TEVO_ENDPOINTS, type EndpointName, type TevoEnvironment } from './endpoints.ts';
import {
  RETRY_TRANSIENT,
  TevoError,
  execute,
  readTevoJson,
  transportConfig,
  type FetchLike,
  type QueryValue,
  type TevoCredentials,
  type TransportConfig,
} from './transport.ts';
import type { TevoOrder, TevoShipment } from './types.ts';

export { TevoError };

export interface TevoClientOptions {
  credentials: () => TevoCredentials | Promise<TevoCredentials>;
  environment?: TevoEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

export class TevoClient {
  private readonly cfg: TransportConfig;

  constructor(opts: TevoClientOptions) {
    this.cfg = transportConfig(opts);
  }

  private async read(name: EndpointName, query?: Record<string, QueryValue>, path?: Record<string, string | number>): Promise<unknown> {
    const ep = TEVO_ENDPOINTS[name];
    if (ep.access !== 'read') throw new Error(`tevo client: "${name}" is not a read endpoint (Hard Rule #2)`);
    const { res, creds } = await execute(this.cfg, ep, { query, path }, RETRY_TRANSIENT);
    return readTevoJson(res, ep, creds);
  }

  /** GET /v9/orders: a page of orders ({orders: [...]} or a bare list). */
  async listOrders(query: Record<string, QueryValue> = {}): Promise<TevoOrder[]> {
    const v = await this.read('listOrders', query);
    const list = Array.isArray(v) ? v : (v as { orders?: unknown } | null)?.orders;
    return Array.isArray(list) ? (list as TevoOrder[]) : [];
  }

  /** GET /v9/orders/{id}. */
  async getOrder(orderId: string | number): Promise<TevoOrder | null> {
    const v = await this.read('showOrder', undefined, { order_id: orderId });
    return v && typeof v === 'object' && 'id' in v ? (v as TevoOrder) : null;
  }

  /** GET /v9/shipments/{id}. */
  async getShipment(shipmentId: string | number): Promise<TevoShipment | null> {
    const v = await this.read('showShipment', undefined, { shipment_id: shipmentId });
    return v && typeof v === 'object' && 'id' in v ? (v as TevoShipment) : null;
  }
}
