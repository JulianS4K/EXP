// Resale unlocks at a max capacity of 250 (mig 20261014140000; the server
// rule is exos_event_max_capacity / exos_resale_unlocked, and the operator
// can change the number there). This mirrors it so the editor can say why
// marketplaces and S4K are off before a save is refused.

export const RESALE_MIN_CAPACITY = 250;

/** The event's max capacity: the overall cap when set (never above what the
 *  capped ticket types add up to, unless one has no cap), else the capped
 *  ticket types' sum. A ticket type with no cap (0) adds nothing without an
 *  overall cap. Pass each tier's admissions (a table tier's capacity ×
 *  party size, see admissionsForTier), as the server counts people. */
export function eventMaxCapacity(totalTickets: number | null | undefined, tierCapacities: number[]): number {
  const total = Math.max(0, Math.trunc(Number(totalTickets) || 0));
  const caps = tierCapacities.map((c) => Math.max(0, Math.trunc(Number(c) || 0)));
  const capped = caps.filter((c) => c > 0).reduce((a, b) => a + b, 0);
  if (total > 0) return caps.some((c) => c === 0) ? total : Math.min(total, capped);
  return capped;
}

export function resaleUnlocked(maxCapacity: number, min = RESALE_MIN_CAPACITY): boolean {
  return maxCapacity >= min;
}

export function resaleLockedText(maxCapacity: number, min = RESALE_MIN_CAPACITY): string {
  return `Resale marketplaces and S4K unlock at a max capacity of ${min}. This event's is ${maxCapacity}.`;
}
