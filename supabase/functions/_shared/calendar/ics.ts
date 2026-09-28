// A small RFC 5545 iCalendar writer (docs/calendar.md).
//
// Used by the exos-calendar edge function (subscribable .ics feeds) and by the
// SPA's "Add to calendar" download (src/lib/calendar.ts), so both emit the
// same bytes for the same event.
//
// Choices, and why:
//   * Times are UTC (DTSTART:20261107T020000Z). Every calendar client handles
//     UTC, and the viewer's calendar renders it in their own zone, which is
//     the right wall clock for someone travelling to the venue too. The
//     alternative, DTSTART;TZID=America/New_York plus a VTIMEZONE block, needs
//     the zone's DST rules written out; Intl can't give us those, and a wrong
//     VTIMEZONE is worse than none (Outlook trusts it over its own tz data).
//     The venue's zone still goes on the calendar as X-WR-TIMEZONE (a display
//     hint Apple and Google read).
//   * Lines end in CRLF and are folded at 75 octets of UTF-8 (§3.1), never
//     inside a multi-byte character, so emoji and accents survive.
//   * TEXT values escape backslash, semicolon, comma and newlines (§3.3.11).
//     URI values (URL) aren't TEXT and aren't escaped; control characters are
//     dropped from every value.
//
// Pure: no Deno, DOM or Supabase imports.

export interface IcsEvent {
  /** Globally unique and stable for the event's lifetime (e.g. `<uuid>@exos`). */
  uid: string;
  summary: string;
  start: Date;
  end: Date;
  /** DTSTAMP. Defaults to the calendar's `now`. */
  stamp?: Date;
  /** LAST-MODIFIED. */
  lastModified?: Date;
  /** SEQUENCE: must not go down when the event changes (see sequenceFrom). */
  sequence?: number;
  location?: string;
  geo?: { lat: number; lng: number } | null;
  description?: string;
  url?: string;
  status?: 'CONFIRMED' | 'TENTATIVE' | 'CANCELLED';
  categories?: string[];
}

export interface IcsCalendar {
  /** X-WR-CALNAME / NAME (RFC 7986). */
  name: string;
  description?: string;
  /** IANA zone, as a display hint (X-WR-TIMEZONE). Event times are UTC regardless. */
  timezone?: string | null;
  /** How often subscribers should re-fetch (REFRESH-INTERVAL + X-PUBLISHED-TTL). Omit for a one-off file. */
  refreshMinutes?: number;
  /** A link to the calendar's page (URL, RFC 7986). */
  url?: string;
  events: IcsEvent[];
  now?: Date;
}

export const PRODID = '-//Exos//Exos Calendar 1.0//EN';

const CRLF = '\r\n';
const pad = (n: number, w = 2) => String(n).padStart(w, '0');

