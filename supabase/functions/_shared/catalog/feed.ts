// Ad catalog feeds: an org's published upcoming events as "products" for
// dynamic / catalog ads on Meta, TikTok and Google Merchant Center, served by
// supabase/functions/exos-catalog-feed (docs/marketing-catalog.md).
//
// One item per event. The item id is the Exos event id, which is exactly the
// content_ids value the pixels send on ViewContent and Purchase
// (src/views/EventDetails.tsx, src/lib/purchasePixel.ts), so the platforms can
// join ad events to catalog items.
//
//   * price: the lowest all-in price a buyer can pay right now, with the same
//     rules as the storefront's "from $X" (src/lib/pricing.ts buyerTierPrice:
//     the scheduled price in force plus any exclusive tax; Exos adds no buyer
//     fee). Only tiers that are on sale and not sold out count; when none is,
//     the lowest upcoming (presale) tier, else the lowest of all.
//   * availability: in stock (a tier on sale with seats left), preorder (a
//     tier opens later, with its availability_date), else out of stock.
//   * link: the event page, tagged utm_source=<platform>&utm_medium=paid_social
//     &utm_campaign=catalog&utm_content=<event id>, so catalog sales show up in
//     attribution.
//   * image_link: the cover image, else the first gallery image; extra gallery
//     images go in additional_image_link. An event with no image is left out
//     (every platform requires one).
//   * brand: the organizer's name.
//
// Only fields that are already public on the event page are used (the edge
// function reads the exos_public_* views with the anon key).
//
// Pure: no Deno or Supabase imports; the edge function does the reads.

import { allInCents, effectiveTierPrice } from '../pricing.ts';
import { marketCategory, marketTitle, type MarketCategory } from '../marketplace/eventStandard.ts';
import { mdToPlain } from '../richText.ts';
import { eventPageUrl, zonedIso } from '../googleEvents/feed.ts';

export type CatalogPlatform = 'meta' | 'tiktok' | 'google';
export type CatalogFileType = 'csv' | 'xml';
export const CATALOG_PLATFORMS: readonly CatalogPlatform[] = ['meta', 'tiktok', 'google'];

/** Which file types each platform ingests from this feed. */
export const PLATFORM_FILE_TYPES: Record<CatalogPlatform, readonly CatalogFileType[]> = {
  meta: ['csv', 'xml'],
  tiktok: ['csv'],
  google: ['xml'],
};

/** Default platform for a bare /<slug>.csv or /<slug>.xml. */
export const DEFAULT_PLATFORM: Record<CatalogFileType, CatalogPlatform> = { csv: 'meta', xml: 'google' };

/** A row of exos_public_events (select *), the columns the catalog reads. */
export interface CatalogEventRow {
  id: string;
  slug: string | null;
  org_id: string;
  name: string;
  description?: string | null;
  starts_at: string | null;
  ends_at?: string | null;
  timezone?: string | null;
  currency?: string | null;
  venue_name?: string | null;
  venue_address?: unknown;
  primary_performer_name?: string | null;
  category?: string | null;
  genres?: string[] | null;
  image_url?: string | null;
  total_tickets?: number | null;
  tickets_sold?: number | null;
  summary?: string | null;
  description_md?: string | null;
  gallery?: Array<{ url?: unknown }> | null;
}

/** A row of exos_public_tiers. */
export interface CatalogTierRow {
  id: string;
  event_id: string;
  price: number | string;
  capacity: number;
  sold: number;
  sales_start: string | null;
  sales_end: string | null;
  price_schedule?: unknown;
  exclusive_tax_percent?: number | string | null;
}

export interface CatalogOrg {
  id: string;
  name: string;
  slug: string | null;
}

export interface CatalogOptions {
  /** Public SPA base, e.g. https://exos.example.com/bridge (no trailing slash). */
  appBase: string;
  platform: CatalogPlatform;
  now?: Date;
}

export type Availability = 'in stock' | 'out of stock' | 'preorder';

