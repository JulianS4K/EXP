// Add-to-calendar helpers — build Google Calendar / Outlook "add event" URLs
// and an RFC-5545 .ics document from an Event, plus the links to the
// subscribable exos-calendar feeds (docs/calendar.md).
//
// Times are emitted in UTC (the compact `YYYYMMDDTHHMMSSZ` form both Google and
// Apple/Outlook accept), so we don't have to ship VTIMEZONE blocks — the wall
// clock the attendee sees is whatever their calendar renders the UTC instant as,
// which matches how the rest of the app stores the event (a single instant).

import type { Event } from '../types';
import { publicUrl } from './utils';
import { buildCalendar } from '../../supabase/functions/_shared/calendar/ics.ts';
import {
  eventUid,
  feedUrl,
  googleSubscribeUrl,
  googleTemplateUrl,
  outlookComposeUrl,
  webcalUrl,
} from '../../supabase/functions/_shared/calendar/feed.ts';

export { venueKey } from '../../supabase/functions/_shared/calendar/feed.ts';

// When an event has no explicit end time, assume this length so the calendar
// block isn't zero-width (most ticketed events run a few hours).
const DEFAULT_DURATION_MS = 2 * 60 * 60 * 1000;

export interface CalendarFields {
  title: string;
  start: Date;
  end: Date;
  location: string;
  description: string;
  url: string;
}

function toDate(v: unknown): Date | null {
  if (!v) return null;
  // Timestamp shim (has toDate) or an ISO string / Date.
  if (typeof (v as { toDate?: () => Date }).toDate === 'function') return (v as { toDate: () => Date }).toDate();
  const d = new Date(v as string | number | Date);
  return isNaN(d.getTime()) ? null : d;
}

// Normalize an Event into the fields both exporters need. Returns null when the
// event has no usable start instant (nothing to add).
export function eventCalendarFields(event: Event): CalendarFields | null {
  const start = toDate(event.timing?.startTime) ?? toDate(event.date);
  if (!start) return null;
  const rawEnd = toDate(event.timing?.endTime);
  const end = rawEnd && rawEnd.getTime() > start.getTime() ? rawEnd : new Date(start.getTime() + DEFAULT_DURATION_MS);

  const location = [
    event.location,
    event.address?.street,
    event.address?.city,
    event.address?.region,
    event.address?.postal,
  ]
    .map((s) => (s ?? '').trim())
    .filter(Boolean)
    .join(', ');

  const url = publicUrl(`event/${event.id}`);
  const description = [event.description?.trim(), url].filter(Boolean).join('\n\n');

  return { title: event.title || 'Event', start, end, location, description, url };
}

// https://calendar.google.com/calendar/render?action=TEMPLATE&text=…&dates=…/…
export function googleCalendarUrl(event: Event): string | null {
  const f = eventCalendarFields(event);
  if (!f) return null;
  return googleTemplateUrl({ title: f.title, start: f.start, end: f.end, details: f.description, location: f.location });
}

// Outlook "new event" deeplink: Outlook.com, or Microsoft 365 with `work`.
export function outlookCalendarUrl(event: Event, work = false): string | null {
  const f = eventCalendarFields(event);
  if (!f) return null;
  return outlookComposeUrl({ title: f.title, start: f.start, end: f.end, details: f.description, location: f.location }, work);
}

// A single-event VCALENDAR document from the shared RFC 5545 writer
// (supabase/functions/_shared/calendar/ics.ts), so the download and the
// exos-calendar feeds agree on the UID, escaping and UTF-8 line folding.
export function icsForEvent(event: Event, stamp: Date = new Date()): string | null {
  const f = eventCalendarFields(event);
  if (!f) return null;
  const cancelled = event.status === 'cancelled';
  return buildCalendar({
    name: f.title,
    timezone: event.timezone ?? null,
    now: stamp,
    events: [{
      uid: eventUid(event.id),
      summary: `${cancelled ? 'Cancelled: ' : ''}${f.title}`,
      start: f.start,
      end: f.end,
      description: f.description,
      location: f.location || undefined,
      url: f.url,
      status: cancelled ? 'CANCELLED' : 'CONFIRMED',
    }],
  });
}

// ── Subscribable feeds (supabase/functions/exos-calendar) ────────────────

// https://<project>.supabase.co/functions/v1/exos-calendar, or '' when the
// Supabase URL isn't configured (the subscribe UI then hides itself).
export function calendarFeedBase(): string {
  const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-calendar` : '';
}

export interface FeedLinks {
  /** The feed itself (paste into "subscribe from URL"). */
  https: string;
  /** Opens Apple Calendar's (or Outlook desktop's) subscribe dialog. */
  webcal: string;
  /** Google Calendar's "add by URL" dialog, prefilled. */
  google: string;
}

export function feedLinks(path: string, base = calendarFeedBase()): FeedLinks | null {
  if (!base) return null;
  const https = feedUrl(base, path);
  return { https, webcal: webcalUrl(https), google: googleSubscribeUrl(https) };
}

export const orgFeedLinks = (slug: string, base?: string) => feedLinks(`org/${encodeURIComponent(slug)}.ics`, base);
export const venueFeedLinks = (key: string, base?: string) => feedLinks(`venue/${encodeURIComponent(key)}.ics`, base);
export const myFeedLinks = (token: string, base?: string) => feedLinks(`me/${encodeURIComponent(token)}.ics`, base);

// A filesystem-safe .ics filename derived from the event title.
export function icsFilename(event: Event): string {
  const base = (event.title || 'event').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
  return `${base || 'event'}.ics`;
}

// Trigger a client-side download of the event's .ics. No-op if the event has no
// usable start instant. Returns whether a file was produced.
export function downloadEventIcs(event: Event): boolean {
  const ics = icsForEvent(event);
  if (!ics) return false;
  const blob = new Blob([ics], { type: 'text/calendar;charset=utf-8' });
  const href = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = href;
  a.download = icsFilename(event);
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Release the object URL on the next tick (after the click is handled).
  setTimeout(() => URL.revokeObjectURL(href), 0);
  return true;
}
