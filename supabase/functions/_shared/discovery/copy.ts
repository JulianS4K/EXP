// Copy-ready event details for a manual discovery submission (DoNYC, Time
// Out, CitySpark, RA, …): what the person working the queue pastes into the
// channel's form. Same title, all-in prices and plain-text description as
// the Google feed (googleEvents/feed.ts) and the ad catalog, so an event
// reads the same everywhere.
//
// The ticket link is the event page tagged utm_source=<channel id>
// &utm_medium=listing&utm_campaign=discovery, so sales from each listing
// show up per channel in the Sources report (_shared/attribution.ts keeps
// these tags). A promo link (mig 20261016110000) isn't used: it is a
// voucher with a redemption limit, and a listing link should have neither.
//
// Pure: no Deno or Supabase imports.

import { allInCents, effectiveTierPrice } from '../pricing.ts';
import { marketTitle } from '../marketplace/eventStandard.ts';
import { mdToPlain } from '../richText.ts';
import { eventPageUrl } from '../googleEvents/feed.ts';

export interface CopyEventRow {
  id: string;
  slug: string | null;
  name: string;
  starts_at: string | null;
  ends_at?: string | null;
  doors_at?: string | null;
  timezone: string | null;
  currency?: string | null;
  venue_name: string | null;
  venue_address?: unknown;
  primary_performer_name?: string | null;
  image_url?: string | null;
  summary?: string | null;
  description_md?: string | null;
  description?: string | null;
  format?: string | null;
}

export interface CopyTierRow {
  price: number | string;
  price_schedule?: unknown;
  exclusive_tax_percent?: number | string | null;
  capacity?: number | null;
  sold?: number | null;
  sales_end?: string | null;
}

export interface SubmissionCopy {
  title: string;
  /** "Fri, Nov 6, 2026, 9:00 PM" in the venue's zone (doors added when set). */
  when: string;
  /** "2026-11-06" and "21:00", for forms with separate date / time fields. */
  date: string;
  time: string;
  venue: string;
  /** One line: "79 N 11th St, Brooklyn, NY 11249, US". */
  address: string;
  /** All-in: "$21.78", "$21.78 - $45.00", "Free". */
  price: string;
  ticketLink: string;
  image: string | null;
  description: string;
  /** Everything above as one block of text. */
  text: string;
}

const s = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

/** The event page, tagged for one discovery channel. */
export function trackingLink(appBase: string, e: Pick<CopyEventRow, 'id' | 'slug'>, channelId: string): string {
  const q = new URLSearchParams({ utm_source: channelId, utm_medium: 'listing', utm_campaign: 'discovery' });
  return `${eventPageUrl(appBase, e)}?${q.toString()}`;
}

/**
 * The ticket link a discovery channel is given for this event. Everything
 * discovery shows or copies as "the ticket link" goes through here, so
 * imported link-out events (buy button on the organizer's own Eventbrite,
 * Luma or Posh checkout; another branch) only need to change this one
 * function. Today: the Exos event page with the channel's tracking tags.
 */
export function discoveryTicketLink(appBase: string, e: Pick<CopyEventRow, 'id' | 'slug'>, channelId: string): string {
  return trackingLink(appBase, e, channelId);
}

export function addressLine(v: unknown): string {
  const a = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  const regionPostal = [s(a.region), s(a.postal) || s(a.postal_code) || s(a.postalCode) || s(a.zip)].filter(Boolean).join(' ');
  return [s(a.street), s(a.city), regionPostal, s(a.country)].filter(Boolean).join(', ');
}

