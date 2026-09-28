// Ticket Evolution order handling: request bodies and the delivery plan. Pure.
//
// An order for our tickets is accepted (POST /v9/orders/{id}/accept with
// our reviewer_id and the internal seat numbers), which commits us to
// deliver. Its shipment comes back as TBD. Delivery is a mobile transfer
// (the Exos standard, ../exosListing.ts EXOS_TRANSFER_STOCK):
//
//   one ticket    PUT /v9/shipments/{tbd} {mobile_transfer_type: TMMobileLink}
//                 -> TEvo returns a NEW shipment id; then
//                 PUT /v9/shipments/{new}/complete {tm_mobile_link: <claim link>}
//   more tickets  TEvo takes one link per shipment and Exos issues one claim
//                 link per ticket, so: PUT /v9/shipments/{tbd}
//                 {mobile_transfer_type: TMMobile} -> TEvo returns the email
//                 (and name) to transfer to; Exos issues the order's transfers
//                 to that email; then PUT /v9/shipments/{new}/complete.
//
// OPEN with TEvo integrations: both types are named for Ticketmaster. Whether
// an Exos claim link / Exos transfer is accepted under them, and which
// transfer_source value to send, isn't in the supplied pages; until TEvo
// says, transfer_source is left out.
//
// Shipment ids that only exist after an earlier step appear in planned paths
// as {shipment_id from …} placeholders: a plan is a record, never sent as is.

import type { PlannedRequest } from '../channel.ts';
import type { TevoAcceptBody, TevoShipmentComplete, TevoShipmentUpdate } from './types.ts';

export class TevoFulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TevoFulfilmentError';
  }
}

function orderIdOf(id: string | number): string {
  const s = String(id).trim();
  if (!/^\d+$/.test(s)) throw new TevoFulfilmentError(`not a TEvo order id: ${s}`);
  return s;
}

export function acceptBody(reviewerId: number | null | undefined, seats?: number[]): TevoAcceptBody {
  if (!Number.isInteger(reviewerId) || (reviewerId as number) <= 0) {
    throw new TevoFulfilmentError('no reviewer_id: set TEVO_REVIEWER_ID to the TEvo user id given to you');
  }
  const body: TevoAcceptBody = { reviewer_id: reviewerId as number };
  if (seats?.length) body.seats = [...seats];
  return body;
}

function claimLinks(urls: string[], quantity: number): string[] {
  const list = urls.map((u) => u.trim()).filter(Boolean);
  if (!list.length) throw new TevoFulfilmentError('at least one claim link is required');
  if (new Set(list).size !== list.length) throw new TevoFulfilmentError('duplicate claim links');
  if (list.length !== quantity) throw new TevoFulfilmentError(`${list.length} claim links for ${quantity} tickets`);
  for (const u of list) {
    if (!/^https:\/\/\S+$/.test(u)) throw new TevoFulfilmentError(`claim link must be https with no spaces: ${u}`);
  }
  return list;
}

/** The whole delivery, in order: accept, set the transfer type, complete. */
export function planTevoDelivery(opts: {
  orderId: string | number;
  quantity: number;
  claimUrls: string[];
  reviewerId: number | null | undefined;
  seats?: number[];
}): PlannedRequest[] {
  const id = orderIdOf(opts.orderId);
  const urls = claimLinks(opts.claimUrls, opts.quantity);
  const accept: PlannedRequest = { channel: 'evo', endpoint: 'acceptOrder', method: 'POST', path: `/v9/orders/${id}/accept`, body: acceptBody(opts.reviewerId, opts.seats) };
  const tbd = '/v9/shipments/{shipment_id from the accept response}';
  const next = '/v9/shipments/{shipment_id from the update response}/complete';
  if (urls.length === 1) {
    const update: TevoShipmentUpdate = { mobile_transfer_type: 'TMMobileLink' };
    const complete: TevoShipmentComplete = { tm_mobile_link: urls[0] };
    return [
      accept,
      { channel: 'evo', endpoint: 'updateShipment', method: 'PUT', path: tbd, body: update },
      { channel: 'evo', endpoint: 'completeShipment', method: 'PUT', path: next, body: complete },
    ];
  }
  const update: TevoShipmentUpdate = { mobile_transfer_type: 'TMMobile' };
  return [
    accept,
    { channel: 'evo', endpoint: 'updateShipment', method: 'PUT', path: tbd, body: update },
    // Between these two, Exos issues the order's transfers to the email the update returns.
    { channel: 'evo', endpoint: 'completeShipment', method: 'PUT', path: next, body: {} satisfies TevoShipmentComplete },
  ];
}

/** The recipient TEvo names on a TMMobile / FlashSeats shipment, lower-cased, or null. */
export function shipmentRecipient(s: { email_address?: { address?: string } | string; ship_to_name?: string } | null | undefined): { email: string; name: string | null } | null {
  const raw = s?.email_address;
  const email = String(typeof raw === 'object' && raw ? raw.address ?? '' : raw ?? '').trim().toLowerCase();
  if (!email.includes('@')) return null;
  return { email, name: s?.ship_to_name?.trim() || null };
}
