// SeatGeek Seller Direct API shapes, from the vendor spec (Seller Direct API
// 1.0.0, OAS3; docs/marketplace/seatgeek/README.md). Field comments are the
// spec's own descriptions. Most fields are optional in practice.

export interface ListingToken {
  seat: number;
  /** The barcode. */
  token: string;
}

/** SingleListing (MultipleListings.listings[] has the same shape). */
export interface SeatGeekListing {
  /** The cost of the ticket (the list price). */
  cost?: number;
  /** The name of the event. */
  event?: string;
  event_date?: string;
  /** The SeatGeek Event ID that should be attached to the listing. */
  event_id?: number;
  event_time?: string;
  /** The date the ticket will be delivered by. */
  in_hand_date?: string;
  is_edelivery?: boolean;
  is_instant?: boolean;
  notes?: string;
  /** The number of tickets available. */
  quantity?: number;
  row?: string;
  seat_from?: number;
  seat_thru?: number;
  section?: string;
  seller_listing_id?: string;
  /** The price the seller paid for the ticket. */
  seller_previously_paid_price_per_ticket?: number;
  seller_subaccount_id?: string;
  /** The internal SeatGeek listing ID. */
  sg_listing_id?: number;
  /** The type of possible splits on the listing. */
  split_type?: string;
  /** The possible splits on the listing. */
  splits?: string;
  /** The type of ticket. */
  stock_type?: string;
  /** Deprecated: renamed to seller_listing_id. */
  ticket_id?: string;
  tokens?: ListingToken[];
  tokens_type?: string;
  venue?: string;
  /** Reads return barcodes here (listing guide), writes send `tokens`. */
  barcodes?: Array<{ seat: number; barcode: string }>;
}

/** split_type values seen in the listing guide. CUSTOM uses `splits` ("1,2,3"). */
export const SEATGEEK_SPLIT_TYPES = ['ANY', 'CUSTOM', 'DONTLEAVEONE'] as const;
/** stock_type values seen in the guide. An integrated event forces "barcode". */
export const SEATGEEK_STOCK_TYPES_SEEN = ['mobile', 'pdf', 'barcode'] as const;

export interface ListingsPage {
  listings: SeatGeekListing[];
  meta: {
    current_page?: string;
    next_page?: string | null;
    per_page?: number;
    previous_page?: string;
    status?: number;
    total?: number;
  };
}

export interface SeatGeekOrder {
  created?: string;
  /** Deprecated in favour of delivery_method. */
  delivery?: string;
  delivery_method?: string;
  event?: {
    date?: string;
    name?: string;
    seatgeek_event_id?: number;
    time?: string;
    venue?: string;
  };
  fees?: number;
  /** A message indicating a fulfillment issue with the order needing attention. */
  fulfillment_issue_message?: string;
  id: string;
  listing?: {
    /** The listing ID provided by the seller (our seller_listing_id). */
    id?: string;
    price?: number;
    quantity?: number;
    row?: string;
    section?: string;
  };
  /** e.g. "confirmed". Not enumerated in the spec. */
  status?: string;
  stock_type?: string;
  subtotal?: number;
  /** The total, less fees (subtotal - fees). What the seller is paid. */
  total?: number;
  transfer_urls?: string[];
  updated?: string;
}

export interface OrdersPage {
  meta: { page?: number; per_page?: number; status?: number; total?: number };
  orders: SeatGeekOrder[];
}

export interface SeatGeekCustomer {
  email?: string;
  first_name?: string;
  last_name?: string;
  phone?: string;
}

export interface SeatGeekInvoice {
  end_date?: number;
  id: string;
  start_date?: number;
  total?: number;
  total_fees?: number;
  total_finance?: number;
  total_order_value?: number;
  total_shipping_costs?: number;
}

export interface SeatGeekCharge {
  amount?: number;
  category?: string;
  comment?: string;
  order_id?: string;
  reason?: string;
  type?: string;
}

export interface SeatGeekDetailedInvoice extends SeatGeekInvoice {
  charges?: SeatGeekCharge[];
}

export interface CurrentRemittance {
  category_sub_totals?: Array<{ amount?: number; name?: string }>;
  end_date_lt?: number;
  start_date_gte?: number;
  total?: number;
  updated_at?: number;
}

export interface PurgeStatus {
  /** RUNNING or NOT_STARTED. */
  status?: string;
}

/** PUT /v3/order body. */
export interface FulfilOrderRequest {
  order_id: string;
  files?: Array<{ file: string }>;
  tokens?: Array<{ seat: string; token: string }>;
  tokens_type?: string;
}

/** POST /v3/order/proofs body. */
export interface OrderProofsInitRequest {
  order_id: string;
  proof_type: 'transfer';
  /** 1 to 10 files; gif, png, jpg, jpeg, pdf, txt or json. */
  files: Array<{ file_name: string }>;
}
