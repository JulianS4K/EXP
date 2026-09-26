// Listing creation, step 1 of the write foundation: request shapes, the
// Exos → StubHub mapping, and a pre-flight check against StubHub's listing
// constraints. Pure: nothing here talks to the network.
//
// Shapes verified against StubHub's OpenAPI specs (docs/marketplace/stubhub/
// openapi/inventory.json) and guides/creating-a-listing.mdx.
//
// Two ways to create a listing:
//   • For a *requested* event (POST /sellerlistings), StubHub's recommended
//     route: we send the event and venue as text and StubHub maps it, or
//     creates the event asynchronously if it doesn't have it. That fits Exos
//     primary events, which usually aren't in StubHub's catalog yet.
//   • For a known StubHub event (POST /events/{id}/sellerlistings), once the
//     event is in bridge_event_xref.
//
// `external_id` (our distribution row id) is StubHub's de-dup key: creating
// with an external_id that already exists makes StubHub DELETE the old
// listing and create a new one. writer.createOrAdopt* looks it up first so
// a retry doesn't churn a live listing.
//
// Flow once writes are authorized (see writer.ts):
//   1. constraints: client.getRequestedEventListingConstraints(buildRequestedEvent(ev))
//      (or listEventListingConstraints(id) for a known event)
//   2. ticketType = pickTicketType(constraints)       → ticket / mobile transfer
//   3. build*ListingRequest(exos row, { ticketType, … }, ev)
//      then checkListingConstraints(request, constraints)
//   4. preview: client.previewSellerListing[ForRequestedEvent](…)
//   5. writer.createOrAdopt*(…)                       → dry-run plan, or live call
//
// Event creation on its own: writer.requestEvent(buildRequestedEvent(ev))
// (PUT /sellerevents). The requested-event listing create also creates the
// event implicitly, so requestEvent is only needed to create an event
// before listing on it.

import type { BarcodeInformation, Money, MoneyInput, Seating } from './types';

/** `split_type` values, from the SplitType schema. */
export const SPLIT_TYPES = ['Any', 'None', 'AvoidOne', 'AvoidOneAndThree', 'Pairs'] as const;
export type SplitType = (typeof SPLIT_TYPES)[number];

export interface SeatingRequest extends Seating {
  hide_seat_details?: boolean;
}

/** Body of POST /events/{eventId}/sellerlistings. */
export interface CreateSellerListingRequest {
  // Required by the docs.
  seating: SeatingRequest;
  /** Per-event value from the constraints' ticket_types[].type; Exos uses pickTicketType(). */
  ticket_type: string;
  split_type: SplitType;
  number_of_tickets: number;
  // Price: send ticket_price (buyer-facing) or ticket_proceeds (seller net).
  ticket_price?: MoneyInput;
  ticket_proceeds?: MoneyInput;
  face_value?: MoneyInput;
  display_number_of_tickets?: number;
  ticket_location_address_id?: number;
  listing_note_ids?: number[];
  in_hand_at?: string;
  /** exos_distribution_listings.id. StubHub replaces any listing with the same external_id. */
  external_id: string;
  notes?: string;
  instant_delivery?: boolean;
  published?: boolean;
  lms_optin?: boolean;
  eticket_ids?: number[];
  purchase_price_per_ticket?: MoneyInput;
  total_purchase_price?: MoneyInput;
  sales_tax_paid?: boolean;
  external_event_information?: ExternalEventInformation[];
  barcodes?: BarcodeInformation[];
}

export interface ExternalEventInformation {
  /** int32 on StubHub's side, so Exos uuids can't go here. */
  id: number;
  platform?: string;
  url?: string;
  venue_id?: number;
  performer_id?: number;
}

/** Body of POST /sellerlistings (create for a requested event). */
export type CreateRequestedEventListingRequest = CreateSellerListingRequest & RequestedEvent;

