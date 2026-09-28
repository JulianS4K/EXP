// Exos events as calendar entries (docs/calendar.md): the row the database
// hands the exos-calendar edge function, turned into an IcsEvent; the venue
// key; and the links the SPA shows (Google / Outlook "add event", feed URLs).
//
// Pure: no Deno, DOM or Supabase imports. The SPA imports it too.

import { buildCalendar, sequenceFrom, type IcsEvent } from './ics.ts';

/** One event as exos_calendar_public_feed / exos_calendar_my_feed return it. */
export interface CalendarEventRow {
  id: string;
  slug: string | null;
  name: string;
  description: string | null;
  status: string;
  starts_at: string | null;
  ends_at: string | null;
  doors_at: string | null;
  timezone: string | null;
  venue_name: string | null;
  venue_address: unknown;
  image_url?: string | null;
  updated_at: string | null;
  org_name?: string | null;
  org_slug?: string | null;
  /** Fresh coordinates only (the 30-day Google caching limit is applied in SQL). */
  lat?: number | null;
  lng?: number | null;
  place_id?: string | null;
  venue_key?: string | null;
  /** /me feed only: the subscriber holds tickets for this event. */
  has_tickets?: boolean;
}

export interface CalendarFeedOptions {
  /** Public SPA base, e.g. https://exos.example.com/bridge (no trailing slash). */
  appBase: string;
  now?: Date;
}

/** When an event has no end time, block out this long. */
export const DEFAULT_DURATION_MS = 2 * 3600_000;

/** Stable across feeds and downloads, so a calendar app updates the entry instead of duplicating it. */
export const eventUid = (id: string): string => `${id.toLowerCase()}@exos`;

const text = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

// ── Venue key ────────────────────────────────────────────────────────
//
// Most events carry their venue as free text (venue_name + venue_address),
// not a venue row, so a venue calendar groups events by a key derived from
// the venue name and city:
//
//   slug(venue_name) [ "--" slug(city) ]        e.g. "brooklyn-steel--brooklyn"
//
// slug = Unicode NFKD, drop combining marks, lowercase, every run of anything
// but a-z / 0-9 becomes one "-", trimmed, at most 60 characters. A slug never
// holds "--", so the separator is unambiguous. SQL computes the same key
// (public.exos_venue_key, migration 20260929073000); both tests check the
// same vectors. A name with no Latin letters or digits has no name key.
//
// Geocoded events also carry a Google Place ID. `place-<place_id>` is a second
// key form; and a name key's feed also takes in any event geocoded to the same
// place as one of its events, which folds spelling variants together.

