// GoTickets sale handling: request bodies, pure.
//
// A sale arrives UNCONFIRMED; the seller confirms it (POST /confirm) or
// rejects it, then fulfils it (POST /fulfill). Exos lists MOBILE_TICKETS and
// fulfils with method SUBMIT_TRANSFER_URL: transferUrl is "a set of valid
// URL(s) to send to the customer to complete the transfer", i.e. one Exos
// claim link per ticket (unique, no whitespace).

import type { GoTicketsFulfillment } from './types.ts';

export class GoTicketsFulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GoTicketsFulfilmentError';
  }
}

export function transferUrlFulfillment(urls: string[], quantity: number): GoTicketsFulfillment {
  const list = urls.map((u) => u.trim()).filter(Boolean);
  if (!list.length) throw new GoTicketsFulfilmentError('at least one transfer url is required');
  if (new Set(list).size !== list.length) throw new GoTicketsFulfilmentError('duplicate transfer urls');
  if (list.length !== quantity) throw new GoTicketsFulfilmentError(`${list.length} transfer urls for ${quantity} tickets`);
  for (const u of list) {
    if (!/^https:\/\/\S+$/.test(u)) throw new GoTicketsFulfilmentError(`transfer url must be https with no spaces: ${u}`);
  }
  return { method: 'SUBMIT_TRANSFER_URL', transferUrl: list };
}
