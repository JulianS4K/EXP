// Urgency labels on the event page's ticket type list (UX quick wins,
// 2026-11-21). One pure function, so every label follows the same rules and
// none of them overstates scarcity.
//
// Rules:
// - "N left" only when the type is genuinely low: at most LOW_STOCK_MAX (20)
//   left AND at most LOW_STOCK_SHARE (15%) of its capacity (rounded up, at
//   least 1). "1,500 left" of 10,000 is not scarce, and neither is "18 left"
//   of 20; otherwise the list just says Available.
// - Sold out (or closed, capacity 0: there is no unlimited, _shared/capacity.ts)
//   stays in the list, struck through, so a buyer sees the early tiers went.
// - "Sales end soon" in the last SALES_END_SOON_MS (24h) of the type's own
//   sales window (sales_end), while it is still on sale and not sold out.
// - No "Selling fast": the public tier read (exos_public_tiers) carries no
//   sales velocity; the only 24h count (sold_last_24h) is in the organizer's
//   settlement data, and publishing it would need a new public read.

import { capacityLeft } from '../../supabase/functions/_shared/capacity.ts';

export const LOW_STOCK_MAX = 20;
export const LOW_STOCK_SHARE = 0.15;
export const SALES_END_SOON_MS = 24 * 60 * 60 * 1000;

export type TierUrgencyInput = {
  capacity: number | null | undefined;
  sold: number | null | undefined;
  /** epoch ms, or null when the type has no window edge */
  salesStartMs?: number | null;
  salesEndMs?: number | null;
  nowMs: number;
};

export type TierUrgency = {
  left: number;
  soldOut: boolean;
  /** strike the type's name through (sold out or sales ended) */
  struck: boolean;
  /** the "N left" number, or null when the type isn't low */
  lowStockLeft: number | null;
  salesEndSoon: boolean;
  salesEnded: boolean;
  notYetOnSale: boolean;
};

/** Most "left" a type of this capacity may show as "N left". */
export function lowStockThreshold(capacity: number | null | undefined): number {
  const cap = Math.floor(Number(capacity));
  if (!Number.isFinite(cap) || cap <= 0) return 0;
  return Math.min(LOW_STOCK_MAX, Math.max(1, Math.ceil(cap * LOW_STOCK_SHARE)));
}

export function tierUrgency(i: TierUrgencyInput): TierUrgency {
  const left = capacityLeft(i.capacity, i.sold);
  const soldOut = left === 0;
  const notYetOnSale = i.salesStartMs != null && Number.isFinite(i.salesStartMs) && i.salesStartMs > i.nowMs;
  const salesEnded = i.salesEndMs != null && Number.isFinite(i.salesEndMs) && i.salesEndMs <= i.nowMs;
  const onSale = !soldOut && !notYetOnSale && !salesEnded;
  const lowStockLeft = onSale && left <= lowStockThreshold(i.capacity) ? left : null;
  const salesEndSoon = onSale && i.salesEndMs != null && i.salesEndMs - i.nowMs <= SALES_END_SOON_MS;
  return { left, soldOut, struck: soldOut || salesEnded, lowStockLeft, salesEndSoon, salesEnded, notYetOnSale };
}
