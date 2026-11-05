// Capacity rules (mig 20261105100000, SIM-ORG-3): there is no unlimited.
// A ticket type or add-on sells up to its capacity; capacity 0 means CLOSED
// (stop sales), never "uncapped". Shared by the SPA (forms, pickers, embed),
// the feeds (Google, catalog, listing) and the edge functions, so every
// surface reads 0 the same way the database does (exos_tier_available).
// Pure, no imports.

/** Largest capacity the forms and the API accept. */
export const MAX_CAPACITY = 1_000_000;

/** What a form or API says when a sellable ticket type has no capacity. */
export const CAPACITY_REQUIRED = "needs a capacity of 1 or more (0 closes sales; there is no unlimited)";

/** Units left to sell: capacity - sold, never below 0; a closed (0) or
 *  missing capacity has none left. */
export function capacityLeft(capacity: unknown, sold: unknown): number {
  const cap = Math.floor(Number(capacity));
  if (!Number.isFinite(cap) || cap <= 0) return 0;
  const s = Math.max(0, Math.floor(Number(sold) || 0));
  return Math.max(0, cap - s);
}

/** Capacity 0 (or missing): sales are closed. */
export function isClosedCapacity(capacity: unknown): boolean {
  const cap = Number(capacity);
  return !Number.isFinite(cap) || cap <= 0;
}

/** Nothing left: closed, or sold up to the capacity. */
export function isSoldOut(capacity: unknown, sold: unknown): boolean {
  return capacityLeft(capacity, sold) === 0;
}

/** A capacity a sellable ticket type may be saved with: a whole number from
 *  1 to MAX_CAPACITY. (0 is allowed only to close an existing type.) */
export function isSellableCapacity(capacity: unknown): boolean {
  const n = typeof capacity === "string" && capacity.trim() !== "" ? Number(capacity) : capacity;
  return typeof n === "number" && Number.isInteger(n) && n >= 1 && n <= MAX_CAPACITY;
}
