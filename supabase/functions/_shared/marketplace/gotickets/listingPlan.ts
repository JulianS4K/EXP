// The GoTickets listings for a channel allocation: the Exos listings
// (../exosListing.ts: blocks of at most max per order, internal seats,
// stable "ex…" ids) as GoTickets listings. Planned, not sent.
//
// Fields (Listing schema): externalTicketId = the Exos listing id (GoTickets
// passes it through; Exos only ever addresses its listings by it), row "GA"
// (max 20), lowSeat / highSeat = the block's internal seats, splitType ANY
// within the block, stockType MOBILE_TICKETS (the buyer gets a transfer URL:
// the Exos claim link), price = the listing price, faceValue = the ticket
// type's price, inHandDate = the event day. No eventId: GoTickets maps a
// listing to its event from eventName / venueName / eventDateTime, helped by
// the StubHub / SeatGeek event ids when Exos has them linked. Until it does,
// the listing is "unmapped" (still addressable by externalTicketId).

import { EXOS_TRANSFER_STOCK, entryFor, planExosListings, requireCurrency, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';
import type { GoTicketsListing } from './types.ts';

export type GoTicketsAllocation = ExosAllocation & {
  /** Linked marketplace event ids (exos_channel_event_links), to help GoTickets map the event. */
  stubhubEventId?: string | null;
  seatgeekEventId?: string | null;
};

export interface PlannedGoTicketsListings extends PlannedMarketplaceListings<GoTicketsListing> {
  channel: 'gotickets';
}

export function planGoTicketsListings(a: GoTicketsAllocation): PlannedGoTicketsListings {
  const set = planExosListings(a, 'GoTickets');
  requireCurrency(set, 'USD', 'GoTickets');
  const sh = a.stubhubEventId?.trim();
  const sg = a.seatgeekEventId?.trim();
  const listings = set.listings.map((l) => {
    const body: GoTicketsListing = {
      externalTicketId: l.listing_id,
      section: l.section.slice(0, 200),
      row: l.row,
      lowSeat: String(l.seat_from),
      highSeat: String(l.seat_thru),
      notes: l.notes,
      quantity: l.quantity,
      instant: false,
      splitType: 'ANY',
      inHandDate: l.in_hand_date,
      stockType: EXOS_TRANSFER_STOCK.gotickets,
      ...(l.face_value != null ? { faceValue: l.face_value } : {}),
      price: l.price,
      eventName: l.event.name,
      venueName: l.event.venue,
      eventDateTime: new Date(l.event.starts_at).toISOString(),
      ...(sh ? { stubhubEventId: sh } : {}),
      ...(sg ? { seatgeekEventId: sg } : {}),
    };
    return entryFor(l, { endpoint: 'createListings', method: 'POST', path: '/rest/listings', body });
  });
  return {
    channel: 'gotickets',
    listings,
    per_order_cap: set.per_order_cap,
    unresolved: ['eventId: GoTickets maps the listing to its event itself (unmapped until it does)'],
  };
}
