// Tiered deal brackets (mig 20261102120000, docs/offers-settlements.md
// "Tiered deals"). Pure TypeScript with no imports: dealMath.ts, the
// dashboard and exos-api run this one file, and the SQL twin
// (_exos_bracket_amount) computes the same numbers; tests/exos/
// test_finance_extras.sql checks the fixtures src/lib/dealBrackets.test.ts
// checks.
//
// A bracket changes an offer's percentage from a threshold upward:
//   offer percentage 85, bracket { threshold: 2_000_000, percentage: 90 }
//   = 85 % of the base up to $20,000 and 90 % of the part above.
// Below the lowest threshold the offer's own percentage applies (a bracket
// at threshold 0 replaces it). Thresholds are on one basis per offer:
//   amount   the base itself, in cents (the base is what the deal's
//            percentage applies to: net after expenses for versus, net box
//            office for door, the overage above the split point for plus);
//   tickets  paid tickets sold; each tier gets the share of the base its
//            tickets are of all paid tickets sold.
// Thresholds are whole numbers, unique per offer, so in threshold order they
// are strictly increasing and tiers never overlap or leave gaps. Each tier's
// amount is rounded half-up once (exact integer arithmetic), then summed.

export const BRACKET_BASES = ['amount', 'tickets'] as const;
export type BracketBasis = (typeof BRACKET_BASES)[number];
export const MAX_BRACKETS = 20;
export const MAX_THRESHOLD = 100_000_000_000;

export interface Bracket {
  threshold: number;
  percentage: number;
}

export interface Brackets {
  basis: BracketBasis;
  tiers: Bracket[];
}

export interface TierResult {
  from: number;
  /** null: no upper bound. */
  to: number | null;
  percentage: number;
  /** Basis units in this tier (cents for amount, tickets for tickets). */
  units: number;
  amount: number;
}

/** Percentage in thousandths (85.125 → 85125). */
const milli = (p: number) => Math.round(Math.min(100, Math.max(0, Number.isFinite(p) ? p : 0)) * 1000);

/** Half-up of n / d for n >= 0, d > 0, exact. */
function halfUp(n: bigint, d: bigint): bigint {
  return (2n * n + d) / (2n * d);
}

/** Problems with a set of brackets (empty: fine). Input order does not matter. */
export function bracketErrors(rows: { basis?: unknown; threshold?: unknown; percentage?: unknown }[]): string[] {
  const errors: string[] = [];
  if (rows.length > MAX_BRACKETS) errors.push(`at most ${MAX_BRACKETS} brackets per offer`);
  const bases = new Set(rows.map((r) => r.basis));
  if (bases.size > 1) errors.push('every bracket of an offer has the same basis');
  for (const b of bases) {
    if (!(BRACKET_BASES as readonly unknown[]).includes(b)) errors.push(`basis must be one of ${BRACKET_BASES.join(', ')}`);
  }
  const seen = new Set<number>();
  for (const r of rows) {
    const t = r.threshold;
    if (typeof t !== 'number' || !Number.isSafeInteger(t) || t < 0 || t > MAX_THRESHOLD) {
      errors.push('threshold must be a whole number, 0 or more');
    } else if (seen.has(t)) {
      errors.push(`two brackets start at ${t}: thresholds must be strictly increasing`);
    } else seen.add(t);
    const p = r.percentage;
    if (typeof p !== 'number' || !Number.isFinite(p) || p < 0 || p > 100 || Math.abs(p * 1000 - Math.round(p * 1000)) > 1e-6) {
      errors.push('percentage must be from 0 to 100 (at most 3 decimals)');
    }
  }
  return [...new Set(errors)];
}

/** Brackets in threshold order (a copy). */
export function sortBrackets<T extends { threshold: number }>(rows: readonly T[]): T[] {
  return [...rows].sort((a, b) => a.threshold - b.threshold);
}

