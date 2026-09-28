export type TicketType = 'paid' | 'free' | 'donation';

// Resale-marketplace distribution isn't built (and upstream APIs are
// read-only), so the create/edit forms keep its controls hidden.
export const SHOW_DISTRIBUTION = false;

// The old exos_discount_codes editor stays off: promo codes (% / $ off) are
// vouchers now (mig 20260928060000, Edit event → Promo and access codes),
// which checkout redeems. Saved discount codes were carried over.
export const SHOW_DISCOUNT_CODES = false;

/**
 * Keeps a tier's type in step with its price so a $0 tier doesn't fail
 * publish with "switch its type to Free". Donation tiers are left alone;
 * an empty or unparseable price changes nothing.
 */
export function autoTicketType(current: TicketType, price: unknown): TicketType {
  if (current === 'donation') return current;
  if (price === '' || price === null || price === undefined) return current;
  const n = typeof price === 'number' ? price : Number(price);
  if (!Number.isFinite(n)) return current;
  if (n === 0) return 'free';
  if (n > 0 && current === 'free') return 'paid';
  return current;
}
