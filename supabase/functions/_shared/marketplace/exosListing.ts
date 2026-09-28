// The Exos marketplace listing: one shape, whatever the marketplace.
//
// An allocation (a ticket type's seats set aside for a marketplace, mig
// 20260926193000) becomes the same set of listings on StubHub, SeatGeek and
// Gametime; each marketplace module only translates them (its listingPlan /
// inventory). What every marketplace gets:
//
//   * blocks of at most the event's max per order, so no single order can
//     take more than an Exos buyer could. SeatGeek and Gametime have no way
//     to cap an order below a listing's quantity; StubHub's
//     display_number_of_tickets isn't documented as a purchase cap. Blocks are
//     a hard cap on all three.
//   * internal seat numbers: each block is a contiguous run of the
//     allocation's internal GA seats (mig 20260927030000), sent as the
//     listing's seat range (SeatGeek requires one with a row; StubHub and
//     Gametime take it). Row "GA". Buyers never see these on Exos.
//   * a listing id "ex<base32 allocation id><n>" (./listingIds.ts), stable
//     across re-plans, that comes back on the sale and maps it to its
//     allocation and to the block's seats.
//   * split "any" within the block, delivery by Exos claim link (a transfer
//     the buyer accepts into any Exos account), in hand on the event day.
//   * the event as text (name, venue, venue-local date and time): SeatGeek
//     and Gametime match on it; StubHub needs it to request an event.
//
// Stored plans (exos_distribution_listings.planned_listing / listed_snapshot)
// share one shape too, PlannedMarketplaceListings: per listing its id, seats,
// quantity and the marketplace request. The seat claim (SQL
// exos_claim_internal_seat) and the sync (./sync.ts) read only the shared
// fields.

import { exosEventRef, localDate, type ExosEventRowForChannels } from './channel.ts';
import { MAX_EXOS_LISTINGS_PER_ALLOCATION, exosListingId, stableListingNumbers } from './listingIds.ts';
import { lowestSeats, parseSeatRanges, seatBlocks, seatCount, type SeatRun } from './seats.ts';

export const EXOS_LISTING_NOTES =
  'Delivered by Exos: you get a link to claim the tickets into your Exos account; the entry QR code is in the Exos app.';

export interface ExosAllocation {
  /** exos_distribution_listings.id */
  id: string;
  requested_qty: number | null;
  /** Listing price; the ticket type's price when unset. */
  unit_price: number | string | null;
  tier: { name: string; price: number | string; section_label?: string | null } | null;
  event: (Omit<ExosEventRowForChannels, 'id'> & { id?: string; currency?: string | null; purchase_limits?: unknown }) | null;
  /** exos_distribution_listings.internal_seats: one number per held seat. */
  internal_seats: string | SeatRun[] | null;
  /**
   * What the listings should show (mig 20260928010000): below requested_qty
   * while a live listing waits for the marketplace to take the lower number;
   * the lowest list_qty seats are listed. NULL: requested_qty.
   */
  list_qty?: number | null;
  /** What the marketplace has (listed_snapshot) or was last planned, for stable listing numbers. */
  previous?: unknown;
}

export interface ExosListing {
  listing_id: string;
  n: number;
  seat_from: number;
  seat_thru: number;
  quantity: number;
  section: string;
  row: 'GA';
  price: number;
  face_value: number | null;
  currency: string;
  event: { name: string; venue: string; starts_at: string; local_date: string; local_time: string | null };
  in_hand_date: string;
  split: 'any';
  delivery: 'claim_link';
  notes: string;
}

export interface ExosListingSet {
  allocation_id: string;
  listings: ExosListing[];
  per_order_cap: number;
}

/** One planned marketplace listing, as stored: the shared fields plus the marketplace request. */
export interface PlannedListingEntry<B = unknown> {
  listing_id: string;
  seat_from: number;
  seat_thru: number;
  quantity: number;
  request: { endpoint: string; method: string; path: string; body: B };
}

export interface PlannedMarketplaceListings<B = unknown> {
  channel: 'stubhub' | 'seatgeek' | 'gametime' | 'gotickets' | 'vivid';
  listings: Array<PlannedListingEntry<B>>;
  per_order_cap: number;
  /** Fields the plan couldn't fill without guessing. */
  unresolved: string[];
}

