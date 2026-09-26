// Checkout links: one URL that opens an event with the cart already filled.
//
//   /checkout?products=<tierId>:<qty>,<addonId>:<qty>&coupon=CODE&promoter=…&utm_…
//
// The products/coupon format is Meta's "checkout URL" contract for Facebook
// and Instagram Shops (product id and quantity joined by ':', items by ','),
// so the same page can be a Shop's checkout URL later. Today it's the "buy
// now" link promoters paste into bios, stories and ads. Product ids are our
// tier and add-on UUIDs; the page resolves which event they belong to.
//
// Everything here is advisory: the event page re-validates, and exos-checkout
// re-prices and re-checks inventory server-side.

import { readAttribution, type Attribution } from './attribution';

export interface CheckoutItem { id: string; quantity: number }

export interface ParsedCheckoutLink {
  items: CheckoutItem[];
  /** Our own links name the event, so a hidden tier (not in the public
   *  view) still resolves. Meta's links don't; the tier id resolves it. */
  eventId?: string;
  coupon?: string;
  attribution: Attribution;
  /** Entries that were dropped, for a friendly message. */
  rejected: string[];
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COUPON_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_ITEMS = 20;
const MAX_QTY = 10;

export function parseCheckoutLink(search: string): ParsedCheckoutLink {
  const params = new URLSearchParams(search);
  const rejected: string[] = [];
  const byId = new Map<string, number>();
  const raw = params.get('products') ?? '';
  for (const entry of raw.split(',').map((s) => s.trim()).filter(Boolean).slice(0, MAX_ITEMS)) {
    const [id, qtyStr, extra] = entry.split(':');
    const qty = qtyStr === undefined ? 1 : Number(qtyStr);
    if (extra !== undefined || !UUID_RE.test(id ?? '') || !Number.isInteger(qty) || qty < 1) {
      rejected.push(entry);
      continue;
    }
    const key = id.toLowerCase();
    byId.set(key, Math.min(MAX_QTY, (byId.get(key) ?? 0) + qty));
  }
  const couponRaw = (params.get('coupon') ?? '').trim();
  const coupon = COUPON_RE.test(couponRaw) ? couponRaw : undefined;
  if (couponRaw && !coupon) rejected.push(`coupon ${couponRaw.slice(0, 40)}`);
  const eventRaw = params.get('event') ?? '';
  return {
    items: [...byId].map(([id, quantity]) => ({ id, quantity })),
    eventId: UUID_RE.test(eventRaw) ? eventRaw.toLowerCase() : undefined,
    coupon,
    attribution: readAttribution((k) => params.get(k) ?? undefined),
    rejected,
  };
}

export interface CheckoutLinkInput {
  eventId?: string;
  tierId: string;
  quantity?: number;
  addons?: CheckoutItem[];
  coupon?: string;
  attribution?: Attribution;
}

// Build a checkout link against the app's public base (publicUrl('checkout')).
export function buildCheckoutLink(checkoutBase: string, input: CheckoutLinkInput): string {
  const u = new URL(checkoutBase);
  const products = [
    `${input.tierId}:${Math.max(1, Math.min(MAX_QTY, input.quantity ?? 1))}`,
    ...(input.addons ?? []).filter((a) => a.quantity > 0).map((a) => `${a.id}:${Math.min(MAX_QTY, a.quantity)}`),
  ].join(',');
  if (input.eventId) u.searchParams.set('event', input.eventId);
  u.searchParams.set('products', products);
  if (input.coupon && COUPON_RE.test(input.coupon)) u.searchParams.set('coupon', input.coupon);
  for (const [k, v] of Object.entries(input.attribution ?? {})) if (v) u.searchParams.set(k, v);
  return u.toString();
}

export interface ResolvedRow { id: string; event_id: string }

export type ResolvedCheckout =
  | { ok: true; eventId: string; prefill: CheckoutPrefill; notes: string[] }
  | { ok: false; reason: string };

// Turn parsed items into one event's prefill, given which ids are that
// event's public tiers / add-ons. Pure so it can be tested without Supabase.
export function resolveCheckout(
  parsed: ParsedCheckoutLink,
  tiers: ResolvedRow[],
  addons: ResolvedRow[],
): ResolvedCheckout {
  const notes: string[] = [];
  if (parsed.items.length === 0) return { ok: false, reason: 'This link has no tickets in it.' };
  const tierById = new Map(tiers.map((t) => [t.id.toLowerCase(), t]));
  const addonById = new Map(addons.map((a) => [a.id.toLowerCase(), a]));

  const tierItems = parsed.items.filter((i) => tierById.has(i.id));
  const eventId = parsed.eventId ?? tierById.get(tierItems[0]?.id ?? '')?.event_id
    ?? addonById.get(parsed.items.find((i) => addonById.has(i.id))?.id ?? '')?.event_id;
  if (!eventId) return { ok: false, reason: "We couldn't find this event. It may have ended or not be on sale yet." };

  const sameEventTiers = tierItems.filter((i) => tierById.get(i.id)!.event_id === eventId);
  // Not a public tier and not an add-on: a hidden tier the coupon unlocks, if
  // the link named its event. The event page decides whether it's real.
  const unknown = parsed.items.filter((i) => !tierById.has(i.id) && !addonById.has(i.id));
  const tierItem = sameEventTiers[0] ?? (parsed.eventId ? unknown[0] : undefined);
  if (!tierItem) return { ok: false, reason: 'This link has no ticket type for this event.' };
  if (sameEventTiers.length > 1) notes.push('One ticket type per order: we picked the first one in the link.');

  const addonQty: Record<string, number> = {};
  for (const i of parsed.items) {
    const a = addonById.get(i.id);
    if (a && a.event_id === eventId) addonQty[i.id] = i.quantity;
  }
  if (tierItems.length > sameEventTiers.length) notes.push('Items from another event were left out.');
  if (parsed.rejected.length > 0) notes.push('Some items in the link were not recognised and were left out.');

  return {
    ok: true,
    eventId,
    prefill: { tierId: tierItem.id, quantity: tierItem.quantity, addons: addonQty, coupon: parsed.coupon },
    notes,
  };
}

// What the event page pre-selects after a checkout link resolves. Stored per
// event for the visit, so it survives the sign-in round trip.
export interface CheckoutPrefill {
  tierId: string;
  quantity: number;
  addons: Record<string, number>;
  coupon?: string;
}

const PREFILL_KEY = (eventId: string) => `exos_prefill:${eventId}`;

export function clearPrefill(eventId: string): void {
  try { sessionStorage.removeItem(PREFILL_KEY(eventId)); } catch { /* non-fatal */ }
}

export function savePrefill(eventId: string, prefill: CheckoutPrefill): void {
  try { sessionStorage.setItem(PREFILL_KEY(eventId), JSON.stringify(prefill)); } catch { /* non-fatal */ }
}

// Read without clearing, so the cart survives a re-render, React StrictMode's
// double effect, and the sign-in round trip. Cleared by clearPrefill once
// the buyer has actually checked out.
export function readPrefill(eventId: string): CheckoutPrefill | null {
  try {
    const raw = sessionStorage.getItem(PREFILL_KEY(eventId));
    if (!raw) return null;
    const p = JSON.parse(raw) as CheckoutPrefill;
    if (typeof p?.tierId !== 'string' || !Number.isInteger(p.quantity)) return null;
    return { tierId: p.tierId, quantity: p.quantity, addons: p.addons && typeof p.addons === 'object' ? p.addons : {}, coupon: p.coupon };
  } catch {
    return null;
  }
}
