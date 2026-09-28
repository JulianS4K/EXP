// Vivid Seats reader: read endpoints only (Hard Rule #2).
//
// Vivid rate-limits some reads hard: events/search one request every 5
// seconds, getOrders one every 10 seconds per status (60 for
// PENDING_SHIPMENT). The client spaces those calls itself, per instance.

import type { EventCandidate } from '../channel.ts';
import { VIVID_ENDPOINTS, type EndpointName } from './endpoints.ts';
import { ordersFromXml } from './orders.ts';
import {
  RETRY_TRANSIENT,
  VividError,
  execute,
  readVividBody,
  transportConfig,
  type FetchLike,
  type QueryValue,
  type VividCredentials,
  type TransportConfig,
} from './transport.ts';
import type { VividEvent, VividListing, VividListingsResponse, VividOrder, VividOrderStatus } from './types.ts';

export { VividError };

export interface VividClientOptions {
  credentials: () => VividCredentials | Promise<VividCredentials>;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

/** Documented minimum gaps between calls, in ms. */
export const VIVID_MIN_INTERVAL_MS = { searchEvents: 5_000, getOrders: 10_000, getOrdersPendingShipment: 60_000 } as const;

export class VividClient {
  private readonly cfg: TransportConfig;
  private readonly now: () => number;
  private readonly last = new Map<string, number>();

  constructor(opts: VividClientOptions) {
    this.cfg = transportConfig(opts);
    this.now = opts.now ?? (() => Date.now());
  }

  /** Waits out the documented gap since this client's last call of `key`. */
  private async pace(key: string, gapMs: number) {
    const prev = this.last.get(key);
    if (prev != null) {
      const wait = prev + gapMs - this.now();
      if (wait > 0) await this.cfg.sleep(wait);
    }
    this.last.set(key, this.now());
  }

  private async read(name: EndpointName, query?: Record<string, QueryValue>, path?: Record<string, string | number>) {
    const ep = VIVID_ENDPOINTS[name];
    if (ep.access !== 'read') throw new Error(`vivid client: "${name}" is not a read endpoint (Hard Rule #2)`);
    const { res, creds } = await execute(this.cfg, ep, { query, path }, RETRY_TRANSIENT);
    return readVividBody(res, ep, creds);
  }

  private async readJson<T>(name: EndpointName, query?: Record<string, QueryValue>): Promise<T> {
    const b = await this.read(name, query);
    if (b.kind === 'empty') return [] as unknown as T;
    if (b.kind !== 'json') throw new VividError(`vivid ${name}: expected JSON`, 200, null);
    return b.value as T;
  }

  private async readOrders(name: EndpointName, query: Record<string, QueryValue>): Promise<VividOrder[]> {
    const b = await this.read(name, query);
    if (b.kind === 'empty') return [];
    if (b.kind === 'xml') return ordersFromXml(b.root);
    // JSON, if Vivid ever answers that way: the same fields.
    const v = b.value;
    const list = Array.isArray(v) ? v : v && typeof v === 'object' && 'orderId' in v ? [v] : [];
    return list as VividOrder[];
  }

  /**
   * GET /events/search. With a keyword, at most one page of 1000 events.
   * fromDate needs toDate. Dates are sent as "YYYY-MM-DDTHH:MM:SS" (the
   * format isn't documented; see docs/marketplace/vivid/README.md).
   */
  async searchEvents(q: { eventKeyword?: string; venueKeyword?: string; fromDate?: string; toDate?: string; page?: number }): Promise<VividEvent[]> {
    if (!!q.fromDate !== !!q.toDate) throw new Error('vivid searchEvents: fromDate and toDate go together');
    await this.pace('searchEvents', VIVID_MIN_INTERVAL_MS.searchEvents);
    const v = await this.readJson<VividEvent[]>('searchEvents', { ...q });
    return Array.isArray(v) ? v : [];
  }

  /** GET /listings/v2/get?internalTicketId=: our listing, by our id. */
  async getListingsByTicketId(ticketId: string): Promise<VividListing[]> {
    const v = await this.readJson<VividListingsResponse>('getListings', { internalTicketId: ticketId });
    return Array.isArray(v?.listings) ? v.listings : [];
  }

  /** GET /v1/getOrders: UNCONFIRMED or PENDING_SHIPMENT only; the account may carry broker orders too. */
  async getOrders(status: Extract<VividOrderStatus, 'UNCONFIRMED' | 'PENDING_SHIPMENT'>, page: { pageSize?: number; bookmark?: number } = {}): Promise<VividOrder[]> {
    await this.pace(`getOrders:${status}`, status === 'PENDING_SHIPMENT' ? VIVID_MIN_INTERVAL_MS.getOrdersPendingShipment : VIVID_MIN_INTERVAL_MS.getOrders);
    return this.readOrders('getOrders', { status, pageSize: page.pageSize, bookmark: page.bookmark });
  }

  /** GET /v1/getOrder (not rate-limited). null when Vivid returns no order. */
  async getOrder(orderId: string | number): Promise<VividOrder | null> {
    return (await this.readOrders('getOrder', { orderId }))[0] ?? null;
  }
}

/** A Vivid event as a link candidate. eventDate is venue-local, so it's compared as a local date. */
export function vividEventToCandidate(e: VividEvent): EventCandidate {
  const local = (e.eventDate ?? e.eventDateString ?? '').replace(/(Z|[+-]\d{2}:?\d{2})$/, '');
  return {
    channel: 'vivid',
    externalEventId: String(e.eventId),
    name: e.eventName ?? '',
    startsAt: null,
    startsLocal: /^\d{4}-\d{2}-\d{2}/.test(local) ? local : null,
    venueName: e.venue?.name ?? null,
    venueCity: e.venue?.city ?? null,
    url: e.url ?? (e.webPath ? `https://www.vividseats.com${e.webPath.startsWith('/') ? '' : '/'}${e.webPath}` : null),
  };
}
