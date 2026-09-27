// The Gametime listings for a channel allocation (mig 20260927030000), and
// the inventory CSV that carries them. Planned, not sent.
//
// Gametime takes new listings only as a CSV on its FTP server, one row per
// listing, and the file must be re-sent at least every six hours (a
// "heartbeat") or the account's listings are switched off. Each file is the
// account's inventory: exos-distribute builds it from every live Gametime
// allocation (gametimeInventoryCsv) on every run. Quantity changes and
// deletes between files go through the API (POST /listings/{id},
// DELETE /listings/{id}/delete).
//
// Columns (Gametime's example file and column descriptions): Edit, Event,
// Venue, EventDate (M/D/YYYY), EventTime (h:mm:ss AM), Quantity, Section,
// Row, SeatFrom, SeatThru, Notes, Cost (price per ticket), TicketID (our
// listing id; comes back as the sale's source_id), edelivery_ind (Y/N),
// InHandDate, Instant (Y/N), Splittype, Splitvalue, FaceValue, Stock
// (mobile_transfer | mobile_screencap | eticket | commemorative), Discount,
// ZonePrice.
//
// Exos: one listing per block of at most the event's max per order (as on
// SeatGeek, so no order can take more than that; Splittype ANY within it),
// Row "GA", SeatFrom / SeatThru the allocation's internal seat numbers,
// Stock mobile_transfer (the buyer accepts an Exos claim link), TicketID
// "ex<base32 allocation id><n>" with stable numbers (../listingIds.ts).
// Edit is "y" as in Gametime's example file (not described there).

import { exosEventRef, localDate, type ExosEventRowForChannels } from '../channel.ts';
import { MAX_EXOS_LISTINGS_PER_ALLOCATION, exosListingId, isExosListingId, stableListingNumbers } from '../listingIds.ts';
import { parseSeatRanges, seatBlocks, seatCount, type SeatRun } from '../seats.ts';

export const GAMETIME_CSV_COLUMNS = [
  'Edit', 'Event', 'Venue', 'EventDate', 'EventTime', 'Quantity', 'Section', 'Row', 'SeatFrom', 'SeatThru', 'Notes', 'Cost',
  'TicketID', 'edelivery_ind', 'InHandDate', 'Instant', 'Splittype', 'Splitvalue', 'FaceValue', 'Stock', 'Discount', 'ZonePrice',
] as const;
export type GametimeCsvRow = Record<(typeof GAMETIME_CSV_COLUMNS)[number], string>;

/** A planned Gametime listing: its CSV row, plus the fields the sync and the seat claim read. */
export interface GametimeListingBody extends GametimeCsvRow {
  seller_listing_id: string;
  seat_from: number;
  seat_thru: number;
  quantity: number;
}

export interface GametimeAllocation {
  id: string;
  requested_qty: number | null;
  unit_price: number | string | null;
  tier: { name: string; price: number | string; section_label?: string | null } | null;
  event: (Omit<ExosEventRowForChannels, 'id'> & { id?: string; currency?: string | null; purchase_limits?: unknown }) | null;
  internal_seats: string | SeatRun[] | null;
  /** The listings Gametime has (listed_snapshot) or were last planned, for stable numbers. */
  previous?: ReadonlyArray<{ seller_listing_id?: string; seat_from?: number; seat_thru?: number }> | null;
}

export interface PlannedGametimeListings {
  endpoint: 'uploadInventory';
  listings: Array<{ body: GametimeListingBody }>;
  per_order_cap: number;
  unresolved: string[];
}

const NOTES = 'Delivered by Exos: a link to claim the tickets into your Exos account; the entry QR code is in the Exos app.';

