// SeatGeek order handling: the PATCH /order form bodies, pure. Nothing here
// talks to the network.
//
// The spec's order flow: SeatGeek submits an order, the seller updates its
// status (PATCH /order `status`), and fulfils it. Fulfilment routes:
//   * PATCH /order with delivery_method + stock_type (both "Required when
//     fulfilling an order") and a `transfer_url` ("Link for customer to
//     accept transfer"). Exos's route: each ticket sold becomes an Exos
//     transfer, and the claim link (/claim/{transferId}) is the transfer URL.
//   * PUT /v3/order with PDF files or barcode tokens (not used: Exos tickets
//     are rotating barcodes, claimed into an account).
//
// Per SeatGeek's Order Management guide: PATCH /order status is one of
// confirmed / denied / fulfilled. A transfer link is sent as `transfer_url`
// ("multiple URLs can be sent if they are comma separated"), and when one is
// given, delivery_method must be `electronic` and stock_type `mobile`. The
// buyer sees the link on SeatGeek and accepts the transfer: for Exos that is
// the claim link, which puts the ticket in any Exos account they choose.

import type { FormFields } from './transport.ts';

export class SeatGeekFulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SeatGeekFulfilmentError';
  }
}

/** Deny a submitted order (SeatGeek tells the buyer). */
export function denyOrderForm(orderId: string): FormFields {
  if (!orderId.trim()) throw new SeatGeekFulfilmentError('order id is required');
  return [['order_id', orderId.trim()], ['status', 'denied']];
}

/** Accept a submitted order. */
export function confirmOrderForm(orderId: string): FormFields {
  if (!orderId.trim()) throw new SeatGeekFulfilmentError('order id is required');
  return [['order_id', orderId.trim()], ['status', 'confirmed']];
}

export interface TransferFulfilment {
  orderId: string;
  urls: string[];
  quantity: number;
}

export interface PlannedOrderForm {
  form: Array<[string, string]>;
  /** Fields the plan couldn't fill without guessing (none today). Sending needs them resolved. */
  unresolved: string[];
}

/** Fulfil with one Exos claim link per ticket (PATCH /order). */
export function transferFulfilmentForm(f: TransferFulfilment): PlannedOrderForm {
  if (!f.orderId.trim()) throw new SeatGeekFulfilmentError('order id is required');
  const urls = f.urls.map((u) => u.trim()).filter(Boolean);
  if (!urls.length) throw new SeatGeekFulfilmentError('at least one transfer url is required');
  if (new Set(urls).size !== urls.length) throw new SeatGeekFulfilmentError('duplicate transfer urls');
  if (urls.length !== f.quantity) {
    throw new SeatGeekFulfilmentError(`${urls.length} transfer urls for ${f.quantity} tickets`);
  }
  for (const u of urls) {
    if (!/^https:\/\//.test(u)) throw new SeatGeekFulfilmentError(`transfer url must be https: ${u}`);
  }
  for (const u of urls) {
    if (u.includes(',')) throw new SeatGeekFulfilmentError(`transfer url can't contain a comma: ${u}`);
  }
  const form: Array<[string, string]> = [
    ['order_id', f.orderId.trim()],
    ['status', 'fulfilled'],
    ['delivery_method', 'electronic'],
    ['stock_type', 'mobile'],
    ['transfer_url', urls.join(',')],
  ];
  const unresolved: string[] = [];
  return { form, unresolved };
}