/**
 * Body of PATCH /sellerlistings/{id}. StubHub blanks any seating field left
 * out of a PATCH, so `seating` must be sent whole or not at all.
 */
export type UpdateSellerListingRequest = Partial<Omit<CreateSellerListingRequest, 'external_id'>>;

/** GET /events/{eventId}/listingconstraints (and the per-listing variant). */
export interface ListingConstraints {
  min_ticket_price?: Money | null;
  max_ticket_price?: Money | null;
  min_number_of_tickets?: number | null;
  max_number_of_tickets?: number | null;
  ticket_location_required?: boolean | null;
  seats_required?: boolean | null;
  /** Valid sections/rows; empty means any text is accepted. */
  sections?: unknown[] | null;
  primary_order_id_required?: boolean | null;
  home_or_away_required?: boolean | null;
  _embedded?: {
    /** { type: SplitType, name, description } */
    split_types?: unknown[];
    /** { type, name, id } */
    ticket_types?: unknown[];
    /** { code, name, symbol, decimal_places } */
    currencies?: unknown[];
    listing_notes?: unknown[];
    [key: string]: unknown;
  };
}

// ── Exos → StubHub mapping ───────────────────────────────────────────

/** The subset of an exos_distribution_listings row the mapping needs. */
export interface ExosDistributionRow {
  id: string;
  channel: string;
  requested_qty: number | null;
  unit_price: number | string | null;
}

export interface ListingDetails {
  /** From pickTicketType(constraints): the event's ticket-transfer / mobile-transfer type. */
  ticketType: string;
  splitType: SplitType;
  section: string;
  row?: string;
  seatFrom?: string;
  seatTo?: string;
  currency: string;
  /**
   * What `unit_price` means. Exos organizers set the price the buyer pays,
   * so the default is `ticket_price`; use `ticket_proceeds` to pin our net.
   */
  priceAs?: 'ticket_price' | 'ticket_proceeds';
  faceValue?: number;
  inHandAt?: Date | string;
  instantDelivery?: boolean;
  /** Default false: create unpublished, publish after a human looks at it. */
  published?: boolean;
  notes?: string;
}

export class ListingMappingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ListingMappingError';
  }
}

const money = (amount: number, currency_code: string): MoneyInput => ({
  amount: Math.round(amount * 100) / 100,
  currency_code,
});

export function buildCreateListingRequest(row: ExosDistributionRow, d: ListingDetails): CreateSellerListingRequest {
  if (row.channel !== 'stubhub') {
    throw new ListingMappingError(`distribution row ${row.id} is for channel "${row.channel}", not stubhub`);
  }
  const qty = row.requested_qty;
  if (qty == null || !Number.isInteger(qty) || qty <= 0) {
    throw new ListingMappingError(`distribution row ${row.id}: requested_qty must be a positive integer`);
  }
  const price = row.unit_price == null ? NaN : Number(row.unit_price);
  if (!Number.isFinite(price) || price <= 0) {
    throw new ListingMappingError(`distribution row ${row.id}: unit_price must be a positive number`);
  }
  if (!/^[A-Z]{3}$/.test(d.currency)) throw new ListingMappingError(`currency must be ISO 4217, got "${d.currency}"`);
  if (!d.section.trim()) throw new ListingMappingError('section is required');
  if (!(SPLIT_TYPES as readonly string[]).includes(d.splitType)) {
    throw new ListingMappingError(`split type must be one of ${SPLIT_TYPES.join(', ')}, got "${d.splitType}"`);
  }
  if (!d.ticketType.trim()) throw new ListingMappingError('ticket type is required');

  const req: CreateSellerListingRequest = {
    external_id: row.id,
    number_of_tickets: qty,
    ticket_type: d.ticketType,
    split_type: d.splitType,
    seating: {
      section: d.section,
      row: d.row ?? null,
      seat_from: d.seatFrom ?? null,
      seat_to: d.seatTo ?? null,
    },
    [d.priceAs ?? 'ticket_price']: money(price, d.currency),
    published: d.published ?? false,
  };
  if (d.faceValue != null) req.face_value = money(d.faceValue, d.currency);
  if (d.inHandAt != null) req.in_hand_at = d.inHandAt instanceof Date ? d.inHandAt.toISOString() : d.inHandAt;
  if (d.instantDelivery != null) req.instant_delivery = d.instantDelivery;
  if (d.notes) req.notes = d.notes;
  return req;
}

