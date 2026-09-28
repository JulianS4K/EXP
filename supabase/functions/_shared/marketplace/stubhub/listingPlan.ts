// The StubHub listings for a channel allocation: the Exos listings
// (../exosListing.ts: blocks of at most max per order, internal seats,
// stable "ex…" ids) as StubHub seller listings. Planned, not sent.
//
// Standardized with SeatGeek and Gametime (was: one listing per allocation
// showing buyers at most max per order through display_number_of_tickets,
// which StubHub doesn't document as a purchase cap). Each block is its own
// listing: external_id the Exos listing id, seating section / row "GA" /
// seat_from–seat_to the block's internal seats, split_type from the ticket
// type's split policy (../listingStandard.ts: Any / AvoidOne / Pairs / None).
//
// Route: when the event is linked to a StubHub event, POST
// /events/{id}/sellerlistings; otherwise the requested-event listing, POST
// /sellerlistings, which also asks StubHub to create the event.
//
// ticket_type is left null in the plan: StubHub lists the accepted types per
// event (listing constraints), and pickTicketType() chooses from those at
// send time (mobile transfer, then electronic transfer). A plan never carries a
// guessed value. Listings are created unpublished.

import { exosEventForListing, type ExosEventRow } from './eventRequest.ts';
import {
  buildCreateListingRequest,
  buildRequestedEventListingRequest,
  EXOS_TICKET_TYPE_PREFERENCE,
  type ListingDetails,
} from './listing.ts';
import { assertListingId, marketSplitFor } from '../listingStandard.ts';
import { entryFor, planExosListings, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';

export type AllocationForListing = ExosAllocation & {
  event: (ExosEventRow & { currency?: string | null; purchase_limits?: unknown }) | null;
  /** The linked StubHub event id (exos_channel_event_links), if any. */
  stubhubEventId?: string | null;
};

export interface PlannedListing extends PlannedMarketplaceListings<Record<string, unknown>> {
  channel: 'stubhub';
  ticket_type_from: string[];
}

export function planStubHubListing(a: AllocationForListing): PlannedListing {
  const set = planExosListings(a, 'StubHub');
  const known = a.stubhubEventId?.trim();
  const requested = known ? null : exosEventForListing(a.event!);
  const listings = set.listings.map((l) => {
    const details: ListingDetails = {
      // Placeholder so the builder validates the rest; nulled below.
      ticketType: EXOS_TICKET_TYPE_PREFERENCE[0],
      splitType: marketSplitFor('stubhub', l.split, l.quantity).type as ListingDetails['splitType'],
      section: l.section,
      row: l.row,
      seatFrom: String(l.seat_from),
      seatTo: String(l.seat_thru),
      currency: l.currency,
      ...(l.face_value != null ? { faceValue: l.face_value } : {}),
      notes: l.notes,
      published: false,
    };
    const row = { id: assertListingId('stubhub', l.listing_id), channel: 'stubhub', requested_qty: l.quantity, unit_price: l.price };
    const body = (requested
      ? buildRequestedEventListingRequest(row, details, requested)
      : buildCreateListingRequest(row, details)) as unknown as Record<string, unknown>;
    body.ticket_type = null;
    return entryFor(l, known
      ? { endpoint: 'createSellerListing', method: 'POST', path: `/events/${encodeURIComponent(known)}/sellerlistings`, body }
      : { endpoint: 'createSellerListingForRequestedEvent', method: 'POST', path: '/sellerlistings', body });
  });
  return {
    channel: 'stubhub',
    listings,
    per_order_cap: set.per_order_cap,
    unresolved: [],
    notices: set.notices,
    ticket_type_from: [...EXOS_TICKET_TYPE_PREFERENCE],
  };
}
