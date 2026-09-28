// The Exos listing standard: one listing model, translated field by field
// for each marketplace. ./eventStandard.ts does the event (title, section,
// category); this does the listing: its id, how buyers may split it, and
// which field carries what on each marketplace.
//
// Split policy. The organizer picks one per ticket type
// (exos_ticket_tiers.market_split, mig 20260929061000) and every marketplace
// gets it in its own words:
//
//   policy      StubHub   SeatGeek        Gametime       GoTickets        Vivid Seats     TEvo
//   any         Any       ANY             ANY            ANY              ANY             ANY
//   no_single   AvoidOne  DONTLEAVEONE    NEVERLEAVEONE  NEVER_LEAVE_ONE  NEVERLEAVEONE   NEVERLEAVEONE
//   pairs       Pairs     CUSTOM 2,4..q   CUSTOM 2:4..q  CUSTOM [2,4..q]  CUSTOM 2,4..q   CUSTOM [2,4..q]
//   together    None      CUSTOM q        NOSPLIT        NO_SPLIT         CUSTOM q        NONE
//
// A custom list always ends at the listing's quantity: SeatGeek falls back
// to DEFAULT otherwise, and the others read it the same way. "pairs" listings
// hold an even number of seats (./exosListing.ts makes even blocks), so the
// list 2, 4, … ends at q. Where a marketplace documents the enum but not the
// custom value's format (Gametime's "2:4" example, Vivid's plain-string
// splitValue), the plan says so in its notices.
//
// Listing ids. Exos addresses its listings only by its own id
// ("ex<base32 allocation id><n>", ./listingIds.ts, 30 to 32 characters) and
// never touches a listing without one. LISTING_ID_FIELDS says where that id
// goes on each marketplace and how long it may be; TEvo takes a positive
// integer (remote_id, numbered by exos_tevo_remote_ids) and keeps the Exos id
// in internal_notes.

import { isExosListingId } from './listingIds.ts';

export const MARKET_SPLITS = ['any', 'no_single', 'pairs', 'together'] as const;
export type MarketSplit = (typeof MARKET_SPLITS)[number];

/** Organizer-facing names (the Marketplaces grid). */
export const MARKET_SPLIT_LABEL: Record<MarketSplit, string> = {
  any: 'Any quantity',
  no_single: "Don't leave one",
  pairs: 'Pairs only',
  together: 'All together',
};

/** The stored value, or 'any' for anything else (NULL, an old row, a typo). */
export function parseMarketSplit(v: unknown): MarketSplit {
  return typeof v === 'string' && (MARKET_SPLITS as readonly string[]).includes(v) ? (v as MarketSplit) : 'any';
}

/** The quantities a buyer can take from a listing of `qty` under the policy. */
export function buyableQuantities(split: MarketSplit, qty: number): number[] {
  if (!Number.isInteger(qty) || qty <= 0) return [];
  const all = Array.from({ length: qty }, (_, i) => i + 1);
  switch (split) {
    case 'any':
      return all;
    case 'no_single':
      return all.filter((n) => qty - n !== 1);
    case 'pairs':
      return all.filter((n) => n % 2 === 0);
    case 'together':
      return [qty];
  }
}

/** The biggest listing the policy allows under a max per order (pairs: an even number). */
export function splitBlockMax(split: MarketSplit, maxPerOrder: number | null): number | null {
  if (split !== 'pairs' || maxPerOrder == null) return maxPerOrder;
  const even = maxPerOrder - (maxPerOrder % 2);
  if (even < 2) throw new Error('"Pairs only" needs a max per order of at least 2');
  return even;
}

export type SplitChannel = 'stubhub' | 'seatgeek' | 'gametime' | 'gotickets' | 'vivid' | 'evo';

export interface MarketSplitFields {
  /** The marketplace's split type value. */
  type: string;
  /** The allowed quantities, for a CUSTOM type; null otherwise. */
  values: number[] | null;
}

const NAMED: Record<SplitChannel, Record<Exclude<MarketSplit, 'pairs'>, string | null>> = {
  stubhub: { any: 'Any', no_single: 'AvoidOne', together: 'None' },
  seatgeek: { any: 'ANY', no_single: 'DONTLEAVEONE', together: null },
  gametime: { any: 'ANY', no_single: 'NEVERLEAVEONE', together: 'NOSPLIT' },
  gotickets: { any: 'ANY', no_single: 'NEVER_LEAVE_ONE', together: 'NO_SPLIT' },
  vivid: { any: 'ANY', no_single: 'NEVERLEAVEONE', together: null },
  evo: { any: 'ANY', no_single: 'NEVERLEAVEONE', together: 'NONE' },
};

/** The split for one listing of `qty`, in the marketplace's words. */
export function marketSplitFor(channel: SplitChannel, split: MarketSplit, qty: number): MarketSplitFields {
  if (!Number.isInteger(qty) || qty <= 0) throw new Error(`bad listing quantity ${qty}`);
  if (split === 'pairs') {
    if (qty % 2 !== 0) throw new Error(`a "Pairs only" listing needs an even quantity, got ${qty}`);
    if (channel === 'stubhub') return { type: 'Pairs', values: null };
    return { type: 'CUSTOM', values: buyableQuantities('pairs', qty) };
  }
  const named = NAMED[channel][split];
  if (named) return { type: named, values: null };
  // "together" where there's no named type: a custom list of just the quantity.
  return { type: 'CUSTOM', values: [qty] };
}

