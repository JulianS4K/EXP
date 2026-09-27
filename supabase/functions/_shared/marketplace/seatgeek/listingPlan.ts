// The SeatGeek listings for a channel allocation: the Exos listings
// (../exosListing.ts: blocks of at most max per order, internal seats,
// stable "ex…" ids) in SeatGeek's fields. Planned, not sent. Field rules:
// SeatGeek "Listing Fields" page.
//
// Why blocks: one order takes at most one listing, and a CUSTOM `splits`
// list must end at the listing's full quantity (otherwise SeatGeek falls
// back to DEFAULT), so splits can't cap an order below the quantity.
//
// Fields: event / venue / event_date / event_time are required even with an
// event_id (SeatGeek matches events on title + venue). row is required
// ("GA"), and with it seat_from / seat_thru: the block's internal seats.
// stock_type "mobile" (the buyer accepts a transfer link: Exos's claim
// link), is_edelivery true, split_type ANY, in_hand_date the event day.
// seller_listing_id (max 32 chars) is the Exos listing id.

import { entryFor, planExosListings, requireCurrency, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';
import type { SeatGeekListing } from './types.ts';

export {
  MAX_EXOS_LISTINGS_PER_ALLOCATION as MAX_SEATGEEK_LISTINGS_PER_ALLOCATION,
  allocationIdFromListingId as allocationIdFromSellerListingId,
  exosListingId as exosSellerListingId,
  isExosListingId as isExosSellerListingId,
} from '../listingIds.ts';

/** Split qty into groups of at most `max` (the last one takes the rest). */
export function groupSizes(qty: number, max: number | null): number[] {
  if (!Number.isInteger(qty) || qty <= 0) return [];
  if (!max || max >= qty) return [qty];
  const out: number[] = [];
  for (let left = qty; left > 0; left -= max) out.push(Math.min(max, left));
  return out;
}

export type SeatGeekAllocation = ExosAllocation & {
  /** The linked SeatGeek event id (exos_channel_event_links), if any. */
  seatgeekEventId?: string | null;
};

export type SeatGeekListingBody = SeatGeekListing & { seller_listing_id: string };

export interface PlannedSeatGeekListings extends PlannedMarketplaceListings<SeatGeekListingBody> {
  channel: 'seatgeek';
}

export function planSeatGeekListings(a: SeatGeekAllocation): PlannedSeatGeekListings {
  const eventId = a.seatgeekEventId?.trim();
  if (eventId && !/^\d+$/.test(eventId)) throw new Error(`"${eventId}" is not a SeatGeek event id`);
  const set = planExosListings(a, 'SeatGeek');
  requireCurrency(set, 'USD', 'SeatGeek');
  const unresolved: string[] = [];
  if (!eventId) unresolved.push('event_id (not linked: SeatGeek matches on the event title and venue)');
  const listings = set.listings.map((l) => {
    const body: SeatGeekListingBody = {
      seller_listing_id: l.listing_id,
      event: l.event.name,
      venue: l.event.venue,
      event_date: l.event.local_date,
      event_time: l.event.local_time ?? 'TBD',
      ...(eventId ? { event_id: Number(eventId) } : {}),
      quantity: l.quantity,
      cost: l.price,
      section: l.section,
      row: l.row,
      seat_from: l.seat_from,
      seat_thru: l.seat_thru,
      stock_type: 'mobile',
      is_edelivery: true,
      split_type: 'ANY',
      in_hand_date: l.in_hand_date,
      notes: l.notes,
    };
    return entryFor(l, { endpoint: 'createListing', method: 'PUT', path: `/listings/single/${encodeURIComponent(l.listing_id)}`, body });
  });
  return { channel: 'seatgeek', listings, per_order_cap: set.per_order_cap, unresolved };
}