/** The Exos event, as StubHub's requested-event endpoints need it. */
export interface ExosEventForListing {
  name: string;
  startsAt: Date | string;
  venueName: string;
  venueCity: string;
  venueStateProvince?: string;
  /** Two-letter ISO 3166, e.g. "US". */
  countryCode?: string;
  /** Default true: Exos events have a fixed start. */
  dateConfirmed?: boolean;
}

/**
 * PutRequestedEventRequest: the body of both PUT /sellerevents (ask StubHub
 * to create the event) and PUT /listingconstraints (constraints for it).
 */
export interface RequestedEvent {
  event: { name: string; start_date: string; date_confirmed?: boolean; note?: string };
  venue: { name: string; city: string; state_province?: string };
  /** Two-letter ISO 3166. */
  country?: { code: string };
}

export function buildRequestedEvent(ev: ExosEventForListing): RequestedEvent {
  const start = ev.startsAt instanceof Date ? ev.startsAt : new Date(ev.startsAt);
  if (Number.isNaN(start.getTime())) throw new ListingMappingError('event start is not a date');
  if (!ev.name.trim()) throw new ListingMappingError('event name is required');
  if (!ev.venueName.trim() || !ev.venueCity.trim()) throw new ListingMappingError('venue name and city are required');
  if (ev.countryCode != null && !/^[A-Z]{2}$/.test(ev.countryCode)) {
    throw new ListingMappingError(`country must be ISO 3166 alpha-2, got "${ev.countryCode}"`);
  }
  const req: RequestedEvent = {
    event: { name: ev.name.trim(), start_date: start.toISOString(), date_confirmed: ev.dateConfirmed ?? true },
    venue: { name: ev.venueName.trim(), city: ev.venueCity.trim() },
  };
  if (ev.venueStateProvince) req.venue.state_province = ev.venueStateProvince;
  if (ev.countryCode) req.country = { code: ev.countryCode };
  return req;
}

export function buildRequestedEventListingRequest(
  row: ExosDistributionRow,
  d: ListingDetails,
  ev: ExosEventForListing,
): CreateRequestedEventListingRequest {
  return { ...buildCreateListingRequest(row, d), ...buildRequestedEvent(ev) };
}

// ── Ticket type ──────────────────────────────────────────────────────

/**
 * Exos lists tickets as a transfer (decided 2026-09-26): ticket transfer
 * first, mobile transfer second. StubHub doesn't enumerate ticket_type
 * values; each event's constraints list what it accepts. So we never send a
 * guessed string: `pickTicketType` returns the constraint's own `type`.
 */
export const EXOS_TICKET_TYPE_PREFERENCE = ['TicketTransfer', 'MobileTransfer'] as const;

const squashType = (s: string) => s.toLowerCase().replace(/[^a-z]/g, '');

/**
 * The first preferred type the event accepts, matched on the constraint's
 * `type` or display `name` ignoring case, spaces and punctuation ("Mobile
 * Transfer", "mobile_transfer" and "MobileTransfer" all match). Throws with
 * the available types when none match, so a human picks rather than us.
 */
