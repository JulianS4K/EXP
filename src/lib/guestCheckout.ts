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
