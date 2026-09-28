// Vivid Seats Broker Portal API shapes (OpenAPI 3.0.1, supplied by the
// operator 2026-09-28; docs/marketplace/vivid/README.md). Only the fields
// Exos uses are typed.

export type VividSplitType = 'DEFAULT' | 'ANY' | 'CUSTOM' | 'NEVERLEAVEONE';
export type VividStockType =
  | 'ELECTRONIC' | 'FLASH' | 'TMET' | 'MOBILE_SCREENCAP' | 'HARD' | 'PAPERLESS' | 'PAPERLESS_CARD' | 'PAPERLESS_WALKIN';

/** ManagedBrokerListingDoc (POST /listings/v2/create, PUT /listings/v2/update). */
export interface VividListing {
  /** Vivid's listing id: set by Vivid. Only a PUT carries it, read back by our ticketId. */
  id?: number;
  /** Vivid's event id (events/search eventId). Optional: without it the listing may wait on Vivid's mapping team. */
  productionId?: number;
  quantity: number;
  section: string;
  row: string;
  seatFrom?: string;
  seatThru?: string;
  notes?: string;
  /** Unit price. */
  price: number;
  /** Ours: the Exos listing id (Vivid calls it internalTicketId in queries, brokerTicketId on orders). */
  ticketId: string;
  electronic?: boolean;
  electronicTransfer?: boolean;
  /** date-time */
  inHandDate?: string;
  splitType?: VividSplitType;
  splitValue?: string;
  stockType?: VividStockType;
  faceValue?: number;
  instantTransfer?: boolean;
  hideSeats?: boolean;
  internalNotes?: string;
  /** Required with venue and eventDate. */
  eventName: string;
  venue: string;
  venueCity?: string;
  venueRegion?: string;
  venueCountryCode?: string;
  /** Venue-local date-time, no offset ("The eventDate timezone is the Venue local timezone"). */
  eventDate: string;
  priceCurrency?: string;
  [key: string]: unknown;
}

export interface VividInsertListingResponse {
  success?: boolean;
  message?: string;
  listing?: VividListing;
}

export interface VividListingsResponse {
  success?: boolean;
  message?: string;
  listings?: VividListing[];
}

export interface VividEvent {
  eventId: number;
  eventName?: string;
  /** date-time; the venue's local time (eventDateString alongside). */
  eventDate?: string;
  eventDateString?: string;
  venue?: { venueId?: number; name?: string; city?: string; state?: string; countryCode?: string; timezone?: string } | null;
  canSell?: boolean;
  url?: string;
  webPath?: string;
}

export type VividOrderStatus = 'UNCONFIRMED' | 'PENDING_SHIPMENT' | 'COMPLETED' | 'VERIFICATION' | 'PENDING_RESERVATION';

/** Order (v1, XML). Numbers arrive as text; orderFromXml() converts them. */
export interface VividOrder {
  orderId: number;
  orderToken?: string;
  /** Our ticketId: the Exos listing id. */
  brokerTicketId?: string;
  section?: string;
  row?: string;
  seats?: string[];
  notes?: string;
  quantity?: number;
  /** Per ticket: what the seller is paid. */
  cost?: number;
  event?: string;
  eventDate?: string;
  orderDate?: string;
  expectedShipDate?: string;
  venue?: string;
  status?: VividOrderStatus | string;
  listingId?: number;
  productionId?: number;
  eventId?: number;
  electronicDelivery?: boolean;
  transferViaURL?: boolean;
  firstName?: string;
  lastName?: string;
  emailAddress?: string;
  mobilePhoneNumber?: string;
  retransferEmail?: string;
  retransferPhone?: string;
  [key: string]: unknown;
}
