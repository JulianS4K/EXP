// The Vivid Seats listings for a channel allocation: the Exos listings
// (../exosListing.ts: blocks of at most max per order, internal seats,
// stable "ex…" ids) as Vivid listings (ManagedBrokerListingDoc). Planned,
// not sent.
//
// Fields: ticketId = the Exos listing id (Vivid returns it on the order as
// brokerTicketId; Exos only addresses its listings by it), row "GA",
// seatFrom / seatThru = the block's internal seats with hideSeats on (GA
// buyers shouldn't see them), splitType / splitValue from the ticket type's
// split policy (../listingStandard.ts), stockType
// ELECTRONIC with electronicTransfer (delivered by URL transfer: the Exos
// claim link), price, faceValue, inHandDate = the event day.
// eventName, venue and eventDate (venue-local, no offset) are required;
// productionId is Vivid's event id when Exos has the event linked (pass 0,
// GET /events/search). Without it Vivid's mapping team matches the listing,
// which can take a while.

import { exosEventRef } from '../channel.ts';
import { EXOS_TRANSFER_STOCK, entryFor, planExosListings, requireCurrency, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';
import { assertListingId, commaSplits, marketSplitFor, splitFormatNotice } from '../listingStandard.ts';
import type { VividListing, VividSplitType } from './types.ts';

export type VividAllocation = ExosAllocation & {
  /** The linked Vivid event id (exos_channel_event_links), sent as productionId. */
  vividProductionId?: string | null;
};

export interface PlannedVividListings extends PlannedMarketplaceListings<VividListing> {
  channel: 'vivid';
}

export function planVividListings(a: VividAllocation): PlannedVividListings {
  const set = planExosListings(a, 'Vivid Seats', 'vivid');
  requireCurrency(set, 'USD', 'Vivid Seats');
  const ref = exosEventRef({ ...a.event!, id: a.event!.id ?? a.id })!;
  const pid = a.vividProductionId?.trim();
  const productionId = pid && /^\d+$/.test(pid) ? Number(pid) : undefined;
  const unresolved: string[] = [];
  if (productionId == null) unresolved.push("productionId: not linked to a Vivid event yet; Vivid's mapping team matches it (can be slow)");
  const notices = [...set.notices];
  const listings = set.listings.map((l) => {
    if (!l.event.local_time) throw new Error("Vivid Seats needs the venue-local start time: set the event's timezone");
    const split = marketSplitFor('vivid', l.split, l.quantity);
    const fmt = splitFormatNotice('vivid', split);
    if (fmt && !notices.includes(fmt)) notices.push(fmt);
    const body: VividListing = {
      ...(productionId != null ? { productionId } : {}),
      ticketId: assertListingId('vivid', l.listing_id),
      quantity: l.quantity,
      section: l.section,
      row: l.row,
      seatFrom: String(l.seat_from),
      seatThru: String(l.seat_thru),
      hideSeats: true,
      notes: l.notes,
      price: l.price,
      ...(l.face_value != null ? { faceValue: l.face_value } : {}),
      priceCurrency: 'USD',
      splitType: split.type as VividSplitType,
      ...(split.values ? { splitValue: commaSplits(split.values) } : {}),
      stockType: EXOS_TRANSFER_STOCK.vivid,
      electronic: true,
      electronicTransfer: true,
      inHandDate: `${l.in_hand_date}T00:00:00`,
      eventName: l.event.name,
      venue: l.event.venue,
      ...(ref.venueCity ? { venueCity: ref.venueCity } : {}),
      ...(ref.venueRegion ? { venueRegion: ref.venueRegion } : {}),
      ...(ref.countryCode ? { venueCountryCode: ref.countryCode } : {}),
      eventDate: `${l.event.local_date}T${l.event.local_time}`,
    };
    return entryFor(l, { endpoint: 'createListing', method: 'POST', path: '/listings/v2/create', body });
  });
  return { channel: 'vivid', listings, per_order_cap: set.per_order_cap, unresolved, notices };
}