export interface CatalogItem {
  id: string;
  title: string;
  description: string;
  availability: Availability;
  /** Only for preorder: when the first tier opens (ISO 8601 with the venue's offset). */
  availabilityDate?: string;
  condition: 'new';
  /** "21.78 USD" */
  price: string;
  link: string;
  imageLink: string;
  additionalImageLinks: string[];
  brand: string;
  /** "Event Tickets > Concerts" */
  productType: string;
  /** When the listing should stop: the event's end (or start + 6 h). ISO 8601. */
  expirationDate: string;
  /** 0 local start date, 1 venue, 2 city, 3 category, 4 when (this_week / this_month / later). */
  customLabels: [string, string, string, string, string];
}

export interface SkippedItem {
  event_id: string;
  name: string;
  reason: string;
}

// ── helpers ─────────────────────────────────────────────────────────

const text = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

const CATEGORY_LABEL: Record<MarketCategory, string> = {
  concerts: 'Concerts', nightlife: 'Nightlife', comedy: 'Comedy', theater: 'Theater',
  sports: 'Sports', festivals: 'Festivals', other: 'Events',
};

/** https URLs only, at most 2,000 chars (what the platforms fetch). */
export function httpsUrl(v: unknown): string | null {
  const s = text(v);
  if (!s || s.length > 2000) return null;
  try {
    const u = new URL(s);
    return u.protocol === 'https:' ? u.toString() : null;
  } catch {
    return null;
  }
}

/** "21.78 USD": two decimals and the ISO 4217 code, the format all three platforms take. */
export function formatPrice(cents: number, currency: string): string {
  const c = Math.max(0, Math.round(cents));
  return `${Math.floor(c / 100)}.${String(c % 100).padStart(2, '0')} ${(currency || 'USD').toUpperCase()}`;
}

/** The event page, tagged for the platform the ad ran on. */
export function catalogLink(appBase: string, e: Pick<CatalogEventRow, 'id' | 'slug'>, platform: CatalogPlatform): string {
  const q = new URLSearchParams({ utm_source: platform, utm_medium: 'paid_social', utm_campaign: 'catalog', utm_content: e.id });
  return `${eventPageUrl(appBase, { id: e.id, slug: e.slug })}?${q.toString()}`;
}

// Plain one-paragraph text: no HTML, no control characters, collapsed spaces.
function plain(v: string, max: number): string {
  // eslint-disable-next-line no-control-regex
  return v.replace(/<[^>]*>/g, ' ').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
}

function eventEnd(e: CatalogEventRow): number {
  const end = e.ends_at ? Date.parse(e.ends_at) : NaN;
  return Number.isNaN(end) ? Date.parse(String(e.starts_at)) + 6 * 3600_000 : end;
}

interface TierState {
  cents: number;
  onSale: boolean;
  upcoming: boolean;
  opensAt: number | null;
}

function tierState(t: CatalogTierRow, now: Date): TierState {
  const scheduled = effectiveTierPrice(Number(t.price), t.price_schedule, now);
  const cents = allInCents(Math.round(scheduled * 100), Number(t.exclusive_tax_percent) || 0);
  const left = t.capacity > 0 ? t.capacity - t.sold : Infinity;
  const opensAt = t.sales_start ? Date.parse(t.sales_start) : NaN;
  const endsAt = t.sales_end ? Date.parse(t.sales_end) : NaN;
  const notYet = !Number.isNaN(opensAt) && opensAt > now.getTime();
  const ended = !Number.isNaN(endsAt) && endsAt < now.getTime();
  return {
    cents,
    onSale: left > 0 && !notYet && !ended,
    upcoming: left > 0 && notYet && !ended,
    opensAt: notYet ? opensAt : null,
  };
}

