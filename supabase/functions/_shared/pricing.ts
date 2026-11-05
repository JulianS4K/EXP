// Server-side scheduled tier price, used by exos-checkout to charge what the
// storefront shows. Mirrors EXP src/lib/pricing.ts effectiveTierPrice exactly;
// EXP's src/lib/pricingParity.test.ts compares the two. Imports only its
// sibling fees.ts, so both Deno and vitest can load it.

import { type UnitFee, unitFeeTotals } from "./fees.ts";

// Base price, overridden by the latest schedule step whose startsAt has passed
// (inclusive); malformed steps are ignored.
export function effectiveTierPrice(basePrice: number, schedule: unknown, now: Date = new Date()): number {
  if (!Array.isArray(schedule)) return basePrice;
  const steps = (schedule as Array<{ price?: unknown; startsAt?: unknown } | null>)
    .filter((st): st is { price: number; startsAt: string } =>
      !!st && typeof st.price === "number" && st.price >= 0 &&
      typeof st.startsAt === "string" && !Number.isNaN(Date.parse(st.startsAt)))
    .map((st) => ({ at: Date.parse(st.startsAt), price: st.price }))
    .sort((a, b) => a.at - b.at);
  let price = basePrice;
  for (const st of steps) {
    if (st.at <= now.getTime()) price = st.price;
    else break;
  }
  return price;
}

// All-in unit price in cents: the price plus its passed-on fees (organizer fee
// rules, mig 20261027100000, _shared/fees.ts) plus its EXCLUSIVE tax on the
// price and the taxable fees, per unit, so the charge is exactly (displayed
// all-in price x quantity). exclusiveTaxPercent is 0 when the price already
// includes tax. Without fees it is the price + tax, as before. Mirrors EXP
// src/lib/pricing.ts allInPrice.
export function allInCents(unitCents: number, exclusiveTaxPercent: number, fees?: readonly UnitFee[] | null): number {
  const rate = Number(exclusiveTaxPercent) || 0;
  const f = unitFeeTotals(unitCents, fees);
  if (rate <= 0) return unitCents + f.total;
  return unitCents + f.total + Math.round(((unitCents + f.taxable) * rate) / 100);
}

// A voucher's per-ticket price (mig 20260928060000): a pinned price, a percent
// off or an amount off the scheduled price, in whole cents. exos-checkout
// charges it and the storefront shows it, so both call this. Never negative.
export interface VoucherPricing {
  overridePrice?: number | null;
  discountPercent?: number | null;
  discountAmount?: number | null;
}
export function voucherUnitPrice(scheduled: number, v: VoucherPricing | null | undefined): number {
  const base = Math.round(scheduled * 100);
  if (!v) return base / 100;
  if (v.overridePrice != null) return Math.max(0, Math.round(Number(v.overridePrice) * 100)) / 100;
  const pct = Number(v.discountPercent);
  if (v.discountPercent != null && pct > 0 && pct < 100) return Math.round((base * (100 - pct)) / 100) / 100;
  const off = Number(v.discountAmount);
  if (v.discountAmount != null && off > 0) return Math.max(0, base - Math.round(off * 100)) / 100;
  return base / 100;
}
