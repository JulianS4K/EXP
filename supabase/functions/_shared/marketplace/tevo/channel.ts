// Ticket Evolution as a MarketplaceChannel (../channel.ts), channel id 'evo'.
//   link    none yet: TEvo's event search isn't in the supplied pages
//   create  none
//   list    not yet: how a seller puts inventory on TEvo (ticket groups or a
//           POS feed) isn't in the supplied pages
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
import { exosListingRef, fraudGate, orderEmail } from './orders.ts';
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
  const waiting = 'wait' in gate && gate.wait;
  const status: SaleStatus = waiting ? 'pending' : STATUS[String(o.state ?? '').toLowerCase()] ?? 'unknown';
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
    capabilities: { findEvents: false, createEvent: false, listings: false, fulfilByUrls: true, displayQuantityCap: false },
    normalizeSale: normalizeTevoOrder,
    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[], seats?: number[]): PlannedRequest[] {
      return planTevoDelivery({ orderId: sale.externalOrderId, quantity: sale.quantity, claimUrls, reviewerId: opts.reviewerId, seats });
    },
  };
}