/** Lowest current all-in price and the availability, from the public tiers. */
export function priceAndAvailability(
  e: Pick<CatalogEventRow, 'total_tickets' | 'tickets_sold'>, tiers: CatalogTierRow[], now: Date,
): { cents: number; availability: Availability; opensAt: number | null } | null {
  if (!tiers.length) return null;
  const states = tiers.map((t) => tierState(t, now));
  const min = (xs: TierState[]) => Math.min(...xs.map((s) => s.cents));
  const eventFull = Number(e.total_tickets) > 0 && Number(e.tickets_sold) >= Number(e.total_tickets);
  const onSale = states.filter((s) => s.onSale);
  if (onSale.length && !eventFull) return { cents: min(onSale), availability: 'in stock', opensAt: null };
  const upcoming = states.filter((s) => s.upcoming);
  if (upcoming.length && !eventFull) {
    return {
      cents: min(upcoming),
      availability: 'preorder',
      opensAt: Math.min(...upcoming.map((s) => s.opensAt ?? Infinity)),
    };
  }
  return { cents: min(states), availability: 'out of stock', opensAt: null };
}

function images(e: CatalogEventRow): string[] {
  const out: string[] = [];
  const cover = httpsUrl(e.image_url);
  if (cover) out.push(cover);
  for (const g of Array.isArray(e.gallery) ? e.gallery : []) {
    const u = httpsUrl(g && typeof g === 'object' ? (g as { url?: unknown }).url : null);
    if (u && !out.includes(u)) out.push(u);
  }
  return out.slice(0, 11); // the cover + up to 10 extras (Google's cap; Meta takes 20)
}

function city(v: unknown): string {
  const a = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  return text(a.city);
}

function whenLabel(startMs: number, now: Date): string {
  const days = (startMs - now.getTime()) / 86_400_000;
  return days <= 7 ? 'this_week' : days <= 31 ? 'this_month' : 'later';
}

function description(e: CatalogEventRow, title: string, when: string): string {
  const body = e.description_md?.trim() ? mdToPlain(e.description_md) : (e.description ?? '');
  const full = plain([e.summary ?? '', body].filter((s) => s.trim()).join(' '), 5000);
  // Required everywhere, and Meta wants it to differ from the title.
  if (full && full.toLowerCase() !== title.toLowerCase()) return full;
  const where = [text(e.venue_name), city(e.venue_address)].filter(Boolean).join(', ');
  return plain(`${title}${where ? ` at ${where}` : ''}${when ? `, ${when}` : ''}. Tickets on Exos.`, 5000);
}

/** Why an event can't be a catalog item, or null. */
export function catalogBlocker(e: CatalogEventRow, tiers: CatalogTierRow[], now: Date): string | null {
  if (!e.starts_at || Number.isNaN(Date.parse(e.starts_at))) return 'no start time';
  if (eventEnd(e) < now.getTime()) return 'already over';
  if (!tiers.length) return 'no public ticket types';
  if (!marketTitle({ name: e.name, primary_performer_name: e.primary_performer_name ?? null, venue_name: e.venue_name ?? null })) {
    return 'no usable title';
  }
  if (!images(e).length) return 'no https image (every ad platform requires one)';
  return null;
}

