// StubHub writer: the foundation for listing creation and sale fulfilment.
//
// NOT LIVE. CLAUDE.md Hard Rule #2 still holds: nothing in Exos sends a
// write to StubHub today. This class exists so the write path is built,
// typed and tested before it's needed, and so switching it on is a single,
// reviewable decision instead of new code.
//
// Two modes:
//   dry-run (default)  Every method returns the exact request it *would*
//                      send ({ method, url, body }) and never calls fetch.
//                      Safe to run anywhere, with or without credentials.
//   live               Sends the request. Requires a WriteAuthorization
//                      naming the operator, when they approved, where the
//                      approval is recorded, and which endpoints it covers.
//                      An endpoint outside that list is refused.
//
// Retries: writes retry only on 429 (StubHub didn't process the request).
// A 5xx or network error on a create is ambiguous, so it is never retried
// blindly; `createOrAdoptListing` resolves it on the next run by looking the
// listing up by `external_id` first.

import type { StubHubClient } from './client';
import { StubHubError } from './client';
import { STUBHUB_ENDPOINTS, type EndpointName } from './endpoints';
import {
  RETRY_THROTTLED,
  execute,
  relativeUrl,
  transportConfig,
  type FetchLike,
  type RequestParts,
  type TokenSource,
  type TransportConfig,
} from './transport';
import type { CreateSellerListingRequest, UpdateSellerListingRequest } from './listing';
import {
  attachETicketsRequest,
  confirmSaleRequest,
  eticketUrlsRequest,
  mobileTransferRequest,
  type MobileTransferProvider,
  type UpdateSaleRequest,
} from './fulfilment';
import type { Sale, SellerListing } from './types';

type WriteEndpoints = {
  [K in EndpointName]: (typeof STUBHUB_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type WriteEndpointName = WriteEndpoints;

/** Build order for the write side: listing creation first, then sales. */
export const STUBHUB_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly WriteEndpointName[] }> = [
  {
    phase: '1. Listing creation',
    endpoints: ['createSellerListing'],
  },
  {
    phase: '2. Listing management (price/qty sync, delist)',
    endpoints: ['updateSellerListingByExternalId', 'deleteSellerListingByExternalId'],
  },
  {
    phase: '3. Sale fulfilment (confirm + e-ticket URLs)',
    endpoints: ['updateSale', 'rejectSale'],
  },
  {
    phase: '4. E-ticket PDF delivery (fallback)',
    endpoints: ['uploadSaleETickets', 'saveSaleETickets', 'deleteSaleETicket'],
  },
  {
    phase: '5. Webhook registration',
    endpoints: ['createWebhook', 'updateWebhook', 'deleteWebhook', 'pingWebhook'],
  },
];

export interface WriteAuthorization {
  /** Operator who approved (Hard Rule #2 / charter §6.1 carve-out). */
  approvedBy: string;
  /** ISO timestamp of the approval. */
  approvedAt: string;
  /** Where the approval is recorded (PR, doc, ticket). */
  reference: string;
  /** Exactly which write endpoints are approved. */
  endpoints: readonly WriteEndpointName[];
}

export type WriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: WriteAuthorization };

export interface PlannedWrite {
  endpoint: WriteEndpointName;
  method: string;
  /** Relative to the API host. */
  url: string;
  body?: unknown;
}

export type WriteResult<T> =
  | { dryRun: true; planned: PlannedWrite }
  | { dryRun: false; planned: PlannedWrite; response: T };

