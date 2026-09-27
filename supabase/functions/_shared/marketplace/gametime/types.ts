// Gametime API v3 shapes (Swagger 2.0 "Gametime API" v3, supplied by the
// operator 2026-09-27; docs/marketplace/gametime/README.md). Money is USD
// cents. Datetimes come as "ISODate(2015-01-09T18:08:30.357Z)".

export type GametimePurchaseStatus = 'unconfirmed' | 'unfulfilled' | 'completed' | 'rejected';
export type GametimeDeliveryType = 'electronic' | 'instant' | 'barcode' | 'hard' | 'mobile' | 'flashseats';

/** Keys are seat numbers; values carry the barcode. */
export type GametimeSeatBarcodes = Record<string, { barcode?: string }>;

export interface GametimePurchase {
  /** The order number. */
  id: string;
  status?: GametimePurchaseStatus | string;
  created_at?: string;
  purchased_at?: string;
  quantity?: number;
  /** Our listing id (the CSV TicketID). */
  listing_reference_id?: string;
  /** USD cents. */
  price?: number;
  seats?: GametimeSeatBarcodes;
  /** The ticket recipient. */
  email?: string;
  phone?: string;
  first_name?: string;
  last_name?: string;
  delivery_type?: GametimeDeliveryType | string;
  event_id?: string;
  event_name?: string;
  event_date?: string;
  venue?: string;
  section?: string;
  row?: string;
}

export interface GametimePurchasesPage {
  results?: GametimePurchase[];
  page?: number;
  per_page?: number;
  /** Records actually returned. */
  page_size?: number;
}

/** The sales notification webhook body (money in cents). */
export interface GametimeSaleNotification {
  id: string;
  /** Our listing id. */
  source_id: string;
  quantity: number;
  unit_price?: number;
  payout?: number;
  event_id?: string;
  event_name?: string;
  event_date?: string;
  venue?: string;
  section?: string;
  row?: string;
  fulfill_type?: string;
  deal?: string;
}

/** POST /listings/{id}: quantity 0 removes the listing. */
export interface GametimeListingEdit {
  quantity: number;
  /** The purchasable quantities, e.g. [1, 2]. */
  lots: number[];
  tdc_verification_ids?: string[];
  tdc_ticket_ids?: string[];
  tdc_barcodes?: string[];
}
