// The SeatGeek listings for a channel allocation (mig 20260926193000),
// planned, not sent. Field rules: SeatGeek "Listing Fields" page.
//
// One order can take at most one listing. SeatGeek has no way to show buyers
// part of a listing: a CUSTOM `splits` list must end at the listing's full
// quantity (otherwise SeatGeek falls back to its DEFAULT splits), so splits
// can't cap an order below the quantity. The allocation is therefore split
// into listings of at most the event's maxPerOrder each (10 seats, max 4 ->
// 4 + 4 + 2). A buyer can still place several orders; the per-account limit
// flags catch that once the tickets are claimed, as on StubHub.
//
// seller_listing_id (max 32 chars): "ex" + the allocation id in 26-char
// base32 + the group number, e.g. "exab3k...q2" (at most 32). The fixed shape
// is how the writer tells an Exos listing from the broker listings on the
// same account, and how a sale's listing id maps back to its allocation row
// (allocationIdFromSellerListingId).
//
// Fields: event / venue / event_date / event_time are required even with an
// event_id (SeatGeek matches events on title + venue, so use its names when
// the event is linked). stock_type "mobile" (the buyer accepts a transfer
// link: Exos's claim link), is_edelivery true. row is required: Exos
// general-admission tiers use "GA". seat_from / seat_thru are required when a
// row is given: they are the allocation's internal seat numbers (mig
// 20260927030000, ../seats.ts), so a listing is one contiguous block of them,
// and every ticket sold on it gets one of its numbers. Buyers never see them
// on Exos.
//
// Listing numbers stay put across re-plans: a block keeps the number of the
// earlier listing (listed_snapshot, else the last plan) whose seats it
// overlaps; new blocks get numbers never used before. So a sale or a resize
// updates listings rather than renaming them, and a listing that sold out or
// was dropped is deleted, not reused.

import { exosEventRef, localDate, type ExosEventRowForChannels } from '../channel.ts';
import { parseSeatRanges, seatBlocks, seatCount, type SeatRun } from '../seats.ts';
import { MAX_EXOS_LISTINGS_PER_ALLOCATION, exosListingId, stableListingNumbers } from '../listingIds.ts';
import type { SeatGeekListing } from './types.ts';

export {
  MAX_EXOS_LISTINGS_PER_ALLOCATION as MAX_SEATGEEK_LISTINGS_PER_ALLOCATION,
  allocationIdFromListingId as allocationIdFromSellerListingId,
  exosListingId as exosSellerListingId,
  isExosListingId as isExosSellerListingId,
} from '../listingIds.ts';

/** Split qty into groups of at most `max` (the last one takes the rest). */
export function groupSizes(qty: number, max: number | null): number[] {
  if (!Number.isInteger(qty) || qty <= 0) return [];
  if (!max || max >= qty) return [qty];
  const out: number[] = [];
  for (let left = qty; left > 0; left -= max) out.push(Math.min(max, left));
  return out;
}

export interface SeatGeekAllocation {
  /** exos_distribution_listings.id */
  id: string;
  requested_qty: number | null;
  unit_price: number | string | null;
  tier: { name: string; price: number | string; section_label?: string | null } | null;
  event: (Omit<ExosEventRowForChannels, 'id'> & { id?: string; currency?: string | null; purchase_limits?: unknown }) | null;
  /** The linked SeatGeek event id (exos_channel_event_links), if any. */
  seatgeekEventId?: string | null;
  /** exos_distribution_listings.internal_seats: one number per allocated seat. */
  internal_seats: string | SeatRun[] | null;
  /** The listings SeatGeek has (listed_snapshot) or were last planned, for stable numbers. */
  previous?: ReadonlyArray<{ seller_listing_id?: string; seat_from?: number; seat_thru?: number }> | null;
}

export interface PlannedSeatGeekListings {
  endpoint: 'createListing';
  method: 'PUT';
  listings: Array<{ path: string; body: SeatGeekListing & { seller_listing_id: string } }>;
  /** The most one order can take (the largest listing). */
  per_order_cap: number;
  unresolved: string[];
}

function maxPerOrder(limits: unknown): number | null {
  const v = (limits as { maxPerOrder?: unknown } | null)?.maxPerOrder;
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number.parseInt(v, 10) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** "HH:MM:SS" venue-local, from occurs_at_local, else starts_at in the event's zone. */
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

export function planSeatGeekListings(a: SeatGeekAllocation): PlannedSeatGeekListings {
  if (!a.tier) throw new Error('the allocation has no ticket type');
  if (!a.event) throw new Error('event not found');
  const ref = exosEventRef({ ...a.event, id: a.event.id ?? a.id });
  if (!ref) throw new Error('the event needs a name, a start time and a venue');
  const qty = a.requested_qty ?? 0;
  if (!Number.isInteger(qty) || qty <= 0) throw new Error('nothing allocated to SeatGeek');
  const price = Number(a.unit_price ?? a.tier.price);
  if (!Number.isFinite(price) || price <= 0) throw new Error('the ticket type has no price');
  const currency = (a.event.currency || 'USD').toUpperCase();
  if (currency !== 'USD') throw new Error(`SeatGeek listings are in USD; this event is in ${currency}`);
  const section = (a.tier.section_label || a.tier.name || '').trim().slice(0, 127);
  if (!section) throw new Error('the ticket type has no name to use as the section');

  const eventId = a.seatgeekEventId?.trim();
  if (eventId && !/^\d+$/.test(eventId)) throw new Error(`"${eventId}" is not a SeatGeek event id`);
  const runs = parseSeatRanges(a.internal_seats);
  if (seatCount(runs) !== qty) {
    throw new Error(`the allocation has ${seatCount(runs)} internal seat numbers for ${qty} seats: save it again`);
  }
  const blocks = seatBlocks(runs, maxPerOrder(a.event.purchase_limits));
  const numbers = stableListingNumbers(a.id, blocks, a.previous ?? []);
  if (blocks.length > MAX_EXOS_LISTINGS_PER_ALLOCATION || Math.max(...numbers) > MAX_EXOS_LISTINGS_PER_ALLOCATION) {
    throw new Error(`that would be ${blocks.length} SeatGeek listings; raise the max per order`);
  }
  const date = localDate(ref);
  const time = localTime(ref) ?? 'TBD';
  const unresolved: string[] = [];
  if (!eventId) unresolved.push('event_id (not linked: SeatGeek matches on the event title and venue)');

  const order = blocks.map((b, i) => ({ b, n: numbers[i] })).sort((x, y) => x.n - y.n);
  const sizes = order.map(({ b }) => b.thru - b.from + 1);
  const listings = order.map(({ b, n }) => {
    const size = b.thru - b.from + 1;
    const id = exosListingId(a.id, n);
    const body: SeatGeekListing & { seller_listing_id: string } = {
      seller_listing_id: id,
      event: ref.name.slice(0, 255),
      venue: ref.venueName.slice(0, 255),
      event_date: date,
      event_time: time,
      ...(eventId ? { event_id: Number(eventId) } : {}),
      quantity: size,
      cost: Math.round(price * 100) / 100,
      section,
      row: 'GA',
      seat_from: b.from,
      seat_thru: b.thru,
      stock_type: 'mobile',
      is_edelivery: true,
      split_type: 'ANY',
      in_hand_date: date,
      notes: 'Delivered by Exos: you get a link to claim the tickets into your Exos account; the entry QR code is in the Exos app.',
    };
    return { path: `/listings/single/${encodeURIComponent(id)}`, body };
  });
  return { endpoint: 'createListing', method: 'PUT', listings, per_order_cap: Math.max(...sizes), unresolved };
}
