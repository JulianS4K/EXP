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
import { readAttribution, type Attribution } from './attribution';
import { currentInAppRecord } from './inAppBrowser';
import { rememberProofToken } from './orderProof';

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

/** What the event page hands the PayPal page: in the URL fragment (#cart=,
 *  so it works where storage is blocked, as in Instagram's browser, and never
 *  reaches a server log or a Referer), and in sessionStorage as a backup. */
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
// An hour is plenty: the seat hold itself is 30 minutes.
const CART_TTL_MS = 3600_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function stashPayPalCart(cart: PayPalCart): void {
  try { sessionStorage.setItem(CART_KEY, JSON.stringify(cart)); } catch { /* storage blocked: the fragment carries it */ }
}

function toBase64Url(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(s: string): string | null {
  try {
    const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/'));
    return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
  } catch {
    return null;
  }
}

/** "#cart=…" for the PayPal page URL. */
export function payPalCartFragment(cart: PayPalCart): string {
  return `#cart=${toBase64Url(JSON.stringify(cart))}`;
}

// A cart from either place, checked field by field: the fragment is a URL
// anyone can edit (the server re-prices everything anyway).
function parseCart(raw: unknown, now: number): PayPalCart | null {
  if (!raw || typeof raw !== 'object') return null;
  const c = raw as Record<string, unknown>;
  if (typeof c.eventId !== 'string' || !UUID_RE.test(c.eventId)) return null;
  if (typeof c.tierId !== 'string' || !UUID_RE.test(c.tierId)) return null;
  const quantity = Number(c.quantity);
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) return null;
  const at = Number(c.at);
  if (!Number.isFinite(at) || now - at > CART_TTL_MS) return null;
  const addons = Array.isArray(c.addons)
    ? c.addons.filter((a): a is { addon_id: string; quantity: number } =>
      !!a && typeof a.addon_id === 'string' && UUID_RE.test(a.addon_id) && Number.isInteger(a.quantity) && a.quantity > 0 && a.quantity <= 10)
    : undefined;
  const attrIn = c.attribution && typeof c.attribution === 'object' ? (c.attribution as Record<string, unknown>) : {};
  const displayCents = Number.isInteger(c.displayCents) ? (c.displayCents as number) : undefined;
  return {
    eventId: c.eventId, tierId: c.tierId, quantity, at,
    title: typeof c.title === 'string' ? c.title.slice(0, 200) : '',
    currency: typeof c.currency === 'string' && /^[a-z]{3}$/i.test(c.currency) ? c.currency.toLowerCase() : 'usd',
    addons: addons && addons.length > 0 ? addons : undefined,
    voucherCode: typeof c.voucherCode === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(c.voucherCode) ? c.voucherCode : undefined,
    attribution: readAttribution((k) => attrIn[k]),
    displayCents,
  };
}

/** The cart from the URL fragment (#cart=), else the session copy. */
export function readPayPalCart(now = Date.now(), hash: string = typeof location !== 'undefined' ? location.hash : ''): PayPalCart | null {
  const m = /(?:^#|&)cart=([A-Za-z0-9_-]+)/.exec(hash || '');
  if (m) {
    const text = fromBase64Url(m[1]);
    try {
      const fromUrl = text ? parseCart(JSON.parse(text), now) : null;
      if (fromUrl) return fromUrl;
    } catch { /* not JSON: try storage */ }
  }
  try {
    const raw = sessionStorage.getItem(CART_KEY);
    return raw ? parseCart(JSON.parse(raw), now) : null;
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
      in_app_browser: currentInAppRecord(),
    },
  });
  if (error) throw await fnError(error, 'Could not start PayPal checkout.');
  const d = data as { paypal_order_id?: string; session_id?: string; approve_url?: string | null; proof_token?: string } | null;
  if (!d?.paypal_order_id || !d.session_id) throw new Error('Could not start PayPal checkout.');
  // A guest's tickets wait for proof of the email (mig 20261105100000).
  rememberProofToken(d.session_id, d.proof_token);
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
