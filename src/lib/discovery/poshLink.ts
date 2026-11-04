// Posh "Third-Party Links" discovery channel (mig 20261104150000,
// docs/organizer-guide.md "Discovery listings" and "Posh"). Pure logic:
//   * poshLinkEligibility: whether the Promote page offers posh_link, and the
//     warning to show (mirrors _exos_posh_link_blocked, which refuses it).
//   * poshKit: the copy-ready fields for Posh's Create Event -> External
//     tickets form, with the tracked Exos ticket link.
//   * poshFunnel: Posh's page views -> ticket-link clicks (entered by the
//     organizer) -> Exos orders with utm_source=posh_link, with rates.
// Exos never writes to Posh: there is no Posh API for any of this.

import { discoveryTicketLink, addressLine, plainDescription, type CopyEventRow } from '../../../supabase/functions/_shared/discovery/copy.ts';

export const POSH_LINK_CHANNEL = 'posh_link';

/** Posh's form limits aren't published; these keep the copy short enough to paste (not verified). */
export const POSH_TITLE_MAX = 100;
export const POSH_DESCRIPTION_MAX = 1000;

// ── eligibility ─────────────────────────────────────────────────────────

/** exos_discovery_event_channels -> 'posh_link' (_exos_posh_link_facts). */
export interface PoshLinkFacts {
  link_out: boolean;
  link_out_platform: string | null;
  ticket_backend: string | null;
  /** An active Posh webhook for the org, and this event linked, capped or with Posh orders. */
  posh_webhooks: boolean;
  /** The refusal _exos_posh_link_blocked gives (null = allowed). */
  blocked?: string | null;
}

export interface PoshLinkEligibility {
  offered: boolean;
  /** Why it isn't offered (a link-out event). */
  blocked: string | null;
  /** Offered, but worth a second look. */
  warning: string | null;
}

const PLATFORM: Record<string, string> = {
  posh: 'Posh', eventbrite: 'Eventbrite', luma: 'Luma', pretix: 'pretix', hievents: 'hi.events',
};
const platformName = (p: string | null | undefined) => (p && PLATFORM[p]) || 'another platform';

/** The refusal, worded as the database words it (capitalised for display). */
export function poshLinkBlockedReason(platform: string | null | undefined): string {
  const tail = platform === 'posh'
    ? 'this event is sold on Posh, so it already has a Posh page. Posh (third-party link) is for events sold on Exos.'
    : `this event is sold on ${platform === 'eventbrite' || platform === 'luma' ? platformName(platform) : 'another platform'} (a link-out event), so Posh (third-party link) isn't offered: it is for events sold on Exos.`;
  return tail.charAt(0).toUpperCase() + tail.slice(1);
}

export const POSH_WEBHOOK_WARNING =
  "Posh webhooks are connected for this event, so it looks like it's sold on Posh. Third-party link mode is for events sold on Exos, not Posh: in this mode the Posh page's Get Tickets button sends buyers to Exos instead of your Posh checkout.";

export function poshLinkEligibility(f: PoshLinkFacts | null | undefined): PoshLinkEligibility {
  if (!f) return { offered: true, blocked: null, warning: null };
  if (f.link_out) {
    return { offered: false, blocked: poshLinkBlockedReason(f.link_out_platform ?? f.ticket_backend), warning: null };
  }
  if (f.posh_webhooks) return { offered: true, blocked: null, warning: POSH_WEBHOOK_WARNING };
  if (f.ticket_backend && f.ticket_backend !== 'exos') {
    const p = platformName(f.ticket_backend);
    return {
      offered: true, blocked: null,
      warning: `Tickets for this event are sold on ${p}. Posh visitors land on the Exos page and go on to ${p}, so their orders won't show in the Exos funnel.`,
    };
  }
  return { offered: true, blocked: null, warning: null };
}

// ── copy kit ────────────────────────────────────────────────────────────

export interface PoshKitField {
  key: 'title' | 'start' | 'end' | 'timezone' | 'venue' | 'address' | 'description' | 'image' | 'ticketLink';
  label: string;
  value: string;
}

export interface PoshKit {
  title: string;
  /** "2026-11-06" / "21:00" in the event's time zone. */
  startDate: string;
  startTime: string;
  endDate: string;
  endTime: string;
  timezone: string;
  /** "Fri, Nov 6, 2026, 9:00 PM - 2:00 AM (America/New_York)". */
  when: string;
  venue: string;
  address: string;
  description: string;
  image: string | null;
  /** The event page with utm_source=posh_link, for Posh's external ticket URL. */
  ticketLink: string;
  /** The non-empty fields above, in form order, for copy buttons. */
  fields: PoshKitField[];
}

interface Zoned { date: string; time: string; label: string; clock: string }

