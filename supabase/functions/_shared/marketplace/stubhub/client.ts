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
// What it deliberately doesn't: any `write`. `send()` refuses an endpoint
// tagged `write` before a byte leaves the process (CLAUDE.md Hard Rule #2).
// Writes live in writer.ts, which is dry-run unless the operator authorizes
// them.
//
// Hosts and auth are from StubHub's OpenAPI specs + guides
// (docs/marketplace/stubhub/openapi/): pass `environment: 'production' |
// 'sandbox'`. Two token flows matter:
//   • clientCredentialsToken(): application-only; PUBLIC data only (catalog).
//   • refreshTokenSource(): user-login tokens, needed for anything seller-
//     side (listings, sales, payments, webhooks). StubHub's refresh tokens
//     are single-use, so each refresh persists the new one.

import { STUBHUB_ENDPOINTS, type EndpointName } from './endpoints.ts';
import {
  DEFAULT_USER_AGENT,
  RETRY_TRANSIENT,
  StubHubError,
  execute,
  transportConfig,
  type FetchLike,
  type HostOptions,
  type RequestParts,
  type TokenSource,
  type TransportConfig,
} from './transport.ts';
import type {
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
} from './types.ts';
import type { ListingConstraints, RequestedEvent } from './listing.ts';

export { StubHubError, STUBHUB_ENVIRONMENTS, toQueryString, type StubHubEnvironment } from './transport.ts';

export interface StubHubClientOptions extends HostOptions {
  /** Returns a current OAuth2 access token. */
  accessToken: TokenSource;
  fetch?: FetchLike;
  /** Retries on 429/502/503/504 (all our calls are side-effect free). Default 2. */
  maxRetries?: number;
  /** Injectable for tests. */
  sleep?: (ms: number) => Promise<void>;
}

export class UpstreamWriteForbiddenError extends Error {
  constructor(readonly endpoint: string) {
    super(
      `stubhub: "${endpoint}" writes to StubHub. The read client never sends writes; ` +
        'use StubHubWriter, which is dry-run unless the operator has authorized it (CLAUDE.md Hard Rule #2).',
    );
    this.name = 'UpstreamWriteForbiddenError';
  }
}

export class StubHubClient {
  private readonly cfg: TransportConfig;

  constructor(opts: StubHubClientOptions) {
    this.cfg = transportConfig(opts);
  }

  // ── Transport ──────────────────────────────────────────────────────

  private async send(name: EndpointName, parts: RequestParts = {}): Promise<Response> {
    const ep = STUBHUB_ENDPOINTS[name];
    if (ep.access === 'write') throw new UpstreamWriteForbiddenError(name);
    return execute(this.cfg, ep, parts, RETRY_TRANSIENT);
  }

  private async json<T>(name: EndpointName, parts?: RequestParts): Promise<T> {
    const res = await this.send(name, parts);
    return (await res.json()) as T;
  }

