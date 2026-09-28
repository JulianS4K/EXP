// The Exos marketplace standard for an EVENT: what an Exos event looks like
// on StubHub, SeatGeek, Vivid Seats, Gametime, GoTickets and Ticket Evolution,
// and whether it's ready to go there (the ticket side is ./exosListing.ts).
//
// Marketplaces match an event to their catalog on the same few things: a
// clean title (the performer or show, nothing else), the venue by name and
// city, the venue-local date and time, and a category. Their mapping teams
// and catalog searches trip over Exos-style titles ("LATE NIGHT JAZZ 🎷 11/6
// SOLD OUT!!"), missing cities or time zones, and ticket-type names used as
// sections ("Early Bird Phase 2" is General Admission on a marketplace). So:
//
//   marketTitle      the title as a catalog would carry it
//   marketSection    the section a ticket type lists under
//   marketCategory   the marketplaces' category for the event
//   eventReadiness   per marketplace: what blocks listing, what hurts matching
//
// Pure (no Deno / Node / Supabase), shared by exos-distribute's planners and
// the event editor.

export type MarketplaceId = 'stubhub' | 'seatgeek' | 'gametime' | 'gotickets' | 'vivid' | 'evo';

export type MarketCategory = 'concerts' | 'nightlife' | 'comedy' | 'theater' | 'sports' | 'festivals' | 'other';

export interface StandardEventInput {
  name: string | null | undefined;
  primary_performer_name?: string | null;
  performer_names?: string[] | null;
  category?: string | null;
  genres?: string[] | null;
  starts_at?: string | null;
  occurs_at_local?: string | null;
  timezone?: string | null;
  venue_name?: string | null;
  venue_location?: string | null;
  venue_address?: { street?: string | null; city?: string | null; region?: string | null; postal?: string | null; country?: string | null } | null;
  currency?: string | null;
}

export interface StandardTierInput {
  name: string;
  section_label?: string | null;
  is_table?: boolean;
}

export interface Readiness {
  channel: MarketplaceId;
  /** Nothing can be listed until these are fixed. */
  blocking: string[];
  /** Listing works, but matching to the marketplace's event is slower or riskier. */
  warnings: string[];
  ready: boolean;
}

export const MARKETPLACE_LABEL: Record<MarketplaceId, string> = {
  stubhub: 'StubHub', seatgeek: 'SeatGeek', gametime: 'Gametime', gotickets: 'GoTickets', vivid: 'Vivid Seats', evo: 'Ticket Evolution',
};

const MAX_TITLE = 100;
const MONTHS = 'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
const WEEKDAYS = 'mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?';

/** "11/6", "11/06/26", "Nov 6", "Friday, November 6th", "2026" and similar, anywhere in a title. */
const DATE_RE = new RegExp(
  [
    `\\b(?:${WEEKDAYS})\\b\\.?,?\\s*(?:(?:${MONTHS})\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?)?`,
    `\\b(?:${MONTHS})\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?`,
    `\\b\\d{1,2}[/.]\\d{1,2}(?:[/.]\\d{2,4})?\\b`,
    `\\b20\\d{2}\\b`,
  ].join('|'),
  'gi',
);
/** Sales words that don't belong in a catalog title. */
const NOISE_RE = /\b(?:sold[\s-]*out|last\s+(?:call|chance)|few\s+(?:tickets\s+)?left|(?:on\s+sale\s+)?now|tickets?|tix|free\s+entry|rsvp|limited)\b/gi;
const AGE_RE = /\(?\b(18|21)\s*\+\s*\)?/;

function collapse(s: string): string {
  return s
    .replace(/[​-‍﻿]/g, '')
    .replace(/\s*([!?.,:;|~*_])(?:\s*\1)+/g, '$1') // runs of the same punctuation
    .replace(/\s+/g, ' ')
    .replace(/^[\s\-–—|:,.·*~_]+|[\s\-–—|:,·*~_]+$/g, '')
    .trim();
}

