// Gift cards, giving, passes and memberships: the pure maths shared by the
// edge functions (exos-checkout, exos-commerce) and the SPA (src/lib/commerce.ts
// re-exports it; src/lib/commerce.test.ts tests it). No Deno or Supabase
// imports. Amounts are integer minor units (cents).
//
// The SQL side (mig 20261030130000) checks the same code format
// (exos_gift_card_check_ok); the test runs the same vectors.

export const GIFT_CARD_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** Stripe's smallest card charge in a two-decimal currency (USD, EUR, GBP, CAD...). */
export const MIN_CARD_CHARGE_CENTS = 50;

/** Upper case without dashes or spaces; null if anything but the alphabet (16 long) is left. */
export function normalizeGiftCardCode(code: unknown): string | null {
  if (typeof code !== 'string') return null;
  const c = code.replace(/[\s-]/g, '').toUpperCase();
  return /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{16}$/.test(c) ? c : null;
}

function luhnSum(chars: string, startFactor: 1 | 2): number {
  let f = startFactor;
  let s = 0;
  for (let i = chars.length - 1; i >= 0; i--) {
    const v = GIFT_CARD_ALPHABET.indexOf(chars[i]) * f;
    s += Math.floor(v / 32) + (v % 32);
    f = f === 2 ? 1 : 2;
  }
  return s;
}

/** The Luhn mod 32 check character for 15 payload characters. */
export function giftCardCheckChar(payload: string): string {
  return GIFT_CARD_ALPHABET[(32 - (luhnSum(payload, 2) % 32)) % 32];
}

/** True for a well-formed code (a single mistyped character always fails). */
export function giftCardCheckOk(code: unknown): boolean {
  const c = normalizeGiftCardCode(code);
  return c !== null && luhnSum(c, 1) % 32 === 0;
}

/** A new code from 15 random bytes (each mod 32: uniform, 75 bits). */
export function makeGiftCardCode(random15: Uint8Array): string {
  if (random15.length < 15) throw new Error('need 15 random bytes');
  let p = '';
  for (let i = 0; i < 15; i++) p += GIFT_CARD_ALPHABET[random15[i] % 32];
  return p + giftCardCheckChar(p);
}

/** XXXX-XXXX-XXXX-XXXX (as typed if it isn't a code). */
export function formatGiftCardCode(code: string): string {
  const c = normalizeGiftCardCode(code);
  return c ? c.match(/.{4}/g)!.join('-') : code;
}

/**
 * How much of an order a gift card pays. All of it when the balance covers
 * it; otherwise as much as leaves a card charge Stripe accepts (at least
 * MIN_CARD_CHARGE_CENTS). 0 when nothing can be applied.
 */
export function giftCardApplied(totalCents: number, applicableCents: number, minCharge = MIN_CARD_CHARGE_CENTS): number {
  const total = Math.max(0, Math.trunc(totalCents));
  const avail = Math.max(0, Math.trunc(applicableCents));
  if (total === 0 || avail === 0) return 0;
  if (avail >= total) return total;
  const rest = total - avail;
  if (rest >= minCharge) return avail;
  return Math.max(0, total - minCharge);
}

/** A donation amount from a form or a request: whole cents, 1.00 to 100,000.00. */
export function parseDonationCents(v: unknown): number | null {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n)) return null;
  return n >= 100 && n <= 10_000_000 ? n : null;
}

/** Major units typed by a person ("25", "25.5") to cents; null if it isn't money. */
export function majorToCents(v: string): number | null {
  const t = v.trim();
  if (!/^\d{1,9}(\.\d{1,2})?$/.test(t)) return null;
  const [a, b = ''] = t.split('.');
  return Number(a) * 100 + Number((b + '00').slice(0, 2));
}

/** The donor's cover-the-fees top-up: bps of the gift, half up. */
export function coverFeesCents(amountCents: number, bps: number): number {
  if (amountCents <= 0 || bps <= 0) return 0;
  return Math.floor((amountCents * bps + 5000) / 10000);
}

/**
 * Round-up donation at checkout: up to the next whole unit; an order that is
 * already whole rounds to the next multiple of 5 units.
 */
export function roundUpDonationCents(totalCents: number): number {
  if (totalCents <= 0) return 0;
  const r = totalCents % 100;
  if (r !== 0) return 100 - r;
  const units = totalCents / 100;
  return (5 - (units % 5)) * 100;
}

/** Percent off a unit, rounded half up once (member price). 0-100. */
export function memberUnitCents(unitCents: number, discountPercent: number): number {
  if (unitCents <= 0 || !(discountPercent > 0)) return Math.max(0, unitCents);
  const pct = Math.min(100, discountPercent);
  const off = Math.floor((unitCents * Math.round(pct * 1000) + 50_000) / 100_000);
  return Math.max(0, unitCents - off);
}

/** Members' price applies to at most 1 + guestAllowance tickets per order. */
export function memberPriceApplies(quantity: number, guestAllowance: number): boolean {
  return quantity >= 1 && quantity <= 1 + Math.max(0, Math.trunc(guestAllowance || 0));
}

export interface PassEligibility {
  event_ids?: string[] | null;
  date_from?: string | null;
  date_to?: string | null;
  tier_ids?: string[] | null;
}

/** Whether a pass covers an event (named events, or a start date in the range) and tier. */
export function passCovers(e: PassEligibility, event: { id: string; starts_at: string | null }, tierId: string): boolean {
  const named = e.event_ids ?? [];
  if (named.length > 0) {
    if (!named.includes(event.id)) return false;
  } else {
    if (!event.starts_at) return false;
    const t = Date.parse(event.starts_at);
    if (e.date_from && t < Date.parse(e.date_from)) return false;
    if (e.date_to && t >= Date.parse(e.date_to)) return false;
  }
  const tiers = e.tier_ids ?? [];
  return tiers.length === 0 || tiers.includes(tierId);
}

/** Credits left on a pass; null = unlimited (a season pass over a date range). */
export function passCreditsLeft(total: number | null, used: number): number | null {
  return total === null ? null : Math.max(0, total - used);
}

/** Stripe subscription status → membership status (docs/memberships.md). */
export function membershipStatusFromStripe(s: string | null | undefined): 'active' | 'past_due' | 'cancelled' | 'expired' | null {
  switch (s) {
    case 'active':
    case 'trialing':
      return 'active';
    case 'past_due':
    case 'unpaid':
      return 'past_due';
    case 'canceled':
      return 'cancelled';
    case 'incomplete_expired':
      return 'expired';
    default:
      return null;
  }
}
