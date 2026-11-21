// The event page's "from" price, by the shared rule (supabase/functions/
// _shared/eventStrings.ts: the catalog feed's, which the crawler card and the
// JSON-LD use too), from the page's mapped ticket types (lib/events.ts mapTier).

import { eventFrom, money, type FromAvailability, type FromTier } from '../../supabase/functions/_shared/eventStrings.ts';
import type { Event } from '../types';

type Tier = NonNullable<Event['ticketTiers']>[number];
type Ts = { toMillis?: () => number } | null | undefined;

const iso = (t: Ts): string | null => {
  const ms = t?.toMillis?.();
  return typeof ms === 'number' && Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : null;
};

/** Mapped tiers in the public view's column names. */
export function pageTierRows(tiers: readonly Tier[] | undefined): FromTier[] {
  return (tiers ?? []).map((t) => ({
    price: t.price,
    price_schedule: t.priceSchedule,
    exclusive_tax_percent: t.exclusiveTaxPercent ?? 0,
    passed_on_fees: t.passedOnFees ?? [],
    capacity: t.capacity,
    sold: t.sold,
    sales_start: iso(t.salesStart as Ts),
    sales_end: iso(t.salesEnd as Ts),
  }));
}

/** The "from" price in currency units (all-in) and its availability, or null with no ticket types. */
export function pageFrom(
  tiers: readonly Tier[] | undefined, ev: { totalTickets?: number; ticketsSold?: number } = {}, now: Date = new Date(),
): { amount: number; cents: number; availability: FromAvailability } | null {
  const r = eventFrom(pageTierRows(tiers), now, { total_tickets: ev.totalTickets ?? 0, tickets_sold: ev.ticketsSold ?? 0 });
  return r ? { amount: r.cents / 100, cents: r.cents, availability: r.availability } : null;
}

/** "$25" / "Free": the shared money format. */
export function pageMoney(cents: number, currency: string | undefined): string {
  return money(cents, currency || 'USD');
}