function maxPerOrder(limits: unknown): number | null {
  const v = (limits as { maxPerOrder?: unknown } | null)?.maxPerOrder;
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number.parseInt(v, 10) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** "HH:MM:SS" venue-local, from occurs_at_local, else starts_at in the event's zone; null if unknown. */
function localTime(ev: { startsAt: string; occursAtLocal?: string | null; timezone?: string | null }): string | null {
  const m = /T(\d{2}:\d{2})(:\d{2})?/.exec(ev.occursAtLocal ?? '');
  if (m) return `${m[1]}${m[2] ?? ':00'}`;
  if (!ev.timezone) return null;
  try {
    return new Intl.DateTimeFormat('en-GB', { timeZone: ev.timezone, hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' })
      .format(new Date(ev.startsAt));
  } catch {
    return null;
  }
}

/** The listing entries of a stored plan / snapshot (the shared shape). */
export function plannedEntries(v: unknown): Array<{ listing_id: string; seat_from?: number; seat_thru?: number; request?: { body?: unknown } }> {
  const ls = (v as { listings?: unknown } | null)?.listings;
  if (!Array.isArray(ls)) return [];
  return ls.filter((l): l is { listing_id: string } => !!l && typeof (l as { listing_id?: unknown }).listing_id === 'string');
}

/** The allocation's listings, the same for every marketplace. `label` names the marketplace in errors. */
export function planExosListings(a: ExosAllocation, label: string): ExosListingSet {
  if (!a.tier) throw new Error('the allocation has no ticket type');
  if (!a.event) throw new Error('event not found');
  const ref = exosEventRef({ ...a.event, id: a.event.id ?? a.id });
  if (!ref) throw new Error('the event needs a name, a start time and a venue');
  const held = a.requested_qty ?? 0;
  const qty = a.list_qty ?? held;
  if (!Number.isInteger(qty) || qty <= 0) throw new Error(`nothing allocated to ${label}`);
  const price = Number(a.unit_price ?? a.tier.price);
  if (!Number.isFinite(price) || price <= 0) throw new Error('the ticket type has no price');
  const face = Number(a.tier.price);
  const section = (a.tier.section_label || a.tier.name || '').trim().slice(0, 127);
  if (!section) throw new Error('the ticket type has no name to use as the section');
  const all = parseSeatRanges(a.internal_seats);
  if (seatCount(all) !== held || qty > held) {
    throw new Error(`the allocation has ${seatCount(all)} internal seat numbers for ${held} seats: save it again`);
  }
  const runs = qty < held ? lowestSeats(all, qty) : all;
  const blocks = seatBlocks(runs, maxPerOrder(a.event.purchase_limits));
  const prev = plannedEntries(a.previous).map((e) => ({ seller_listing_id: e.listing_id, seat_from: e.seat_from, seat_thru: e.seat_thru }));
  const numbers = stableListingNumbers(a.id, blocks, prev);
  if (blocks.length > MAX_EXOS_LISTINGS_PER_ALLOCATION || Math.max(...numbers) > MAX_EXOS_LISTINGS_PER_ALLOCATION) {
    throw new Error(`that would be ${blocks.length} ${label} listings; raise the max per order`);
  }
  const date = localDate(ref);
  const event = { name: ref.name.slice(0, 255), venue: ref.venueName.slice(0, 255), starts_at: ref.startsAt, local_date: date, local_time: localTime(ref) };
  const listings = blocks
    .map((b, i) => ({ b, n: numbers[i] }))
    .sort((x, y) => x.n - y.n)
    .map(({ b, n }): ExosListing => ({
      listing_id: exosListingId(a.id, n),
      n,
      seat_from: b.from,
      seat_thru: b.thru,
      quantity: b.thru - b.from + 1,
      section,
      row: 'GA',
      price: Math.round(price * 100) / 100,
      face_value: Number.isFinite(face) && face > 0 ? Math.round(face * 100) / 100 : null,
      currency: (a.event!.currency || 'USD').toUpperCase(),
      event,
      in_hand_date: date,
      split: 'any',
      delivery: 'claim_link',
      notes: EXOS_LISTING_NOTES,
    }));
  return { allocation_id: a.id, listings, per_order_cap: Math.max(...listings.map((l) => l.quantity)) };
}

/** A shared entry for one listing and its marketplace request. */
export function entryFor<B>(l: ExosListing, request: PlannedListingEntry<B>['request']): PlannedListingEntry<B> {
  return { listing_id: l.listing_id, seat_from: l.seat_from, seat_thru: l.seat_thru, quantity: l.quantity, request };
}

/** Marketplaces that only take one currency. */
export function requireCurrency(set: ExosListingSet, currency: string, label: string): void {
  const c = set.listings[0]?.currency;
  if (c && c !== currency) throw new Error(`${label} listings are in ${currency}; this event is in ${c}`);
}
