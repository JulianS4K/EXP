// Read-only StubHub API client.
//
// Plain `fetch`, no dependencies, so the same file can back a Deno edge
// function (reconcile / xref jobs) as well as Node scripts and tests.
//
// What it covers: every endpoint tagged `read` or `lookup` in endpoints.ts:
// catalog sync + event xref, our own listings/sales/payouts for reconcile,
// listing previews (fee/proceeds quotes; nothing is created), and webhook
// config reads.
//
// What it deliberately doesn't: any `write`. `request()` refuses an endpoint
// tagged `write` before a byte leaves the process (CLAUDE.md Hard Rule #2).
// Listing push stays with exos-distribute, which is gated on operator
// sign-off.
//
// The vendor reference documents neither the API host nor the OAuth token
// URL, so both are required config (no guessed defaults). Auth is OAuth2
// bearer; `clientCredentialsToken()` below is a caching provider for the
// standard client-credentials grant if that's what the account is issued.

import { STUBHUB_ENDPOINTS, buildPath, type EndpointName } from './endpoints';
import type {
  ApiErrorBody,
  CatalogEvent,
  EventFilterQuery,
  EventSearchQuery,
  MapEventRequest,
  MapEventResult,
  Page,
  Payment,
  Sale,
  SaleQuery,
  SellerEvent,
  SellerListing,
  SellerListingDraft,
  SellerListingQuery,
  StubHubUser,
  Venue,
  VenueQuery,
  Webhook,
  CatalogPageQuery,
} from './types';

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
type TokenSource = () => string | Promise<string>;
type QueryValue = string | number | boolean | Date | null | undefined;

export interface StubHubClientOptions {
  /** API host, e.g. from STUBHUB_API_BASE_URL. No trailing path needed. */
  baseUrl: string;
  /** Returns a current OAuth2 access token. */
  accessToken: TokenSource;
  fetch?: FetchLike;
  /** Retries on 429/502/503/504 (all our calls are side-effect free). Default 2. */
  maxRetries?: number;
  /** Injectable for tests. */
  sleep?: (ms: number) => Promise<void>;
}

export class StubHubError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: ApiErrorBody | string | null,
  ) {
    super(message);
    this.name = 'StubHubError';
  }
}

export class UpstreamWriteForbiddenError extends Error {
  constructor(readonly endpoint: string) {
    super(
      `stubhub: "${endpoint}" writes to StubHub. Upstream writes are forbidden ` +
        'without explicit operator authorization (CLAUDE.md Hard Rule #2).',
    );
    this.name = 'UpstreamWriteForbiddenError';
  }
}

const RETRYABLE = new Set([429, 502, 503, 504]);

export function toQueryString(query: Record<string, QueryValue> = {}): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === '') continue;
    params.set(k, v instanceof Date ? v.toISOString() : String(v));
  }
  const s = params.toString();
  return s ? `?${s}` : '';
}

/** Retry-After is seconds or an HTTP date; fall back to exponential backoff. */
function retryDelayMs(res: Response, attempt: number): number {
  const header = res.headers.get('retry-after');
  if (header) {
    const secs = Number(header);
    if (Number.isFinite(secs)) return Math.min(secs * 1000, 60_000);
    const at = Date.parse(header);
    if (Number.isFinite(at)) return Math.max(0, Math.min(at - Date.now(), 60_000));
  }
  return 500 * 2 ** attempt;
}

export class StubHubClient {
  private readonly baseUrl: string;
  private readonly accessToken: TokenSource;
  private readonly fetchImpl: FetchLike;
  private readonly maxRetries: number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(opts: StubHubClientOptions) {
    if (!opts.baseUrl) throw new Error('stubhub: baseUrl is required');
    this.baseUrl = opts.baseUrl.replace(/\/+$/, '');
    this.accessToken = opts.accessToken;
    this.fetchImpl = opts.fetch ?? ((input, init) => fetch(input, init));
    this.maxRetries = opts.maxRetries ?? 2;
    this.sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  // ── Transport ──────────────────────────────────────────────────────

  private async send(
    name: EndpointName,
    opts: { path?: Record<string, string | number>; query?: Record<string, QueryValue>; body?: unknown } = {},
  ): Promise<Response> {
    const ep = STUBHUB_ENDPOINTS[name];
    if (ep.access === 'write') throw new UpstreamWriteForbiddenError(name);

    const url = this.baseUrl + buildPath(ep.path, opts.path) + toQueryString(opts.query);
    const hasBody = opts.body !== undefined;

    for (let attempt = 0; ; attempt++) {
      const token = await this.accessToken();
      const res = await this.fetchImpl(url, {
        method: ep.method,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/hal+json, application/json',
          ...(hasBody ? { 'Content-Type': 'application/json' } : {}),
        },
        body: hasBody ? JSON.stringify(opts.body) : undefined,
      });
      if (res.ok) return res;
      if (RETRYABLE.has(res.status) && attempt < this.maxRetries) {
        await this.sleep(retryDelayMs(res, attempt));
        continue;
      }
      const text = await res.text();
      let body: ApiErrorBody | string | null = text || null;
      try {
        body = text ? (JSON.parse(text) as ApiErrorBody) : null;
      } catch {
        // non-JSON error body; keep the raw text
      }
      const detail = typeof body === 'object' && body?.message ? `: ${body.message}` : '';
      throw new StubHubError(`stubhub ${ep.method} ${ep.path} -> ${res.status}${detail}`, res.status, body);
    }
  }