/** Title Case for an ALL-CAPS title; anything with lower case is left as the organizer wrote it. */
function unshout(s: string): string {
  const letters = s.replace(/[^\p{L}]/gu, '');
  if (letters.length < 5 || letters !== letters.toUpperCase()) return s;
  const small = new Set(['a', 'an', 'and', 'at', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'vs', 'with', 'ft', 'feat']);
  return s.toLowerCase().replace(/\p{L}[\p{L}'’]*/gu, (w, i: number) =>
    i > 0 && small.has(w) ? w : w.charAt(0).toUpperCase() + w.slice(1));
}

/**
 * The event's title as a marketplace catalog would carry it: the show or
 * performer, without emoji, dates, venue suffixes or sales words, not in all
 * caps. Falls back to the performer when nothing's left. Empty = unusable.
 */
export function marketTitle(ev: Pick<StandardEventInput, 'name' | 'primary_performer_name' | 'venue_name'>): string {
  let s = String(ev.name ?? '').normalize('NFKC');
  s = s.replace(/\p{Extended_Pictographic}|\p{Emoji_Modifier}|️/gu, ' ');
  s = s.replace(DATE_RE, ' ').replace(NOISE_RE, ' ').replace(AGE_RE, ' ').replace(/[!?]{2,}/g, ' ');
  // "Show @ Venue" / "Show at Venue" when the venue is the event's own.
  const venue = String(ev.venue_name ?? '').trim();
  if (venue.length >= 3) {
    const esc = venue.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    s = s.replace(new RegExp(`\\s*(?:@|\\bat\\b|-|–|—|\\|)\\s*(?:the\\s+)?${esc}\\s*$`, 'i'), ' ');
  }
  s = s.replace(/[()[\]{}]\s*[()[\]{}]/g, ' ');
  s = unshout(collapse(s));
  if (!s) s = collapse(String(ev.primary_performer_name ?? ''));
  return s.slice(0, MAX_TITLE).trim();
}

/** 21+ / 18+ from the title, for the listing notes (marketplaces show age limits in notes). */
export function ageLimit(name: string | null | undefined): string | null {
  const m = AGE_RE.exec(String(name ?? ''));
  return m ? `${m[1]}+` : null;
}

const PHASE_RE = /\b(?:early[\s-]*bird|super[\s-]*early|presale|pre[\s-]*sale|advance|regular|standard|general|ga|phase\s*\d+|tier\s*\d+|wave\s*\d+|round\s*\d+|release\s*\d+|last[\s-]*chance|final|door|day[\s-]*of|student|group|single|entry|admission|ticket)s?\b/gi;

/**
 * The section a ticket type lists under. The organizer's section label wins;
 * tables list as a table section; VIP as VIP; price phases of the same entry
 * ("Early Bird", "Phase 2", "Door") are General Admission, as marketplaces
 * list GA; anything else keeps its (cleaned) name.
 */
export function marketSection(tier: StandardTierInput): string {
  const label = collapse(String(tier.section_label ?? ''));
  if (label) return label.slice(0, 60);
  const name = collapse(String(tier.name ?? '').normalize('NFKC').replace(/\p{Extended_Pictographic}|️/gu, ' '));
  if (tier.is_table || /\b(?:table|booth|bottle|cabana)\b/i.test(name)) return 'Table';
  if (/\bv\.?i\.?p\b/i.test(name)) return /\b(?:meet|m&g|backstage)\b/i.test(name) ? 'VIP Meet & Greet' : 'VIP';
  if (/\b(?:balcony|mezz(?:anine)?|orchestra|floor|pit|lawn|mezz)\b/i.test(name)) return unshout(name).slice(0, 60);
  const rest = collapse(name.replace(PHASE_RE, ' ').replace(/[-–—:|]+/g, ' '));
  if (!rest) return 'General Admission';
  return unshout(name).slice(0, 60);
}

const GENRE_CATEGORY: Array<[RegExp, MarketCategory]> = [
  [/comedy|stand[\s-]*up|improv|sketch|open\s*mic/i, 'comedy'],
  [/theat(?:re|er)|musical|opera|ballet|dance|play\b|drag|cabaret|burlesque/i, 'theater'],
  [/festival/i, 'festivals'],
  [/club|lounge|bar\b|underground|house\s*party|rave|dj/i, 'nightlife'],
];

/** The marketplaces' category (they list live entertainment and sports; the rest is "other"). */
export function marketCategory(ev: Partial<Pick<StandardEventInput, 'category' | 'genres' | 'name'>>): MarketCategory {
  const cat = String(ev.category ?? '').trim().toLowerCase();
  const hay = `${(ev.genres ?? []).join(' ')} ${cat}`;
  for (const [re, c] of GENRE_CATEGORY) if (re.test(hay)) return c;
  if (cat === 'music') return 'concerts';
  if (cat === 'nightlife') return 'nightlife';
  if (cat === 'sports') return 'sports';
  if (cat === 'comedy') return 'comedy';
  if (cat === 'arts') return 'theater';
  if (!cat) {
    for (const [re, c] of GENRE_CATEGORY) if (re.test(String(ev.name ?? ''))) return c;
    return 'concerts';
  }
  return 'other';
}

function txt(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

/** What stands between this event and each marketplace. */
export function eventReadiness(
  ev: StandardEventInput,
  tiers: StandardTierInput[],
  channels: readonly MarketplaceId[],
): Readiness[] {
  const title = marketTitle(ev);
  const venue = txt(ev.venue_name) || txt(ev.venue_location);
  const addr = ev.venue_address ?? {};
  const city = txt(addr.city);
  const region = txt(addr.region);
  const country = txt(addr.country);
  const performer = txt(ev.primary_performer_name) || (ev.performer_names ?? []).map(txt).find(Boolean) || '';
  const category = marketCategory(ev);
  const hasLocalTime = /T\d{2}:\d{2}/.test(ev.occurs_at_local ?? '') || !!txt(ev.timezone);
  const currency = (txt(ev.currency) || 'USD').toUpperCase();
  const sections = tiers.map(marketSection);
  const renamed = tiers.filter((t, i) => sections[i] !== collapse(t.name) && !/^(?:ga|general admission)$/i.test(collapse(t.name)));

  const common = { blocking: [] as string[], warnings: [] as string[] };
  if (!title) common.blocking.push('Give the event a title (the show or performer).');
  if (!ev.starts_at) common.blocking.push('Set the start date and time.');
  if (!venue) common.blocking.push('Add the venue name.');
  if (!city) common.warnings.push('Add the venue city: marketplaces match events by venue and city.');
  if (city && (!region || !country)) common.warnings.push('Add the venue state/region and country for exact matching.');
  if (!txt(ev.timezone)) common.warnings.push("Set the event's time zone so marketplaces show the right local time.");
  if ((category === 'concerts' || category === 'comedy') && !performer) {
    common.warnings.push('Add the headliner: marketplaces match concerts and comedy by performer.');
  }
  if (category === 'other') {
    common.warnings.push('Marketplaces list concerts, nightlife, comedy, theater, festivals and sports; this category may be refused.');
  }
  if (title && txt(ev.name) && title !== collapse(txt(ev.name))) {
    common.warnings.push(`Listed as "${title}" (dates, emoji and sales words are dropped from marketplace titles).`);
  }
  if (renamed.length) {
    common.warnings.push(`Ticket types list as marketplace sections: ${renamed.slice(0, 4).map((t) => `${t.name} → ${marketSection(t)}`).join(', ')}.`);
  }

  return channels.map((channel) => {
    const blocking = [...common.blocking];
    const warnings = [...common.warnings];
    if (channel === 'stubhub' && !city) blocking.push('StubHub needs the venue city to request the event.');
    if (channel === 'vivid' && !hasLocalTime) blocking.push("Vivid Seats needs the venue-local start time: set the event's time zone.");
    if ((channel === 'vivid' || channel === 'evo') && currency !== 'USD') blocking.push(`${MARKETPLACE_LABEL[channel]} lists in USD only; this event is in ${currency}.`);
    if (channel === 'evo') warnings.push('Ticket Evolution needs Exos staff to link the event before anything lists.');
    if (channel === 'gametime' && !city) warnings.push('Gametime matches by event name, venue and date; the city makes that reliable.');
    return { channel, blocking, warnings, ready: blocking.length === 0 };
  });
}
