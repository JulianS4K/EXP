// One source for the strings that describe an event to a buyer (2026-11-21):
// the date line, the money format and the all-in "from" price. The event page
// (src/views/EventDetails.tsx and its client JSON-LD, through
// src/lib/eventFrom.ts), the org storefront's cards and the crawler card and
// JSON-LD (src/lib/hosting/seo.ts) read them from here. The ad catalog feed
// (_shared/catalog/feed.ts) doesn't import this file: it is the other way
// round, this file calls the feed's own price rule, so an ad, the page it
// lands on and the feed behind it quote the same price.
//
// The "from" price is the catalog feed's rule (feed.ts priceAndAvailability,
// the one ad platforms see): the lowest all-in price among the ticket types on
// sale with seats left; when none is, the lowest upcoming (presale) one; else
// the lowest of all. Before, the crawler card took the lowest of ALL types
// (a sold-out early bird included) and the page's JSON-LD the lowest price
// before fees and tax.
//
// Pure: no Deno, DOM or Supabase imports.

import { priceAndAvailability, type CatalogTierRow } from './catalog/feed.ts';
import type { UnitFee } from './fees.ts';

/** A ticket type as any surface has it, in the public view's column names. */
export interface FromTier {
  price: number | string;
  price_schedule?: unknown;
  exclusive_tax_percent?: number | string | null;
  passed_on_fees?: readonly UnitFee[] | unknown;
  /** Absent (a narrow read): counted as sold out, so the lowest of all applies. */
  capacity?: number | null;
  sold?: number | null;
  available?: number | null;
  sales_start?: string | null;
  sales_end?: string | null;
}

export type FromAvailability = 'in stock' | 'preorder' | 'out of stock';

/** The event's all-in "from" price in cents and its availability, or null with no ticket types. */
export function eventFrom(
  tiers: readonly FromTier[], now: Date = new Date(),
  ev: { total_tickets?: number | null; tickets_sold?: number | null } = {},
): { cents: number; availability: FromAvailability } | null {
  const rows = (tiers ?? []).filter((t) => t && Number.isFinite(Number(t.price))).map((t) => ({
    id: '', event_id: '',
    price: t.price,
    capacity: Number(t.capacity ?? 0) || 0,
    sold: Number(t.sold ?? 0) || 0,
    ...(t.available !== undefined ? { available: t.available } : {}),
    sales_start: t.sales_start ?? null,
    sales_end: t.sales_end ?? null,
    price_schedule: t.price_schedule,
    exclusive_tax_percent: t.exclusive_tax_percent ?? null,
    passed_on_fees: (Array.isArray(t.passed_on_fees) ? t.passed_on_fees : null) as readonly UnitFee[] | null,
  })) as CatalogTierRow[];
  const pa = priceAndAvailability({ total_tickets: ev.total_tickets ?? 0, tickets_sold: ev.tickets_sold ?? 0 }, rows, now);
  return pa ? { cents: pa.cents, availability: pa.availability } : null;
}

/** schema.org availability for an Offer. */
export function schemaAvailability(a: FromAvailability): string {
  return a === 'in stock' ? 'https://schema.org/InStock' : a === 'preorder' ? 'https://schema.org/PreOrder' : 'https://schema.org/SoldOut';
}

const CURRENCY_SYMBOLS: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', CAD: 'CA$', AUD: 'A$' };

/** "$25", "$25.50", "Free", "1,200 MXN". */
export function money(cents: number, currency: string): string {
  if (cents === 0) return 'Free';
  const code = (currency || 'USD').toUpperCase();
  const amount = (cents / 100)
    .toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    .replace('.00', '');
  const sym = CURRENCY_SYMBOLS[code];
  return sym ? `${sym}${amount}` : `${amount} ${code}`;
}

/** "from $25 all-in", "Free", or null without a price. */
export function fromLabel(cents: number | null | undefined, currency: string): string | null {
  if (cents == null || !Number.isFinite(cents)) return null;
  return cents === 0 ? 'Free' : `from ${money(cents, currency)} all-in`;
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * "Fri Oct 2 · 10 PM", from the wall-clock time exactly as written (the
 * organizer's local time when present), never shifted into another zone.
 */
export function dateLabel(startsAt: string | null | undefined, local: string | null | undefined): string | null {
  const raw = local || startsAt;
  if (!raw) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(raw);
  if (!m) return null;
  const [y, mo, d, h, mi] = m.slice(1).map((x) => Number(x ?? 0));
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  const weekday = DAYS[new Date(Date.UTC(y, mo - 1, d)).getUTCDay()];
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  const time = mi === 0 ? `${hour12} ${h < 12 ? 'AM' : 'PM'}` : `${hour12}:${String(mi).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
  return `${weekday} ${MONTHS[mo - 1]} ${d} · ${time}`;
}

/** The event's name for titles and cards: trimmed, single-spaced, at most 200 characters. */
export function eventTitle(name: unknown): string {
  return String(name ?? '').replace(/\s+/g, ' ').trim().slice(0, 200);
}

/** "Fri Oct 3 · 10 PM · Elsewhere · from $25 all-in": the card / ad line. */
export function eventLine(p: { date: string | null; venue: string | null; fromCents: number | null; currency: string }): string {
  return [p.date, p.venue, fromLabel(p.fromCents, p.currency)].filter(Boolean).join(' · ');
}