/** The tiers in force: the offer's percentage from 0 to the first threshold, then each bracket. */
function tiersOf(defaultPct: number, b: Brackets): { from: number; percentage: number }[] {
  const sorted = sortBrackets(b.tiers.filter((t) => Number.isFinite(t.threshold) && t.threshold >= 0));
  const out: { from: number; percentage: number }[] = [];
  if (!sorted.length || sorted[0].threshold > 0) out.push({ from: 0, percentage: defaultPct });
  for (const t of sorted) {
    if (out.length && out[out.length - 1].from === t.threshold) out[out.length - 1] = { from: t.threshold, percentage: t.percentage };
    else out.push({ from: Math.floor(t.threshold), percentage: t.percentage });
  }
  return out;
}

/**
 * The tiered amount of `base` (cents) with `sold` paid tickets. `defaultPct`
 * is the offer's own percentage (below the first threshold).
 */
export function tieredAmount(base: number, sold: number, defaultPct: number, b: Brackets): { amount: number; tiers: TierResult[] } {
  const x = Math.max(0, Math.round(Number.isFinite(base) ? base : 0));
  const n = Math.max(0, Math.floor(Number.isFinite(sold) ? sold : 0));
  const tiers = tiersOf(defaultPct, b);
  const out: TierResult[] = [];
  let total = 0n;
  for (let i = 0; i < tiers.length; i++) {
    const from = tiers[i].from;
    const to = i + 1 < tiers.length ? tiers[i + 1].from : null;
    const pm = BigInt(milli(tiers[i].percentage));
    let units: number;
    let amount: bigint;
    if (b.basis === 'tickets') {
      if (n === 0) {
        // Nothing sold: the whole base sits in the tier in force at 0 tickets.
        units = 0;
        amount = i === 0 ? halfUp(BigInt(x) * pm, 100_000n) : 0n;
      } else {
        units = Math.max(0, Math.min(n, to ?? n) - from);
        amount = halfUp(BigInt(x) * BigInt(units) * pm, BigInt(n) * 100_000n);
      }
    } else {
      units = Math.max(0, Math.min(x, to ?? x) - from);
      amount = halfUp(BigInt(units) * pm, 100_000n);
    }
    total += amount;
    out.push({ from, to, percentage: tiers[i].percentage, units, amount: Number(amount) });
  }
  return { amount: Number(total), tiers: out };
}

/** The smallest base (cents) whose tiered amount reaches `target`; null when no base does. */
export function tieredReachAt(target: number, sold: number, defaultPct: number, b: Brackets): number | null {
  const goal = Math.max(0, Math.round(target));
  if (goal === 0) return 0;
  let hi = 1;
  while (tieredAmount(hi, sold, defaultPct, b).amount < goal) {
    hi *= 2;
    if (hi > MAX_THRESHOLD * 4) return null;
  }
  let lo = 0;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (tieredAmount(mid, sold, defaultPct, b).amount >= goal) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/** "85% to $20,000, 90% above" style text, given a money formatter. */
export function describeBrackets(defaultPct: number, b: Brackets, money: (cents: number) => string): string {
  const tiers = tiersOf(defaultPct, b);
  const unit = (v: number) => (b.basis === 'tickets' ? `${v.toLocaleString('en-US')} tickets` : money(v));
  return tiers.map((t, i) => {
    const next = tiers[i + 1];
    if (next) return i === 0 && t.from === 0 ? `${t.percentage}% to ${unit(next.from)}` : `${t.percentage}% from ${unit(t.from)} to ${unit(next.from)}`;
    return t.from === 0 ? `${t.percentage}%` : `${t.percentage}% above ${unit(t.from)}`;
  }).join(', ');
}

/** Brackets as the database returns them (settlement inputs' deal_brackets). */
export function bracketsFromJson(v: unknown): Brackets | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as { basis?: unknown; tiers?: unknown };
  const basis = o.basis === 'tickets' ? 'tickets' : o.basis === 'amount' ? 'amount' : null;
  if (!basis || !Array.isArray(o.tiers) || !o.tiers.length) return null;
  const tiers = (o.tiers as { threshold?: unknown; percentage?: unknown }[]).map((t) => ({
    threshold: Number(t?.threshold), percentage: Number(t?.percentage),
  })).filter((t) => Number.isFinite(t.threshold) && Number.isFinite(t.percentage));
  return tiers.length ? { basis, tiers } : null;
}
