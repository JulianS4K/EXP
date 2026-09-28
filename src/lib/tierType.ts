export type TicketType = 'paid' | 'free' | 'donation';

// The old "distribution" blocks (exclusivity, the unsaved discount-token
// editor) stay hidden.
export const SHOW_DISTRIBUTION = false;

// Marketplaces: omnichannel distribution of the event's own inventory. The
// organizer picks marketplaces and sets seats per ticket type (GA on StubHub
// only, VIP everywhere, ...). Listings are planned; nothing is sent to a
// marketplace until the operator authorizes live writes (dry-run writers).
export const SHOW_MARKETPLACES = true;

/** The marketplaces Exos is integrated with (docs/marketplace/). */
export const MARKETPLACE_NETWORKS = [
  { id: 'stubhub', name: 'StubHub' },
  { id: 'seatgeek', name: 'SeatGeek' },
  { id: 'vivid', name: 'Vivid Seats' },
  { id: 'gametime', name: 'Gametime' },
  { id: 'gotickets', name: 'GoTickets' },
  { id: 'evo', name: 'Ticket Evolution' },
] as const;

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
