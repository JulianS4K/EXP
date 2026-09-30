import { describe, expect, it } from 'vitest';
import {
  buildCalendar,
  escapeText,
  foldLine,
  icsUtc,
  sequenceFrom,
  type IcsEvent,
} from '../../supabase/functions/_shared/calendar/ics.ts';
import {
  buildEventsCalendar,
  calendarEvent,
  eventUid,
  googleSubscribeUrl,
  googleTemplateUrl,
  locationLine,
  outlookComposeUrl,
  parseCalendarPath,
  venueKey,
  webcalUrl,
  type CalendarEventRow,
} from '../../supabase/functions/_shared/calendar/feed.ts';
import { orgFeedLinks, myFeedLinks, outlookCalendarUrl, icsForEvent } from './calendar';
import { Timestamp } from './timestamp';
import type { Event } from '../types';

const BASE = 'https://exos.example.com/bridge';
const NOW = new Date('2026-10-01T12:00:00Z');
const utf8 = (s: string) => new TextEncoder().encode(s).length;
const unfold = (ics: string) => ics.replace(/\r\n /g, '');

const row = (over: Partial<CalendarEventRow> = {}): CalendarEventRow => ({
  id: '11111111-1111-4111-8111-111111111111',
  slug: 'late-night-jazz',
  name: 'Late Night Jazz, Vol. 2; the return',
  description: '<p>Two sets.</p><p>Bar opens early &amp; late.</p>',
  status: 'published',
  starts_at: '2026-11-07T02:00:00+00:00',
  ends_at: '2026-11-07T05:00:00+00:00',
  doors_at: '2026-11-07T01:00:00+00:00',
  timezone: 'America/New_York',
  venue_name: 'Blue Room',
  venue_address: { street: '1 Main St', city: 'Brooklyn', region: 'NY', postal: '11211', country: 'US' },
  updated_at: '2026-09-20T10:00:00+00:00',
  org_name: 'Night Owls',
  org_slug: 'night-owls',
  lat: 40.712776,
  lng: -73.935242,
  place_id: 'ChIJ1',
  ...over,
});

describe('escapeText', () => {
  it('escapes backslash, semicolon, comma and newlines (RFC 5545 3.3.11)', () => {
    expect(escapeText('a\\b;c,d\ne\r\nf\rg')).toBe('a\\\\b\\;c\\,d\\ne\\nf\\ng');
  });
  it('drops control characters but keeps tabs and unicode', () => {
    expect(escapeText('x\u0000y\u0007z\tü🎷')).toBe('xyz\tü🎷');
  });
});

describe('foldLine', () => {
  it('leaves short lines alone', () => {
    expect(foldLine('SUMMARY:short')).toBe('SUMMARY:short');
  });
  it('folds at 75 octets with a leading space on continuations', () => {
    const line = `DESCRIPTION:${'x'.repeat(200)}`;
    const parts = foldLine(line).split('\r\n');
    expect(parts.length).toBeGreaterThan(2);
    parts.forEach((p, i) => {
      expect(utf8(p)).toBeLessThanOrEqual(75);
      if (i > 0) expect(p.startsWith(' ')).toBe(true);
    });
    expect(parts[0].length).toBe(75);
    expect(unfold(foldLine(line))).toBe(line);
  });
  it('never splits a multi-byte UTF-8 character', () => {
    const line = `SUMMARY:${'é'.repeat(50)}${'🎷'.repeat(30)}日本語`.repeat(2);
    const folded = foldLine(line);
    for (const p of folded.split('\r\n')) {
      expect(utf8(p)).toBeLessThanOrEqual(75);
      // A lone surrogate would mean a code point was cut in half.
      expect(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(p)).toBe(false);
    }
    expect(unfold(folded)).toBe(line);
  });
});