  private async json<T>(name: EndpointName, opts?: Parameters<StubHubClient['send']>[1]): Promise<T> {
    const res = await this.send(name, opts);
    return (await res.json()) as T;
  }

  private async bytes(name: EndpointName, opts?: Parameters<StubHubClient['send']>[1]): Promise<ArrayBuffer> {
    const res = await this.send(name, opts);
    return res.arrayBuffer();
  }

  // ── Catalog ────────────────────────────────────────────────────────

  listEvents(query: EventFilterQuery = {}) {
    return this.json<Page<CatalogEvent>>('listEvents', { query: { ...query } });
  }

  searchEvents(query: EventSearchQuery) {
    return this.json<Page<CatalogEvent>>('searchEvents', { query: { ...query } });
  }

  /**
   * Batch get. A merged event comes back under its surviving id; `_embedded`
   * also carries an old-id → new-id mapping.
   */
  getEventsByIds(eventIds: number[], query: CatalogPageQuery = {}) {
    return this.json<Page<CatalogEvent>>('getEventsByIds', { query: { ...query }, body: { event_ids: eventIds } });
  }

  /** A returned `id` different from the one asked for means the event was merged. */
  getEvent(eventId: number) {
    return this.json<CatalogEvent>('getEvent', { path: { eventId } });
  }

  /** `platform` is documented as e.g. `legacy_stubhub`. */
  getEventByExternalId(platform: string, externalEventId: number | string) {
    return this.json<CatalogEvent>('getEventByExternalId', { path: { platform, externalEventId } });
  }

  searchCategories(q: string) {
    return this.json<unknown>('searchCategories', { query: { q } });
  }

  listCategoryEvents(categoryId: number, query: CatalogPageQuery = {}) {
    return this.json<Page<CatalogEvent>>('listCategoryEvents', { path: { categoryId }, query: { ...query } });
  }

  /** Events in the category and every descendant category, de-duped by StubHub. */
  listAllCategoryEvents(categoryId: number, query: CatalogPageQuery = {}) {
    return this.json<Page<CatalogEvent>>('listAllCategoryEvents', { path: { categoryId }, query: { ...query } });
  }

  /** Best-effort match of an event we know by name/date/venue to StubHub's catalog. */
  mapEvent(req: MapEventRequest) {
    const local_date = req.local_date instanceof Date ? req.local_date.toISOString() : req.local_date;
    return this.json<MapEventResult>('mapEvent', { body: { ...req, local_date } });
  }

  listVenues(query: VenueQuery = {}) {
    return this.json<Page<Venue>>('listVenues', { query: { ...query } });
  }

  getVenue(venueId: number) {
    return this.json<Venue>('getVenue', { path: { venueId } });
  }

  // ── Inventory (our own listings; read + preview only) ─────────────

  listSellerListings(query: SellerListingQuery = {}) {
    return this.json<Page<SellerListing>>('listSellerListings', { query: { ...query } });
  }

  listSellerListingUpdates(updatedSince: Date | string) {
    return this.json<Page<SellerListing>>('listSellerListingUpdates', { query: { updated_since: updatedSince } });
  }

  getSellerListing(listingId: number) {
    return this.json<SellerListing>('getSellerListing', { path: { listingId } });
  }

  /** Look up by the id we assigned (`external_id`). */
  getSellerListingByExternalId(externalId: string) {
    return this.json<SellerListing>('getSellerListingByExternalId', { path: { externalId } });
  }

  /** Quote fees/proceeds for a listing. StubHub creates nothing. */
  previewSellerListing(eventId: number, draft: SellerListingDraft) {
    return this.json<SellerListing>('previewSellerListing', { path: { eventId }, body: serializeDraft(draft) });
  }

  /** Quote an update to a listing. StubHub applies nothing. */
  previewSellerListingUpdate(listingId: number, draft: SellerListingDraft) {
    return this.json<SellerListing>('previewSellerListingUpdate', { path: { listingId }, body: serializeDraft(draft) });
  }

  listEventListingConstraints(eventId: number) {
    return this.json<unknown>('listEventListingConstraints', { path: { eventId } });
  }

