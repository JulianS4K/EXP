// Exos listing ids on the marketplaces that take our own id for a listing
// (SeatGeek seller_listing_id, Gametime TicketID / source_id).
//
// "ex" + the allocation id (exos_distribution_listings.id) in 26-char base32
// + the listing number, at most 32 characters (SeatGeek's limit). The fixed
// shape is how a writer tells an Exos listing from the broker listings on
// the same account, and how a sale's listing id maps back to its allocation.
//
// Listing numbers stay put across re-plans: a block of seats keeps the
// number of the earlier listing whose seats it overlaps; new blocks get
// numbers never used before. So a sale or a resize updates listings rather
// than renaming them, and a listing that sold out is deleted, not reused.

import type { SeatRun } from './seats.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
const EXOS_ID = /^ex([a-z2-7]{26})([1-9][0-9]{0,3})$/;
export const MAX_EXOS_LISTINGS_PER_ALLOCATION = 9999;

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

export function exosListingId(allocationId: string, n: number): string {
  if (!UUID_RE.test(allocationId)) throw new Error(`not an allocation id: ${allocationId}`);
  if (!Number.isInteger(n) || n < 1 || n > MAX_EXOS_LISTINGS_PER_ALLOCATION) throw new Error(`bad group number ${n}`);
  return `ex${uuidToBase32(allocationId)}${n}`;
}

/** "ex<base32><n>" -> the allocation uuid; anything else (broker listings) -> null. */
export function allocationIdFromListingId(id: string | null | undefined): string | null {
  const m = id ? EXOS_ID.exec(id) : null;
  return m ? base32ToUuid(m[1]) : null;
}

export function isExosListingId(id: string | null | undefined): boolean {
  return allocationIdFromListingId(id) !== null;
}

/** A number per block: the earlier listing's whose seats it overlaps, else one above every number used before. */
export function stableListingNumbers(
  allocationId: string,
  blocks: SeatRun[],
  previous: ReadonlyArray<{ seller_listing_id?: string; seat_from?: number; seat_thru?: number }>,
): number[] {
  const prev = previous
    .filter((p) => allocationIdFromListingId(p.seller_listing_id) === allocationId)
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
