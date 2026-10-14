// Two inventory pools on an S4K-route event (mig 20261014130000): per ticket
// type, the organizer picks how many seats S4K gets; Exos and Eventbrite
// share the rest. Pure (RPCs: ./s4kNetwork).

export interface PoolTier {
  tierId: string;
  name: string;
  capacity: number;
  sold: number;
  splittable: boolean;
  /** S4K's split: its total for this ticket type, sold included. */
  s4kSplit: number;
  s4kSold: number;
  /** Seats S4K holds now (split − sold). */
  s4kHeld: number;
  /** Free now for Exos + Eventbrite (null: no cap). */
  sharedFree: number | null;
  eventbriteMapped: boolean;
  /** The listings Albert sees for this ticket type (mig 20261014150000): up to three quantities. */
  listings: number[];
}

export type PrimarySource = 'exos' | 'eventbrite';

export interface PoolStatus {
  route: 'direct' | 's4k';
  onFeed: boolean;
  /** Each S4K listing's most tickets (default 8); also the set left to the primary source. */
  listingQty: number;
  primarySource: PrimarySource;
  rebalance: boolean;
  eventbriteLinked: boolean;
  tiers: PoolTier[];
}

const n = (v: unknown): number => (Number.isFinite(Number(v)) ? Math.max(0, Math.trunc(Number(v))) : 0);

export function parsePoolStatus(raw: any): PoolStatus {
  return {
    route: raw?.route === 's4k' ? 's4k' : 'direct',
    onFeed: raw?.on_feed === true,
    listingQty: n(raw?.listing_qty) || 8,
    primarySource: raw?.primary_source === 'eventbrite' ? 'eventbrite' : 'exos',
    rebalance: raw?.rebalance !== false,
    eventbriteLinked: raw?.eventbrite_linked === true,
    tiers: (Array.isArray(raw?.tiers) ? raw.tiers : [])
      .filter((t: any) => typeof t?.tier_id === 'string')
      .map((t: any) => ({
        tierId: t.tier_id,
        name: String(t.name ?? ''),
        capacity: n(t.capacity),
        sold: n(t.sold),
        splittable: t.splittable === true,
        s4kSplit: n(t.s4k_split),
        s4kSold: n(t.s4k_sold),
        s4kHeld: n(t.s4k_held),
        sharedFree: t.shared_free == null ? null : n(t.shared_free),
        eventbriteMapped: t.eventbrite_mapped === true,
        listings: Array.isArray(t.listings) ? t.listings.map(n).filter((q: number) => q > 0) : [],
      })),
  };
}

/** The most S4K's split can be now: what it sold, what it holds, and what's
 *  free in the shared pool. */
export function maxSplit(t: PoolTier): number {
  return t.s4kSold + t.s4kHeld + (t.sharedFree ?? Math.max(0, t.capacity - t.sold));
}

/** S4K's split for "give S4K p% of each": p% of capacity, never below what
 *  S4K sold, never above what can be given now. */
export function splitForPercent(t: PoolTier, pct: number): number {
  const p = Math.min(100, Math.max(0, Number.isFinite(pct) ? pct : 0));
  const want = Math.floor((t.capacity * p) / 100);
  return Math.min(maxSplit(t), Math.max(t.s4kSold, want));
}

/** Why a typed split can't be saved, or null. */
export function splitError(t: PoolTier, seats: number): string | null {
  if (!Number.isInteger(seats) || seats < 0) return 'Whole seats, 0 or more.';
  if (seats > 0 && !t.splittable) return `${t.name} can't go to S4K (free, table or no capacity).`;
  if (seats < t.s4kSold) return `S4K already sold ${t.s4kSold}; the split can't go below that.`;
  if (seats > maxSplit(t)) return `Only ${maxSplit(t)} can go to S4K now (the rest is sold).`;
  return null;
}

/** The two pools after a split: S4K's unsold seats, and what Exos +
 *  Eventbrite would have free. */
export function poolsAfter(t: PoolTier, seats: number): { s4k: number; shared: number | null } {
  const s4k = Math.max(0, seats - t.s4kSold);
  if (t.sharedFree == null) return { s4k, shared: null };
  return { s4k, shared: Math.max(0, t.sharedFree + t.s4kHeld - s4k) };
}

/** What three listings of up to `qty` show for `held` seats in S4K's pool. */
export function listingQuantities(held: number, qty: number): number[] {
  const out: number[] = [];
  const q = Math.max(1, Math.trunc(qty));
  for (let i = 0; i < 3; i++) {
    const left = Math.max(0, Math.trunc(held) - i * q);
    if (left > 0) out.push(Math.min(q, left));
  }
  return out;
}
