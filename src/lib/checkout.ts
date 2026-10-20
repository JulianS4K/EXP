// Stripe checkout + Connect onboarding seam (D4-OPS-7 SCAFFOLD).
//
// Thin wrappers over the edge functions (exos-checkout / exos-connect-onboard).
// supabase.functions.invoke forwards the signed-in user's JWT automatically, so
// both calls run as the authenticated buyer / org owner. A signed-out buyer
// passes guestEmail instead (guest checkout, mig 20260928050000). UI wiring (a "Buy"
// button on the event page, a "Set up payments" button in org settings) calls
// these and redirects to the returned Stripe-hosted URL.

import { supabase } from './supabase';
import type { Attribution } from './attribution';
import type { AdIds, MarketingConsent } from './adIds';
import { fanMessage } from './fanErrors';

/** Ad click ids / browser ids and consent for the checkout record (lib/adIds.ts). */
interface CheckoutRecordInput {
  adIds?: AdIds;
  consent?: MarketingConsent;
}

function recordBody(input: CheckoutRecordInput): { ad_ids?: AdIds; consent?: MarketingConsent } {
  return {
    ad_ids: input.adIds && Object.keys(input.adIds).length > 0 ? input.adIds : undefined,
    consent: input.consent,
  };
}

/** A signed-in checkout whose session has expired (or a code that needs an
 *  account): the page sends the buyer to sign in and resumes the purchase. */
export class SignInRequiredError extends Error {
  readonly signInRequired = true;
  constructor(message = 'Your session expired. Sign in and try again.') {
    super(message);
    this.name = 'SignInRequiredError';
  }
}

export function isSignInRequired(err: unknown): err is SignInRequiredError {
  return (err as { signInRequired?: unknown } | null)?.signInRequired === true;
}

const statusOf = (error: unknown): number | undefined =>
  (error as { context?: { status?: unknown } } | null)?.context?.status as number | undefined;

/** The function's own error message ("sold out", "purchase limit…"), if any,
 *  in fan words (lib/fanErrors.ts). The gateway's own refusals carry
 *  `message` ("Invalid JWT") rather than `error`. A 401 asks for a sign-in. */
export async function functionError(error: unknown, fallback: string): Promise<Error> {
  let payload: { error?: string; message?: string; msg?: string } | null = null;
  try {
    payload = await (error as { context?: Response }).context?.json();
  } catch {
    /* not JSON */
  }
  const raw = payload?.error || payload?.message || payload?.msg || (error as { message?: string })?.message;
  if (statusOf(error) === 401) {
    return new SignInRequiredError(/code/i.test(raw ?? '') ? 'Sign in to use a code.' : undefined);
  }
  return new Error(fanMessage(raw, fallback));
}

/** exos-checkout, retried once on a 401 after refreshing the session (an
 *  access token that expired while the page sat open). Guests have no session. */
async function invokeCheckout(body: Record<string, unknown>, fallback: string): Promise<unknown> {
  let { data, error } = await supabase.functions.invoke('exos-checkout', { body });
  if (error && statusOf(error) === 401 && !body.guest_email) {
    const refreshed = await supabase.auth.refreshSession().catch(() => null);
    if (refreshed?.data?.session) ({ data, error } = await supabase.functions.invoke('exos-checkout', { body }));
  }
  if (error) throw await functionError(error, fallback);
  return data;
}

