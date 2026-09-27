// Gametime reader: GET /purchases only (Hard Rule #2).

import { GAMETIME_ENDPOINTS, type EndpointName, type GametimeEnvironment } from './endpoints.ts';
import { GametimeError, RETRY_TRANSIENT, execute, transportConfig, type FetchLike, type KeySource, type QueryValue, type TransportConfig } from './transport.ts';
import type { GametimePurchase, GametimePurchasesPage } from './types.ts';

export { GametimeError };

export interface GametimeClientOptions {
  /** GAMETIME_API_KEY (the `source` key). */
  apiKey: KeySource;
  environment?: GametimeEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

export class GametimeClient {
  private readonly cfg: TransportConfig;

  constructor(opts: GametimeClientOptions) {
    this.cfg = transportConfig(opts);
  }

  private async get<T>(name: EndpointName, query?: Record<string, QueryValue>): Promise<T> {
    const ep = GAMETIME_ENDPOINTS[name];
    if (ep.access !== 'read') throw new Error(`gametime client: "${name}" is not a read endpoint (Hard Rule #2)`);
    const res = await execute(this.cfg, ep, { query }, RETRY_TRANSIENT);
    return (await res.json()) as T;
  }

  /**
   * GET /purchases. `completed: false` = every open (actionable) purchase;
   * `status` = unconfirmed | unfulfilled | completed | rejected. Results can
   * include rejected purchases: check each one's status.
   */
  listPurchases(q: { status?: string; completed?: boolean; per_page?: number; page?: number; sort_by_created_at?: 'asc' | 'desc' } = {}) {
    return this.get<GametimePurchasesPage>('listPurchases', q);
  }

  /** One purchase by order number, or null. */
  async getPurchase(orderNumber: string): Promise<GametimePurchase | null> {
    const r = await this.get<GametimePurchasesPage>('listPurchases', { order_number: orderNumber });
    return (r.results ?? []).find((p) => String(p.id) === String(orderNumber)) ?? r.results?.[0] ?? null;
  }
}

/** The ticket recipient's email, trimmed and lower-cased, or null. */
export function purchaseEmail(p: GametimePurchase | null | undefined): string | null {
  const e = (p?.email ?? '').trim().toLowerCase();
  return e && e.includes('@') ? e : null;
}

/** "ISODate(2015-01-09T18:08:30.357Z)" (or a plain ISO string) -> ISO string, or null. */
export function gametimeDate(v: string | null | undefined): string | null {
  if (!v) return null;
  const m = /^ISODate\((.*)\)$/.exec(v.trim());
  const iso = (m ? m[1] : v).trim().replace(/^"|"$/g, '');
  return Number.isNaN(Date.parse(iso)) ? null : new Date(iso).toISOString();
}
