// StubHub API wire types (API v2.249.0.0, Catalog v1.0.0.75).
//
// Transcribed from the vendor reference in docs/marketplace/stubhub/. Only
// the fields the docs show on the top-level resources are typed; `_embedded`
// sub-resources are left loose because the printed samples collapse them.
// Every field is optional/nullable on the wire unless the docs mark it
// required, so treat these as "what StubHub may send", not guarantees.

export interface Money {
  amount: number | null;
  /** ISO 4217. */
  currency_code: string;
  /** Human-readable, e.g. "$120.00". */
  display?: string;
}

export interface MoneyInput {
  amount: number;
  currency_code: string;
}

export interface HalLink {
  href: string;
  templated?: boolean;
  title?: string;
}

export type HalLinks = Record<string, HalLink | undefined>;

/** Paged list envelope. Catalog lists also carry `deleted_items`. */
export interface Page<T> {
  total_items: number | null;
  page: number | null;
  page_size: number | null;
  _links?: HalLinks;
  _embedded?: {
    items?: T[] | null;
    deleted_items?: unknown[] | null;
  };
}

/** Error body on 4xx/5xx. `errors` maps a property name to messages. */
export interface ApiErrorBody {
  code?: string;
  message?: string;
  errors?: Record<string, string[]> | null;
}

/** BarcodeInformation2 (request side): barcodes for one seat. */
export interface BarcodeInformation {
  seat_ordinal?: number | null;
  seat?: string | null;
  row?: string | null;
  barcode_values?: string[] | null;
}

export interface Seating {
  section?: string | null;
  row?: string | null;
  seat_from?: string | null;
  seat_to?: string | null;
}

// ── Catalog ────────────────────────────────────────────────────────────

export interface CatalogEvent {
  id: number;
  name: string;
  start_date: string;
  end_date?: string | null;
  on_sale_date?: string | null;
  date_confirmed?: boolean;
  time_confirmed?: boolean;
  type?: string | null;
  status?: string | null;
  min_ticket_price?: Money | null;
  _links?: HalLinks;
  _embedded?: {
    categories?: unknown[];
    external_mappings?: unknown[];
    genre?: unknown;
    merged_events?: unknown[];
    venue?: Venue;
  };
}

export interface Venue {
  id: number;
  name: string;
  city?: string | null;
  state_province?: string | null;
  postal_code?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  _links?: HalLinks;
  _embedded?: { country?: unknown; external_mappings?: unknown[] };
}

export interface CatalogPageQuery {
  page?: number;
  page_size?: number;
  updated_since?: Date | string;
  /** Only `resource_version` is documented for catalog lists. */
  sort?: string;
  min_resource_version?: number;
}

export interface EventFilterQuery extends CatalogPageQuery {
  country_code?: string;
  latitude?: number;
  longitude?: number;
  max_distance_in_meters?: number;
  genre_id?: number;
  exclude_parking_passes?: boolean;
}

export interface EventSearchQuery extends EventFilterQuery {
  q?: string;
  date?: Date | string;
}

export interface VenueQuery extends CatalogPageQuery {
  country_code?: string;
}

/** Body of POST /catalog/mapevent. */
export interface MapEventRequest {
  event_name: string;
  local_date: Date | string;
  venue_name?: string;
  venue_city?: string;
  venue_state?: string;
  venue_country?: string;
  category_name?: string | null;
}

export interface MapEventResult {
  EventResource?: CatalogEvent | null;
  VenueResource?: Venue | null;
  Category?: unknown;
  [key: string]: unknown;
}

// ── Inventory ──────────────────────────────────────────────────────────

export interface SellerListing {
  id: number;
  created_at: string;
  updated_at?: string;
  number_of_tickets: number;
  display_number_of_tickets?: number;
  seating?: Seating | null;
  display_seating?: Seating | null;
  ticket_price?: Money | null;
  ticket_proceeds?: Money | null;
  face_value?: Money | null;
  purchase_price_per_ticket?: Money | null;
  total_purchase_price?: Money | null;
  /** Our id for the listing (set to the Exos distribution row id). */
  external_id?: string | null;
  expires_at?: string | null;
  in_hand_at?: string | null;
  instant_delivery?: boolean;
  undeliverable?: boolean;
  is_ticket_concierge?: boolean;
  is_auto_po?: boolean;
  sales_tax_paid?: boolean;
  barcodes?: BarcodeInformation[] | null;
  _links?: HalLinks;
  _embedded?: Record<string, unknown>;
}

export interface SellerListingQuery {
  event_id?: number;
  requested_event_id?: string;
  page?: number;
  page_size?: number;
  updated_since?: Date | string;
  /** created_at, event_date, price, … (see inventory reference). */
  sort?: string;
}

/** Body for the listing *preview* endpoints (nothing is created). */
export interface SellerListingDraft {
  ticket_price?: MoneyInput;
  ticket_proceeds?: MoneyInput;
  face_value?: MoneyInput;
  seating?: Seating & { hide_seat_details?: boolean };
  ticket_type?: string;
  split_type?: string;
  number_of_tickets?: number;
  display_number_of_tickets?: number;
  in_hand_at?: Date | string;
  external_id?: string;
  notes?: string;
  instant_delivery?: boolean;
}

export interface SellerEvent {
  id: number;
  name?: string;
  start_date?: string;
  _links?: HalLinks;
  _embedded?: Record<string, unknown>;
  [key: string]: unknown;
}

// ── Sales ──────────────────────────────────────────────────────────────

export interface Sale {
  id: number;
  created_at: string;
  number_of_tickets: number;
  status: string;
  status_description?: string | null;
  seating?: Seating | null;
  proceeds?: Money | null;
  display_proceeds?: Money | null;
  confirm_by?: string | null;
  ship_by?: string | null;
  in_hand_at?: string | null;
  external_listing_id?: string | null;
  is_legacy_stubhub_order?: boolean;
  barcodes?: unknown[] | null;
  _links?: HalLinks;
  _embedded?: {
    delivery_method?: unknown;
    event?: CatalogEvent;
    ticket_type?: unknown;
    ticketholders?: unknown[];
    venue?: Venue;
  };
}

export interface SaleQuery {
  page?: number;
  page_size?: number;
  updated_since?: Date | string;
  /** created_at, event_date, inhand_at, payment_amount, quantity, resource_version. */
  sort?: string;
}

/** GET /sales/{saleId}/ticketholders (identity fields depend on the event). */
export interface TicketHolder {
  id?: number | null;
  title?: string | null;
  full_name?: string | null;
  email_address?: string | null;
  date_of_birth?: string | null;
  document_type?: string | null;
  document_number?: string | null;
  [key: string]: unknown;
}

export interface Payment {
  /** Absent on the `payments/next` preview. */
  id?: number;
  created_at: string;
  number_of_sales: number;
  payment_amount?: Money | null;
  credits?: Money | null;
  charges?: Money | null;
  proceeds?: Money | null;
  _links?: HalLinks;
  _embedded?: { payment_method?: unknown; sales?: Sale[] };
}

// ── Account / webhooks ─────────────────────────────────────────────────

export interface StubHubUser {
  id?: number;
  [key: string]: unknown;
}

export interface Webhook {
  id: number;
  name: string | null;
  url: string | null;
  topics: string[] | null;
  created_at: string;
  /** Echoed back on every delivery; see webhook.ts. */
  authorization_header?: string | null;
  _links?: HalLinks;
}
