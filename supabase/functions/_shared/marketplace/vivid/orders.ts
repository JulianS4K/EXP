// Vivid Seats v1 orders: XML in, VividOrder out. Pure.
//
// getOrders answers with a list and getOrder with one order; the wrapper's
// name isn't documented, so an order is any element with an <orderId> child.
// <seats> holds <seat> elements ("<seats><seat>1</seat><seat>2</seat></seats>").

import { child, elementsWithChild, xmlValue, type XmlElement } from './xml.ts';
import type { VividOrder } from './types.ts';

const INT_FIELDS = ['orderId', 'quantity', 'listingId', 'productionId', 'eventId', 'mercuryOrderId', 'purchaseOrderId'];
const NUM_FIELDS = ['cost'];
const BOOL_FIELDS = ['electronicDelivery', 'transferViaURL', 'instantTransfer', 'instantFlashSeats', 'zone', 'barCodesRequired', 'soldAsIntegrated'];

function toInt(v: unknown): number | undefined {
  const s = typeof v === 'string' ? v.trim() : typeof v === 'number' ? String(v) : '';
  return /^-?\d+$/.test(s) ? Number(s) : undefined;
}

export function orderFromXml(el: XmlElement): VividOrder {
  const raw = xmlValue(el) as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(raw)) {
    if (k === 'seats') continue;
    if (INT_FIELDS.includes(k)) out[k] = toInt(v);
    else if (NUM_FIELDS.includes(k)) {
      const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
      out[k] = Number.isFinite(n) ? n : undefined;
    } else if (BOOL_FIELDS.includes(k)) out[k] = typeof v === 'string' ? v.trim().toLowerCase() === 'true' : undefined;
    else out[k] = typeof v === 'string' ? v : v;
  }
  const seats = child(el, 'seats');
  out.seats = seats ? seats.children.map((s) => s.text.trim()).filter(Boolean) : [];
  if (out.orderId === undefined) throw new Error('vivid: an order without a numeric orderId');
  return out as VividOrder;
}

/** Every order in a getOrders / getOrder / getCompletedOrders document. */
export function ordersFromXml(root: XmlElement): VividOrder[] {
  return elementsWithChild(root, 'orderId').map(orderFromXml);
}

/** The buyer's email from an order, trimmed and lower-cased, or null. */
export function orderEmail(o: VividOrder | null | undefined): string | null {
  const e = String(o?.emailAddress ?? '').trim().toLowerCase();
  return e && e.includes('@') ? e : null;
}
