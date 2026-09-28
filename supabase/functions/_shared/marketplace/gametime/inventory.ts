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
// Exos: the Exos listings (../exosListing.ts: blocks of at most max per
// order, internal seats as SeatFrom / SeatThru, row GA, TicketID the "ex…"
// listing id) as CSV rows. Stock mobile_transfer (the buyer accepts an Exos
// claim link), Splittype ANY within the block. Edit is "y" as in Gametime's
// example file (not described there).

import { entryFor, planExosListings, requireCurrency, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';
import { isExosListingId } from '../listingIds.ts';

export const GAMETIME_CSV_COLUMNS = [
  'Edit', 'Event', 'Venue', 'EventDate', 'EventTime', 'Quantity', 'Section', 'Row', 'SeatFrom', 'SeatThru', 'Notes', 'Cost',
  'TicketID', 'edelivery_ind', 'InHandDate', 'Instant', 'Splittype', 'Splitvalue', 'FaceValue', 'Stock', 'Discount', 'ZonePrice',
] as const;
export type GametimeCsvRow = Record<(typeof GAMETIME_CSV_COLUMNS)[number], string>;

export type GametimeAllocation = ExosAllocation;

export interface PlannedGametimeListings extends PlannedMarketplaceListings<GametimeCsvRow> {
  channel: 'gametime';
}

/** "HH:MM:SS" -> "h:mm:ss AM". */
function time12(t: string): string {
  const [h, m, sec] = t.split(':');
  const hh = Number(h);
  return `${hh % 12 === 0 ? 12 : hh % 12}:${m}:${sec ?? '00'} ${hh < 12 ? 'AM' : 'PM'}`;
}

const money = (n: number) => n.toFixed(2);

export function planGametimeListings(a: GametimeAllocation): PlannedGametimeListings {
  const set = planExosListings(a, 'Gametime');
  requireCurrency(set, 'USD', 'Gametime');
  const listings = set.listings.map((l) => {
    if (!l.event.local_time) throw new Error("the event's local start time is unknown: set its time zone");
    const [y, mo, d] = l.event.local_date.split('-');
    const body: GametimeCsvRow = {
      Edit: 'y',
      Event: l.event.name,
      Venue: l.event.venue,
      EventDate: `${Number(mo)}/${Number(d)}/${y}`,
      EventTime: time12(l.event.local_time),
      Quantity: String(l.quantity),
      Section: l.section,
      Row: l.row,
      SeatFrom: String(l.seat_from),
      SeatThru: String(l.seat_thru),
      Notes: l.notes,
      Cost: money(l.price),
      TicketID: l.listing_id,
      edelivery_ind: 'Y',
      InHandDate: l.in_hand_date,
      Instant: 'N',
      Splittype: 'ANY',
      Splitvalue: '',
      FaceValue: l.face_value != null ? money(l.face_value) : '',
      Stock: 'mobile_transfer',
      Discount: '',
      ZonePrice: '',
    };
    // One row of the inventory file (FTP), not an HTTP call.
    return entryFor(l, { endpoint: 'uploadInventory', method: 'FTP', path: 'inventory.csv', body });
  });
  return {
    channel: 'gametime',
    listings,
    per_order_cap: set.per_order_cap,
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
