// Gametime as a MarketplaceChannel (../channel.ts).
//   link    none: Gametime has no event search API; listings carry the event
//           name, venue and date for Gametime to match
//   create  none
//   list    the inventory CSV (inventory.ts)
//   sell    GET /purchases (and the sales webhook) -> MarketplaceSale
//   fulfil  confirm, then confirm_transfer with one Exos claim link per ticket

import type { MarketplaceChannel, MarketplaceSale, PlannedRequest, SaleStatus } from '../channel.ts';
import { allocationIdFromListingId } from '../listingIds.ts';
import { gametimeDate, purchaseEmail } from './client.ts';
import { transferConfirmationForm } from './fulfilment.ts';
import type { GametimePurchase, GametimeSaleNotification } from './types.ts';

const STATUS: Record<string, SaleStatus> = {
  unconfirmed: 'pending',
  unfulfilled: 'confirmed',
  completed: 'delivered',
  rejected: 'cancelled',
};

/**
 * A purchase (GET /purchases), or a sales notification (webhook), optionally
 * merged: `{ ...notification, ...purchase }` keeps the webhook's payout.
 */
export function normalizeGametimeSale(raw: unknown): MarketplaceSale {
  const p = raw as GametimePurchase & Partial<GametimeSaleNotification>;
  if (!p || typeof p !== 'object' || p.id == null || String(p.id).trim() === '') throw new Error('not a Gametime purchase');
  const listing = p.listing_reference_id ?? p.source_id ?? null;
  const status: SaleStatus = p.status == null
    ? 'pending' // a sales notification: sold, not yet confirmed
    : STATUS[String(p.status).toLowerCase()] ?? 'unknown';
  // payout (webhook) is the seller's total; a purchase's price isn't said to be per ticket or total.
  const payout = typeof p.payout === 'number' ? p.payout / 100 : null;
  return {
    channel: 'gametime',
    externalOrderId: String(p.id),
    externalEventId: p.event_id != null ? String(p.event_id) : null,
    externalListingId: allocationIdFromListingId(listing) ?? listing,
    quantity: Number(p.quantity) || 0,
    status,
    buyerEmail: purchaseEmail(p),
    proceeds: payout != null && Number.isFinite(payout) ? { amount: payout, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: gametimeDate(p.purchased_at ?? p.created_at),
    section: p.section ?? null,
    row: p.row ?? null,
  };
}

export function gametimeChannel(): MarketplaceChannel {
  return {
    id: 'gametime',
    label: 'Gametime',
    capabilities: { findEvents: false, createEvent: false, listings: true, fulfilByUrls: true, displayQuantityCap: false },
    normalizeSale: normalizeGametimeSale,
    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[]): PlannedRequest {
      const n = encodeURIComponent(sale.externalOrderId);
      return {
        channel: 'gametime',
        endpoint: 'confirmTransfer',
        method: 'POST',
        path: `/purchases/${n}/confirm_transfer`,
        body: {
          // An unconfirmed purchase is confirmed first ("only if delivery is guaranteed": it is, the tickets exist).
          confirm_first: { endpoint: 'confirmPurchase', method: 'POST', path: `/purchases/${n}/confirm` },
          form: transferConfirmationForm({ orderNumber: sale.externalOrderId, urls: claimUrls, quantity: sale.quantity }),
        },
      };
    },
  };
}
