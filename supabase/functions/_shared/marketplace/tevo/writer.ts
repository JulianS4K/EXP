// Ticket Evolution writer: orders and shipments, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to TEvo
// today. Same design as the other writers: dry-run by default (returns what
// it would send, never calls fetch); live needs a WriteAuthorization naming
// the operator, when, where it's recorded, and exactly which endpoints.
//
// Always refused, whatever the authorization: the `forbidden` endpoints
// (buying, etickets, airbills), and accepting an order that isn't for an
// Exos listing or whose fraud check hasn't cleared (orders.ts). The TEvo
// account can carry Terminal-2 broker orders; Exos only touches its own.
// Planned writes never hold the token, the secret or a signature.

import { TEVO_ENDPOINTS, type EndpointName, type TevoEnvironment } from './endpoints.ts';
import {
  RETRY_THROTTLED,
  execute,
  readTevoJson,
  relativeUrl,
  transportConfig,
  type FetchLike,
  type RequestParts,
  type TevoCredentials,
  type TransportConfig,
} from './transport.ts';
import { exosListingRef, fraudGate } from './orders.ts';
import type { TevoAcceptBody, TevoOrder, TevoShipmentComplete, TevoShipmentUpdate } from './types.ts';

type WriteEndpoints = {
  [K in EndpointName]: (typeof TEVO_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type TevoWriteEndpoint = WriteEndpoints;

export const TEVO_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly TevoWriteEndpoint[] }> = [
  { phase: '1. Orders for Exos listings: accept, then deliver by mobile transfer', endpoints: ['acceptOrder', 'updateShipment', 'completeShipment'] },
];

export interface TevoWriteAuthorization {
  approvedBy: string;
  approvedAt: string;
  reference: string;
  endpoints: readonly TevoWriteEndpoint[];
}

export type TevoWriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: TevoWriteAuthorization };

export interface TevoPlannedWrite {
  endpoint: TevoWriteEndpoint;
  method: string;
  url: string;
  body?: unknown;
}

export type TevoWriteResult<T> =
  | { dryRun: true; planned: TevoPlannedWrite }
  | { dryRun: false; planned: TevoPlannedWrite; response: T };

export class TevoWriteRefusedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`tevo write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'TevoWriteRefusedError';
  }
}

export interface TevoWriterOptions {
  mode?: TevoWriterMode;
  credentials?: () => TevoCredentials | Promise<TevoCredentials>;
  environment?: TevoEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

function validateAuthorization(a: TevoWriteAuthorization): string | null {
  if (!a.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!a.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(a.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!a.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of a.endpoints) {
    if ((TEVO_ENDPOINTS as Record<string, { access: string }>)[e]?.access !== 'write') return `"${e}" is not an allowed write endpoint`;
  }
  return null;
}

const idOf = (v: string | number, what: string, endpoint: string): string => {
  const s = String(v).trim();
  if (!/^\d+$/.test(s)) throw new TevoWriteRefusedError(endpoint, `not a TEvo ${what} id: ${s}`);
  return s;
};

export class TevoWriter {
  private readonly mode: TevoWriterMode;
  private readonly cfg: TransportConfig | null;

  constructor(opts: TevoWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new TevoWriteRefusedError('*', bad);
      if (!opts.credentials) throw new Error('tevo writer: live mode needs credentials');
      this.cfg = transportConfig({ ...opts, credentials: opts.credentials });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private async write<T>(endpoint: TevoWriteEndpoint, parts: RequestParts): Promise<TevoWriteResult<T>> {
    const ep = TEVO_ENDPOINTS[endpoint];
    if (ep.access !== 'write') throw new TevoWriteRefusedError(endpoint, 'not a write endpoint');
    const planned: TevoPlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    if (parts.json !== undefined) planned.body = parts.json;
    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };
    if (!this.mode.authorization.endpoints.includes(endpoint)) throw new TevoWriteRefusedError(endpoint, 'not in the authorization scope');
    const { res, creds } = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    return { dryRun: false, planned, response: (await readTevoJson(res, ep, creds)) as T };
  }

  /**
   * POST /v9/orders/{id}/accept. The order must be one we read back: every
   * item sold from an Exos listing, and its fraud check cleared.
   */
  acceptOrder(order: TevoOrder, body: TevoAcceptBody) {
    const id = idOf(order?.id, 'order', 'acceptOrder');
    const items = order.items ?? [];
    if (!items.length || items.some((it) => !exosListingRef(it))) {
      throw new TevoWriteRefusedError('acceptOrder', `order ${id} is not (only) for Exos listings; the account may carry broker orders`);
    }
    const gate = fraudGate(order);
    if ('reason' in gate) throw new TevoWriteRefusedError('acceptOrder', gate.reason);
    if (!Number.isInteger(body.reviewer_id) || body.reviewer_id <= 0) throw new TevoWriteRefusedError('acceptOrder', 'no reviewer_id');
    return this.write<TevoOrder>('acceptOrder', { path: { order_id: id }, json: body });
  }

  /** PUT /v9/shipments/{id}: the mobile transfer type (link or email). */
  updateShipment(shipmentId: string | number, body: TevoShipmentUpdate) {
    if (body.mobile_transfer_type !== 'TMMobileLink' && body.mobile_transfer_type !== 'TMMobile') {
      throw new TevoWriteRefusedError('updateShipment', 'Exos delivers by mobile transfer only');
    }
    return this.write<unknown>('updateShipment', { path: { shipment_id: idOf(shipmentId, 'shipment', 'updateShipment') }, json: body });
  }

  /** PUT /v9/shipments/{id}/complete, with the claim link when there is one. */
  completeShipment(shipmentId: string | number, body: TevoShipmentComplete) {
    if (body.tm_mobile_link != null && !/^https:\/\/\S+$/.test(body.tm_mobile_link)) {
      throw new TevoWriteRefusedError('completeShipment', 'the transfer link must be https');
    }
    return this.write<unknown>('completeShipment', { path: { shipment_id: idOf(shipmentId, 'shipment', 'completeShipment') }, json: body });
  }
}