  getSellerListingConstraints(listingId: number) {
    return this.json<unknown>('getSellerListingConstraints', { path: { listingId } });
  }

  listSellerEvents(query: Omit<SellerListingQuery, 'event_id' | 'requested_event_id'> = {}) {
    return this.json<Page<SellerEvent>>('listSellerEvents', { query: { ...query } });
  }

  getSellerEvent(eventIdOrRequestedEventId: number | string) {
    return this.json<SellerEvent>('getSellerEvent', { path: { eventIdOrRequestedEventId } });
  }

  // ── Sales + payouts ────────────────────────────────────────────────

  listSales(query: SaleQuery = {}) {
    return this.json<Page<Sale>>('listSales', { query: { ...query } });
  }

  listSaleUpdates(updatedSince: Date | string) {
    return this.json<Page<Sale>>('listSaleUpdates', { query: { updated_since: updatedSince } });
  }

  getSale(saleId: number) {
    return this.json<Sale>('getSale', { path: { saleId } });
  }

  listSaleTicketHolders(saleId: number) {
    return this.json<unknown>('listSaleTicketHolders', { path: { saleId } });
  }

  /** Documented as `application/octet-stream`, so returned raw. */
  listPaymentsRaw() {
    return this.bytes('listPayments');
  }

  getPayment(paymentId: number) {
    return this.json<Payment>('getPayment', { path: { paymentId } });
  }

  /** Preview of the next payout; no `id`, subject to change. */
  getNextPayment() {
    return this.json<Payment>('getNextPayment');
  }

  getETicketDocument(eticketId: number) {
    return this.bytes('getETicketDocument', { path: { eticketId } });
  }

  // ── Account + webhook config (reads) ───────────────────────────────

  getUser() {
    return this.json<StubHubUser>('getUser');
  }

  listWebhooks() {
    return this.json<Page<Webhook>>('listWebhooks');
  }

  getWebhook(webhookId: number) {
    return this.json<Webhook>('getWebhook', { path: { webhookId } });
  }

  // ── Pagination ─────────────────────────────────────────────────────

  /**
   * Walks a paged list from `page` 1 until StubHub stops sending a `next`
   * link (or an empty page / `maxPages` as backstops).
   *
   *   for await (const sale of client.paginate((page) => client.listSales({ page, page_size: 200 }))) …
   */
  async *paginate<T>(fetchPage: (page: number) => Promise<Page<T>>, opts: { maxPages?: number } = {}): AsyncGenerator<T> {
    const maxPages = opts.maxPages ?? 1000;
    for (let page = 1; page <= maxPages; page++) {
      const res = await fetchPage(page);
      const items = res._embedded?.items ?? [];
      for (const item of items) yield item;
      if (items.length === 0 || !res._links?.next) return;
    }
  }
}

function serializeDraft(draft: SellerListingDraft): Record<string, unknown> {
  const { in_hand_at, ...rest } = draft;
  return in_hand_at === undefined
    ? rest
    : { ...rest, in_hand_at: in_hand_at instanceof Date ? in_hand_at.toISOString() : in_hand_at };
}

// ── OAuth2 client-credentials token provider ─────────────────────────

export interface ClientCredentialsOptions {
  tokenUrl: string;
  clientId: string;
  clientSecret: string;
  scope?: string;
  fetch?: FetchLike;
  now?: () => number;
}

/**
 * Returns an `accessToken` source that fetches with the client-credentials
 * grant and caches until 60s before expiry. Concurrent callers share one
 * in-flight request.
 */
export function clientCredentialsToken(opts: ClientCredentialsOptions): TokenSource {
  const fetchImpl: FetchLike = opts.fetch ?? ((input, init) => fetch(input, init));
  const now = opts.now ?? Date.now;
  let cached: { token: string; expiresAt: number } | null = null;
  let inflight: Promise<string> | null = null;

  const refresh = async (): Promise<string> => {
    const form = new URLSearchParams({ grant_type: 'client_credentials' });
    if (opts.scope) form.set('scope', opts.scope);
    const basic = btoa(`${opts.clientId}:${opts.clientSecret}`);
    const res = await fetchImpl(opts.tokenUrl, {
      method: 'POST',
      headers: { Authorization: `Basic ${basic}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
    if (!res.ok) throw new StubHubError(`stubhub token -> ${res.status}`, res.status, await res.text());
    const data = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!data.access_token) throw new StubHubError('stubhub token: no access_token in response', res.status, null);
    const ttlMs = (data.expires_in ?? 3600) * 1000;
    cached = { token: data.access_token, expiresAt: now() + ttlMs - 60_000 };
    return data.access_token;
  };

  return () => {
    if (cached && now() < cached.expiresAt) return cached.token;
    if (!inflight) inflight = refresh().finally(() => { inflight = null; });
    return inflight;
  };
}