/** SeatGeek `splits` / Vivid `splitValue`: "2,4,6". */
export const commaSplits = (v: number[] | null): string => (v ?? []).join(',');
/** Gametime `Splitvalue`: "2:4" (its example; the format isn't described further). */
export const colonSplits = (v: number[] | null): string => (v ?? []).join(':');

/** Plan notices for a custom split whose value format the marketplace doesn't document. */
export function splitFormatNotice(channel: SplitChannel, f: MarketSplitFields): string | null {
  if (f.type !== 'CUSTOM') return null;
  if (channel === 'gametime') return 'Splitvalue: Gametime shows "2:4" as an example but doesn\'t describe the format; confirm with Gametime';
  if (channel === 'vivid') return 'splitValue: Vivid documents it as a plain string; confirm "2,4" is the format';
  return null;
}

/**
 * Where each marketplace takes the Exos listing id, and what it allows.
 * Documented limits only; `null` = none documented.
 */
export const LISTING_ID_FIELDS = {
  stubhub: { field: 'external_id', maxLength: null, comesBackAs: 'external_listing_id' },
  seatgeek: { field: 'seller_listing_id', maxLength: 32, comesBackAs: 'listing.id' },
  gametime: { field: 'TicketID', maxLength: null, comesBackAs: 'source_id / listing_reference_id' },
  gotickets: { field: 'externalTicketId', maxLength: 100, comesBackAs: 'externalTicketId' },
  vivid: { field: 'ticketId', maxLength: null, comesBackAs: 'brokerTicketId' },
  evo: { field: 'internal_notes', maxLength: null, comesBackAs: 'remote_id (numbered: exos_tevo_remote_ids)' },
} as const satisfies Record<SplitChannel, { field: string; maxLength: number | null; comesBackAs: string }>;

/** Refuse anything but an Exos listing id that fits the marketplace's field. */
export function assertListingId(channel: SplitChannel, id: string): string {
  if (!isExosListingId(id)) throw new Error(`"${id}" is not an Exos listing id`);
  const max = LISTING_ID_FIELDS[channel].maxLength;
  if (max != null && id.length > max) throw new Error(`${LISTING_ID_FIELDS[channel].field} "${id}" is longer than ${max}`);
  return id;
}

/**
 * The standard listing fields and each marketplace's name for them (dotted
 * paths into the request body). Tests check every planner fills exactly
 * these; docs/marketplace/README.md shows the same table.
 */
export const LISTING_FIELD_MAP = {
  stubhub: {
    id: 'external_id', quantity: 'number_of_tickets', section: 'seating.section', row: 'seating.row',
    seatFrom: 'seating.seat_from', seatThru: 'seating.seat_to', price: 'ticket_price.amount',
    split: 'split_type', splitValues: null, stock: 'ticket_type', inHand: null, notes: 'notes',
  },
  seatgeek: {
    id: 'seller_listing_id', quantity: 'quantity', section: 'section', row: 'row',
    seatFrom: 'seat_from', seatThru: 'seat_thru', price: 'cost',
    split: 'split_type', splitValues: 'splits', stock: 'stock_type', inHand: 'in_hand_date', notes: 'notes',
  },
  gametime: {
    id: 'TicketID', quantity: 'Quantity', section: 'Section', row: 'Row',
    seatFrom: 'SeatFrom', seatThru: 'SeatThru', price: 'Cost',
    split: 'Splittype', splitValues: 'Splitvalue', stock: 'Stock', inHand: 'InHandDate', notes: 'Notes',
  },
  gotickets: {
    id: 'externalTicketId', quantity: 'quantity', section: 'section', row: 'row',
    seatFrom: 'lowSeat', seatThru: 'highSeat', price: 'price',
    split: 'splitType', splitValues: 'splitValuesSet', stock: 'stockType', inHand: 'inHandDate', notes: 'notes',
  },
  vivid: {
    id: 'ticketId', quantity: 'quantity', section: 'section', row: 'row',
    seatFrom: 'seatFrom', seatThru: 'seatThru', price: 'price',
    split: 'splitType', splitValues: 'splitValue', stock: 'stockType', inHand: 'inHandDate', notes: 'notes',
  },
  evo: {
    id: 'inventory.ticket.internal_notes', quantity: 'inventory.ticket.quantity', section: 'inventory.ticket.section',
    row: 'inventory.ticket.row', seatFrom: 'inventory.ticket.seats', seatThru: 'inventory.ticket.seats',
    price: 'inventory.ticket.price', split: 'inventory.ticket.split_type', splitValues: 'inventory.ticket.split_override',
    stock: 'inventory.ticket.format', inHand: 'inventory.ticket.in_hand_on', notes: 'inventory.ticket.external_notes',
  },
} as const satisfies Record<SplitChannel, Record<string, string | null>>;
