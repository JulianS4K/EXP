// Guest checkout rules the SPA shares with the server (mig 20260928050000).
import { normalizeGuestEmail } from '../../supabase/functions/_shared/guest.ts';

/** Same email rule exos-checkout and exos_create_guest_hold apply. */
export function isGuestEmail(raw: string): boolean {
  return normalizeGuestEmail(raw) !== null;
}

/** Guest checkout is on unless the organizer switched it off for the event. */
export function guestCheckoutAllowed(limits: { guestCheckout?: boolean } | null | undefined): boolean {
  return limits?.guestCheckout !== false;
}

export type SignedOutBuy = 'code-choice' | 'sign-in-code' | 'guest-paid' | 'guest-free' | 'sign-in';

/** What Buy does for a signed-out buyer. A promo / access code needs an
 *  account (exos-checkout refuses one from a guest), so a code waiting for
 *  sign-in never drops silently into a full-price guest checkout: the buyer
 *  picks "sign in to use it" or "continue without it" (skipCode). With no
 *  guest checkout to fall back on, it's straight to sign-in, code kept. */
export function signedOutBuyRoute(o: {
  waitingCode: string | null;
  skipCode?: boolean;
  tierId: string | null | undefined;
  paid: boolean;
  stripeEnabled: boolean;
  guestAllowed: boolean;
}): SignedOutBuy {
  const guest = o.tierId && o.guestAllowed && (o.stripeEnabled || !o.paid) ? (o.paid ? 'guest-paid' : 'guest-free') : null;
  if (o.waitingCode && !o.skipCode) return guest ? 'code-choice' : 'sign-in-code';
  return guest ?? 'sign-in';
}
