// Stripe checkout + Connect onboarding seam (D4-OPS-7 SCAFFOLD).
//
// Thin wrappers over the edge functions (exos-checkout / exos-connect-onboard).
// supabase.functions.invoke forwards the signed-in user's JWT automatically, so
// both calls run as the authenticated buyer / org owner. UI wiring (a "Buy"
// button on the event page, a "Set up payments" button in org settings) calls
// these and redirects to the returned Stripe-hosted URL.

import { supabase } from './supabase';
import type { Attribution } from './attribution';

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
}): Promise<string> {
  const { data, error } = await supabase.functions.invoke('exos-checkout', {
    body: {
      event_id: input.eventId,
      tier_id: input.tierId,
      quantity: input.quantity,
      success_url: input.successUrl,
      cancel_url: input.cancelUrl,
      addons: input.addons && input.addons.length > 0 ? input.addons : undefined,
      voucher_code: input.voucherCode || undefined,
      attribution: input.attribution && Object.keys(input.attribution).length > 0 ? input.attribution : undefined,
    },
  });
  if (error) throw error;
  const url = (data as { url?: string } | null)?.url;
  if (!url) throw new Error('startCheckout: no session url returned');
  return url;
}

/** Create an Embedded Checkout Session (the venue-site iframe mounts it in
 *  place). returnUrl must be our /embed/return page (see lib/embed.ts). */
export async function startEmbeddedCheckout(input: {
  eventId: string;
  tierId: string;
  quantity: number;
  returnUrl: string;
  attribution?: Attribution;
}): Promise<{ clientSecret: string; sessionId: string }> {
  const { data, error } = await supabase.functions.invoke('exos-checkout', {
    body: {
      ui_mode: 'embedded',
      event_id: input.eventId,
      tier_id: input.tierId,
      quantity: input.quantity,
      return_url: input.returnUrl,
      attribution: input.attribution && Object.keys(input.attribution).length > 0 ? input.attribution : undefined,
    },
  });
  if (error) {
    // Surface the function's own message ("sold out", "purchase limit…").
    let payload: { error?: string } | null = null;
    try {
      payload = await (error as { context?: Response }).context?.json();
    } catch {
      /* not JSON */
    }
    throw new Error(payload?.error || error.message || 'Could not start checkout.');
  }
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
