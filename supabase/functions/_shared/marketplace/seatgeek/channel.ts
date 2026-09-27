// SeatGeek as a MarketplaceChannel (../channel.ts).
//   link    Platform API GET /2/events (q + local date), read-only, when
//           SEATGEEK_CLIENT_ID is set
//   create  none: SeatGeek sellers can't create events
//   sell    Seller Direct GET /orders -> MarketplaceSale
//   fulfil  PATCH /order with one Exos claim link per ticket (planned)

import {
  localDate,
  type ExosEventRef,
  type MarketplaceChannel,
  type MarketplaceSale,
  type PlannedRequest,
  type SaleStatus,
} from '../channel.ts';
import { transferFulfilmentForm } from './fulfilment.ts';
import { allocationIdFromSellerListingId } from './listingPlan.ts';
import { platformEventToCandidate, type SeatGeekPlatformClient } from './platform.ts';
import type { SeatGeekOrder } from './types.ts';

// Order statuses (Order Management guide): submitted, confirmed, denied,
// fulfilled, void. The webhook example also shows "pending". An order.broken
// notification is terminal: treated as cancelled (see webhook.ts). Anything
// else is 'unknown' and goes to a human.
const ORDER_STATUS: Record<string, SaleStatus> = {
  submitted: 'pending',
  pending: 'pending',
  confirmed: 'confirmed',
  fulfilled: 'delivered',
  denied: 'cancelled',
  void: 'cancelled',
  broken: 'cancelled',
};

export function normalizeSeatGeekOrder(raw: unknown): MarketplaceSale {
  const o = raw as SeatGeekOrder;
  if (!o || typeof o !== 'object' || o.id == null || String(o.id).trim() === '') throw new Error('not a SeatGeek order');
  const status = ORDER_STATUS[String(o.status ?? '').toLowerCase().replace(/[^a-z]/g, '')] ?? 'unknown';
  // The API spec nests the listing; the guide's older shape has item_id / quantity at the top.
  const legacy = o as SeatGeekOrder & { item_id?: string; quantity?: number };
  const listingId = o.listing?.id ?? legacy.item_id ?? null;
  const eventId = o.event?.seatgeek_event_id;
  const total = Number(o.total);
  return {
    channel: 'seatgeek',
    externalOrderId: String(o.id),
    externalEventId: eventId != null ? String(eventId) : null,
    // "ex<base32 allocation id><n>" -> the allocation row the sale came from.
    externalListingId: allocationIdFromSellerListingId(listingId) ?? listingId,
    quantity: Number(o.listing?.quantity ?? legacy.quantity) || 0,
    status,
    // Not on the order: GET /orders/customer -> customerEmail().
    buyerEmail: null,
    // `total` is subtotal less fees: what the seller is paid. SeatGeek is USD.
    proceeds: Number.isFinite(total) ? { amount: total, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: o.created ?? null,
    section: o.listing?.section ?? null,
    row: o.listing?.row ?? null,
  };
}

export function seatGeekChannel(platform?: SeatGeekPlatformClient): MarketplaceChannel {
  return {
    id: 'seatgeek',
    label: 'SeatGeek',
    capabilities: { findEvents: !!platform, createEvent: false, listings: true, fulfilByUrls: true, displayQuantityCap: false },

    findEvents: platform
      ? async (ev: ExosEventRef) => (await platform.searchEvents(ev.name, localDate(ev))).map(platformEventToCandidate)
      : undefined,

    normalizeSale: normalizeSeatGeekOrder,

    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[]): PlannedRequest {
      return {
        channel: 'seatgeek',
        endpoint: 'updateOrder',
        method: 'PATCH',
        path: '/order',
        body: transferFulfilmentForm({ orderId: sale.externalOrderId, urls: claimUrls, quantity: sale.quantity }),
      };
    },
  };
}
