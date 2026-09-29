// Paid-checkout Purchase pixel.
//
// A free claim fires Purchase on the event page before navigating away. A paid
// checkout leaves the SPA for Stripe and comes back to
// /my-tickets?checkout=success&session_id=cs_..., so the Purchase is reported
// there instead, once per Stripe session:
//
//   1. Before redirecting, EventDetails stashes what it knows (event, org,
//      title, currency, quantity, estimated total) in sessionStorage, which
//      survives the round trip in the same tab. Guests can only use this.
//   2. On return, a signed-in buyer can read their own exos_checkout_sessions
//      row (RLS: buyer_uid = auth.uid()), which has the real charged total
//      (amount_cents: tickets + add-ons + tax, after any voucher), currency
//      and quantity. That wins over the estimate.
//   3. The org's pixels are loaded (consent-gated, lib/pixels.ts) and Purchase
//      fires. A sessionStorage marker per session id stops a reload or a
//      back-navigation from counting it twice.
//
// InitiateCheckout fires on the event page right before the Stripe redirect.
// The Stripe session id isn't something the page can use as the dedupe id
// for it (a later server-side event couldn't know which browser event it
// matches), so it gets a random id, kept in the stash as initiateEventId.
//
// Params carry GA4 `items` (one line: the event, its quantity and unit
// price) next to the Meta / TikTok fields.

import { supabase } from './supabase';
import { getPublicOrg } from './orgs';
import { initOrgPixelsForPurchase, trackPixelEvent } from './pixels';

const PENDING_KEY = 'exos.pendingCheckout';
const TRACKED_PREFIX = 'exos.purchaseTracked.';
// A stash older than this is from some earlier, abandoned checkout.
const PENDING_TTL_MS = 6 * 60 * 60 * 1000;

export interface PendingCheckout {
  eventId: string;
  orgId: string;
  title: string;
  currency: string;
  quantity: number;
  /** Estimated total in major units (what the buyer saw); undefined if unknown. */
  value?: number;
  /** The InitiateCheckout pixel's event id (random; see the header). */
  initiateEventId?: string;
  at: number;
}

export interface CheckoutSessionRow {
  event_id: string;
  org_id: string;
  quantity: number;
  amount_cents: number;
  currency: string;
}

export function rememberPendingCheckout(p: Omit<PendingCheckout, 'at'>): void {
  try {
    sessionStorage.setItem(PENDING_KEY, JSON.stringify({ ...p, at: Date.now() }));
  } catch { /* storage blocked: the session row (signed in) still works */ }
}

function readPending(now: number): PendingCheckout | null {
  try {
    const raw = sessionStorage.getItem(PENDING_KEY);
    if (!raw) return null;
    const p = JSON.parse(raw) as PendingCheckout;
    if (!p || typeof p.eventId !== 'string' || typeof p.at !== 'number' || now - p.at > PENDING_TTL_MS) return null;
    return p;
  } catch {
    return null;
  }
}

/** A fresh pixel event id (for InitiateCheckout, whose Stripe session id isn't known yet). */
export function newPixelEventId(): string {
  try {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  } catch { /* fall through */ }
  return `ic_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
}

/** GA4 `items`: one line for the event's tickets (price = the unit value when the total is known). */
export function ga4Items(eventId: string, name: string | undefined, quantity: number, value?: number): Record<string, unknown>[] {
  const item: Record<string, unknown> = { item_id: eventId, quantity: quantity > 0 ? quantity : 1 };
  if (name) item.item_name = name;
  if (typeof value === 'number' && Number.isFinite(value) && quantity > 0) {
    item.price = Math.round((value / quantity) * 100) / 100;
  }
  return [item];
}

/** InitiateCheckout params from what the event page knows before the redirect. */
export function initiateCheckoutParams(p: Omit<PendingCheckout, 'at'>): Record<string, unknown> {
  const params: Record<string, unknown> = {
    content_ids: [p.eventId],
    content_name: p.title,
    currency: (p.currency || 'usd').toUpperCase(),
    num_items: p.quantity,
  };
  if (typeof p.value === 'number' && Number.isFinite(p.value)) params.value = Math.round(p.value * 100) / 100;
  params.items = ga4Items(p.eventId, p.title, p.quantity, params.value as number | undefined);
  return params;
}

/** Stripe Checkout Session ids look like cs_test_… / cs_live_…. */
export function isCheckoutSessionId(id: string | null | undefined): id is string {
  return typeof id === 'string' && /^cs_[A-Za-z0-9_]{8,250}$/.test(id);
}

/**
 * The Purchase params and the org to attribute it to, from the session row
 * when readable, else the pre-redirect stash. Null when neither says which
 * org sold it (no pixel to fire).
 */
export function purchaseFromCheckout(
  row: CheckoutSessionRow | null,
  pending: PendingCheckout | null,
): { orgId: string; params: Record<string, unknown> } | null {
  // A stash for a different event than the session row is stale.
  const stash = pending && (!row || row.event_id === pending.eventId) ? pending : null;
  const orgId = row?.org_id ?? stash?.orgId;
  const eventId = row?.event_id ?? stash?.eventId;
  if (!orgId || !eventId) return null;
  const params: Record<string, unknown> = { content_ids: [eventId] };
  if (stash?.title) params.content_name = stash.title;
  if (row) {
    params.value = Math.round(row.amount_cents) / 100;
    params.currency = (row.currency || 'usd').toUpperCase();
    params.num_items = row.quantity;
  } else if (stash) {
    if (typeof stash.value === 'number' && Number.isFinite(stash.value)) params.value = Math.round(stash.value * 100) / 100;
    params.currency = (stash.currency || 'usd').toUpperCase();
    params.num_items = stash.quantity;
  }
  params.items = ga4Items(
    eventId,
    stash?.title,
    typeof params.num_items === 'number' ? params.num_items : 1,
    typeof params.value === 'number' ? params.value : undefined,
  );
  return { orgId, params };
}

/**
 * Called by My Tickets on ?checkout=success. `sessionId` is Stripe's
 * {CHECKOUT_SESSION_ID}; without one the stash's timestamp is the dedupe key.
 * Never throws: a pixel must not break the confirmation page.
 */
export async function trackCheckoutReturn(sessionId: string | null): Promise<void> {
  try {
    const pending = readPending(Date.now());
    const sid = isCheckoutSessionId(sessionId) ? sessionId : null;
    if (!sid && !pending) return;
    const key = TRACKED_PREFIX + (sid ?? `pending:${pending!.at}`);
    try {
      if (sessionStorage.getItem(key)) return;
      sessionStorage.setItem(key, '1');
    } catch { /* storage blocked: fire anyway, best-effort */ }

    let row: CheckoutSessionRow | null = null;
    if (sid) {
      // Readable only by the signed-in buyer; a guest gets no row (null).
      const { data } = await supabase
        .from('exos_checkout_sessions')
        .select('event_id, org_id, quantity, amount_cents, currency')
        .eq('session_id', sid)
        .maybeSingle();
      row = (data as CheckoutSessionRow | null) ?? null;
    }
    const purchase = purchaseFromCheckout(row, pending);
    try { sessionStorage.removeItem(PENDING_KEY); } catch { /* non-fatal */ }
    if (!purchase) return;

    const org = await getPublicOrg(purchase.orgId);
    initOrgPixelsForPurchase(purchase.orgId, org?.marketing?.pixels);
    // The Stripe session id doubles as the dedupe id a server-side
    // conversion for the same order will carry.
    trackPixelEvent('Purchase', purchase.params, sid ?? undefined);
  } catch (err) {
    console.warn('Purchase pixel skipped:', err);
  }
}