/** Create a Checkout Session for an event/tier; returns the Stripe-hosted URL. */
export async function startCheckout(input: {
  eventId: string;
  tierId: string;
  quantity: number;
  successUrl: string;
  cancelUrl: string;
  /** Optional product add-ons (merch) to charge alongside the ticket. */
  addons?: { addon_id: string; quantity: number }[];
  /** Optional access voucher (may bypass a sold-out tier / pin a price). */
  voucherCode?: string;
  /** Promoter + campaign tags the buyer arrived with (see lib/attribution.ts). */
  attribution?: Attribution;
  /** Signed out: pay as a guest; tickets go to this email. */
  guestEmail?: string;
} & CheckoutRecordInput): Promise<string> {
  const data = await invokeCheckout({
    event_id: input.eventId,
    tier_id: input.tierId,
    quantity: input.quantity,
    success_url: input.successUrl,
    cancel_url: input.cancelUrl,
    addons: input.addons && input.addons.length > 0 ? input.addons : undefined,
    voucher_code: input.voucherCode || undefined,
    attribution: input.attribution && Object.keys(input.attribution).length > 0 ? input.attribution : undefined,
    guest_email: input.guestEmail?.trim().toLowerCase() || undefined,
    ...recordBody(input),
  }, 'Could not start checkout.');
  const url = (data as { url?: string } | null)?.url;
  if (!url) throw new Error('startCheckout: no session url returned');
  return url;
}

/** Free tickets for a signed-out buyer: issued now and emailed as claim links
 *  (exos-checkout's guest free claim; same limits as a guest purchase). */
export async function claimFreeAsGuest(input: {
  eventId: string;
  tierId: string;
  quantity: number;
  guestEmail: string;
  successUrl: string;
  cancelUrl: string;
  voucherCode?: string;
  /** Free add-ons claimed with the tickets (exos-checkout records them on the order). */
  addons?: { addon_id: string; quantity: number }[];
  attribution?: Attribution;
} & CheckoutRecordInput): Promise<{ issued: number; email: string }> {
  const data = await invokeCheckout({
    event_id: input.eventId,
    tier_id: input.tierId,
    quantity: input.quantity,
    success_url: input.successUrl,
    cancel_url: input.cancelUrl,
    addons: input.addons && input.addons.length > 0 ? input.addons : undefined,
    voucher_code: input.voucherCode || undefined,
    attribution: input.attribution && Object.keys(input.attribution).length > 0 ? input.attribution : undefined,
    guest_email: input.guestEmail.trim().toLowerCase(),
    ...recordBody(input),
  }, 'Could not send your tickets.');
  const d = data as { free?: boolean; issued?: number; email?: string } | null;
  if (!d?.free || !d.issued) throw new Error('Could not send your tickets.');
  return { issued: d.issued, email: d.email ?? input.guestEmail };
}

/** Create an Embedded Checkout Session (the venue-site iframe mounts it in
 *  place). returnUrl must be our /embed/return page (see lib/embed.ts). */
export async function startEmbeddedCheckout(input: {
  eventId: string;
  tierId: string;
  quantity: number;
  returnUrl: string;
  attribution?: Attribution;
} & CheckoutRecordInput): Promise<{ clientSecret: string; sessionId: string }> {
  const data = await invokeCheckout({
    ui_mode: 'embedded',
    event_id: input.eventId,
    tier_id: input.tierId,
    quantity: input.quantity,
    return_url: input.returnUrl,
    attribution: input.attribution && Object.keys(input.attribution).length > 0 ? input.attribution : undefined,
    ...recordBody(input),
  }, 'Could not start checkout.');
  const d = data as { client_secret?: string; session_id?: string } | null;
  if (!d?.client_secret || !d.session_id) throw new Error('startEmbeddedCheckout: no client secret returned');
  return { clientSecret: d.client_secret, sessionId: d.session_id };
}

/** Start (or resume) Stripe Connect onboarding for an org; returns the link URL. */
export async function startStripeOnboarding(input: {
  orgId: string;
  returnUrl: string;
  refreshUrl: string;
}): Promise<string> {
  const { data, error } = await supabase.functions.invoke('exos-connect-onboard', {
    body: { org_id: input.orgId, return_url: input.returnUrl, refresh_url: input.refreshUrl },
  });
  if (error) throw error;
  const url = (data as { url?: string } | null)?.url;
  if (!url) throw new Error('startStripeOnboarding: no url returned');
  return url;
}
