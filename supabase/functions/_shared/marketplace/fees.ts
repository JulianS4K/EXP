// Marketplace seller fees, and the list price that keeps an organizer's
// money the same whichever store sells the ticket.
//
// Buyers on a marketplace pay whatever that marketplace adds on top; Exos
// can't see or control that markup. What Exos controls is the price it lists
// at, and each marketplace takes its seller fee out of that before paying.
// Net-equal pricing lists at the smallest price whose payout, after the fee,
// is what Exos charges for the ticket (40.00 nets 40.00), so a sale anywhere
// pays the organizer the same as a sale on Exos. A marketplace price never
// undercuts Exos: the payout alone is the Exos price, so the list price is higher.
//
// Rates, from real S4K orders (docs/marketplace/README.md, "Seller fees"):
//   evo       3% of the order total, rounded to the cent, half up (TEvo
//             order.fee; 4,371 of 4,371 sales, May-Sep 2026)
//   seatgeek  5% of the subtotal, not rounded (raw.fees; 8,506 of 8,507
//             orders since March 2026)
//   stubhub, gametime, gotickets, vivid: not known. Their sales report the
//             payout only, and the price S4K listed at isn't in Terminal's
//             data. Exos records the price it listed at on every sale
//             (exos_marketplace_orders.list_unit_price, mig 20260929062000),
//             so exos_marketplace_fee_rates shows the real rate once they
//             sell; set it here then. Until then they list at the Exos price.

import type { SplitChannel } from './listingStandard.ts';

export interface SellerFee {
  /** Basis points of the gross (300 = 3%). */
  bps: number;
  /** How the marketplace rounds the fee. */
  rounding: 'cent_half_up' | 'none';
  /** Where the rate comes from. */
  source: string;
}

export const SELLER_FEES: Record<SplitChannel, SellerFee | null> = {
  evo: { bps: 300, rounding: 'cent_half_up', source: 'TEvo order.fee, 4,371/4,371 S4K sales (2026-05..09)' },
  seatgeek: { bps: 500, rounding: 'none', source: 'SeatGeek order fees/subtotal, 8,506/8,507 orders since 2026-03' },
  stubhub: null,
  gametime: null,
  gotickets: null,
  vivid: null,
};

/** The fee on a gross of `grossCents`, in cents (may be fractional when the marketplace doesn't round). */
export function sellerFeeCents(channel: SplitChannel, grossCents: number): number {
  const f = SELLER_FEES[channel];
  if (!f || !Number.isFinite(grossCents) || grossCents <= 0) return 0;
  const exact = (grossCents * f.bps) / 10000;
  return f.rounding === 'cent_half_up' ? Math.floor(exact + 0.5) : exact;
}

/** The most tickets one listing is checked for (a listing is at most one order: max per order). */
export const NET_EQUAL_MAX_QTY = 100;

/**
 * The per-ticket list price, in cents, that nets exactly `targetCents` per
 * ticket after the marketplace's fee: the smallest L whose payout on n
 * tickets is at least n x target for every n up to NET_EQUAL_MAX_QTY. It
 * starts at target / (1 - rate) and steps up a cent while the fee's
 * rounding would leave any quantity short.
 */
export function netEqualListCents(channel: SplitChannel, targetCents: number): number {
  const f = SELLER_FEES[channel];
  if (!Number.isInteger(targetCents) || targetCents <= 0) return targetCents;
  if (!f || f.bps <= 0) return targetCents;
  let list = Math.ceil((targetCents * 10000) / (10000 - f.bps));
  // Never below the exact gross-up; a cent or two above covers rounding.
  const short = (l: number) => {
    for (let n = 1; n <= NET_EQUAL_MAX_QTY; n++) if (payoutCents(channel, l, n) < targetCents * n) return true;
    return false;
  };
  while (short(list)) list++;
  return list;
}

/** Dollars in, dollars out (2 decimals): the net-equal list price for an Exos price. */
export function netEqualListPrice(channel: SplitChannel, exosPrice: number): number {
  const cents = Math.round(exosPrice * 100);
  return netEqualListCents(channel, cents) / 100;
}

/** What the organizer is paid for `qty` tickets listed at `unitCents` (cents, rounded to the cent). */
export function payoutCents(channel: SplitChannel, unitCents: number, qty: number): number {
  const gross = unitCents * qty;
  return Math.round(gross - sellerFeeCents(channel, gross));
}