export function venueSlug(s: string | null | undefined): string {
  const out = (s ?? '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '');
  return out;
}

/** The venue key for a name + address, or null when the name has nothing to key on. */
export function venueKey(name: string | null | undefined, address: unknown): string | null {
  const n = venueSlug(name);
  if (!n) return null;
  const a = (address && typeof address === 'object' ? address : {}) as Record<string, unknown>;
  const c = venueSlug(text(a.city));
  return c ? `${n}--${c}` : n;
}

export const VENUE_KEY_RE = /^(?:[a-z0-9]+(?:-[a-z0-9]+)*(?:--[a-z0-9]+(?:-[a-z0-9]+)*)?|place-[A-Za-z0-9_-]{1,300})$/;

// ── Feed URLs (exos-calendar) ────────────────────────────────────────

export type CalendarRoute =
  | { kind: 'org' | 'venue' | 'event'; ref: string }
  | { kind: 'me'; token: string };

const SLUG_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** A personal feed token (exos_calendar_feed_token_create). */
export const FEED_TOKEN_RE = /^exc_[0-9a-f]{48}$/;

/** The feed a request path names (anything after ".../exos-calendar/"), or null. */
export function parseCalendarPath(pathname: string): CalendarRoute | null {
  const parts = pathname.split('/').filter(Boolean);
  const at = parts.lastIndexOf('exos-calendar');
  const rest = at >= 0 ? parts.slice(at + 1) : parts;
  if (rest.length !== 2) return null;
  const [kind, file] = rest;
  let ref: string;
  try {
    ref = decodeURIComponent(file).replace(/\.ics$/i, '');
  } catch {
    return null;
  }
  if (kind === 'org' && SLUG_RE.test(ref)) return { kind, ref };
  if (kind === 'venue' && VENUE_KEY_RE.test(ref)) return { kind, ref };
  if (kind === 'event' && UUID_RE.test(ref)) return { kind, ref: ref.toLowerCase() };
  if (kind === 'me' && FEED_TOKEN_RE.test(ref)) return { kind, token: ref };
  return null;
}

// ── Event → calendar entry ──────────────────────────────────────────

export function locationLine(venueName: string | null | undefined, address: unknown): string {
  const a = (address && typeof address === 'object' ? address : {}) as Record<string, unknown>;
  const cityLine = [text(a.city), [text(a.region), text(a.postal) || text(a.postal_code) || text(a.zip)].filter(Boolean).join(' ')]
    .filter(Boolean).join(', ');
  return [text(venueName), text(a.street), cityLine, text(a.country)].filter(Boolean).join(', ');
}

export function eventPageUrl(appBase: string, e: { id: string; slug?: string | null }): string {
  return e.slug ? `${appBase}/e/${encodeURIComponent(e.slug)}` : `${appBase}/event/${e.id}`;
}

function plain(v: string | null | undefined, max: number): string {
  const s = (v ?? '').replace(/<\s*br\s*\/?>/gi, '\n').replace(/<\/p>/gi, '\n').replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&')
    .replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

function localTime(iso: string, timeZone: string | null): string | null {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  try {
    return new Intl.DateTimeFormat('en-US', {
      timeZone: timeZone || 'UTC', hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
    }).format(new Date(t));
  } catch {
    return null;
  }
}

/** One Exos event as a VEVENT, or null when it has no usable start. */
export function calendarEvent(row: CalendarEventRow, opts: CalendarFeedOptions): IcsEvent | null {
  if (!row.starts_at) return null;
  const start = new Date(row.starts_at);
  if (Number.isNaN(start.getTime())) return null;
  const endRaw = row.ends_at ? new Date(row.ends_at) : null;
  const end = endRaw && !Number.isNaN(endRaw.getTime()) && endRaw > start ? endRaw : new Date(start.getTime() + DEFAULT_DURATION_MS);
  const cancelled = row.status === 'cancelled';
  const url = eventPageUrl(opts.appBase, row);
  const doors = row.doors_at ? localTime(row.doors_at, row.timezone) : null;
  const body = plain(row.description, 1500);
  const description = [
    cancelled ? 'This event was cancelled.' : `Tickets: ${url}`,
    row.has_tickets ? `You have tickets: ${opts.appBase}/my-tickets` : '',
    doors ? `Doors: ${doors}` : '',
    row.org_name ? `Presented by ${text(row.org_name)}` : '',
    body,
  ].filter(Boolean).join('\n\n');
  const updated = row.updated_at ? new Date(row.updated_at) : null;
  const hasGeo = typeof row.lat === 'number' && typeof row.lng === 'number';
  return {
    uid: eventUid(row.id),
    summary: `${cancelled ? 'Cancelled: ' : ''}${text(row.name) || 'Event'}`,
    start,
    end,
    ...(updated && !Number.isNaN(updated.getTime()) ? { stamp: updated, lastModified: updated } : {}),
    sequence: sequenceFrom(row.updated_at),
    location: locationLine(row.venue_name, row.venue_address) || undefined,
    geo: hasGeo ? { lat: row.lat as number, lng: row.lng as number } : null,
    description,
    url,
    status: cancelled ? 'CANCELLED' : 'CONFIRMED',
  };
}

export interface FeedMeta {
  name: string;
  description?: string;
  timezone?: string | null;
  url?: string;
  /** Subscribed feeds: minutes between refreshes. Omit for a one-off download. */
  refreshMinutes?: number;
}

/** A whole .ics document from rows (sorted by start, rows without a start dropped). */
export function buildEventsCalendar(rows: CalendarEventRow[], meta: FeedMeta, opts: CalendarFeedOptions): string {
  const events = [...rows]
    .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)) || a.id.localeCompare(b.id))
    .map((r) => calendarEvent(r, opts))
    .filter((e): e is IcsEvent => e !== null);
  return buildCalendar({ ...meta, events, now: opts.now });
}

// ── Links for the SPA ────────────────────────────────────────────────

export interface AddLinkFields {
  title: string;
  start: Date;
  end: Date;
  location?: string;
  details?: string;
}

const compactUtc = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

/** Google Calendar "create event" template. */
export function googleTemplateUrl(f: AddLinkFields): string {
  const q = new URLSearchParams({ action: 'TEMPLATE', text: f.title, dates: `${compactUtc(f.start)}/${compactUtc(f.end)}` });
  if (f.details) q.set('details', f.details);
  if (f.location) q.set('location', f.location);
  return `https://calendar.google.com/calendar/render?${q.toString()}`;
}

/** Outlook "new event" deeplink. `work` = Microsoft 365 (outlook.office.com), else Outlook.com. */
export function outlookComposeUrl(f: AddLinkFields, work = false): string {
  const q = new URLSearchParams({
    path: '/calendar/action/compose', rru: 'addevent', subject: f.title,
    startdt: f.start.toISOString().replace(/\.\d{3}Z$/, 'Z'), enddt: f.end.toISOString().replace(/\.\d{3}Z$/, 'Z'),
  });
  if (f.details) q.set('body', f.details);
  if (f.location) q.set('location', f.location);
  return `https://${work ? 'outlook.office.com' : 'outlook.live.com'}/calendar/0/deeplink/compose?${q.toString()}`;
}

/** https://<project>.supabase.co/functions/v1/exos-calendar + path. */
export function feedUrl(functionsBase: string, path: string): string {
  return `${functionsBase.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`;
}

/** The same feed as a webcal:// link (opens the OS calendar app's subscribe dialog). */
export function webcalUrl(httpsUrl: string): string {
  return httpsUrl.replace(/^https?:\/\//i, 'webcal://');
}

/** Google Calendar's "add calendar by URL" dialog, prefilled. */
export function googleSubscribeUrl(httpsUrl: string): string {
  return `https://calendar.google.com/calendar/render?cid=${encodeURIComponent(webcalUrl(httpsUrl))}`;
}
