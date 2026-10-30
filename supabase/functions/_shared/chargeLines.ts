// What a checkout charges, processor-neutral (mig 20261031220000).
//
// exos-checkout prices an order once (scheduled tier price, voucher, fee
// rules folded into the all-in unit price, exclusive tax) and lists it as
// ChargeLines. Stripe's line_items and PayPal's order items are both mapped
// from that one list, so the two processors can never charge different
// amounts for the same cart (src/lib/paypal.test.ts "pricing parity").
// Only paid lines are charged: a $0 line is left out on both (Stripe rejects
// it in payment mode; PayPal needs item_total = amount).

import type { ChargeLine } from "./paypal/model.ts";

export type { ChargeLine };

/** Sum of what the lines charge, in cents. */
export function chargeTotalCents(lines: readonly ChargeLine[]): number {
  return lines.filter((l) => l.unitCents > 0 && l.quantity > 0).reduce((n, l) => n + l.unitCents * l.quantity, 0);
}

export interface StripeLineItem {
  quantity: number;
  price_data: {
    currency: string;
    unit_amount: number;
    product_data: { name: string; description?: string };
  };
}

/** Stripe Checkout line_items for the same lines. */
export function stripeLineItems(lines: readonly ChargeLine[], currency: string): StripeLineItem[] {
  return lines.filter((l) => l.unitCents > 0 && l.quantity > 0).map((l) => ({
    quantity: l.quantity,
    price_data: {
      currency,
      unit_amount: l.unitCents,
      product_data: { name: l.name, ...(l.description ? { description: l.description } : {}) },
    },
  }));
}
