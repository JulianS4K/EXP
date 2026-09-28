// Venue POS: line and cart totals with tax. PURE, integer cents, no imports
// beyond sibling .ts files, so Deno (exos-pos) and vitest (src/lib/pos) both
// load it. Scaffolding for Phase 3 (docs/pos.md).
//
// Tax follows checkout exactly (exos-checkout, _shared/pricing.ts,
// public.exos_tax_cents) and the SQL line trigger (exos_pos_tg_line, mig
// 20260929074000):
//   exclusive rule: the tax is computed PER UNIT and rounded, so the guest
//                   pays exactly the all-in price on the menu board
//                   (allInCents) x quantity.
//   inclusive rule: the price already has the tax in it; the embedded tax is
//                   extracted from the line total.

import { allInCents } from '../pricing.ts';

export type PosCategory = 'ticket' | 'bar' | 'merch';
export const POS_CATEGORIES: readonly PosCategory[] = ['ticket', 'bar', 'merch'];

/** An exos_tax_rules row, as the POS needs it. null = untaxed. */
export interface PosTaxRule {
  ratePercent: number;
  priceIncludesTax: boolean;
}

export interface PosLineInput {
  category: PosCategory;
  unitPriceCents: number;
  quantity: number;
  tax?: PosTaxRule | null;
}

export interface PosLineTotals {
  /** What the line costs net of tax. */
  netCents: number;
  taxCents: number;
  /** What the guest pays for the line (tax in). */
  totalCents: number;
}

const cents = (n: number): number => (Number.isFinite(n) ? Math.round(n) : 0);

/** Mirrors public.exos_tax_cents: inclusive extracts the embedded tax, exclusive adds on top. Half up. */
export function taxCents(amountCents: number, ratePercent: number, inclusive: boolean): number {
  const rate = Number(ratePercent) || 0;
  const amount = cents(amountCents);
  if (rate <= 0 || amount <= 0) return 0;
  return inclusive ? Math.round((amount * rate) / (100 + rate)) : Math.round((amount * rate) / 100);
}

/** One line: 2 beers at 8.00 + 10% (exclusive) = 17.60, tax 1.60. */
export function lineTotals(line: PosLineInput): PosLineTotals {
  const unit = Math.max(cents(line.unitPriceCents), 0);
  const qty = Math.max(Math.trunc(Number(line.quantity) || 0), 0);
  const rate = Number(line.tax?.ratePercent) || 0;
  if (qty === 0) return { netCents: 0, taxCents: 0, totalCents: 0 };
  if (rate > 0 && line.tax?.priceIncludesTax) {
    const total = unit * qty;
    const tax = taxCents(total, rate, true);
    return { netCents: total - tax, taxCents: tax, totalCents: total };
  }
  const allIn = allInCents(unit, rate);
  const total = allIn * qty;
  const tax = (allIn - unit) * qty;
  return { netCents: total - tax, taxCents: tax, totalCents: total };
}

export interface PosCartTotals extends PosLineTotals {
  lines: PosLineTotals[];
  byCategory: Record<PosCategory, number>;
}

/** Sum of the lines; per-category totals (tax in) feed the settlement. */
export function cartTotals(lines: readonly PosLineInput[]): PosCartTotals {
  const out: PosCartTotals = {
    netCents: 0, taxCents: 0, totalCents: 0, lines: [],
    byCategory: { ticket: 0, bar: 0, merch: 0 },
  };
  for (const l of lines) {
    const t = lineTotals(l);
    out.lines.push(t);
    out.netCents += t.netCents;
    out.taxCents += t.taxCents;
    out.totalCents += t.totalCents;
    out.byCategory[l.category] += t.totalCents;
  }
  return out;
}

/** Can this item be rung? Mirrors the SQL line trigger's refusals. */
export function sellable(
  item: { active: boolean; is86d: boolean; inventoryCount?: number | null },
  quantity: number,
): { ok: true } | { ok: false; reason: 'inactive' | '86d' | 'sold-out' } {
  if (!item.active) return { ok: false, reason: 'inactive' };
  if (item.is86d) return { ok: false, reason: '86d' };
  if (item.inventoryCount != null && item.inventoryCount < quantity) return { ok: false, reason: 'sold-out' };
  return { ok: true };
}