function zoned(iso: string | null | undefined, tz: string): Zoned | null {
  const t = iso ? Date.parse(iso) : NaN;
  if (Number.isNaN(t)) return null;
  try {
    const p: Record<string, string> = {};
    for (const x of new Intl.DateTimeFormat('en-US', {
      timeZone: tz, weekday: 'short', year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h12',
    }).formatToParts(new Date(t))) p[x.type] = x.value;
    const n: Record<string, string> = {};
    for (const x of new Intl.DateTimeFormat('en-US', {
      timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).formatToParts(new Date(t))) n[x.type] = x.value;
    const clock = `${p.hour}:${p.minute} ${(p.dayPeriod ?? '').toUpperCase()}`.trim();
    return {
      date: `${n.year}-${n.month}-${n.day}`,
      time: `${n.hour}:${n.minute}`,
      clock,
      label: `${p.weekday}, ${p.month} ${p.day}, ${p.year}, ${clock}`,
    };
  } catch {
    return null;
  }
}

function cap(s: string, max: number): string {
  const t = s.replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}…` : t;
}

export function poshKit(e: CopyEventRow, appBase: string): PoshKit {
  const tz = e.timezone || 'UTC';
  const start = zoned(e.starts_at, tz);
  const end = zoned(e.ends_at, tz);
  const title = cap(e.name ?? '', POSH_TITLE_MAX);
  const online = e.format === 'online';
  const venue = online ? 'Online' : (e.venue_name ?? '').trim();
  const address = online ? '' : addressLine(e.venue_address);
  const description = plainDescription(e, POSH_DESCRIPTION_MAX);
  const image = /^https:\/\//i.test((e.image_url ?? '').trim()) ? (e.image_url ?? '').trim() : null;
  const ticketLink = discoveryTicketLink(appBase, e, POSH_LINK_CHANNEL);
  const when = start
    ? `${start.label}${end ? ` - ${end.date === start.date ? end.clock : end.label}` : ''} (${tz})`
    : '';
  const fields: PoshKitField[] = ([
    ['title', 'Title', title],
    ['start', 'Starts', start ? `${start.date} ${start.time}` : ''],
    ['end', 'Ends', end ? `${end.date} ${end.time}` : ''],
    ['timezone', 'Time zone', start ? tz : ''],
    ['venue', 'Venue', venue],
    ['address', 'Address', address],
    ['description', 'Description', description],
    ['image', 'Image URL', image ?? ''],
    ['ticketLink', 'External ticket URL', ticketLink],
  ] as const).filter(([, , v]) => v !== '').map(([key, label, value]) => ({ key, label, value }));
  return {
    title,
    startDate: start?.date ?? '', startTime: start?.time ?? '',
    endDate: end?.date ?? '', endTime: end?.time ?? '',
    timezone: tz, when, venue, address, description, image, ticketLink, fields,
  };
}

// ── stats + funnel ──────────────────────────────────────────────────────

/** One organizer-entered reading (exos_discovery_posh_stats). */
export interface PoshReading {
  id: string;
  as_of: string;
  page_views: number;
  link_clicks: number;
  updated_at?: string;
}

/** exos_posh_link_funnel -> exos. */
export interface PoshExosOrders {
  orders: number;
  tickets: number;
  gross_cents: number;
  currency: string;
}

export interface PoshFunnel {
  /** The latest reading (Posh's totals as of that day), or null. */
  latest: PoshReading | null;
  views: number;
  clicks: number;
  orders: number;
  tickets: number;
  grossCents: number;
  /** clicks / views, orders / clicks, orders / views; null when the denominator is 0. */
  clickRate: number | null;
  orderRate: number | null;
  viewToOrder: number | null;
  notes: string[];
}

const rate = (num: number, den: number): number | null => (den > 0 ? num / den : null);

export function poshFunnel(readings: readonly PoshReading[], exos: PoshExosOrders | null | undefined): PoshFunnel {
  const sorted = [...readings].sort((a, b) => (a.as_of < b.as_of ? -1 : a.as_of > b.as_of ? 1 : 0));
  const latest = sorted.length ? sorted[sorted.length - 1] : null;
  const prev = sorted.length > 1 ? sorted[sorted.length - 2] : null;
  const views = latest?.page_views ?? 0;
  const clicks = latest?.link_clicks ?? 0;
  const orders = exos?.orders ?? 0;
  const notes: string[] = [];
  if (!latest) notes.push('No Posh numbers yet: enter the page views and ticket-link clicks Posh shows.');
  if (latest && clicks > views) notes.push('Posh shows more clicks than views; check the numbers on Posh.');
  if (latest && prev && (latest.page_views < prev.page_views || latest.link_clicks < prev.link_clicks)) {
    notes.push(`The ${latest.as_of} reading is lower than ${prev.as_of}; Posh's numbers are totals, so check it.`);
  }
  if (latest && orders > clicks) notes.push('More Exos orders than Posh clicks: some buyers may have shared the link, or the Posh numbers are older than the orders.');
  return {
    latest, views, clicks, orders,
    tickets: exos?.tickets ?? 0,
    grossCents: exos?.gross_cents ?? 0,
    clickRate: latest ? rate(clicks, views) : null,
    orderRate: latest ? rate(orders, clicks) : null,
    viewToOrder: latest ? rate(orders, views) : null,
    notes,
  };
}

/** "12.5%", or "–" with nothing to divide by. */
export function formatRate(r: number | null): string {
  if (r == null || !Number.isFinite(r)) return '–';
  const pct = r * 100;
  return `${pct >= 10 || pct === 0 ? pct.toFixed(0) : pct.toFixed(1)}%`;
}

/** A count as the RPC takes it: a whole number from 0 to 100,000,000 (commas allowed). */
export function parseCount(v: string | null | undefined): number | null | 'invalid' {
  const t = (v ?? '').trim().replace(/,/g, '');
  if (t === '') return null;
  if (!/^\d{1,9}$/.test(t)) return 'invalid';
  const n = Number(t);
  return n <= 100_000_000 ? n : 'invalid';
}
