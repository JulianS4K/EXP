// Ticket Evolution writer: inventory, orders and shipments, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to TEvo
// today. Same design as the other writers: dry-run by default (returns what
// it would send, never calls fetch); live needs a WriteAuthorization naming
// the operator, when, where it's recorded, and exactly which endpoints.
//
// Always refused, whatever the authorization: the `forbidden` endpoints
// (buying, etickets, airbills, bulk inventory update / delete), accepting an
// order that isn't for an Exos listing or whose fraud check hasn't cleared
// (orders.ts), and any inventory that isn't an Exos listing: it must carry
// an Exos listing id and an Exos remote_id (listingPlan.ts), in the
// configured office, as a mobile transfer. The TEvo office can carry
// Terminal-2 broker inventory and orders; Exos only touches its own.
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
import { isExosTevoRemoteId } from './listingPlan.ts';
import { isExosListingId } from '../listingIds.ts';
import { EXOS_TRANSFER_STOCK } from '../exosListing.ts';
import type {
  TevoAcceptBody,
  TevoInventoryBody,
  TevoInventoryPatch,
  TevoInventoryTicket,
  TevoOrder,
  TevoShipmentComplete,
  TevoShipmentUpdate,
} from './types.ts';

type WriteEndpoints = {
  [K in EndpointName]: (typeof TEVO_ENDPOINTS)[K]['access'] extends 'write' ? K : never;
}[EndpointName];
export type TevoWriteEndpoint = WriteEndpoints;

export const TEVO_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly TevoWriteEndpoint[] }> = [
  { phase: '1. Exos listings as TEvo inventory, one ticket group each', endpoints: ['createInventory', 'updateInventory', 'deleteInventory'] },
  { phase: '2. Orders for Exos listings: accept, then deliver by mobile transfer', endpoints: ['acceptOrder', 'updateShipment', 'completeShipment'] },
];

/** An Exos listing TEvo has: its TEvo id and ours, from the listed snapshot. */
export interface TevoInventoryRef {
  inventory_id: string | number;
  listing_id: string;
  remote_id: number;
}

const MAX_PRICE = 1_000_000;

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
  /** TEVO_OFFICE_ID: inventory is only created in this office. */
  officeId?: number | null;
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

/** An Exos listing's TEvo id, or refused. */
function exosRef(endpoint: string, ref: TevoInventoryRef): string {
  if (!isExosListingId(ref?.listing_id)) throw new TevoWriteRefusedError(endpoint, 'not an Exos listing');
  if (!isExosTevoRemoteId(ref.remote_id)) throw new TevoWriteRefusedError(endpoint, `remote_id ${String(ref.remote_id)} is not an Exos remote_id`);
  return idOf(ref.inventory_id, 'inventory', endpoint);
}

/** Mobile transfer, a sane price, seats matching the quantity, an in-hand date. */
function ticketRules(endpoint: string, t: Partial<TevoInventoryTicket>, full: boolean): void {
  if ((full || 'format' in t) && t.format !== EXOS_TRANSFER_STOCK.evo) {
    throw new TevoWriteRefusedError(endpoint, `Exos lists mobile transfers only (format ${EXOS_TRANSFER_STOCK.evo})`);
  }
  if ((full || 'price' in t) && !(typeof t.price === 'number' && t.price > 0 && t.price <= MAX_PRICE)) {
    throw new TevoWriteRefusedError(endpoint, 'price must be above 0 and at most 1,000,000');
  }
  if (full || 'quantity' in t || 'seats' in t) {
    // A block that moved without resizing changes its seats only.
    const q = t.quantity ?? (full ? undefined : t.seats?.length);
    if (!Number.isInteger(q) || q! < 1) throw new TevoWriteRefusedError(endpoint, 'quantity must be at least 1');
    const seats = t.seats ?? [];
    if (seats.length !== q || new Set(seats.map((x) => x.seat)).size !== q || seats.some((x) => !Number.isInteger(x.seat))) {
      throw new TevoWriteRefusedError(endpoint, 'seats must be unique whole numbers, one per ticket');
    }
  }
  if ((full || 'in_hand' in t) && t.in_hand === false && !/^\d{4}-\d{2}-\d{2}$/.test(String(t.in_hand_on ?? ''))) {
    throw new TevoWriteRefusedError(endpoint, 'in_hand_on (YYYY-MM-DD) is required when not in hand');
  }
}

export class TevoWriter {
  private readonly mode: TevoWriterMode;
  private readonly cfg: TransportConfig | null;
  private readonly officeId: number | null;

  constructor(opts: TevoWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    this.officeId = Number.isInteger(opts.officeId) && opts.officeId! > 0 ? opts.officeId! : null;
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
  /** POST /v9/inventory: one Exos listing (listingPlan.ts) as a ticket group. */
  createInventory(body: TevoInventoryBody) {
    const ep = 'createInventory';
    const inv = body?.inventory;
    const t = inv?.ticket;
    if (!t) throw new TevoWriteRefusedError(ep, 'no inventory.ticket');
    if (!isExosListingId(t.internal_notes)) throw new TevoWriteRefusedError(ep, 'internal_notes is not an Exos listing id');
    if (!isExosTevoRemoteId(t.remote_id)) throw new TevoWriteRefusedError(ep, `remote_id ${String(t.remote_id)} is not an Exos remote_id`);
    if (this.officeId == null) throw new TevoWriteRefusedError(ep, 'no office configured (TEVO_OFFICE_ID)');
    if (inv.office?.id !== this.officeId) throw new TevoWriteRefusedError(ep, 'not the configured office');
    if (!Number.isInteger(inv.event?.id) || inv.event.id! <= 0) throw new TevoWriteRefusedError(ep, 'no TEvo event id: link the event first');
    if (!inv.venue?.name?.trim()) throw new TevoWriteRefusedError(ep, 'no venue name');
    for (const k of ['section', 'row'] as const) if (!String(t[k] ?? '').trim()) throw new TevoWriteRefusedError(ep, `no ${k}`);
    if (t.type !== 'EVENT') throw new TevoWriteRefusedError(ep, 'Exos lists event tickets only');
    ticketRules(ep, t, true);
    return this.write<{ inventory?: { id?: number } }>(ep, { json: body });
  }

  /** PATCH /v9/inventory/{id}: changed ticket fields of an Exos listing (sync.ts). */
  updateInventory(ref: TevoInventoryRef, patch: TevoInventoryPatch) {
    const ep = 'updateInventory';
    const id = exosRef(ep, ref);
    const keys = Object.keys(patch?.inventory ?? {});
    if (keys.some((k) => k !== 'ticket')) throw new TevoWriteRefusedError(ep, 'only ticket fields change once listed');
    const t = (patch.inventory.ticket ?? {}) as Partial<TevoInventoryTicket>;
    if (!Object.keys(t).length) throw new TevoWriteRefusedError(ep, 'nothing to change');
    for (const k of ['remote_id', 'internal_notes', 'type'] as const) {
      if (k in t) throw new TevoWriteRefusedError(ep, `${k} is fixed once listed`);
    }
    ticketRules(ep, t, false);
    return this.write<unknown>(ep, { path: { inventory_id: id }, json: patch });
  }

  /** DELETE /v9/inventory/{id}: one Exos listing (never the bulk delete). */
  deleteInventory(ref: TevoInventoryRef) {
    const ep = 'deleteInventory';
    return this.write<null>(ep, { path: { inventory_id: exosRef(ep, ref) } });
  }
}
