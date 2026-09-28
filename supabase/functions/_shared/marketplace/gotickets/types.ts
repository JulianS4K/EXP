// GoTickets Seller Central API v1 shapes (OpenAPI 3.0.1, supplied by the
// operator 2026-09-28; docs/marketplace/gotickets/README.md). Only the fields
// Exos uses are typed.

export type GoTicketsSplitType = 'DEFAULT' | 'ANY' | 'NEVER_LEAVE_ONE' | 'CUSTOM' | 'NO_SPLIT';
export type GoTicketsStockType = 'HARD' | 'MOBILE_TICKETS' | 'PRINT_AT_HOME' | 'WALK_IN' | 'AXS_TRANSFER';

/** A listing (required: externalTicketId, price, row, splitType, stockType). */
export interface GoTicketsListing {
  /** GoTickets' id: set by GoTickets. Exos never sends it (it addresses listings by externalTicketId). */
  id?: number;
  eventId?: number;
  /** Ours, max 100 chars: the Exos listing id. */
  externalTicketId: string;
  section?: string;
  /** Max 20 chars. */
  row: string;
  lowSeat?: string;
  highSeat?: string;
  notes?: string;
  quantity?: number;
  instant?: boolean;
  splitType: GoTicketsSplitType;
  splitValuesSet?: number[];
  /** YYYY-MM-DD */
  inHandDate?: string;
  stockType: GoTicketsStockType;
  faceValue?: number;
  /** Unit asking price. */
  price: number;
  /** For GoTickets' own event mapping when eventId isn't given. */
  eventName?: string;
  venueName?: string;
  eventDateTime?: string;
  stubhubEventId?: string;
  seatgeekEventId?: string;
}

export interface GoTicketsMutateListingResponse {
  mappedListings?: GoTicketsListing[];
  /** Not yet matched to a GoTickets event: only addressable by externalTicketId until GoTickets maps them. */
  unmappedListings?: GoTicketsListing[];
  errors?: Array<{ listing?: GoTicketsListing; errors?: string[] }>;
}

export type GoTicketsSellerStatus =
  | 'NONE' | 'UNCONFIRMED' | 'PENDING_FULFILLMENT' | 'COMPLETED' | 'PENDING_RETRANSFER' | 'PENDING_TRANSFER_PROOF'
  | 'PENDING_UPGRADE_APPROVAL' | 'PENDING_UPGRADE_FULFILLMENT' | 'PENDING_CUSTOMER_PICKUP' | 'PENDING_PROOF_OF_PICKUP' | 'FRAUD_HOLD';

export interface GoTicketsSale {
  /** The order id. */
  id: number;
  createTime?: string;
  deliveryMethod?: string;
  sellerStatus?: GoTicketsSellerStatus | string;
  cancelReason?: 'REJECTED' | 'CANCELLED' | null;
  quantity?: number;
  section?: string;
  row?: string;
  lowSeat?: string;
  highSeat?: string;
  listingId?: number;
  /** Our listing id. */
  externalTicketId?: string;
  stockType?: string;
  event?: { id?: number; name?: string; eventTimeUtc?: string } | null;
  customerFirstName?: string;
  customerLastName?: string;
  customerEmailAddress?: string;
  customerPhoneNumber?: string;
  totalPayout?: number;
  fulfilled?: boolean;
  [key: string]: unknown;
}

export type GoTicketsWebhookType =
  | 'HOLD' | 'IN_HAND_DATE_CHANGE_REQUEST' | 'ORDER_CANCELLED' | 'ORDER_EMAIL_ADDRESS_UPDATED'
  | 'PURCHASE_CONFIRMED' | 'PURCHASE_FULFILLED' | 'RETRANSFER' | 'SALE';

/** What GoTickets POSTs to a webhook target (WebhookBasePayload). */
export interface GoTicketsWebhookPayload {
  id: string;
  externalTicketId?: string;
  section?: string;
  row?: string;
  payout?: number;
  quantity?: number;
  deliveryMethod?: string;
  createTime?: string;
  type: GoTicketsWebhookType | string;
}

/** POST /rest/sales/{orderId}/fulfill */
export interface GoTicketsFulfillment {
  method: 'SUBMIT_TRANSFER_URL';
  transferUrl: string[];
}