describe('buildCalendar', () => {
  const ev: IcsEvent = {
    uid: 'x@exos', summary: 'Show', start: new Date('2026-11-07T02:00:00Z'), end: new Date('2026-11-07T05:00:00Z'),
  };
  const ics = buildCalendar({ name: 'Night Owls · Exos', timezone: 'America/New_York', refreshMinutes: 360, events: [ev], now: NOW });

  it('uses CRLF everywhere and ends with CRLF', () => {
    expect(ics.endsWith('END:VCALENDAR\r\n')).toBe(true);
    expect(ics.replace(/\r\n/g, '')).not.toMatch(/[\r\n]/);
  });
  it('has the calendar headers', () => {
    const lines = ics.split('\r\n');
    expect(lines.slice(0, 5)).toEqual(['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Exos//Exos Calendar 1.0//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH']);
    expect(lines).toContain('X-WR-CALNAME:Night Owls · Exos');
    expect(lines).toContain('X-WR-TIMEZONE:America/New_York');
    expect(lines).toContain('REFRESH-INTERVAL;VALUE=DURATION:PT6H');
    expect(lines).toContain('X-PUBLISHED-TTL:PT6H');
  });
  it('writes UTC times and a DTSTAMP', () => {
    expect(ics).toContain('DTSTART:20261107T020000Z\r\n');
    expect(ics).toContain('DTEND:20261107T050000Z\r\n');
    expect(ics).toContain(`DTSTAMP:${icsUtc(NOW)}\r\n`);
    expect(ics).toContain('STATUS:CONFIRMED\r\n');
  });
  it('gives a zero-length event a one hour block', () => {
    const z = buildCalendar({ name: 'z', events: [{ ...ev, end: ev.start }], now: NOW });
    expect(z).toContain('DTEND:20261107T030000Z');
  });
  it('omits refresh hints for a one-off file', () => {
    const one = buildCalendar({ name: 'one', events: [ev], now: NOW });
    expect(one).not.toContain('REFRESH-INTERVAL');
  });
});

describe('sequenceFrom', () => {
  it('grows with updated_at and fits a 32-bit integer', () => {
    const a = sequenceFrom('2026-09-20T10:00:00Z');
    const b = sequenceFrom('2026-09-20T10:00:05Z');
    expect(b - a).toBe(5);
    expect(sequenceFrom('2091-12-31T00:00:00Z')).toBeLessThanOrEqual(2147483647);
    expect(sequenceFrom(null)).toBe(0);
    expect(sequenceFrom('2020-01-01T00:00:00Z')).toBe(0);
  });
});

describe('calendarEvent (Exos row → VEVENT)', () => {
  it('has a stable UID, link, location, geo and description', () => {
    const e = calendarEvent(row(), { appBase: BASE, now: NOW })!;
    expect(e.uid).toBe('11111111-1111-4111-8111-111111111111@exos');
    expect(calendarEvent(row({ name: 'Renamed', updated_at: '2026-09-25T00:00:00Z' }), { appBase: BASE })!.uid).toBe(e.uid);
    expect(e.url).toBe(`${BASE}/e/late-night-jazz`);
    expect(e.location).toBe('Blue Room, 1 Main St, Brooklyn, NY 11211, US');
    expect(e.geo).toEqual({ lat: 40.712776, lng: -73.935242 });
    expect(e.description).toContain(`Tickets: ${BASE}/e/late-night-jazz`);
    expect(e.description).toContain('Doors: 8:00 PM EST');
    expect(e.description).toContain('Two sets.\nBar opens early & late.');
    expect(e.status).toBe('CONFIRMED');
    expect(e.sequence).toBe(sequenceFrom('2026-09-20T10:00:00Z'));
  });
  it('bumps SEQUENCE when the event changes', () => {
    const a = calendarEvent(row(), { appBase: BASE })!;
    const b = calendarEvent(row({ updated_at: '2026-09-21T10:00:00Z' }), { appBase: BASE })!;
    expect(b.sequence!).toBeGreaterThan(a.sequence!);
  });
  it('marks cancelled events', () => {
    const e = calendarEvent(row({ status: 'cancelled' }), { appBase: BASE })!;
    expect(e.status).toBe('CANCELLED');
    expect(e.summary.startsWith('Cancelled: ')).toBe(true);
    expect(e.description!.startsWith('This event was cancelled.')).toBe(true);
  });
  it('defaults the end to two hours and skips rows without a start', () => {
    const e = calendarEvent(row({ ends_at: null }), { appBase: BASE })!;
    expect(e.end.getTime() - e.start.getTime()).toBe(2 * 3600_000);
    expect(calendarEvent(row({ starts_at: null }), { appBase: BASE })).toBeNull();
  });
  it('uses the venue time zone for the doors line (DST aware)', () => {
    const summer = calendarEvent(row({ doors_at: '2026-07-01T23:30:00Z', timezone: 'America/Los_Angeles' }), { appBase: BASE })!;
    expect(summer.description).toContain('Doors: 4:30 PM PDT');
  });
  it('puts the store-page summary before the description when present', () => {
    expect(calendarEvent(row({ summary: 'Two sets, one late.' }), { appBase: BASE })!.description)
      .toContain('Two sets, one late.\n\nTwo sets.\nBar opens early & late.');
    expect(calendarEvent(row(), { appBase: BASE })!.description).not.toContain('Two sets, one late.');
  });
  it('links ticket holders to their tickets in the /me feed', () => {
    expect(calendarEvent(row({ has_tickets: true }), { appBase: BASE })!.description).toContain(`You have tickets: ${BASE}/my-tickets`);
  });
});