/** 20261107T020000Z */
export function icsUtc(d: Date): string {
  return `${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
}

// Everything below U+0020 except TAB, plus DEL (§3.3.11 forbids CONTROL in TEXT).
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

/** A TEXT value (§3.3.11): \\ \; \, and \n for any line break. */
export function escapeText(s: string): string {
  return s
    .replace(/\r\n?/g, '\n')
    .replace(CONTROL, '')
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\n/g, '\\n');
}

/** A URI (or other non-TEXT) value: no escaping, but no control characters or line breaks. */
function cleanValue(s: string): string {
  return s.replace(/[\r\n]+/g, ' ').replace(CONTROL, '');
}

function utf8Len(cp: number): number {
  return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
}

/**
 * Fold one content line to at most 75 octets per physical line (§3.1).
 * Continuation lines start with one space, which counts toward their 75.
 * Splits only between code points, so a UTF-8 sequence is never cut.
 */
export function foldLine(line: string): string {
  const out: string[] = [];
  let cur = '';
  let octets = 0;
  let limit = 75;
  for (const ch of line) {
    const n = utf8Len(ch.codePointAt(0)!);
    if (octets + n > limit) {
      out.push(cur);
      cur = ' ';
      octets = 1;
      limit = 75;
    }
    cur += ch;
    octets += n;
  }
  out.push(cur);
  return out.join(CRLF);
}

/**
 * SEQUENCE from a last-modified time: seconds since 2024-01-01T00:00Z. It only
 * grows as the event is edited, and stays inside the 32-bit INTEGER range
 * until 2092.
 */
export function sequenceFrom(updatedAt: string | Date | null | undefined): number {
  if (!updatedAt) return 0;
  const t = updatedAt instanceof Date ? updatedAt.getTime() : Date.parse(updatedAt);
  if (Number.isNaN(t)) return 0;
  const s = Math.floor((t - Date.UTC(2024, 0, 1)) / 1000);
  return Math.min(Math.max(s, 0), 2147483647);
}

function durationFromMinutes(m: number): string {
  const mins = Math.max(1, Math.round(m));
  const h = Math.floor(mins / 60);
  const r = mins % 60;
  return `PT${h ? `${h}H` : ''}${r || !h ? `${r}M` : ''}`;
}

function eventLines(e: IcsEvent, now: Date): string[] {
  const lines = [
    'BEGIN:VEVENT',
    `UID:${cleanValue(e.uid)}`,
    `DTSTAMP:${icsUtc(e.stamp ?? now)}`,
    `DTSTART:${icsUtc(e.start)}`,
    `DTEND:${icsUtc(e.end.getTime() > e.start.getTime() ? e.end : new Date(e.start.getTime() + 3600_000))}`,
    `SUMMARY:${escapeText(e.summary)}`,
  ];
  if (e.sequence !== undefined) lines.push(`SEQUENCE:${Math.max(0, Math.floor(e.sequence))}`);
  if (e.lastModified) lines.push(`LAST-MODIFIED:${icsUtc(e.lastModified)}`);
  if (e.location) lines.push(`LOCATION:${escapeText(e.location)}`);
  if (e.geo && Number.isFinite(e.geo.lat) && Number.isFinite(e.geo.lng)) {
    lines.push(`GEO:${e.geo.lat.toFixed(6)};${e.geo.lng.toFixed(6)}`);
  }
  if (e.description) lines.push(`DESCRIPTION:${escapeText(e.description)}`);
  if (e.url) lines.push(`URL:${cleanValue(e.url)}`);
  if (e.categories?.length) lines.push(`CATEGORIES:${e.categories.map(escapeText).join(',')}`);
  lines.push(`STATUS:${e.status ?? 'CONFIRMED'}`);
  lines.push('TRANSP:OPAQUE');
  lines.push('END:VEVENT');
  return lines;
}

/** The whole VCALENDAR, CRLF line endings, folded, ending in CRLF. */
export function buildCalendar(cal: IcsCalendar): string {
  const now = cal.now ?? new Date();
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    `PRODID:${PRODID}`,
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `NAME:${escapeText(cal.name)}`,
    `X-WR-CALNAME:${escapeText(cal.name)}`,
  ];
  if (cal.description) {
    lines.push(`DESCRIPTION:${escapeText(cal.description)}`, `X-WR-CALDESC:${escapeText(cal.description)}`);
  }
  if (cal.timezone) lines.push(`X-WR-TIMEZONE:${cleanValue(cal.timezone)}`);
  if (cal.url) lines.push(`URL:${cleanValue(cal.url)}`);
  if (cal.refreshMinutes) {
    const d = durationFromMinutes(cal.refreshMinutes);
    lines.push(`REFRESH-INTERVAL;VALUE=DURATION:${d}`, `X-PUBLISHED-TTL:${d}`);
  }
  for (const e of cal.events) lines.push(...eventLines(e, now));
  lines.push('END:VCALENDAR');
  return lines.map(foldLine).join(CRLF) + CRLF;
}
