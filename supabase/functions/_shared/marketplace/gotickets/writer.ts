// GoTickets writer: listings, sales and webhooks, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to GoTickets
// today. Same design as the other writers: dry-run by default (returns what
// it would send, never calls fetch); live needs a WriteAuthorization naming
// the operator, when, where it's recorded, and exactly which endpoints.
//
// Always refused, whatever the authorization: the `forbidden` endpoints
// (inventory snapshot, delete by event, anything by GoTickets' internal
// listing id), and any listing whose externalTicketId isn't an Exos listing
// id, or that carries a GoTickets id. The seller account can carry broker
// listings; Exos only ever touches its own.

import { GOTICKETS_ENDPOINTS, type EndpointName } from './endpoints.ts';
import { RETRY_THROTTLED, execute, relativeUrl, transportConfig, type FetchLike, type GoTicketsCredentials, type RequestParts, type TransportConfig } from './transport.ts';
import { isExosListingId } from '../listingIds.ts';
import type { GoTicketsFulfillment, GoTicketsListing, GoTicketsMutateListingResponse, GoTicketsWebhookType } from './types.ts';

type WriteEndpoints = {
  [K in EndpointName]: (typeof GOTICKETS_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type GoTicketsWriteEndpoint = WriteEndpoints;

export const GOTICKETS_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly GoTicketsWriteEndpoint[] }> = [
  { phase: '1. Listings by external id (create, update, delete)', endpoints: ['createListings', 'updateListingByExternalId', 'deleteListingsByExternalIds'] },
  { phase: '2. Sales: confirm, then fulfil with the claim links', endpoints: ['confirmSale', 'fulfillSale', 'rejectSale'] },
  { phase: '3. Webhooks (SALE, ORDER_CANCELLED) to exos-marketplace-sales', endpoints: ['createWebhook'] },
];

export interface GoTicketsWriteAuthorization {
  approvedBy: string;
  approvedAt: string;
  reference: string;
  endpoints: readonly GoTicketsWriteEndpoint[];
}

export type GoTicketsWriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: GoTicketsWriteAuthorization };

export interface GoTicketsPlannedWrite {
  endpoint: GoTicketsWriteEndpoint;
  method: string;
  url: string;
  body?: unknown;
}

export type GoTicketsWriteResult<T> =
  | { dryRun: true; planned: GoTicketsPlannedWrite }
  | { dryRun: false; planned: GoTicketsPlannedWrite; response: T };

export class GoTicketsWriteRefusedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`gotickets write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'GoTicketsWriteRefusedError';
  }
}

export interface GoTicketsWriterOptions {
  mode?: GoTicketsWriterMode;
  credentials?: () => GoTicketsCredentials | Promise<GoTicketsCredentials>;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

function validateAuthorization(a: GoTicketsWriteAuthorization): string | null {
  if (!a.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!a.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(a.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!a.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of a.endpoints) {
    if ((GOTICKETS_ENDPOINTS as Record<string, { access: string }>)[e]?.access !== 'write') return `"${e}" is not an allowed write endpoint`;
  }
  return null;
}

export class GoTicketsWriter {
  private readonly mode: GoTicketsWriterMode;
  private readonly cfg: TransportConfig | null;

  constructor(opts: GoTicketsWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new GoTicketsWriteRefusedError('*', bad);
      if (!opts.credentials) throw new Error('gotickets writer: live mode needs credentials');
      this.cfg = transportConfig({ ...opts, credentials: opts.credentials });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private async write<T>(endpoint: GoTicketsWriteEndpoint, parts: RequestParts = {}): Promise<GoTicketsWriteResult<T>> {
    const ep = GOTICKETS_ENDPOINTS[endpoint];
    if (ep.access !== 'write') throw new GoTicketsWriteRefusedError(endpoint, 'not a write endpoint');
    const planned: GoTicketsPlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    if (parts.body !== undefined) planned.body = parts.body;
    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };
    if (!this.mode.authorization.endpoints.includes(endpoint)) throw new GoTicketsWriteRefusedError(endpoint, 'not in the authorization scope');
    const res = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    const text = await res.text();
    let response: unknown = null;
    if (text) {
      try {
        response = JSON.parse(text);
      } catch {
        response = text;
      }
    }
    return { dryRun: false, planned, response: response as T };
  }

  private assertOwn(l: GoTicketsListing, endpoint: string) {
    if (l.id != null) throw new GoTicketsWriteRefusedError(endpoint, 'Exos addresses listings by externalTicketId only, never by GoTickets id');
    this.assertExos(l.externalTicketId, endpoint);
  }

  private assertExos(id: string, endpoint: string) {
    if (!isExosListingId(id)) throw new GoTicketsWriteRefusedError(endpoint, `"${id}" is not an Exos listing id (the account may carry broker listings)`);
  }

  /** POST /rest/listings: up to 100. */
  createListings(listings: GoTicketsListing[]) {
    if (!listings.length || listings.length > 100) throw new GoTicketsWriteRefusedError('createListings', '1 to 100 listings per request');
    for (const l of listings) this.assertOwn(l, 'createListings');
    return this.write<GoTicketsMutateListingResponse>('createListings', { body: listings });
  }

  /** PUT /rest/listings/external-id/{id}: the whole listing (no partial updates). */
  updateListing(listing: GoTicketsListing) {
    this.assertOwn(listing, 'updateListingByExternalId');
    return this.write<unknown>('updateListingByExternalId', { path: { externalId: listing.externalTicketId }, body: listing });
  }

  /** DELETE /rest/listings/external-id with the ids (max 100; missing ones fail silently). */
  deleteListings(externalIds: string[]) {
    if (!externalIds.length || externalIds.length > 100) throw new GoTicketsWriteRefusedError('deleteListingsByExternalIds', '1 to 100 ids per request');
    for (const id of externalIds) this.assertExos(id, 'deleteListingsByExternalIds');
    return this.write<unknown>('deleteListingsByExternalIds', { body: externalIds });
  }

  confirmSale(orderId: string | number) {
    return this.write<unknown>('confirmSale', { path: { orderId } });
  }

  rejectSale(orderId: string | number) {
    return this.write<unknown>('rejectSale', { path: { orderId } });
  }

  /** POST /fulfill with one Exos claim link per ticket. */
  fulfilWithTransferUrls(orderId: string | number, body: GoTicketsFulfillment) {
    return this.write<unknown>('fulfillSale', { path: { orderId }, body });
  }

  /** POST /rest/webhooks (max 3 per type). The target carries our token in its query string. */
  createWebhook(webhookType: GoTicketsWebhookType, targetUrl: string) {
    if (!/^https:\/\//.test(targetUrl)) throw new GoTicketsWriteRefusedError('createWebhook', 'the target must be https');
    return this.write<unknown>('createWebhook', { body: { webhookType, targetUrl, active: true } });
  }
}