/** One event as a catalog item. Call catalogBlocker first. */
export function catalogItem(e: CatalogEventRow, tiers: CatalogTierRow[], org: CatalogOrg, opts: CatalogOptions): CatalogItem {
  const now = opts.now ?? new Date();
  const tz = e.timezone || 'UTC';
  const currency = (e.currency || 'USD').toUpperCase();
  const title = plain(marketTitle({ name: e.name, primary_performer_name: e.primary_performer_name ?? null, venue_name: e.venue_name ?? null }), 150);
  const pa = priceAndAvailability(e, tiers, now)!;
  const start = zonedIso(e.starts_at!, tz) ?? new Date(Date.parse(e.starts_at!)).toISOString();
  const localDate = start.slice(0, 10);
  const imgs = images(e);
  const cat = marketCategory({ category: e.category ?? null, genres: e.genres ?? null, name: e.name });
  const endMs = eventEnd(e);
  const opens = pa.opensAt != null && Number.isFinite(pa.opensAt) ? new Date(pa.opensAt).toISOString() : null;
  return {
    id: e.id,
    title,
    description: description(e, title, localDate),
    availability: pa.availability,
    ...(pa.availability === 'preorder' && opens ? { availabilityDate: zonedIso(opens, tz) ?? opens } : {}),
    condition: 'new',
    price: formatPrice(pa.cents, currency),
    link: catalogLink(opts.appBase, e, opts.platform),
    imageLink: imgs[0],
    additionalImageLinks: imgs.slice(1),
    brand: plain(org.name, 100) || 'Exos',
    productType: `Event Tickets > ${CATEGORY_LABEL[cat]}`,
    expirationDate: zonedIso(new Date(endMs).toISOString(), tz) ?? new Date(endMs).toISOString(),
    customLabels: [
      localDate,
      plain(text(e.venue_name), 100),
      plain(city(e.venue_address), 100),
      CATEGORY_LABEL[cat].toLowerCase(),
      whenLabel(Date.parse(e.starts_at!), now),
    ],
  };
}

/** The org's catalog: items in start order, plus the events left out and why. */
export function buildCatalog(
  input: { org: CatalogOrg; events: CatalogEventRow[]; tiers: CatalogTierRow[] }, opts: CatalogOptions,
): { items: CatalogItem[]; skipped: SkippedItem[] } {
  const now = opts.now ?? new Date();
  const byEvent = new Map<string, CatalogTierRow[]>();
  for (const t of input.tiers) byEvent.set(t.event_id, [...(byEvent.get(t.event_id) ?? []), t]);
  const items: CatalogItem[] = [];
  const skipped: SkippedItem[] = [];
  const events = input.events
    .filter((e) => e.org_id === input.org.id)
    .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)) || a.id.localeCompare(b.id));
  for (const e of events) {
    const tiers = byEvent.get(e.id) ?? [];
    const why = catalogBlocker(e, tiers, now);
    if (why) skipped.push({ event_id: e.id, name: e.name, reason: why });
    else items.push(catalogItem(e, tiers, input.org, opts));
  }
  return { items, skipped };
}

// ── serializers ─────────────────────────────────────────────────────