function parts(utc: string, tz: string): Record<string, string> | null {
  const t = Date.parse(utc);
  if (Number.isNaN(t)) return null;
  try {
    const out: Record<string, string> = {};
    for (const p of new Intl.DateTimeFormat('en-US', {
      timeZone: tz, weekday: 'short', year: 'numeric', month: 'short', day: 'numeric',
      hour: 'numeric', minute: '2-digit', hourCycle: 'h12',
    }).formatToParts(new Date(t))) out[p.type] = p.value;
    for (const p of new Intl.DateTimeFormat('en-US', {
      timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).formatToParts(new Date(t))) out[`n_${p.type}`] = p.value;
    return out;
  } catch {
    return null;
  }
}

const clock = (p: Record<string, string>) => `${p.hour}:${p.minute} ${(p.dayPeriod ?? '').toUpperCase()}`.trim();

/** All-in price range over the public tiers still selling (else all of them). */
export function priceRange(tiers: readonly CopyTierRow[], currency: string, now: Date): string {
  if (!tiers.length) return '';
  const selling = tiers.filter((t) => !(t.sales_end && Date.parse(t.sales_end) < now.getTime())
    && !(Number(t.capacity) > 0 && Number(t.sold) >= Number(t.capacity)));
  const use = selling.length ? selling : tiers;
  const cents = use.map((t) => allInCents(Math.round(effectiveTierPrice(Number(t.price), t.price_schedule, now) * 100), Number(t.exclusive_tax_percent) || 0));
  const lo = Math.min(...cents), hi = Math.max(...cents);
  if (hi === 0) return 'Free';
  let fmt: Intl.NumberFormat;
  try {
    fmt = new Intl.NumberFormat('en-US', { style: 'currency', currency: currency.toUpperCase() });
  } catch {
    fmt = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
  }
  const f = (c: number) => (c === 0 ? 'Free' : fmt.format(c / 100));
  return lo === hi ? f(lo) : `${f(lo)} - ${f(hi)}`;
}

export function plainDescription(e: Pick<CopyEventRow, 'summary' | 'description_md' | 'description'>, max = 2000): string {
  const body = e.description_md?.trim() ? mdToPlain(e.description_md) : (e.description ?? '').replace(/<[^>]*>/g, ' ');
  const all = [e.summary ?? '', body].map((x) => x.replace(/\s+/g, ' ').trim()).filter(Boolean).join(' ');
  return all.length > max ? `${all.slice(0, max - 1).trimEnd()}…` : all;
}

export function submissionCopy(
  e: CopyEventRow, tiers: readonly CopyTierRow[], channelId: string, appBase: string, now: Date = new Date(),
): SubmissionCopy {
  const tz = e.timezone || 'UTC';
  const start = e.starts_at ? parts(e.starts_at, tz) : null;
  const doors = e.doors_at ? parts(e.doors_at, tz) : null;
  const when = start
    ? `${start.weekday}, ${start.month} ${start.day}, ${start.year}, ${clock(start)}${doors ? ` (doors ${clock(doors)})` : ''}`
    : '';
  const title = marketTitle({ name: e.name, primary_performer_name: e.primary_performer_name ?? null, venue_name: e.venue_name ?? null }) || s(e.name);
  const venue = e.format === 'online' ? 'Online' : s(e.venue_name);
  const address = e.format === 'online' ? '' : addressLine(e.venue_address);
  const price = priceRange(tiers, e.currency || 'USD', now);
  const ticketLink = discoveryTicketLink(appBase, e, channelId);
  const image = /^https:\/\//i.test(s(e.image_url)) ? s(e.image_url) : null;
  const description = plainDescription(e);
  const text = [
    title,
    when,
    [venue, address].filter(Boolean).join(', '),
    price ? `Tickets: ${price} (all-in)` : '',
    ticketLink,
    image ?? '',
    '',
    description,
  ].filter((l, i, a) => l !== '' || (i > 0 && a[i - 1] !== '')).join('\n').trim();
  return {
    title,
    when,
    date: start ? `${start.n_year}-${start.n_month}-${start.n_day}` : '',
    time: start ? `${start.n_hour}:${start.n_minute}` : '',
    venue,
    address,
    price,
    ticketLink,
    image,
    description,
    text,
  };
}