export class WriteNotAuthorizedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`stubhub write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'WriteNotAuthorizedError';
  }
}

export interface StubHubWriterOptions {
  /** Default dry-run. */
  mode?: WriterMode;
  /** Needed for live mode only. */
  baseUrl?: string;
  accessToken?: TokenSource;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
  /** Read client for idempotency lookups (createOrAdoptListing). */
  reader?: StubHubClient;
  /** Called with every planned write, dry-run or live (audit log hook). */
  onPlan?: (p: PlannedWrite) => void;
}

function validateAuthorization(auth: WriteAuthorization): string | null {
  if (!auth.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!auth.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(auth.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!auth.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of auth.endpoints) {
    if (STUBHUB_ENDPOINTS[e]?.access !== 'write') return `"${e}" is not a write endpoint`;
  }
  return null;
}

export class StubHubWriter {
  private readonly mode: WriterMode;
  private readonly cfg: TransportConfig | null;
  private readonly reader?: StubHubClient;
  private readonly onPlan?: (p: PlannedWrite) => void;

  constructor(opts: StubHubWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    this.reader = opts.reader;
    this.onPlan = opts.onPlan;
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new WriteNotAuthorizedError('*', bad);
      if (!opts.baseUrl || !opts.accessToken) {
        throw new Error('stubhub writer: live mode needs baseUrl and accessToken');
      }
      this.cfg = transportConfig({ ...opts, baseUrl: opts.baseUrl, accessToken: opts.accessToken });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private async write<T>(endpoint: WriteEndpointName, parts: RequestParts = {}): Promise<WriteResult<T>> {
    const ep = STUBHUB_ENDPOINTS[endpoint];
    const planned: PlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    if (parts.body !== undefined) planned.body = parts.body;
    this.onPlan?.(planned);

    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };

    if (!this.mode.authorization.endpoints.includes(endpoint)) {
      throw new WriteNotAuthorizedError(endpoint, 'not in the authorization scope');
    }
    const res = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    const text = res.status === 204 ? '' : await res.text();
    return { dryRun: false, planned, response: (text ? JSON.parse(text) : null) as T };
  }

  // ── 1. Listing creation ────────────────────────────────────────────

  createSellerListing(eventId: number, req: CreateSellerListingRequest) {
    return this.write<SellerListing>('createSellerListing', { path: { eventId }, body: req });
  }

  /**
   * Idempotent create keyed on `external_id` (our distribution row id): if
   * StubHub already has a listing with that id (e.g. a previous run's create
   * succeeded but the response was lost), adopt it instead of creating a
   * duplicate. Without a `reader`, behaves like createSellerListing.
   */
  async createOrAdoptListing(
    eventId: number,
    req: CreateSellerListingRequest,
  ): Promise<WriteResult<SellerListing> | { adopted: true; listing: SellerListing }> {
    if (this.reader) {
      try {
        const existing = await this.reader.getSellerListingByExternalId(req.external_id);
        return { adopted: true, listing: existing };
      } catch (e) {
        if (!(e instanceof StubHubError && e.status === 404)) throw e;
      }
    }
    return this.createSellerListing(eventId, req);
  }

  // ── 2. Listing management ──────────────────────────────────────────

  updateListing(externalId: string, req: UpdateSellerListingRequest) {
    return this.write<SellerListing>('updateSellerListingByExternalId', { path: { externalId }, body: req });
  }

  delistListing(externalId: string) {
    return this.write<null>('deleteSellerListingByExternalId', { path: { externalId } });
  }

  // ── 3. Sale fulfilment ─────────────────────────────────────────────

  updateSale(saleId: number, req: UpdateSaleRequest) {
    return this.write<Sale>('updateSale', { path: { saleId }, body: req });
  }

  confirmSale(saleId: number) {
    return this.updateSale(saleId, confirmSaleRequest());
  }

  reportMobileTransfer(saleId: number, provider: MobileTransferProvider, confirmationNumber: string) {
    return this.updateSale(saleId, mobileTransferRequest(provider, confirmationNumber));
  }

  /** Exos default delivery: one claim URL per ticket (see fulfilment.ts). */
  deliverETicketUrls(saleId: number, urls: string[], ticketCount: number) {
    return this.updateSale(saleId, eticketUrlsRequest(urls, ticketCount));
  }

  attachETickets(saleId: number, eticketIds: number[]) {
    return this.updateSale(saleId, attachETicketsRequest(eticketIds));
  }

  /** Report a problem with the sale. Irreversible on StubHub's side. */
  rejectSale(saleId: number) {
    return this.write<null>('rejectSale', { path: { saleId } });
  }
}
