// Vivid Seats writer: listings and orders, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to Vivid Seats
// today. Same design as the other writers: dry-run by default (returns what
// it would send, never calls fetch); live needs a WriteAuthorization naming
// the operator, when, where it's recorded, and exactly which endpoints.
//
// Always refused, whatever the authorization: the `forbidden` endpoints,
// any listing whose ticketId isn't an Exos listing id, a delete by Vivid's
// listingId, and an update whose Vivid id wasn't read back by our ticketId
// (updateListingById below does that read first). The broker account can
// carry Terminal-2 listings; Exos only ever touches its own.
//
// Planned requests never hold the API token: v1 form posts get `apiToken`
// from the transport at send time.

import { VIVID_ENDPOINTS, type EndpointName } from './endpoints.ts';
import {
  RETRY_THROTTLED,
  execute,
  readVividBody,
  relativeUrl,
  transportConfig,
  type FetchLike,
  type FormValue,
  type RequestParts,
  type TransportConfig,
  type VividCredentials,
} from './transport.ts';
import { isExosListingId } from '../listingIds.ts';
import { xmlValue } from './xml.ts';
import type { VividConfirmForm, VividTransferViaUrlForm } from './fulfilment.ts';
import type { VividInsertListingResponse, VividListing } from './types.ts';

type WriteEndpoints = {
  [K in EndpointName]: (typeof VIVID_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type VividWriteEndpoint = WriteEndpoints;

export const VIVID_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly VividWriteEndpoint[] }> = [
  { phase: '1. Listings by our ticketId (create, update, delete)', endpoints: ['createListing', 'updateListing', 'deleteListing'] },
  { phase: '2. Orders: confirm, then transfer with the claim links', endpoints: ['confirmOrder', 'transferOrderViaURL', 'rejectOrder'] },
];

export interface VividWriteAuthorization {
  approvedBy: string;
  approvedAt: string;
  reference: string;
  endpoints: readonly VividWriteEndpoint[];
}

export type VividWriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: VividWriteAuthorization };

export interface VividPlannedWrite {
  endpoint: VividWriteEndpoint;
  method: string;
  url: string;
  body?: unknown;
}

export type VividWriteResult<T> =
  | { dryRun: true; planned: VividPlannedWrite }
  | { dryRun: false; planned: VividPlannedWrite; response: T };

export class VividWriteRefusedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`vivid write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'VividWriteRefusedError';
  }
}

export interface VividWriterOptions {
  mode?: VividWriterMode;
  credentials?: () => VividCredentials | Promise<VividCredentials>;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

function validateAuthorization(a: VividWriteAuthorization): string | null {
  if (!a.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!a.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(a.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!a.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of a.endpoints) {
    if ((VIVID_ENDPOINTS as Record<string, { access: string }>)[e]?.access !== 'write') return `"${e}" is not an allowed write endpoint`;
  }
  return null;
}

export class VividWriter {
  private readonly mode: VividWriterMode;
  private readonly cfg: TransportConfig | null;

  constructor(opts: VividWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new VividWriteRefusedError('*', bad);
      if (!opts.credentials) throw new Error('vivid writer: live mode needs credentials');
      this.cfg = transportConfig({ ...opts, credentials: opts.credentials });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private async write<T>(endpoint: VividWriteEndpoint, parts: RequestParts = {}): Promise<VividWriteResult<T>> {
    const ep = VIVID_ENDPOINTS[endpoint];
    if (ep.access !== 'write') throw new VividWriteRefusedError(endpoint, 'not a write endpoint');
    const planned: VividPlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    const body = parts.json ?? parts.form;
    if (body !== undefined) planned.body = body;
    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };
    if (!this.mode.authorization.endpoints.includes(endpoint)) throw new VividWriteRefusedError(endpoint, 'not in the authorization scope');
    const { res, creds } = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    const b = await readVividBody(res, ep, creds);
    const response = b.kind === 'json' ? b.value : b.kind === 'xml' ? xmlValue(b.root) : null;
    return { dryRun: false, planned, response: response as T };
  }

  private assertExos(id: string | null | undefined, endpoint: string) {
    if (!isExosListingId(id)) throw new VividWriteRefusedError(endpoint, `"${id}" is not an Exos listing id (the account may carry broker listings)`);
  }

  /** POST /listings/v2/create: one listing, keyed by our ticketId. */
  createListing(listing: VividListing) {
    if (listing.id != null) throw new VividWriteRefusedError('createListing', 'a new listing carries no Vivid id');
    this.assertExos(listing.ticketId, 'createListing');
    return this.write<VividInsertListingResponse>('createListing', { json: listing });
  }

  /**
   * PUT /listings/v2/update: the whole listing, with Vivid's id. Vivid keys
   * the update by that id, so it must come from reading the listing back by
   * our ticketId (updateListingById's `current`), and that listing must be ours.
   */
  updateListing(listing: VividListing, current: VividListing) {
    this.assertExos(listing.ticketId, 'updateListing');
    if (current.id == null || current.ticketId !== listing.ticketId) {
      throw new VividWriteRefusedError('updateListing', 'the Vivid id must come from the listing read back by the same ticketId');
    }
    return this.write<unknown>('updateListing', { json: { ...listing, id: current.id } });
  }

  /** DELETE /listings/v2/delete?internalTicketId=: by our id, never by Vivid's listingId. */
  deleteListing(ticketId: string) {
    this.assertExos(ticketId, 'deleteListing');
    return this.write<unknown>('deleteListing', { query: { internalTicketId: ticketId } });
  }

  confirmOrder(form: VividConfirmForm) {
    return this.write<unknown>('confirmOrder', { form: form as unknown as Record<string, FormValue> });
  }

  rejectOrder(orderId: string | number) {
    return this.write<unknown>('rejectOrder', { form: { orderId: String(orderId) } });
  }

  /** POST /v1/transferOrderViaURL with one Exos claim link per ticket. */
  transferOrderViaUrl(form: VividTransferViaUrlForm) {
    return this.write<unknown>('transferOrderViaURL', { form: form as unknown as Record<string, FormValue> });
  }
}
