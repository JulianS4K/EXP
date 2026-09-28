// Server-side scheduled tier price, used by exos-checkout to charge what the
// storefront shows. Mirrors EXP src/lib/pricing.ts effectiveTierPrice exactly;
// EXP's src/lib/pricingParity.test.ts compares the two. No imports, so both
// Deno and vitest can load it.
//
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

// All-in unit price in cents: the price plus its EXCLUSIVE tax, per unit, so
// the charge is exactly (displayed all-in price x quantity). exclusiveTaxPercent
// is 0 when the price already includes tax. Mirrors EXP src/lib/pricing.ts allInPrice.
export function allInCents(unitCents: number, exclusiveTaxPercent: number): number {
  const rate = Number(exclusiveTaxPercent) || 0;
  if (rate <= 0) return unitCents;
  return unitCents + Math.round((unitCents * rate) / 100);
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
