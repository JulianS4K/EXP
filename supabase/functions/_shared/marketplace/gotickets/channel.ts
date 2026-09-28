// GoTickets as a MarketplaceChannel (../channel.ts).
//   link    none needed: GoTickets maps listings to its events itself (from
//           the event name / venue / time, plus StubHub / SeatGeek ids)
//   create  none
//   sell    GET /rest/sales (and webhooks, read back) -> MarketplaceSale
//   fulfil  confirm, then fulfil with one Exos claim link per ticket

import type { MarketplaceChannel, MarketplaceSale, PlannedRequest, SaleStatus } from '../channel.ts';
import { allocationIdFromListingId } from '../listingIds.ts';
import { saleEmail } from './client.ts';
import { transferUrlFulfillment } from './fulfilment.ts';
import type { GoTicketsSale } from './types.ts';

const STATUS: Record<string, SaleStatus> = {
  UNCONFIRMED: 'pending',
  PENDING_FULFILLMENT: 'confirmed',
  COMPLETED: 'delivered',
  // Delivered; GoTickets wants proof the transfer went through.
  PENDING_TRANSFER_PROOF: 'delivered',
};

export function normalizeGoTicketsSale(raw: unknown): MarketplaceSale {
  const s = raw as GoTicketsSale;
  if (!s || typeof s !== 'object' || s.id == null || String(s.id).trim() === '') throw new Error('not a GoTickets sale');
  // A rejected or cancelled sale is over, whatever its seller status; anything
  // else unexpected (retransfer, upgrade, pickup, fraud hold) goes to a human.
  const status: SaleStatus = s.cancelReason ? 'cancelled' : STATUS[String(s.sellerStatus ?? '').toUpperCase()] ?? 'unknown';
  const listing = typeof s.externalTicketId === 'string' ? s.externalTicketId : null;
  const payout = typeof s.totalPayout === 'number' ? s.totalPayout : null;
  return {
    channel: 'gotickets',
    externalOrderId: String(s.id),
    externalEventId: s.event?.id != null ? String(s.event.id) : null,
    externalListingId: allocationIdFromListingId(listing) ?? listing,
    listingRef: listing,
    quantity: Number(s.quantity) || 0,
    status,
    buyerEmail: saleEmail(s),
    proceeds: payout != null && Number.isFinite(payout) ? { amount: payout, currency: 'USD' } : null,
    confirmBy: null,
    shipBy: null,
    createdAt: s.createTime ?? null,
    section: s.section ?? null,
    row: s.row ?? null,
  };
}

export function goTicketsChannel(): MarketplaceChannel {
  return {
    id: 'gotickets',
    label: 'GoTickets',
    capabilities: { findEvents: false, createEvent: false, listings: true, fulfilByUrls: true, displayQuantityCap: false },
    normalizeSale: normalizeGoTicketsSale,
    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[]): PlannedRequest[] {
      const n = encodeURIComponent(sale.externalOrderId);
      return [
        { channel: 'gotickets', endpoint: 'confirmSale', method: 'POST', path: `/rest/sales/${n}/confirm` },
        { channel: 'gotickets', endpoint: 'fulfillSale', method: 'POST', path: `/rest/sales/${n}/fulfill`, body: transferUrlFulfillment(claimUrls, sale.quantity) },
      ];
    },
  };
}
