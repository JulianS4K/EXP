// The Ticket Evolution listings for a channel allocation: the Exos listings
// (../exosListing.ts: blocks of at most max per order, internal seats,
// stable "ex…" ids) as TEvo inventory, one ticket group each (Inventory /
// Create). Planned, not sent.
//
// Fields: remote_id = the listing's number from exos_tevo_remote_ids (mig
// 20260928080000; TEvo wants a positive integer, unique per office, and
// hands it back on the order's ticket group), internal_notes = the Exos
// listing id, row "GA", seats = the block's internal seats (quantity must
// match), split ANY within the block, format TM_mobile (mobile transfer:
// delivered with the Exos claim link, fulfilment.ts), in_hand false until
// the event day, price, face_value. The event goes by TEvo's event id when
// Exos has the event linked, the office by TEVO_OFFICE_ID; both are
// required, so without them the plan says what's missing and the writer
// won't send it.

import { EXOS_TRANSFER_STOCK, entryFor, planExosListings, requireCurrency, type ExosAllocation, type PlannedMarketplaceListings } from '../exosListing.ts';
import type { TevoInventoryBody } from './types.ts';

/** exos_tevo_remote_ids numbers from here up (never a broker POS's range). */
export const EXOS_TEVO_REMOTE_ID_MIN = 1_900_000_001;
export const EXOS_TEVO_REMOTE_ID_MAX = 2_147_483_647;

export function isExosTevoRemoteId(v: unknown): boolean {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^\d+$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isInteger(n) && n >= EXOS_TEVO_REMOTE_ID_MIN && n <= EXOS_TEVO_REMOTE_ID_MAX;
}

export type TevoAllocation = ExosAllocation & {
  /** The linked TEvo event id (exos_channel_event_links). */
  tevoEventId?: string | null;
  /** TEVO_OFFICE_ID: the office the inventory belongs to. */
  officeId?: number | string | null;
  /** listing id -> remote_id, from exos_tevo_remote_ids. */
  remoteIds?: Readonly<Record<string, number>>;
};

export interface PlannedTevoListings extends PlannedMarketplaceListings<TevoInventoryBody> {
  channel: 'evo';
}

const posInt = (v: unknown): number | undefined => {
  const s = typeof v === 'number' ? String(v) : typeof v === 'string' ? v.trim() : '';
  return /^[1-9]\d*$/.test(s) ? Number(s) : undefined;
};

export function planTevoListings(a: TevoAllocation): PlannedTevoListings {
  const set = planExosListings(a, 'Ticket Evolution');
  requireCurrency(set, 'USD', 'Ticket Evolution');
  const eventId = posInt(a.tevoEventId);
  const officeId = posInt(a.officeId);
  const unresolved: string[] = [];
  if (eventId == null) unresolved.push('event.id: link the event to its Ticket Evolution event (TEvo needs the id)');
  if (officeId == null) unresolved.push('office.id: set TEVO_OFFICE_ID');
  const listings = set.listings.map((l) => {
    const remoteId = a.remoteIds?.[l.listing_id];
    if (!isExosTevoRemoteId(remoteId)) unresolved.push(`remote_id for ${l.listing_id}: not numbered yet (exos_tevo_remote_ids)`);
    const seats = Array.from({ length: l.quantity }, (_, i) => ({ seat: l.seat_from + i }));
    const body: TevoInventoryBody = {
      inventory: {
        event: {
          ...(eventId != null ? { id: eventId } : {}),
          name: l.event.name,
          occurs_at_date: l.event.local_date,
          ...(l.event.local_time ? { occurs_at_time: l.event.local_time.slice(0, 5) } : {}),
        },
        office: officeId != null ? { id: officeId } : {},
        ticket: {
          format: EXOS_TRANSFER_STOCK.evo,
          price: l.price,
          quantity: l.quantity,
          remote_id: isExosTevoRemoteId(remoteId) ? remoteId! : 0,
          row: l.row,
          section: l.section,
          type: 'EVENT',
          seats,
          split_type: 'ANY',
          in_hand: false,
          in_hand_on: l.in_hand_date,
          ...(l.face_value != null ? { face_value: l.face_value } : {}),
          external_notes: l.notes,
          internal_notes: l.listing_id,
        },
        venue: { name: l.event.venue },
      },
    };
    return entryFor(l, { endpoint: 'createInventory', method: 'POST', path: '/v9/inventory', body });
  });
  return { channel: 'evo', listings, per_order_cap: set.per_order_cap, unresolved };
}
