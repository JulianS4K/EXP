// The Exos fee: 3% of every transaction, paid by the organizer, the way a
// card processor takes a percentage of each sale (operator, 2026-09-28).
//
//   Exos checkout      3% of the order total (all-in, tax included): the
//                      Stripe application fee on the organizer's payout.
//   marketplace sale   3% of what the marketplace pays (the payout, after
//                      its own seller fee): exos_marketplace_orders.exos_fee
//                      (mig 20260929062000).
//
// Buyers never pay an Exos fee. With net-equal marketplace prices
// (marketplace/fees.ts) the organizer nets the same on every store: a 40.00
// ticket pays 38.80 whether it sells on Exos, SeatGeek or TEvo. Rounded to
// the cent, half up. The SQL side reads the same rate from
// exos_platform_fee_bps(); change both together.

export const EXOS_FEE_BPS = 300;

/** The Exos fee on a transaction of `amountCents`: 3%, to the cent, half up (4000 -> 120, 2150 -> 65). */
export function exosFeeCents(amountCents: number, bps: number = EXOS_FEE_BPS): number {
  if (!Number.isFinite(amountCents) || amountCents <= 0 || !Number.isFinite(bps) || bps <= 0) return 0;
  return Math.floor((Math.round(amountCents) * bps + 5000) / 10000);
}

/** What the organizer keeps of a transaction after the Exos fee. */
export function organizerNetCents(amountCents: number, bps: number = EXOS_FEE_BPS): number {
  return Math.round(amountCents) - exosFeeCents(amountCents, bps);
}