function maxPerOrder(limits: unknown): number | null {
  const v = (limits as { maxPerOrder?: unknown } | null)?.maxPerOrder;
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number.parseInt(v, 10) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** "h:mm:ss AM" venue-local. */
function localTime12(ev: { startsAt: string; occursAtLocal?: string | null; timezone?: string | null }): string | null {
  let hh: number, mm: string, ss: string;
  const m = /T(\d{2}):(\d{2})(?::(\d{2}))?/.exec(ev.occursAtLocal ?? '');
  if (m) {
    hh = Number(m[1]); mm = m[2]; ss = m[3] ?? '00';
  } else if (ev.timezone) {
    try {
      const t = new Intl.DateTimeFormat('en-GB', { timeZone: ev.timezone, hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' })
        .format(new Date(ev.startsAt)).split(':');
      hh = Number(t[0]); mm = t[1]; ss = t[2];
    } catch {
      return null;
    }
  } else {
    return null;
  }
  return `${hh % 12 === 0 ? 12 : hh % 12}:${mm}:${ss} ${hh < 12 ? 'AM' : 'PM'}`;
}

const money = (n: number) => (Math.round(n * 100) / 100).toFixed(2);

export function planGametimeListings(a: GametimeAllocation): PlannedGametimeListings {
  if (!a.tier) throw new Error('the allocation has no ticket type');
  if (!a.event) throw new Error('event not found');
  const ref = exosEventRef({ ...a.event, id: a.event.id ?? a.id });
  if (!ref) throw new Error('the event needs a name, a start time and a venue');
  const qty = a.requested_qty ?? 0;
  if (!Number.isInteger(qty) || qty <= 0) throw new Error('nothing allocated to Gametime');
  const price = Number(a.unit_price ?? a.tier.price);
  if (!Number.isFinite(price) || price <= 0) throw new Error('the ticket type has no price');
  const currency = (a.event.currency || 'USD').toUpperCase();
  if (currency !== 'USD') throw new Error(`Gametime listings are in USD; this event is in ${currency}`);
  const section = (a.tier.section_label || a.tier.name || '').trim();
  if (!section) throw new Error('the ticket type has no name to use as the section');
  const time = localTime12(ref);
  if (!time) throw new Error("the event's local start time is unknown: set its time zone");
  const runs = parseSeatRanges(a.internal_seats);
  if (seatCount(runs) !== qty) {
    throw new Error(`the allocation has ${seatCount(runs)} internal seat numbers for ${qty} seats: save it again`);
  }
  const blocks = seatBlocks(runs, maxPerOrder(a.event.purchase_limits));
  const numbers = stableListingNumbers(a.id, blocks, a.previous ?? []);
  if (blocks.length > MAX_EXOS_LISTINGS_PER_ALLOCATION || Math.max(...numbers) > MAX_EXOS_LISTINGS_PER_ALLOCATION) {
    throw new Error(`that would be ${blocks.length} Gametime listings; raise the max per order`);
  }
  const face = Number(a.tier.price);
  const [y, mo, d] = localDate(ref).split('-');
  const eventDate = `${Number(mo)}/${Number(d)}/${y}`;

  const order = blocks.map((b, i) => ({ b, n: numbers[i] })).sort((x, z) => x.n - z.n);
  const listings = order.map(({ b, n }) => {
    const size = b.thru - b.from + 1;
    const id = exosListingId(a.id, n);
    const body: GametimeListingBody = {
      Edit: 'y',
      Event: ref.name.slice(0, 255),
      Venue: ref.venueName.slice(0, 255),
      EventDate: eventDate,
      EventTime: time,
      Quantity: String(size),
      Section: section.slice(0, 127),
      Row: 'GA',
      SeatFrom: String(b.from),
      SeatThru: String(b.thru),
      Notes: NOTES,
      Cost: money(price),
      TicketID: id,
      edelivery_ind: 'Y',
      InHandDate: localDate(ref),
      Instant: 'N',
      Splittype: 'ANY',
      Splitvalue: '',
      FaceValue: Number.isFinite(face) && face > 0 ? money(face) : '',
      Stock: 'mobile_transfer',
      Discount: '',
      ZonePrice: '',
      seller_listing_id: id,
      seat_from: b.from,
      seat_thru: b.thru,
      quantity: size,
    };
    return { body };
  });
  return {
    endpoint: 'uploadInventory',
    listings,
    per_order_cap: Math.max(...listings.map((l) => l.body.quantity)),
    // Gametime's examples use numeric TicketIDs; it doesn't say others are refused.
    unresolved: ['TicketID: Exos ids are "ex…" strings; confirm Gametime accepts non-numeric ids'],
  };
}

function csvField(v: string): string {
  return /[",\r\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

/** The whole inventory file: a header and one row per listing. Exos listings only. */
export function gametimeInventoryCsv(rows: ReadonlyArray<GametimeCsvRow>): string {
  for (const r of rows) {
    if (!isExosListingId(r.TicketID)) throw new Error(`"${r.TicketID}" is not an Exos listing id`);
  }
  const lines = [GAMETIME_CSV_COLUMNS.join(',')];
  for (const r of rows) lines.push(GAMETIME_CSV_COLUMNS.map((c) => csvField(String(r[c] ?? ''))).join(','));
  return lines.join('\r\n') + '\r\n';
}

/** The CSV row of a planned listing body (drops the helper fields). */
export function csvRowOf(b: GametimeListingBody): GametimeCsvRow {
  const row = {} as GametimeCsvRow;
  for (const c of GAMETIME_CSV_COLUMNS) row[c] = b[c];
  return row;
}