export function pickTicketType(
  constraints: ListingConstraints,
  preference: readonly string[] = EXOS_TICKET_TYPE_PREFERENCE,
): string {
  const available: Array<{ type: string; name?: string }> = [];
  for (const item of constraints._embedded?.ticket_types ?? []) {
    if (item && typeof item === 'object') {
      const t = (item as Record<string, unknown>).type;
      const n = (item as Record<string, unknown>).name;
      if (typeof t === 'string' && t) available.push({ type: t, name: typeof n === 'string' ? n : undefined });
    }
  }
  for (const want of preference) {
    const key = squashType(want);
    const hit = available.find((a) => squashType(a.type) === key || (a.name != null && squashType(a.name) === key));
    if (hit) return hit.type;
  }
  const listed = available.map((a) => (a.name ? `${a.type} (${a.name})` : a.type)).join(', ') || 'none listed';
  throw new ListingMappingError(`event accepts none of ${preference.join(' / ')}; available: ${listed}`);
}

// ── Pre-flight constraint check ──────────────────────────────────────

export interface ConstraintIssue {
  field: string;
  message: string;
}

/**
 * Allowed request values from a constraints `_embedded` list. SplitType and
 * TicketType items carry the value to send in `type` (`name` is localised
 * display text). Returns null (skip the check) if there's nothing to go on.
 */
export function allowedValues(list: unknown[] | undefined): Set<string> | null {
  if (!list?.length) return null;
  const out = new Set<string>();
  for (const item of list) {
    if (typeof item === 'string') out.add(item);
    else if (item && typeof item === 'object') {
      const v = (item as Record<string, unknown>).type;
      if (typeof v === 'string' && v) out.add(v);
    }
  }
  return out.size ? out : null;
}

/**
 * Checks a request against the documented scalar constraints. An empty
 * result means "nothing we can see is wrong", not "StubHub will accept it";
 * the preview endpoint is the authoritative check.
 */
export function checkListingConstraints(
  req: CreateSellerListingRequest | UpdateSellerListingRequest,
  c: ListingConstraints,
): ConstraintIssue[] {
  const issues: ConstraintIssue[] = [];
  const qty = req.number_of_tickets;
  if (qty != null) {
    if (c.min_number_of_tickets != null && qty < c.min_number_of_tickets) {
      issues.push({ field: 'number_of_tickets', message: `below minimum ${c.min_number_of_tickets}` });
    }
    if (c.max_number_of_tickets != null && qty > c.max_number_of_tickets) {
      issues.push({ field: 'number_of_tickets', message: `above maximum ${c.max_number_of_tickets}` });
    }
  }

  const price = req.ticket_price;
  if (price) {
    for (const [bound, lim] of [['min', c.min_ticket_price], ['max', c.max_ticket_price]] as const) {
      if (lim?.amount == null) continue;
      if (lim.currency_code && lim.currency_code !== price.currency_code) {
        issues.push({ field: 'ticket_price', message: `currency ${price.currency_code} but constraints are in ${lim.currency_code}` });
        continue;
      }
      if (bound === 'min' ? price.amount < lim.amount : price.amount > lim.amount) {
        issues.push({ field: 'ticket_price', message: `${bound === 'min' ? 'below minimum' : 'above maximum'} ${lim.amount}` });
      }
    }
  }

  if (c.seats_required && req.seating && (!req.seating.seat_from || !req.seating.seat_to)) {
    issues.push({ field: 'seating', message: 'seat_from and seat_to are required for this event' });
  }
  // Only a create must carry it; an update leaves the existing address alone.
  const isCreate = 'external_id' in req;
  if (c.ticket_location_required && isCreate && req.ticket_location_address_id == null) {
    issues.push({ field: 'ticket_location_address_id', message: 'a ticket location address is required for this event' });
  }

  const splits = allowedValues(c._embedded?.split_types);
  if (splits && req.split_type != null && !splits.has(req.split_type)) {
    issues.push({ field: 'split_type', message: `"${req.split_type}" is not one of ${[...splits].join(', ')}` });
  }
  const types = allowedValues(c._embedded?.ticket_types);
  if (types && req.ticket_type != null && !types.has(req.ticket_type)) {
    issues.push({ field: 'ticket_type', message: `"${req.ticket_type}" is not one of ${[...types].join(', ')}` });
  }
  return issues;
}
