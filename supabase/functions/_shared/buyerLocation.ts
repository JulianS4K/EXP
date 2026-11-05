// Where a buyer is (mig 20261106140000, docs/security.md "Buyer location"): the
// country, region, city and postal code of the payer's billing address, as
// the payment processor already hands it to us. Exos never geolocates an IP
// address and never stores a street line.
//
//   stripe_billing        Checkout Session customer_details.address (in the
//                         checkout.session.completed payload itself)
//   stripe_card_billing   the charge's billing_details.address (read by the
//                         fee-actuals PaymentIntent read the webhook already
//                         makes; no extra Stripe call)
//   stripe_card_country   the card's issuing country only
//                         (payment_method_details.card.country)
//   paypal_payer          the PayPal / Venmo payer's address in the capture
//                         response (payment_source.*.address, payer.address)
//   paypal_shipping       purchase_units[0].shipping.address, when present
//
// Pure, no imports (structural types only), so Deno and vitest
// (src/lib/buyerLocation.test.ts) load the same code. stripe-webhook and
// exos-paypal call exos_record_order_location with locationRpcArgs; the SQL
// cleans every value again.

export type LocationSource =
  | 'stripe_billing'
  | 'stripe_card_billing'
  | 'stripe_card_country'
  | 'paypal_payer'
  | 'paypal_shipping';

export interface BuyerLocation {
  /** ISO 3166-1 alpha-2, upper case. Always set: no country, no location. */
  country: string;
  region: string | null;
  city: string | null;
  postal_code: string | null;
  source: LocationSource;
}

export const REGION_MAX = 80;
export const CITY_MAX = 80;
export const POSTAL_MAX = 16;

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : null);

/** An ISO alpha-2 country code ("us" -> "US"), or null. "XX"-style placeholders are kept as Stripe sends them. */
export function cleanCountry(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(s) ? s : null;
}

/** Free text (a city or a region): NFKC, no control characters, single spaces, capped; null when empty. */
export function cleanPart(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  const s = v.normalize('NFKC').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) return null;
  return [...s].slice(0, max).join('').trim() || null;
}

/** A postal code: letters, digits, spaces and dashes only, upper case, capped; null otherwise. */
export function cleanPostal(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.normalize('NFKC').trim().replace(/\s+/g, ' ').toUpperCase();
  if (!s || s.length > POSTAL_MAX || !/^[A-Z0-9][A-Z0-9 -]*$/.test(s)) return null;
  return s;
}

/**
 * A Stripe-shaped address ({ line1, line2, city, state, postal_code, country })
 * reduced to what Exos keeps. line1 / line2 are never read.
 */
export function fromStripeAddress(a: unknown, source: LocationSource): BuyerLocation | null {
  const addr = obj(a);
  const country = cleanCountry(addr?.country);
  if (!addr || !country) return null;
  return {
    country,
    region: cleanPart(addr.state, REGION_MAX),
    city: cleanPart(addr.city, CITY_MAX),
    postal_code: cleanPostal(addr.postal_code),
    source,
  };
}

/** A PayPal-shaped address ({ address_line_1, admin_area_2, admin_area_1, postal_code, country_code }). */
export function fromPayPalAddress(a: unknown, source: LocationSource): BuyerLocation | null {
  const addr = obj(a);
  const country = cleanCountry(addr?.country_code);
  if (!addr || !country) return null;
  return {
    country,
    region: cleanPart(addr.admin_area_1, REGION_MAX),
    city: cleanPart(addr.admin_area_2, CITY_MAX),
    postal_code: cleanPostal(addr.postal_code),
    source,
  };
}

/** The buyer's billing address on a Checkout Session (checkout.session.completed's data.object). */
export function locationFromStripeSession(session: unknown): BuyerLocation | null {
  const s = obj(session);
  return fromStripeAddress(obj(s?.customer_details)?.address, 'stripe_billing');
}

/**
 * From a charge (the PaymentIntent's latest_charge): its billing address when
 * it has a country, else the card's issuing country alone.
 */
export function locationFromStripeCharge(charge: unknown): BuyerLocation | null {
  const c = obj(charge);
  if (!c) return null;
  const billed = fromStripeAddress(obj(c.billing_details)?.address, 'stripe_card_billing');
  if (billed) return billed;
  const country = cleanCountry(obj(obj(c.payment_method_details)?.card)?.country);
  return country ? { country, region: null, city: null, postal_code: null, source: 'stripe_card_country' } : null;
}

/**
 * From a PayPal Orders v2 order (the capture response or GET /orders/:id):
 * the payer's address on the funding source (paypal / venmo), then payer.address,
 * then the first purchase unit's shipping address.
 */
export function locationFromPayPalOrder(order: unknown): BuyerLocation | null {
  const o = obj(order);
  if (!o) return null;
  const ps = obj(o.payment_source);
  for (const k of ['paypal', 'venmo']) {
    const loc = fromPayPalAddress(obj(ps?.[k])?.address, 'paypal_payer');
    if (loc) return loc;
  }
  const payer = fromPayPalAddress(obj(o.payer)?.address, 'paypal_payer');
  if (payer) return payer;
  const pu = Array.isArray(o.purchase_units) ? obj(o.purchase_units[0]) : null;
  return fromPayPalAddress(obj(pu?.shipping)?.address, 'paypal_shipping');
}

/** exos_record_order_location's arguments. */
export function locationRpcArgs(sessionId: string, loc: BuyerLocation): Record<string, string | null> {
  return {
    p_session_id: sessionId,
    p_country: loc.country,
    p_region: loc.region,
    p_city: loc.city,
    p_postal_code: loc.postal_code,
    p_source: loc.source,
  };
}

export type LocationOutcome = 'recorded' | 'kept' | 'skipped' | 'none' | 'error';

interface LocationDb {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
}

/**
 * Best effort, never throws: store one order's location. 'none' when the
 * payment carried no country. A database error (or the migration not yet
 * applied) is logged and leaves the order without a location; it never fails
 * fulfilment.
 */
export async function recordBuyerLocation(
  db: LocationDb, sessionId: string, loc: BuyerLocation | null, log: (msg: string, err?: unknown) => void,
): Promise<LocationOutcome> {
  if (!loc) return 'none';
  try {
    const { data, error } = await db.rpc('exos_record_order_location', locationRpcArgs(sessionId, loc));
    if (error) {
      if (error.code !== 'PGRST202') log(`buyer location: record failed for ${sessionId}`, error);
      return 'error';
    }
    const s = String(data ?? '');
    return s === 'recorded' || s === 'kept' ? s : 'skipped';
  } catch (e) {
    log(`buyer location: record failed for ${sessionId}`, e);
    return 'error';
  }
}
