// SeatGeek writer: listings and order fulfilment, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to SeatGeek
// today. Same design as the StubHub writer:
//   dry-run (default)  every method returns the request it would send and
//                      never calls fetch.
//   live               sends it; needs a WriteAuthorization naming the
//                      operator, when, where it's recorded, and exactly which
//                      endpoints. Anything else is refused.
//
// Always refused, whatever the authorization: the `forbidden` endpoints
// (CSV inventory sync, purge), which act on the whole seller account, broker
// listings included. And a delete is refused for any seller_listing_id that
// isn't an Exos one (exosSellerListingId), for the same reason.
//
// Writes retry only on 429: a 5xx on a create is ambiguous, and a listing
// PUT is keyed on our seller_listing_id, so the next run repeats it safely.

import { SEATGEEK_ENDPOINTS, type EndpointName } from './endpoints.ts';
import {
  RETRY_THROTTLED,
  execute,
  relativeUrl,
  transportConfig,
  type FetchLike,
  type FormFields,
  type RequestParts,
  type AuthScheme,
  type TokenSource,
  type TransportConfig,
} from './transport.ts';
import { confirmOrderForm, denyOrderForm, transferFulfilmentForm, SeatGeekFulfilmentError, type TransferFulfilment } from './fulfilment.ts';
import { isExosSellerListingId } from './listingPlan.ts';
import type { SeatGeekListing, SeatGeekOrder } from './types.ts';

type WriteEndpoints = {
  [K in EndpointName]: (typeof SEATGEEK_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type SeatGeekWriteEndpoint = WriteEndpoints;

/** Build order for the write side. */
export const SEATGEEK_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly SeatGeekWriteEndpoint[] }> = [
  { phase: '1. Listing creation (one listing per max-per-order group)', endpoints: ['createListing'] },
  { phase: '2. Listing management (price/qty sync, delist)', endpoints: ['updateListing', 'bulkDeleteListings'] },
  { phase: '3. Order confirm + fulfil (transfer URLs)', endpoints: ['updateOrder'] },
];

export interface SeatGeekWriteAuthorization {
  approvedBy: string;
  approvedAt: string;
  reference: string;
  endpoints: readonly SeatGeekWriteEndpoint[];
}

export type SeatGeekWriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: SeatGeekWriteAuthorization };

export interface SeatGeekPlannedWrite {
  endpoint: SeatGeekWriteEndpoint;
  method: string;
  /** Relative to the API host. */
  url: string;
  body?: unknown;
  form?: FormFields;
}

export type SeatGeekWriteResult<T> =
  | { dryRun: true; planned: SeatGeekPlannedWrite }
  | { dryRun: false; planned: SeatGeekPlannedWrite; response: T };

export class SeatGeekWriteRefusedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`seatgeek write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'SeatGeekWriteRefusedError';
  }
}

export interface SeatGeekWriterOptions {
  mode?: SeatGeekWriterMode;
  token?: TokenSource;
  authScheme?: AuthScheme;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
  onPlan?: (p: SeatGeekPlannedWrite) => void;
}

function validateAuthorization(a: SeatGeekWriteAuthorization): string | null {
  if (!a.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!a.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(a.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!a.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of a.endpoints) {
    const access = (SEATGEEK_ENDPOINTS as Record<string, { access: string }>)[e]?.access;
    if (access !== 'write') return `"${e}" is not an allowed write endpoint`;
  }
  return null;
}

export class SeatGeekWriter {
  private readonly mode: SeatGeekWriterMode;
  private readonly cfg: TransportConfig | null;
  private readonly onPlan?: (p: SeatGeekPlannedWrite) => void;

  constructor(opts: SeatGeekWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    this.onPlan = opts.onPlan;
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new SeatGeekWriteRefusedError('*', bad);
      if (!opts.token) throw new Error('seatgeek writer: live mode needs a token');
      this.cfg = transportConfig({ ...opts, token: opts.token });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private async write<T>(endpoint: SeatGeekWriteEndpoint, parts: RequestParts = {}): Promise<SeatGeekWriteResult<T>> {
    const ep = SEATGEEK_ENDPOINTS[endpoint];
    if (ep.access !== 'write') throw new SeatGeekWriteRefusedError(endpoint, 'not a write endpoint');
    const planned: SeatGeekPlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    if (parts.body !== undefined) planned.body = parts.body;
    if (parts.form) planned.form = parts.form;
    this.onPlan?.(planned);
    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };
    if (!this.mode.authorization.endpoints.includes(endpoint)) {
      throw new SeatGeekWriteRefusedError(endpoint, 'not in the authorization scope');
    }
    const res = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    const text = res.status === 204 ? '' : await res.text();
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

  // ── 1. Listing creation ────────────────────────────────────────────

  /** PUT /listings/single/{id}: create, keyed on our seller_listing_id. */
  createListing(listing: SeatGeekListing & { seller_listing_id: string }) {
    this.assertExos(listing.seller_listing_id, 'createListing');
    return this.write<unknown>('createListing', { path: { sellerListingId: listing.seller_listing_id }, body: listing });
  }

  // ── 2. Listing management ──────────────────────────────────────────

  updateListing(sellerListingId: string, patch: Partial<SeatGeekListing>) {
    this.assertExos(sellerListingId, 'updateListing');
    return this.write<unknown>('updateListing', { path: { sellerListingId }, body: patch });
  }

  /**
   * POST /listings/bulk-delete (the guide's recommended route; DELETE
   * /listings is deprecated). Marks the listings inactive; a PUT with the
   * same id re-enables one. Exos ids only (max 10,000).
   */
  deleteListings(sellerListingIds: string[]) {
    if (!sellerListingIds.length) throw new SeatGeekWriteRefusedError('bulkDeleteListings', 'no listing ids');
    if (sellerListingIds.length > 10_000) throw new SeatGeekWriteRefusedError('bulkDeleteListings', 'more than 10,000 ids');
    for (const id of sellerListingIds) this.assertExos(id, 'bulkDeleteListings');
    return this.write<{ ok: boolean }>('bulkDeleteListings', { body: { seller_listing_ids: sellerListingIds } });
  }

  // ── 3. Orders ──────────────────────────────────────────────────────

  confirmOrder(orderId: string) {
    return this.write<SeatGeekOrder>('updateOrder', { form: confirmOrderForm(orderId) });
  }

  denyOrder(orderId: string) {
    return this.write<SeatGeekOrder>('updateOrder', { form: denyOrderForm(orderId) });
  }

  /** PATCH /order with one Exos claim link per ticket. Refused while a field is unresolved. */
  fulfilWithTransferUrls(f: TransferFulfilment) {
    const planned = transferFulfilmentForm(f);
    if (planned.unresolved.length && this.isLive) {
      throw new SeatGeekFulfilmentError(`unresolved: ${planned.unresolved.join(', ')}`);
    }
    return this.write<SeatGeekOrder>('updateOrder', { form: planned.form });
  }

  private assertExos(id: string, endpoint: string) {
    if (!isExosSellerListingId(id)) {
      throw new SeatGeekWriteRefusedError(endpoint, `"${id}" is not an Exos listing id (the account carries broker listings)`);
    }
  }
}