  private async bytes(name: EndpointName, parts?: RequestParts): Promise<ArrayBuffer> {
    const res = await this.send(name, parts);
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

  /** The spec declares this response as octet-stream; parse JSON when it is JSON. */
  async searchCategories(q: string): Promise<unknown> {
    const text = await (await this.send('searchCategories', { query: { q } })).text();
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
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
    return this.json<ListingConstraints>('listEventListingConstraints', { path: { eventId } });
  }

  getSellerListingConstraints(listingId: number) {
    return this.json<ListingConstraints>('getSellerListingConstraints', { path: { listingId } });
  }

  /** Constraints (incl. accepted ticket types) for an event StubHub may not have yet. Changes nothing. */
  getRequestedEventListingConstraints(req: RequestedEvent) {
    return this.json<ListingConstraints>('getRequestedEventListingConstraints', { body: req });
  }

  /** Quote a requested-event listing. StubHub creates nothing. */
  previewSellerListingForRequestedEvent(draft: SellerListingDraft & RequestedEvent) {
    return this.json<SellerListing>('previewSellerListingForRequestedEvent', { body: serializeDraft(draft) });
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

  /** Shape not pinned down in the docs; pass the result to buyerEmail(). */
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

// ── OAuth2 token sources ─────────────────────────────────────────────

/** Scopes from authentication/scopes.md. */
export const STUBHUB_SCOPES = [
  'read:events',
  'read:payment',
  'read:sales',
  'write:sales',
  'read:sellerlistings',
  'write:sellerlistings',
  'read:webhooks',
  'write:webhooks',
  'write:requestedevents',
] as const;
export type StubHubScope = (typeof STUBHUB_SCOPES)[number];

interface TokenEndpointOptions {
  tokenUrl: string;
  clientId: string;
  clientSecret: string;
  scopes?: readonly StubHubScope[];
  userAgent?: string;
  fetch?: FetchLike;
  now?: () => number;
}

interface TokenResponse {
  access_token?: string;
  expires_in?: number;
  refresh_token?: string;
}

/** Basic auth per the docs: URL-encode id and secret (RFC 1738), then base64. */
export function basicAuthHeader(clientId: string, clientSecret: string): string {
  return `Basic ${btoa(`${encodeURIComponent(clientId)}:${encodeURIComponent(clientSecret)}`)}`;
}

async function requestToken(opts: TokenEndpointOptions, form: URLSearchParams): Promise<TokenResponse & { access_token: string }> {
  const fetchImpl: FetchLike = opts.fetch ?? ((input, init) => fetch(input, init));
  if (opts.scopes?.length) form.set('scope', opts.scopes.join(' '));
  const res = await fetchImpl(opts.tokenUrl, {
    method: 'POST',
    headers: {
      Authorization: basicAuthHeader(opts.clientId, opts.clientSecret),
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': opts.userAgent ?? DEFAULT_USER_AGENT,
    },
    body: form.toString(),
  });
  if (!res.ok) throw new StubHubError(`stubhub token -> ${res.status}`, res.status, await res.text());
  const data = (await res.json()) as TokenResponse;
  if (!data.access_token) throw new StubHubError('stubhub token: no access_token in response', res.status, null);
  return data as TokenResponse & { access_token: string };
}

/** Caches a token until 60s before expiry; concurrent callers share one fetch. */
function cachedSource(now: () => number, fetchToken: () => Promise<TokenResponse & { access_token: string }>): TokenSource {
  let cached: { token: string; expiresAt: number } | null = null;
  let inflight: Promise<string> | null = null;
  return () => {
    if (cached && now() < cached.expiresAt) return cached.token;
    if (!inflight) {
      inflight = fetchToken()
        .then((data) => {
          cached = { token: data.access_token, expiresAt: now() + (data.expires_in ?? 3600) * 1000 - 60_000 };
          return data.access_token;
        })
        .finally(() => {
          inflight = null;
        });
    }
    return inflight;
  };
}

export type ClientCredentialsOptions = TokenEndpointOptions;

/**
 * Application-only flow (client credentials). Public data only: catalog
 * events and venues. No refresh token is issued; we just fetch a new one.
 */
export function clientCredentialsToken(opts: ClientCredentialsOptions): TokenSource {
  return cachedSource(opts.now ?? Date.now, () =>
    requestToken(opts, new URLSearchParams({ grant_type: 'client_credentials' })),
  );
}

export interface RefreshTokenOptions extends TokenEndpointOptions {
  /** Current refresh token (from the one-time user-login authorization). */
  loadRefreshToken: () => string | Promise<string>;
  /** StubHub refresh tokens are single-use: persist the rotated one. */
  saveRefreshToken: (token: string) => void | Promise<void>;
}

/**
 * User-login flow. Seller data (listings, sales, payments, webhooks) needs a
 * user token; after the one-time authorization-code exchange, keep it fresh
 * with the refresh-token grant. The new refresh token is saved *before* the
 * access token is handed out, so a crash can't strand us on a spent token.
 */
export function refreshTokenSource(opts: RefreshTokenOptions): TokenSource {
  return cachedSource(opts.now ?? Date.now, async () => {
    const refresh = await opts.loadRefreshToken();
    if (!refresh) throw new StubHubError('stubhub token: no refresh token stored', 0, null);
    const data = await requestToken(opts, new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refresh }));
    if (!data.refresh_token) {
      throw new StubHubError('stubhub token: refresh response had no refresh_token (single-use; cannot continue)', 0, null);
    }
    await opts.saveRefreshToken(data.refresh_token);
    return data;
  });
}
