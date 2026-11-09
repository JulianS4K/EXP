// The free tier and resale (migs 20261014140000, 20261029090000; the server
// rule is exos_event_max_capacity / exos_event_is_free_tier /
// exos_resale_unlocked, and the operator can change the number there):
//
//   * max capacity 150 or less (with a bounded capacity) is the FREE TIER: no
//     Exos fee, and never listed on resale marketplaces or S4K;
//   * over 150, resale needs the organizer's opt-in for the event
//     (ResaleConsentPanel, exos_set_resale_consent).
//
// This mirrors the capacity part so the editors can say why marketplaces and
// S4K are off before a save is refused. The opt-in is the server's to know
// (exos_event_sales_rules).

import { FREE_TIER_MAX_CAPACITY, isFreeTier } from '../../../supabase/functions/_shared/platformFee.ts';

export { FREE_TIER_MAX_CAPACITY };

/** The smallest max capacity that can resell (the server's exos_resale_min_capacity). */
export const RESALE_MIN_CAPACITY = FREE_TIER_MAX_CAPACITY + 1;

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

/** Does the event have a max at all: an overall cap, or every ticket type capped? */
export function eventCapacityBounded(totalTickets: number | null | undefined, tierCapacities: number[]): boolean {
  if (Math.trunc(Number(totalTickets) || 0) > 0) return true;
  return tierCapacities.length > 0 && tierCapacities.every((c) => Math.trunc(Number(c) || 0) > 0);
}

/** The free tier: a bounded max capacity at or under the cutoff. */
export function eventIsFreeTier(maxCapacity: number, bounded: boolean, cutoff = FREE_TIER_MAX_CAPACITY): boolean {
  return bounded && isFreeTier(maxCapacity, cutoff);
}

/** Big enough to resell (the opt-in is still needed). */
export function resaleUnlocked(maxCapacity: number, cutoff = FREE_TIER_MAX_CAPACITY): boolean {
  return maxCapacity > cutoff;
}

/** Why resale is off for a capacity this small (`bounded` false: no max, so not the free tier). */
export function resaleLockedText(maxCapacity: number, cutoff = FREE_TIER_MAX_CAPACITY, bounded = true): string {
  if (!bounded) {
    return `Resale marketplaces and S4K need a max capacity over ${cutoff}. This event's capped ticket types add up to ${maxCapacity}.`;
  }
  return `Free tier: events with a max capacity of ${cutoff} or less pay no Exos fee and are never listed on resale marketplaces or S4K. This event's is ${maxCapacity}.`;
}
