// Vivid Seats as a MarketplaceChannel (../channel.ts).
//   link    GET /events/search (name + the event's local day), read-only,
//           when VIVID_API_TOKEN is set; the event id is the listings'
//           productionId. One search every 5 seconds, so a few per run.
//   create  none: brokers can't create Vivid events (unmapped listings go
//           to Vivid's mapping team instead)
//   sell    GET /v1/getOrders (UNCONFIRMED, PENDING_SHIPMENT) and getOrder,
//           polled: no webhooks -> MarketplaceSale
//   fulfil  confirmOrder, then transferOrderViaURL with one Exos claim link
//           per ticket

import { localDate, type ExosEventRef, type MarketplaceChannel, type MarketplaceSale, type PlannedRequest, type SaleStatus } from '../channel.ts';
import { allocationIdFromListingId } from '../listingIds.ts';
import { orderEmail } from './orders.ts';
import { vividEventToCandidate, type VividClient } from './client.ts';
import { confirmOrderForm, transferViaUrlForm } from './fulfilment.ts';
import type { VividOrder } from './types.ts';

// Searches per exos-distribute run: each costs 5 seconds.
export const VIVID_SEARCHES_PER_RUN = 6;

const STATUS: Record<string, SaleStatus> = {
  UNCONFIRMED: 'pending',
  PENDING_SHIPMENT: 'confirmed',
  COMPLETED: 'delivered',
  // VERIFICATION, PENDING_RESERVATION: a human looks.
};

export function normalizeVividOrder(raw: unknown): MarketplaceSale {
  const o = raw as VividOrder;
  if (!o || typeof o !== 'object' || o.orderId == null || !/^\d+$/.test(String(o.orderId))) throw new Error('not a Vivid Seats order');
  const listing = typeof o.brokerTicketId === 'string' && o.brokerTicketId.trim() ? o.brokerTicketId.trim() : null;
  const qty = Number(o.quantity) || 0;
  const cost = Number(o.cost);
  const event = o.productionId ?? o.eventId;
  return {
    channel: 'vivid',
    externalOrderId: String(o.orderId),
    externalEventId: event != null ? String(event) : null,
    externalListingId: allocationIdFromListingId(listing) ?? listing,
    listingRef: listing,
    quantity: qty,
    status: STATUS[String(o.status ?? '').toUpperCase()] ?? 'unknown',
    buyerEmail: orderEmail(o),
    // cost is per ticket, what the seller is paid.
    proceeds: o.cost != null && Number.isFinite(cost) && qty > 0 ? { amount: Math.round(cost * qty * 100) / 100, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: o.expectedShipDate || null,
    createdAt: o.orderDate || null,
    section: o.section ?? null,
    row: o.row ?? null,
  };
}

function searchDay(ev: ExosEventRef): { fromDate: string; toDate: string } {
  const d = localDate(ev);
  return { fromDate: `${d}T00:00:00`, toDate: `${d}T23:59:59` };
}

export function vividChannel(client?: VividClient): MarketplaceChannel {
  return {
    id: 'vivid',
    label: 'Vivid Seats',
    capabilities: { findEvents: !!client, createEvent: false, listings: true, fulfilByUrls: true, displayQuantityCap: false },
    searchesPerRun: VIVID_SEARCHES_PER_RUN,

    findEvents: client
      ? async (ev: ExosEventRef) => (await client.searchEvents({ eventKeyword: ev.name, ...searchDay(ev) })).map(vividEventToCandidate)
      : undefined,

    normalizeSale: normalizeVividOrder,

    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[], seats?: number[]): PlannedRequest[] {
      return [
        { channel: 'vivid', endpoint: 'confirmOrder', method: 'POST', path: '/v1/confirmOrder', body: confirmOrderForm(sale.externalOrderId, seats) },
        { channel: 'vivid', endpoint: 'transferOrderViaURL', method: 'POST', path: '/v1/transferOrderViaURL', body: transferViaUrlForm(sale.externalOrderId, claimUrls, sale.quantity) },
      ];
    },
  };
}
