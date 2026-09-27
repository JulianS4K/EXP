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
import type { SeatGeekListing } from './types.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
const EXOS_ID = /^ex([a-z2-7]{26})([1-9][0-9]{0,3})$/;
export const MAX_SEATGEEK_LISTINGS_PER_ALLOCATION = 9999;

function uuidToBase32(uuid: string): string {
  const hex = uuid.replace(/-/g, '').toLowerCase();
  let bits = '';
  for (const h of hex) bits += Number.parseInt(h, 16).toString(2).padStart(4, '0');
  bits = bits.padEnd(130, '0'); // 128 bits -> 26 x 5
  let out = '';
  for (let i = 0; i < 130; i += 5) out += B32[Number.parseInt(bits.slice(i, i + 5), 2)];
  return out;
}

function base32ToUuid(b32: string): string | null {
  let bits = '';
  for (const c of b32) {
    const v = B32.indexOf(c);
    if (v < 0) return null;
    bits += v.toString(2).padStart(5, '0');
  }
  if (!/^0+$/.test(bits.slice(128))) return null; // padding must be zero
  let hex = '';
  for (let i = 0; i < 128; i += 4) hex += Number.parseInt(bits.slice(i, i + 4), 2).toString(16);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function exosSellerListingId(allocationId: string, n: number): string {
  if (!UUID_RE.test(allocationId)) throw new Error(`not an allocation id: ${allocationId}`);
  if (!Number.isInteger(n) || n < 1 || n > MAX_SEATGEEK_LISTINGS_PER_ALLOCATION) throw new Error(`bad group number ${n}`);
  return `ex${uuidToBase32(allocationId)}${n}`;
}

export function isExosSellerListingId(id: string | null | undefined): boolean {
  return allocationIdFromSellerListingId(id) !== null;
}

/** "ex<base32><n>" -> the allocation uuid; anything else (broker listings) -> null. */
export function allocationIdFromSellerListingId(id: string | null | undefined): string | null {
  const m = id ? EXOS_ID.exec(id) : null;
  return m ? base32ToUuid(m[1]) : null;
}

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
  const numbers = listingNumbers(a.id, blocks, a.previous ?? []);
  if (blocks.length > MAX_SEATGEEK_LISTINGS_PER_ALLOCATION || Math.max(...numbers) > MAX_SEATGEEK_LISTINGS_PER_ALLOCATION) {
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
    const id = exosSellerListingId(a.id, n);
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

/**
 * A number per block: the earlier listing's whose seats it overlaps, else a
 * new one above every number used before (so a deleted listing's id isn't
 * handed to different seats).
 */
function listingNumbers(
  allocationId: string,
  blocks: SeatRun[],
  previous: ReadonlyArray<{ seller_listing_id?: string; seat_from?: number; seat_thru?: number }>,
): number[] {
  const prev = previous
    .filter((p) => allocationIdFromSellerListingId(p.seller_listing_id) === allocationId)
    .map((p) => ({ n: Number(EXOS_ID.exec(p.seller_listing_id!)![2]), from: Number(p.seat_from), thru: Number(p.seat_thru) }));
  const used = new Set<number>();
  const out = blocks.map((b) => {
    const hit = prev.find((p) => !used.has(p.n) && Number.isInteger(p.from) && Number.isInteger(p.thru) && p.from <= b.thru && b.from <= p.thru);
    if (!hit) return 0;
    used.add(hit.n);
    return hit.n;
  });
  let next = Math.max(0, ...prev.map((p) => p.n)) + 1;
  return out.map((n) => n || next++);
}
