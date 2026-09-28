// Vivid Seats order handling: request bodies, pure.
//
// An order arrives UNCONFIRMED. The seller confirms it (POST
// /v1/confirmOrder; the internal seat numbers go in seatNumbers), and it
// moves to PENDING_SHIPMENT. Exos lists electronic-transfer tickets and
// delivers them with POST /v1/transferOrderViaURL: transferURLList holds one
// Exos claim link per ticket, and transferSource / transferSourceURL say
// where they come from (Exos and its app). Both are form posts; the API
// token is added by the transport when (if ever) one is sent.

export class VividFulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VividFulfilmentError';
  }
}

export interface VividConfirmForm {
  orderId: string;
  seatNumbers?: string;
}

export interface VividTransferViaUrlForm {
  orderId: string;
  transferURLList: string[];
  transferSource: string;
  transferSourceURL: string;
}

function orderIdOf(id: string | number): string {
  const s = String(id).trim();
  if (!/^\d+$/.test(s)) throw new VividFulfilmentError(`not a Vivid order id: ${s}`);
  return s;
}

export function confirmOrderForm(orderId: string | number, seats?: number[]): VividConfirmForm {
  const form: VividConfirmForm = { orderId: orderIdOf(orderId) };
  if (seats?.length) form.seatNumbers = seats.join(',');
  return form;
}

export function transferViaUrlForm(orderId: string | number, urls: string[], quantity: number): VividTransferViaUrlForm {
  const list = urls.map((u) => u.trim()).filter(Boolean);
  if (!list.length) throw new VividFulfilmentError('at least one transfer url is required');
  if (new Set(list).size !== list.length) throw new VividFulfilmentError('duplicate transfer urls');
  if (list.length !== quantity) throw new VividFulfilmentError(`${list.length} transfer urls for ${quantity} tickets`);
  for (const u of list) {
    if (!/^https:\/\/\S+$/.test(u)) throw new VividFulfilmentError(`transfer url must be https with no spaces: ${u}`);
  }
  return { orderId: orderIdOf(orderId), transferURLList: list, transferSource: 'Exos', transferSourceURL: new URL(list[0]).origin };
}
