// The Exos fee: 3% of every transaction, net to Exos after card processing,
// paid by the organizer (operator, 2026-09-28).
//
//   Exos checkout      3% of the order total (all-in, tax included) plus
//                      Stripe's card fee, as the Stripe application fee on
//                      the organizer's payout. With destination charges the
//                      platform pays Stripe, so the application fee carries
//                      Stripe's fee through to the organizer and Exos keeps
//                      3%. Stripe's fee is estimated at its standard US card
//                      rate (2.9% + 30c; EXOS_STRIPE_FEE_BPS /
//                      EXOS_STRIPE_FEE_FIXED_CENTS override).
//   marketplace sale   3% of what the marketplace pays (the payout, after
//                      its own seller fee): exos_marketplace_orders.exos_fee
//                      (mig 20260929062000). The marketplace charged the
//                      card, so there's no Stripe fee and 3% is net already.
//
// Buyers never pay an Exos fee. Rounded to the cent, half up. The SQL side reads the same rate from
// exos_platform_fee_bps(); change both together.

export const EXOS_FEE_BPS = 300;

/** The Exos fee on a transaction of `amountCents`: 3%, to the cent, half up (4000 -> 120, 2150 -> 65). */
export function exosFeeCents(amountCents: number, bps: number = EXOS_FEE_BPS): number {
  if (!Number.isFinite(amountCents) || amountCents <= 0 || !Number.isFinite(bps) || bps <= 0) return 0;
  return Math.floor((Math.round(amountCents) * bps + 5000) / 10000);
}

/** What the organizer keeps of a transaction after the Exos fee (a marketplace payout: no card fee). */
export function organizerNetCents(amountCents: number, bps: number = EXOS_FEE_BPS): number {
  return Math.round(amountCents) - exosFeeCents(amountCents, bps);
}

/** Stripe's standard US card pricing: 2.9% + 30c per successful charge. */
export const STRIPE_CARD_FEE = { bps: 290, fixedCents: 30 } as const;

export interface CardFee {
  bps: number;
  fixedCents: number;
}

/** Stripe's fee on a charge of `amountCents` (estimate at `card` rates; 0 for a free order). */
export function stripeFeeCents(amountCents: number, card: CardFee = STRIPE_CARD_FEE): number {
  if (!Number.isFinite(amountCents) || amountCents <= 0) return 0;
  return Math.floor((Math.round(amountCents) * card.bps + 5000) / 10000) + card.fixedCents;
}

/**
 * The Stripe application fee on an Exos checkout: 3% for Exos plus Stripe's
 * card fee, which the platform pays under destination charges. Never more
 * than the order. 4000 -> 120 + 146 = 266 (the organizer gets 37.34).
 */
export function checkoutApplicationFeeCents(
  amountCents: number,
  opts: { bps?: number; card?: CardFee } = {},
): number {
  if (!Number.isFinite(amountCents) || amountCents <= 0) return 0;
  const fee = exosFeeCents(amountCents, opts.bps ?? EXOS_FEE_BPS) + stripeFeeCents(amountCents, opts.card ?? STRIPE_CARD_FEE);
  return Math.min(Math.round(amountCents), fee);
}