/** One CSV field (RFC 4180): quoted when it holds a comma, quote or line break; quotes doubled. */
export function csvField(v: string): string {
  return /[",\r\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

export function csvLine(fields: readonly string[]): string {
  return fields.map(csvField).join(',');
}

// Column names per platform (sources in docs/marketing-catalog.md): Meta's
// catalog fields, and TikTok's catalog product parameters (sku_id instead of
// id). Both take "additional_image_link" as a comma list.
const CSV_COLUMNS: Record<'meta' | 'tiktok', readonly string[]> = {
  meta: ['id', 'title', 'description', 'availability', 'condition', 'price', 'link', 'image_link', 'brand',
    'additional_image_link', 'product_type', 'custom_label_0', 'custom_label_1', 'custom_label_2', 'custom_label_3', 'custom_label_4'],
  tiktok: ['sku_id', 'title', 'description', 'availability', 'condition', 'price', 'link', 'image_link', 'brand',
    'additional_image_link', 'product_type', 'custom_label_0', 'custom_label_1', 'custom_label_2', 'custom_label_3', 'custom_label_4'],
};

function csvRow(it: CatalogItem): string[] {
  return [it.id, it.title, it.description, it.availability, it.condition, it.price, it.link, it.imageLink, it.brand,
    it.additionalImageLinks.join(','), it.productType, ...it.customLabels];
}

/** Meta or TikTok catalog CSV (UTF-8, CRLF line ends, header row first). */
export function catalogCsv(items: readonly CatalogItem[], platform: 'meta' | 'tiktok'): string {
  return [csvLine(CSV_COLUMNS[platform]), ...items.map((it) => csvLine(csvRow(it)))].join('\r\n') + '\r\n';
}

/** XML text: escaped, with characters XML 1.0 forbids removed. */
export function xmlText(v: string): string {
  return v
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f￾￿]/g, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/**
 * RSS 2.0 with the Google Merchant Center namespace (g:), the format Google
 * Merchant Center documents and Meta also accepts. identifier_exists=no: tickets
 * have no GTIN / MPN. expiration_date takes the item down after the show.
 */
export function catalogRss(
  items: readonly CatalogItem[], channel: { title: string; link: string; description: string }, platform: CatalogPlatform = 'google',
): string {
  // Google's values use underscores (in_stock); Meta's use spaces (in stock).
  const avail = (a: Availability) => (platform === 'google' ? a.replace(/ /g, '_') : a);
  const el = (tag: string, v: string | undefined) => (v ? `      <${tag}>${xmlText(v)}</${tag}>\n` : '');
  const body = items.map((it) =>
    '    <item>\n' +
    el('g:id', it.id) +
    el('title', it.title) +
    el('description', it.description) +
    el('link', it.link) +
    el('g:image_link', it.imageLink) +
    it.additionalImageLinks.map((u) => el('g:additional_image_link', u)).join('') +
    el('g:availability', avail(it.availability)) +
    el('g:availability_date', it.availabilityDate) +
    el('g:price', it.price) +
    el('g:condition', it.condition) +
    el('g:brand', it.brand) +
    el('g:identifier_exists', 'no') +
    el('g:product_type', it.productType) +
    el('g:expiration_date', it.expirationDate) +
    it.customLabels.map((l, i) => el(`g:custom_label_${i}`, l)).join('') +
    '    </item>\n').join('');
  return '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<rss version="2.0" xmlns:g="http://base.google.com/ns/1.0">\n' +
    '  <channel>\n' +
    `    <title>${xmlText(channel.title)}</title>\n` +
    `    <link>${xmlText(channel.link)}</link>\n` +
    `    <description>${xmlText(channel.description)}</description>\n` +
    body +
    '  </channel>\n' +
    '</rss>\n';
}

/** Parses "/…/exos-catalog-feed/<org_slug>.<csv|xml>" (the last path segment). */
export function parseFeedPath(pathname: string): { slug: string; fileType: CatalogFileType } | null {
  const last = decodeURIComponent(pathname.split('/').filter(Boolean).pop() ?? '');
  const m = /^([a-z0-9][a-z0-9-]{0,79})\.(csv|xml)$/.exec(last);
  return m ? { slug: m[1], fileType: m[2] as CatalogFileType } : null;
}

/** The platform for a request, or an error message for a 400. */
export function resolvePlatform(fileType: CatalogFileType, format: string | null): { platform: CatalogPlatform } | { error: string } {
  const p = (format ?? '').trim().toLowerCase() || DEFAULT_PLATFORM[fileType];
  if (!(CATALOG_PLATFORMS as readonly string[]).includes(p)) return { error: 'format must be meta, tiktok or google' };
  const platform = p as CatalogPlatform;
  if (!PLATFORM_FILE_TYPES[platform].includes(fileType)) {
    return { error: `${platform} feeds are served as .${PLATFORM_FILE_TYPES[platform].join(' or .')}` };
  }
  return { platform };
}

/** The serialized feed and its content type. */
export function renderCatalog(
  items: readonly CatalogItem[], platform: CatalogPlatform, fileType: CatalogFileType,
  org: CatalogOrg, appBase: string,
): { body: string; contentType: string } {
  if (fileType === 'csv') {
    return { body: catalogCsv(items, platform === 'tiktok' ? 'tiktok' : 'meta'), contentType: 'text/csv; charset=utf-8' };
  }
  const link = org.slug ? `${appBase}/o/${encodeURIComponent(org.slug)}` : appBase;
  return {
    body: catalogRss(items, { title: `${org.name} events`, link, description: `Upcoming events from ${org.name} on Exos` }, platform),
    contentType: 'application/xml; charset=utf-8',
  };
}
