// Scheduled tier pricing (seller-side dynamic pricing, v1 — time-based).
//
// A tier's `price` is the opening/default price. `priceSchedule` is an ordered
// list of {startsAt, price} steps — "on/after this time, the price becomes this".
// The EFFECTIVE price right now is the price of the latest step whose startsAt is
// in the past, or the base price if none apply. Computed at read time (no cron),
// so the storefront shows the live price and an "increases on <date>" nudge.
//
// This models early-bird → regular → last-minute and steady price ramps. It is
// our OWN primary-market inventory — unrelated to the RULE-2 upstream reprice
// lockdown (see mig 20260703122000).

import { feeUnitCents, unitFeeTotals, type UnitFee } from './fees';

export interface PriceStep {
  /** ISO timestamp — the step takes effect on/after this moment. */
  startsAt: string;
  /** The price from this step onward (until a later step supersedes it). */
  price: number;
}

/** Keep only well-formed steps, normalized + sorted ascending by time. */
export function normalizeSchedule(schedule: unknown): PriceStep[] {
  if (!Array.isArray(schedule)) return [];
  return schedule
    .filter(
      (s): s is PriceStep =>
        !!s &&
        typeof (s as any).price === 'number' &&
        (s as any).price >= 0 &&
        typeof (s as any).startsAt === 'string' &&
        !Number.isNaN(Date.parse((s as any).startsAt)),
    )
    .map((s) => ({ startsAt: new Date(s.startsAt).toISOString(), price: s.price }))
    .sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));
}

/**
 * The tier's price at `now` — base price overridden by the latest already-active
 * schedule step. Falls back to the base price when the schedule is empty/invalid
 * or entirely in the future.
 */
export function effectiveTierPrice(
  basePrice: number,
  schedule?: unknown,
  now: Date = new Date(),
): number {
  const steps = normalizeSchedule(schedule);
  let price = basePrice;
  const t = now.getTime();
  for (const s of steps) {
    if (Date.parse(s.startsAt) <= t) price = s.price;
    else break;
  }
  return price;
}

/**
 * The next scheduled step in the future (for "price changes to $X on <date>"),
 * or null when nothing upcoming. The caller compares its price to the current
 * effective price to decide whether it's a rise or a drop.
 */
export function nextPriceStep(schedule?: unknown, now: Date = new Date()): PriceStep | null {
  const steps = normalizeSchedule(schedule);
  const t = now.getTime();
  for (const s of steps) {
    if (Date.parse(s.startsAt) > t) return s;
  }
  return null;
}

// ---------------------------------------------------------------------------
// All-in pricing (operator decision 2026-09-24): every price a buyer sees is
// the full amount they pay. "All-in" = price + the organizer's passed-on fees
// (fee rules, mig 20261027100000, ./fees.ts) + EXCLUSIVE tax on the price and
// the taxable fees, computed per unit in cents exactly like exos-checkout's
// allInCents (supabase/functions/_shared/pricing.ts); pricingParity.test.ts
// keeps them identical. No fee is ever added at checkout.
// ---------------------------------------------------------------------------

/** Price + passed-on fees + exclusive tax, per unit (exclusiveTaxPercent = 0 when tax is included). */
export function allInPrice(price: number, exclusiveTaxPercent?: number | null, fees?: readonly UnitFee[] | null): number {
  const cents = Math.round(price * 100);
  const rate = Number(exclusiveTaxPercent) || 0;
  const f = unitFeeTotals(cents, fees);
  if (rate <= 0) return (cents + f.total) / 100;
  return (cents + f.total + Math.round(((cents + f.taxable) * rate) / 100)) / 100;
}

/** The passed-on fees inside one unit's all-in price, per rule (for "includes $2.00 facility fee"). */
export function includedFees(price: number, fees?: readonly UnitFee[] | null): { name: string; amount: number }[] {
  const cents = Math.round(price * 100);
  return (fees ?? [])
    .map((f) => ({ name: f.name || 'Fee', amount: feeUnitCents(cents, f) / 100 }))
    .filter((f) => f.amount > 0);
}

interface PricedTier {
  price: number;
  priceSchedule?: unknown;
  exclusiveTaxPercent?: number;
  /** Passed-on fee rules (exos_public_tiers.passed_on_fees). */
  passedOnFees?: readonly UnitFee[];
}

/** All-in price of `price` (scheduled / code price) on this tier: its fees and tax. */
export function tierAllInPrice(tier: Omit<PricedTier, 'price'>, price: number): number {
  return allInPrice(price, tier.exclusiveTaxPercent, tier.passedOnFees);
}

/** What a buyer pays per ticket for this tier right now (scheduled price, all-in). */
export function buyerTierPrice(tier: PricedTier, now: Date = new Date()): number {
  return tierAllInPrice(tier, effectiveTierPrice(tier.price, tier.priceSchedule, now));
}

/** Lowest current all-in tier price for "from $X" labels; falls back to `fallback`. */
export function fromPrice(tiers: PricedTier[] | undefined, fallback: number): number {
  if (!tiers || tiers.length === 0) return fallback;
  return Math.min(...tiers.map((t) => buyerTierPrice(t)));
}
