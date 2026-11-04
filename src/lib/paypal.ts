// "Pay with Venmo / PayPal" (mig 20261031220000). PayPal's JS SDK only ever
// loads on the PayPal page (/pay/paypal, views/PayPalCheckout.tsx), never on
// a page with a Stripe card field (docs/pci.md); that page's CSP allows
// PayPal's hosts and not Stripe's (src/lib/hosting/headers.ts).
//
// The order is created by exos-checkout (processor: 'paypal') from the same
// server-side price as a Stripe checkout, and captured by exos-paypal.
// VITE_PAYPAL_CLIENT_ID (the PayPal app's public client id; a sandbox one
// unless the operator went live) switches the button on.

import { supabase } from './supabase';
import type { Attribution } from './attribution';

export function paypalClientId(): string | null {
  const id = (import.meta as { env?: { VITE_PAYPAL_CLIENT_ID?: string } }).env?.VITE_PAYPAL_CLIENT_ID;
  return id && /^[A-Za-z0-9_-]{10,120}$/.test(id) ? id : null;
}

export function paypalEnabled(): boolean {
  return paypalClientId() !== null;
}

/**
 * The SDK URL for the PayPal page: PayPal + Venmo buttons, capture intent, no
 * card fields (cards go through Stripe) and no Pay Later. Venmo is US / USD
 * only; PayPal shows it when the buyer is eligible.
 */
export function paypalSdkUrl(clientId: string, currency: string): string {
  const q = new URLSearchParams({
    'client-id': clientId,
    currency: currency.toUpperCase(),
    intent: 'capture',
    components: 'buttons',
    'enable-funding': 'venmo',
    'disable-funding': 'card,credit,paylater',
  });
  return `https://www.paypal.com/sdk/js?${q.toString()}`;
}

/** Venmo can be offered: USD events only. */
export function venmoPossible(currency: string | null | undefined): boolean {
  return (currency ?? 'usd').toLowerCase() === 'usd';
}

/** Does this published event's org take PayPal / Venmo? (exos_public_payment_methods) */
export async function eventTakesPayPal(eventId: string): Promise<boolean> {
  if (!paypalEnabled()) return false;
  const { data, error } = await supabase.from('exos_public_payment_methods').select('paypal').eq('event_id', eventId).maybeSingle();
  if (error) return false; // before the migration: no PayPal
  return (data as { paypal?: boolean } | null)?.paypal === true;
}

/** What the event page hands the PayPal page (kept in sessionStorage across the redirect flow). */
export interface PayPalCart {
  eventId: string;
  tierId: string;
  quantity: number;
  title: string;
  currency: string;
  addons?: { addon_id: string; quantity: number }[];
  voucherCode?: string;
  attribution?: Attribution;
  /** The all-in total the event page showed, for display only (the server prices it). */
  displayCents?: number;
  at: number;
}

const CART_KEY = 'exos:paypal-cart';

export function stashPayPalCart(cart: PayPalCart): void {
  try { sessionStorage.setItem(CART_KEY, JSON.stringify(cart)); } catch { /* storage blocked */ }
}

export function readPayPalCart(now = Date.now()): PayPalCart | null {
  try {
    const raw = sessionStorage.getItem(CART_KEY);
    if (!raw) return null;
    const c = JSON.parse(raw) as PayPalCart;
    // An hour is plenty: the seat hold itself is 30 minutes.
    if (!c || typeof c.eventId !== 'string' || typeof c.tierId !== 'string' || now - Number(c.at) > 3600_000) return null;
    return c;
  } catch {
    return null;
  }
}

async function fnError(error: unknown, fallback: string): Promise<Error & { retry?: boolean }> {
  let payload: { error?: string; retry?: boolean } | null = null;
  try {
    payload = await (error as { context?: Response }).context?.json();
  } catch { /* not JSON */ }
  return Object.assign(new Error(payload?.error || fallback), { retry: payload?.retry === true });
}

/** Create the PayPal order (holds the seats). Returns PayPal's order id for the SDK. */
export async function createPayPalOrder(cart: PayPalCart, opts: { guestEmail?: string; successUrl: string; cancelUrl: string; redirect?: boolean }): Promise<{
  orderId: string; sessionId: string; approveUrl: string | null;
}> {
  const { data, error } = await supabase.functions.invoke('exos-checkout', {
    body: {
      processor: 'paypal',
      paypal_flow: opts.redirect ? 'redirect' : 'buttons',
      event_id: cart.eventId,
      tier_id: cart.tierId,
      quantity: cart.quantity,
      success_url: opts.successUrl,
      cancel_url: opts.cancelUrl,
      addons: cart.addons && cart.addons.length > 0 ? cart.addons : undefined,
      voucher_code: cart.voucherCode || undefined,
      attribution: cart.attribution && Object.keys(cart.attribution).length > 0 ? cart.attribution : undefined,
      guest_email: opts.guestEmail?.trim().toLowerCase() || undefined,
    },
  });
  if (error) throw await fnError(error, 'Could not start PayPal checkout.');
  const d = data as { paypal_order_id?: string; session_id?: string; approve_url?: string | null } | null;
  if (!d?.paypal_order_id || !d.session_id) throw new Error('Could not start PayPal checkout.');
  return { orderId: d.paypal_order_id, sessionId: d.session_id, approveUrl: d.approve_url ?? null };
}

/** After the buyer approved: capture and issue the tickets. */
export async function capturePayPalOrder(orderId: string): Promise<{ status: string; sessionId?: string }> {
  const { data, error } = await supabase.functions.invoke('exos-paypal', { body: { action: 'capture', order_id: orderId } });
  if (error) throw await fnError(error, 'Could not complete the payment.');
  const d = data as { status?: string; session_id?: string } | null;
  return { status: d?.status ?? 'pending', sessionId: d?.session_id };
}

/** The buyer closed PayPal without paying: give the seats back now. Best effort. */
export async function cancelPayPalOrder(orderId: string): Promise<void> {
  try {
    await supabase.functions.invoke('exos-paypal', { body: { action: 'cancel', order_id: orderId } });
  } catch { /* the hold expires on its own */ }
}

/** PayPal's redirect back: /pay/paypal/return?token=<order id>&PayerID=… */
export function orderIdFromReturn(search: string): string | null {
  const q = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const t = q.get('token') ?? '';
  return /^[A-Z0-9]{8,40}$/.test(t) ? t : null;
}
