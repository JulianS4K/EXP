// Link-out events in the feeds (mig 20261029170000). Where to buy is decided
// in ONE place, the SQL function exos_event_buy_link: the storefront reads it
// through exos_public_event_sales / exos_public_link_outs, the Google and
// calendar feeds through exos_feed_where_to_buy, the catalog feed through
// the same public views. This file only turns those rows into feed fields.
//
// Pure: no Deno or Supabase imports (vitest imports it).

import { SALE_PLATFORM_LABEL, withUtm } from './urls.ts';

/** A row of exos_feed_where_to_buy (service role) or exos_public_link_outs (anon). */
export interface WhereToBuy {
  event_id: string;
  /** exos | eventbrite | luma | posh | pretix | hievents */
  sells_on?: string | null;
  url: string | null;
  link_out?: boolean | null;
  /** exos_public_link_outs names it platform. */
  platform?: string | null;
  source_status?: string | null;
  price_min?: number | string | null;
  price_max?: number | string | null;
  currency?: string | null;
  is_free?: boolean | null;
  ticket_types?: Array<{ name?: unknown; min_price?: unknown; max_price?: unknown; sold_out?: unknown; free?: unknown }> | null;
  previous_starts_at?: string | null;
  rescheduled_at?: string | null;
}

const num = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : null;
};

export const isHttps = (u: unknown): u is string => typeof u === 'string' && /^https:\/\/[^\s/]+\.[^\s]+$/.test(u);

/** Is this a link-out row (Exos sells nothing, buyers go to url)? */
export function isLinkOut(w: WhereToBuy | null | undefined): w is WhereToBuy & { url: string } {
  return !!w && (w.link_out === true || (w.link_out == null && !!w.platform)) && isHttps(w.url);
}

/** Sold somewhere other than Exos right now (link-out, another backend, last call). */
export function sellsElsewhere(w: WhereToBuy | null | undefined): w is WhereToBuy & { url: string } {
  if (!w || !isHttps(w.url)) return false;
  return w.link_out === true || (w.link_out == null && !!w.platform) || (!!w.sells_on && w.sells_on !== 'exos');
}

export function platformOf(w: WhereToBuy): string {
  return (w.platform ?? w.sells_on ?? 'exos') as string;
}

export function platformLabel(w: WhereToBuy): string {
  return SALE_PLATFORM_LABEL[platformOf(w)] ?? 'the organizer\'s site';
}

/** The imported price range, or null when the source gave none. */
export function priceRange(w: WhereToBuy): { min: number; max: number; currency: string } | null {
  const min = num(w.price_min);
  if (min === null) return w.is_free ? { min: 0, max: 0, currency: (w.currency || 'USD').toUpperCase() } : null;
  const max = num(w.price_max) ?? min;
  return { min: Math.min(min, max), max: Math.max(min, max), currency: (w.currency || 'USD').toUpperCase() };
}

/** Listed at all? Cancelled and ended sources leave the feeds (Google gets EventCancelled instead). */
export function linkOutGone(w: WhereToBuy): 'cancelled' | 'ended' | null {
  return w.source_status === 'cancelled' ? 'cancelled' : w.source_status === 'ended' ? 'ended' : null;
}

export const linkOutSoldOut = (w: WhereToBuy): boolean => w.source_status === 'sold_out';

/** The display ticket types with a usable name and price. */
export function displayTypes(w: WhereToBuy): Array<{ name: string; price: number; soldOut: boolean }> {
  const out: Array<{ name: string; price: number; soldOut: boolean }> = [];
  for (const t of Array.isArray(w.ticket_types) ? w.ticket_types : []) {
    const name = typeof t?.name === 'string' ? t.name.trim().slice(0, 200) : '';
    const price = t?.free === true ? 0 : num(t?.min_price);
    if (name && price !== null) out.push({ name, price, soldOut: t?.sold_out === true });
  }
  return out.slice(0, 20);
}

/** The organizer's checkout URL, tagged with where the buyer came from. */
export function trackedBuyUrl(w: WhereToBuy & { url: string }, utm: Record<string, string>): string {
  return withUtm(w.url, utm);
}
