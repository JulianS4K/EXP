// The StubHub listing for a channel allocation (mig 20260926193000), planned,
// not sent: one listing per allocation, showing buyers at most the event's
// max-per-order at a time (display_number_of_tickets), so a single order
// can't take the whole allocation.
//
// Route: when the event is linked to a StubHub event, POST
// /events/{id}/sellerlistings; otherwise the requested-event listing, POST
// /sellerlistings, which also asks StubHub to create the event.
//
// ticket_type is left null in the plan: StubHub lists the accepted types per
// event (listing constraints), and pickTicketType() chooses from those at
// send time (ticket transfer, then mobile transfer). A plan never carries a
// guessed value.

import { exosEventForListing, type ExosEventRow } from './eventRequest.ts';
import {
  buildCreateListingRequest,
  buildRequestedEventListingRequest,
  EXOS_TICKET_TYPE_PREFERENCE,
  maxPerOrderFromLimits,
  type ListingDetails,
} from './listing.ts';

export interface AllocationForListing {
  /** exos_distribution_listings.id: the listing's external_id. */
  id: string;
  requested_qty: number | null;
  unit_price: number | string | null;
  tier: { name: string; price: number | string; section_label?: string | null } | null;
  event: (ExosEventRow & { currency?: string | null; purchase_limits?: unknown }) | null;
  /** The linked StubHub event id (exos_channel_event_links), if any. */
  stubhubEventId?: string | null;
}

export interface PlannedListing {
  endpoint: 'createSellerListing' | 'createSellerListingForRequestedEvent';
  method: 'POST';
  path: string;
  body: Record<string, unknown>;
  /** How many a buyer sees (and can take) at once; null = the whole listing. */
  display_cap: number | null;
  ticket_type_from: string[];
}

export function planStubHubListing(a: AllocationForListing): PlannedListing {
  if (!a.tier) throw new Error('the allocation has no ticket type');
  if (!a.event) throw new Error('event not found');
  const qty = a.requested_qty ?? 0;
  const price = a.unit_price ?? a.tier.price;
  const details: ListingDetails = {
    // Placeholder so the builder validates the rest; nulled below.
    ticketType: EXOS_TICKET_TYPE_PREFERENCE[0],
    // Don't strand a single seat, when there's more than one to sell.
    splitType: qty >= 2 ? 'AvoidOne' : 'Any',
    section: (a.tier.section_label || a.tier.name || '').trim(),
    currency: (a.event.currency || 'USD').toUpperCase(),
    maxPerOrder: maxPerOrderFromLimits(a.event.purchase_limits),
    published: false,
  };
  const row = { id: a.id, channel: 'stubhub', requested_qty: qty, unit_price: price };
  const known = a.stubhubEventId?.trim();
  const body = (known
    ? buildCreateListingRequest(row, details)
    : buildRequestedEventListingRequest(row, details, exosEventForListing(a.event))) as unknown as Record<string, unknown>;
  body.ticket_type = null;
  return {
    endpoint: known ? 'createSellerListing' : 'createSellerListingForRequestedEvent',
    method: 'POST',
    path: known ? `/events/${encodeURIComponent(known)}/sellerlistings` : '/sellerlistings',
    body,
    display_cap: typeof body.display_number_of_tickets === 'number' ? body.display_number_of_tickets : null,
    ticket_type_from: [...EXOS_TICKET_TYPE_PREFERENCE],
  };
}
