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
import { tevoAmountCents } from './payments.ts';

const STATUS: Record<string, SaleStatus> = {
  pending: 'pending',
  accepted: 'confirmed',
  completed: 'delivered',
  delivered: 'delivered',
  rejected: 'cancelled',
  canceled: 'cancelled',
  cancelled: 'cancelled',
};

export function normalizeTevoOrder(raw: unknown): MarketplaceSale {
  const o = raw as TevoOrder;
  if (!o || typeof o !== 'object' || o.id == null || !/^\d+$/.test(String(o.id))) throw new Error('not a TEvo order');
  const items = Array.isArray(o.items) ? o.items : [];
  // Only items sold from an Exos listing are Exos's (the account also carries
  // broker inventory). An order can hold several items: every Exos item must
  // name the SAME Exos listing, or no one listing can supply the quantity.
  const exosItems = items.filter((it) => exosListingRef(it) != null);
  const refs = [...new Set(exosItems.map((it) => exosListingRef(it)!))];
  const counted = exosItems.length ? exosItems : items;
  const first = counted[0];
  const listing = refs[0] ?? exosListingRef(first);
  const qty = counted.reduce((s, it) => s + (Number(it.quantity) || 0), 0);
  // Proceeds are what the seller is paid: the items' price less TEvo's seller
  // fee (order.fee, ~3%; the EvoPay payment is the gross). In cents. The fee
  // is per order: when broker items share the order, Exos's part of it is
  // prorated by price.
  const lineCents = (it: (typeof items)[number]) => {
    const c = tevoAmountCents(it.price);
    return c == null ? null : c * (Number(it.quantity) || 0);
  };
  let grossCents = 0;
  let priced = counted.length > 0;
  for (const it of counted) {
    const c = lineCents(it);
    if (c == null) priced = false;
    else grossCents += c;
  }
  const feeCents = Math.max(0, tevoAmountCents(o.fee) ?? 0);
  const orderCents = items.reduce((s, it) => s + (lineCents(it) ?? 0), 0);
  const exosFeeCents = counted.length === items.length || orderCents <= 0
    ? feeCents
    : Math.round((feeCents * grossCents) / orderCents);
  const proceeds = (grossCents - exosFeeCents) / 100;
  const gate = fraudGate(o);
  // A Client sale Riskified hasn't cleared: exos-marketplace-sales doesn't
  // ingest it yet (tevoAwaitingFraudCheck), so no tickets exist before it
  // clears; one it declined is a cancellation.
  const waiting = 'wait' in gate && gate.wait;
  const declined = orderKind(o) === 'sale_to_client' && 'reason' in gate && !waiting;
  const mapped: SaleStatus = declined ? 'cancelled' : waiting ? 'pending' : STATUS[String(o.state ?? '').toLowerCase()] ?? 'unknown';
  // Several Exos listings in one order: never fulfil the whole quantity from
  // the first one. It goes to a human (status 'unknown' + the reason), unless
  // it's cancelled anyway.
  const split = refs.length > 1 && mapped !== 'cancelled';
  // Exos items next to broker items: TEvo accepts an order as a whole, so
  // Exos can't deliver its part on its own either.
  const mixed = !split && refs.length === 1 && exosItems.length < items.length && mapped !== 'cancelled';
  const status: SaleStatus = split || mixed ? 'unknown' : mapped;
  return {
    channel: 'evo',
    externalOrderId: String(o.id),
    externalEventId: o.event?.id != null ? String(o.event.id) : null,
    externalListingId: allocationIdFromListingId(listing) ?? listing,
    listingRef: listing,
    quantity: qty,
    status,
    buyerEmail: orderEmail(o),
    proceeds: priced && qty > 0 ? { amount: proceeds, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: o.created_at ?? null,
    section: first?.ticket_group?.section ?? null,
    row: first?.ticket_group?.row ?? null,
    note: split
      ? `Ticket Evolution order has items from ${refs.length} different Exos listings (${refs.join(', ')}): fulfil each listing's tickets by hand`
      : mixed
        ? 'Ticket Evolution order mixes this Exos listing with broker items: fulfil the Exos tickets by hand'
        : null,
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