describe('buildEventsCalendar', () => {
  it('escapes the whole event and folds UTF-8 safely', () => {
    const ics = buildEventsCalendar([
      row({ id: '22222222-2222-4222-8222-222222222222', starts_at: '2026-12-01T01:00:00Z', ends_at: null, name: 'Später 🎷 Café, Bühne; Nacht' }),
      row(),
    ], { name: 'Night Owls · Exos', refreshMinutes: 360 }, { appBase: BASE, now: NOW });
    for (const l of ics.split('\r\n')) expect(utf8(l)).toBeLessThanOrEqual(75);
    const flat = unfold(ics);
    expect(flat).toContain('SUMMARY:Late Night Jazz\\, Vol. 2\\; the return');
    expect(flat).toContain('SUMMARY:Später 🎷 Café\\, Bühne\\; Nacht');
    expect(flat).toContain('GEO:40.712776;-73.935242');
    expect(flat).toContain('URL:https://exos.example.com/bridge/e/late-night-jazz');
    // Sorted by start.
    expect(flat.indexOf('UID:1111')).toBeLessThan(flat.indexOf('UID:2222'));
    expect(flat.match(/BEGIN:VEVENT/g)!.length).toBe(2);
  });
});

describe('venueKey (same vectors as tests/exos/test_calendar_feeds.sql K1)', () => {
  it.each([
    ['Brooklyn Steel', { city: 'Brooklyn' }, 'brooklyn-steel--brooklyn'],
    ['  Brooklyn  Steel! ', { city: 'BROOKLYN' }, 'brooklyn-steel--brooklyn'],
    ['Café Oto', { city: 'London' }, 'cafe-oto--london'],
    ['Le Poisson Rouge', null, 'le-poisson-rouge'],
    ['Brooklyn Mirage', { city: '  ' }, 'brooklyn-mirage'],
    ['Säälchen & Co.', { city: 'Berlin' }, 'saalchen-co--berlin'],
    ['東京ドーム', { city: 'Tokyo' }, null],
    [null, { city: 'Tokyo' }, null],
    [`${'a'.repeat(58)} bb`, null, `${'a'.repeat(58)}-b`],
    [`${'a'.repeat(59)} b`, null, 'a'.repeat(59)],
  ])('%s', (name, address, want) => {
    expect(venueKey(name, address)).toBe(want);
  });
});

