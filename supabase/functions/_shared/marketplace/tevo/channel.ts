// Ticket Evolution as a MarketplaceChannel (../channel.ts), channel id 'evo'.
//   link    none yet: TEvo's event search isn't in the supplied pages, so
//           staff link the event by hand (exos_channel_event_links)
//   create  none
//   list    Inventory / Create, one ticket group per Exos listing
//           (listingPlan.ts), planned by exos-distribute, dry-run
//   sell    GET /v9/orders polled (webhooks and Order Integration later,
//           once their payloads are supplied) -> MarketplaceSale
//   fulfil  accept, then a mobile transfer: one link for one ticket, the
//           email route for more (fulfilment.ts)
//
// Order states are mapped from the values TEvo is known to use; one the map
// doesn't know becomes 'unknown' and goes to a human. A Client sale whose
// fraud check is pending stays 'pending' whatever its state says.

import type { MarketplaceChannel, MarketplaceSale, PlannedRequest, SaleStatus } from '../channel.ts';
import { allocationIdFromListingId } from '../listingIds.ts';
import { planTevoDelivery } from './fulfilment.ts';
import { exosListingRef, fraudGate, orderEmail, orderKind } from './orders.ts';
import type { TevoOrder } from './types.ts';

const STATUS: Record<string, SaleStatus> = {
  pending: 'pending',
  accepted: 'confirmed',
  completed: 'delivered',
  delivered: 'delivered',
  rejected: 'cancelled',
  canceled: 'cancelled',
  cancelled: 'cancelled',
};

const num = (v: unknown): number => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : NaN;
};

export function normalizeTevoOrder(raw: unknown): MarketplaceSale {
  const o = raw as TevoOrder;
  if (!o || typeof o !== 'object' || o.id == null || !/^\d+$/.test(String(o.id))) throw new Error('not a TEvo order');
  const items = Array.isArray(o.items) ? o.items : [];
  const first = items[0];
  const listing = exosListingRef(first);
  const qty = items.reduce((s, it) => s + (Number(it.quantity) || 0), 0);
  let proceeds = 0;
  let priced = items.length > 0;
  for (const it of items) {
    const p = num(it.price);
    if (!Number.isFinite(p)) priced = false;
    else proceeds += p * (Number(it.quantity) || 0);
  }
  const gate = fraudGate(o);
  // A Client sale Riskified hasn't cleared: exos-marketplace-sales doesn't
  // ingest it yet (tevoAwaitingFraudCheck), so no tickets exist before it
  // clears; one it declined is a cancellation.
  const waiting = 'wait' in gate && gate.wait;
  const declined = orderKind(o) === 'sale_to_client' && 'reason' in gate && !waiting;
  const status: SaleStatus = declined ? 'cancelled' : waiting ? 'pending' : STATUS[String(o.state ?? '').toLowerCase()] ?? 'unknown';
  return {
    channel: 'evo',
    externalOrderId: String(o.id),
    externalEventId: o.event?.id != null ? String(o.event.id) : null,
    externalListingId: allocationIdFromListingId(listing) ?? listing,
    listingRef: listing,
    quantity: qty,
    status,
    buyerEmail: orderEmail(o),
    proceeds: priced && qty > 0 ? { amount: Math.round(proceeds * 100) / 100, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: o.created_at ?? null,
    section: first?.ticket_group?.section ?? null,
    row: first?.ticket_group?.row ?? null,
  };
}

export function evoChannel(opts: { reviewerId?: number | null } = {}): MarketplaceChannel {
  return {
    id: 'evo',
    label: 'Ticket Evolution',
    capabilities: { findEvents: false, createEvent: false, listings: true, fulfilByUrls: true, displayQuantityCap: false },
    normalizeSale: normalizeTevoOrder,
    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[], seats?: number[]): PlannedRequest[] {
      return planTevoDelivery({ orderId: sale.externalOrderId, quantity: sale.quantity, claimUrls, reviewerId: opts.reviewerId, seats });
    },
  };
}

/** A Client sale waiting on its Riskified check: nothing is issued until it clears. */
export function tevoAwaitingFraudCheck(raw: unknown): boolean {
  const gate = fraudGate(raw as TevoOrder);
  return 'wait' in gate && gate.wait;
}
