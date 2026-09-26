// StubHub as a MarketplaceChannel (../channel.ts).
//   link    GET /catalog/events/search (q + local date), read-only
//   create  PUT /sellerevents (planned, see eventRequest.ts)
//   sell    Sale -> MarketplaceSale
//   fulfil  PATCH /sales/{id} with one claim URL per ticket (planned)

import {
  localDate,
  type EventCandidate,
  type ExosEventRef,
  type MarketplaceChannel,
  type MarketplaceSale,
  type PlannedRequest,
  type SaleStatus,
} from '../channel.ts';
import type { StubHubClient } from './client.ts';
import { planStubHubEventRequest } from './eventRequest.ts';
import { eticketUrlsRequest } from './fulfilment.ts';
import type { CatalogEvent, Sale } from './types.ts';

export function catalogEventToCandidate(e: CatalogEvent): EventCandidate {
  const venue = e._embedded?.venue;
  return {
    channel: 'stubhub',
    externalEventId: String(e.id),
    name: e.name,
    // StubHub's start_date carries the venue offset, so it's both an instant
    // and (its first 10 chars) the local date.
    startsAt: e.start_date ?? null,
    startsLocal: e.start_date ?? null,
    venueName: venue?.name ?? null,
    venueCity: venue?.city ?? null,
    url: e._links?.['event:webpage']?.href ?? null,
  };
}

// Sale statuses aren't enumerated in the spec; these are the ones seen in
// its descriptions. Anything else is 'unknown' and goes to a human.
const SALE_STATUS: Record<string, SaleStatus> = {
  pending: 'pending',
  pendingconfirmation: 'pending',
  confirmed: 'confirmed',
  pendingdelivery: 'confirmed',
  delivered: 'delivered',
  completed: 'delivered',
  cancelled: 'cancelled',
  canceled: 'cancelled',
  rejected: 'cancelled',
};

export function normalizeStubHubSale(raw: unknown): MarketplaceSale {
  const s = raw as Sale;
  if (!s || typeof s !== 'object' || s.id == null) throw new Error('not a StubHub sale');
  const status = SALE_STATUS[String(s.status ?? '').toLowerCase().replace(/[^a-z]/g, '')] ?? 'unknown';
  const eventId = s._embedded?.event?.id;
  return {
    channel: 'stubhub',
    externalOrderId: String(s.id),
    externalEventId: eventId != null ? String(eventId) : null,
    externalListingId: s.external_listing_id ?? null,
    quantity: Number(s.number_of_tickets) || 0,
    status,
    // Not on the sale itself: GET /sales/{id}/ticketholders -> buyerEmail().
    buyerEmail: null,
    proceeds: s.proceeds ? { amount: Number(s.proceeds.amount), currency: s.proceeds.currency_code } : null,
    confirmBy: s.confirm_by ?? null,
    shipBy: s.ship_by ?? null,
    createdAt: s.created_at ?? null,
    section: s.seating?.section ?? null,
    row: s.seating?.row ?? null,
  };
}

export function stubHubChannel(client?: StubHubClient): MarketplaceChannel {
  return {
    id: 'stubhub',
    label: 'StubHub',
    capabilities: { findEvents: !!client, createEvent: true, listings: true, fulfilByUrls: true },

    findEvents: client
      ? async (ev: ExosEventRef) => {
          const page = await client.searchEvents({ q: ev.name, dateLocal: localDate(ev), page_size: 20 });
          return (page._embedded?.items ?? []).map(catalogEventToCandidate);
        }
      : undefined,

    planCreateEvent(ev: ExosEventRef): PlannedRequest {
      // Same builder and error messages as the event-request queue.
      return {
        channel: 'stubhub',
        ...planStubHubEventRequest({
          name: ev.name,
          starts_at: ev.startsAt,
          venue_name: ev.venueName,
          venue_address: { city: ev.venueCity ?? '', region: ev.venueRegion ?? '', country: ev.countryCode ?? '' },
        }),
      };
    },

    normalizeSale: normalizeStubHubSale,

    planFulfilByUrls(sale: MarketplaceSale, claimUrls: string[]): PlannedRequest {
      return {
        channel: 'stubhub',
        endpoint: 'updateSale',
        method: 'PATCH',
        path: `/sales/${encodeURIComponent(sale.externalOrderId)}`,
        body: eticketUrlsRequest(claimUrls, sale.quantity),
      };
    },
  };
}