describe('parseCalendarPath', () => {
  it('reads each feed kind from the function path', () => {
    expect(parseCalendarPath('/exos-calendar/org/night-owls.ics')).toEqual({ kind: 'org', ref: 'night-owls' });
    expect(parseCalendarPath('/functions/v1/exos-calendar/venue/blue-room--brooklyn.ics')).toEqual({ kind: 'venue', ref: 'blue-room--brooklyn' });
    expect(parseCalendarPath('/exos-calendar/venue/place-ChIJ_ab-1.ics')).toEqual({ kind: 'venue', ref: 'place-ChIJ_ab-1' });
    expect(parseCalendarPath('/exos-calendar/event/11111111-1111-4111-8111-11111111111A.ics'))
      .toEqual({ kind: 'event', ref: '11111111-1111-4111-8111-11111111111a' });
    const tok = `exc_${'a1'.repeat(24)}`;
    expect(parseCalendarPath(`/exos-calendar/me/${tok}.ics`)).toEqual({ kind: 'me', token: tok });
  });
  it('refuses anything else', () => {
    for (const p of ['/exos-calendar', '/exos-calendar/org', '/exos-calendar/org/../x.ics', '/exos-calendar/me/abc.ics',
      '/exos-calendar/event/not-a-uuid.ics', '/exos-calendar/venue/Bad Key.ics', '/exos-calendar/venue/a---b.ics',
      '/exos-calendar/org/x/y.ics', '/exos-calendar/org/%E0%A4%A.ics']) {
      expect(parseCalendarPath(p)).toBeNull();
    }
  });
});

describe('links', () => {
  const start = new Date('2026-11-07T02:00:00Z');
  const end = new Date('2026-11-07T05:00:00Z');
  it('Google Calendar template URL', () => {
    const u = new URL(googleTemplateUrl({ title: 'Jazz & more', start, end, location: 'Blue Room, Brooklyn', details: 'Tickets: x' }));
    expect(u.origin + u.pathname).toBe('https://calendar.google.com/calendar/render');
    expect(u.searchParams.get('action')).toBe('TEMPLATE');
    expect(u.searchParams.get('text')).toBe('Jazz & more');
    expect(u.searchParams.get('dates')).toBe('20261107T020000Z/20261107T050000Z');
    expect(u.searchParams.get('location')).toBe('Blue Room, Brooklyn');
    expect(u.searchParams.get('details')).toBe('Tickets: x');
  });
  it('Outlook compose deeplinks', () => {
    const u = new URL(outlookComposeUrl({ title: 'Jazz', start, end }));
    expect(u.host).toBe('outlook.live.com');
    expect(u.searchParams.get('rru')).toBe('addevent');
    expect(u.searchParams.get('startdt')).toBe('2026-11-07T02:00:00Z');
    expect(u.searchParams.get('enddt')).toBe('2026-11-07T05:00:00Z');
    expect(new URL(outlookComposeUrl({ title: 'Jazz', start, end }, true)).host).toBe('outlook.office.com');
  });
  it('feed, webcal and Google subscribe links', () => {
    const base = 'https://abc.supabase.co/functions/v1/exos-calendar';
    const l = orgFeedLinks('night-owls', base)!;
    expect(l.https).toBe(`${base}/org/night-owls.ics`);
    expect(l.webcal).toBe('webcal://abc.supabase.co/functions/v1/exos-calendar/org/night-owls.ics');
    expect(l.google).toBe(googleSubscribeUrl(l.https));
    expect(new URL(l.google).searchParams.get('cid')).toBe(webcalUrl(l.https));
    expect(myFeedLinks('exc_x', base)!.https).toBe(`${base}/me/exc_x.ics`);
    expect(orgFeedLinks('x', '')).toBeNull();
  });
  it('locationLine joins what is there', () => {
    expect(locationLine('Hall', null)).toBe('Hall');
    expect(locationLine(null, { city: 'Austin', region: 'TX' })).toBe('Austin, TX');
  });
  it('eventUid is lower-case and stable', () => {
    expect(eventUid('ABC')).toBe('abc@exos');
  });
});

describe('src/lib/calendar (event page)', () => {
  const ev = {
    id: 'abc-123', title: 'Show, live', description: 'x', location: 'Hall', status: 'cancelled',
    date: Timestamp.fromDate(new Date('2026-08-15T23:30:00Z')),
    timing: { startTime: Timestamp.fromDate(new Date('2026-08-15T23:30:00Z')) },
  } as unknown as Event;
  it('offers Outlook and marks a cancelled download', () => {
    expect(outlookCalendarUrl(ev)).toContain('outlook.live.com');
    const ics = icsForEvent(ev, NOW)!;
    expect(ics).toContain('UID:abc-123@exos');
    expect(ics).toContain('STATUS:CANCELLED');
    expect(ics).toContain('SUMMARY:Cancelled: Show\\, live');
  });
});
