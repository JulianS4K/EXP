// Event import with link-out (mig 20261029170000; docs/organizer-guide.md
// "List an event you sell elsewhere"): reading a pasted Eventbrite, Luma or
// Posh event link.
//
// parseEventUrl turns what an organizer pastes into (platform, source id,
// canonical https URL). It only reads the string: nothing is fetched. The
// SQL (_exos_link_out_url_ok) checks the same rules again, and the edge
// function always re-parses the link itself rather than trusting a platform
// the client names.
//
// Pure: no Deno, DOM or Supabase imports (the SPA and vitest import it too).

export type LinkOutPlatform = 'eventbrite' | 'luma' | 'posh';
export const LINK_OUT_PLATFORMS: readonly LinkOutPlatform[] = ['eventbrite', 'luma', 'posh'];

/** Where an event's tickets are sold, as a buyer reads it. */
export const SALE_PLATFORM_LABEL: Record<string, string> = {
  exos: 'Exos', eventbrite: 'Eventbrite', luma: 'Luma', posh: 'Posh', pretix: 'pretix', hievents: 'hi.events',
};

export interface ParsedEventUrl {
  platform: LinkOutPlatform;
  /** Eventbrite: the numeric event id. Luma: the evt- id or the public slug. Posh: the slug. */
  sourceId: string;
  /** https, no query or fragment. */
  url: string;
}

export type ParseResult = ParsedEventUrl | { error: string };

// Eventbrite's country sites (the same list as the SQL).
const EB_HOST = /^(www\.)?eventbrite\.(com|ca|ie|de|fr|es|nl|it|be|at|ch|se|dk|fi|pt|pl|sg|hk|co\.uk|co\.nz|com\.au|com\.mx|com\.br|com\.ar|com\.pe|com\.co|cl)$/;
const LUMA_HOST = /^(www\.)?(lu\.ma|luma\.com)$/;
const POSH_HOST = /^(www\.)?posh\.vip$/;
const LUMA_EVT = /^evt-[A-Za-z0-9]{4,40}$/;
const LUMA_SLUG = /^[A-Za-z0-9][A-Za-z0-9-]{1,63}$/;
const POSH_SLUG = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
// Luma pages that aren't an event.
const LUMA_RESERVED = new Set([
  'discover', 'signin', 'login', 'signup', 'calendar', 'calendars', 'user', 'u', 'home', 'create', 'pricing', 'explore',
  'settings', 'check-in', 'checkin', 'embed', 'api', 'help', 'map', 'about', 'terms', 'privacy', 'ios', 'android', 'event',
]);

/** Reads a pasted event link. Never fetches it. */
export function parseEventUrl(raw: unknown): ParseResult {
  if (typeof raw !== 'string') return { error: 'Paste the event\'s link.' };
  let s = raw.trim();
  if (!s) return { error: 'Paste the event\'s link.' };
  if (s.length > 1000) return { error: 'That link is too long.' };
  if (!/^[a-z][a-z0-9+.-]*:/i.test(s)) s = `https://${s}`;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return { error: 'That isn\'t a link.' };
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return { error: 'That isn\'t a web link.' };
  if (u.username || u.password || u.port) return { error: 'That link isn\'t an event page.' };
  const host = u.hostname.toLowerCase();
  const segs = u.pathname.split('/').filter(Boolean).map((x) => {
    try { return decodeURIComponent(x); } catch { return x; }
  });

  if (EB_HOST.test(host)) {
    // /e/<name>-tickets-<id>, /e/<id>, or ?eid=<id> (older links).
    let id: string | null = null;
    if (segs[0] === 'e' && segs[1]) id = /(?:^|-)([0-9]{6,24})$/.exec(segs[1])?.[1] ?? null;
    if (!id) {
      const eid = u.searchParams.get('eid');
      if (eid && /^[0-9]{6,24}$/.test(eid)) id = eid;
    }
    if (!id) return { error: 'That Eventbrite link isn\'t an event page (it should look like eventbrite.com/e/…).' };
    const path = segs[0] === 'e' && segs[1] && segs[1].endsWith(id) ? `/e/${encodeURIComponent(segs[1])}` : `/e/${id}`;
    return { platform: 'eventbrite', sourceId: id, url: `https://${host.startsWith('www.') ? host : `www.${host}`}${path}` };
  }

  if (LUMA_HOST.test(host)) {
    const base = host.replace(/^www\./, '');
    // /event/evt-…, /event/manage/evt-…, or /<slug>.
    const evt = segs.find((x) => LUMA_EVT.test(x));
    if (segs[0] === 'event' && evt) return { platform: 'luma', sourceId: evt, url: `https://${base}/event/${evt}` };
    if (segs.length === 1 && LUMA_SLUG.test(segs[0]) && !LUMA_RESERVED.has(segs[0].toLowerCase())) {
      return { platform: 'luma', sourceId: segs[0], url: `https://${base}/${segs[0]}` };
    }
    return { error: 'That Luma link isn\'t an event page (it should look like lu.ma/your-event).' };
  }

  if (POSH_HOST.test(host)) {
    if (segs[0] === 'e' && segs[1] && POSH_SLUG.test(segs[1]) && segs.length === 2) {
      return { platform: 'posh', sourceId: segs[1], url: `https://posh.vip/e/${segs[1]}` };
    }
    return { error: 'That Posh link isn\'t an event page (it should look like posh.vip/e/your-event).' };
  }

  return { error: 'Exos can list events from Eventbrite, Luma and Posh links.' };
}

/** A name to start the form with, from a slug ("summer-rooftop-party" → "Summer Rooftop Party"). */
export function nameFromSlug(p: ParsedEventUrl): string {
  if (p.platform === 'eventbrite' || LUMA_EVT.test(p.sourceId)) return '';
  const words = p.sourceId.replace(/[-_]+/g, ' ').trim();
  if (!words || /^[a-z0-9]{6,12}$/i.test(words) && /\d/.test(words)) return ''; // a random short code, not a name
  return words.replace(/\b\w/g, (c) => c.toUpperCase()).slice(0, 200);
}

/** The URL with tracking parameters added (existing ones kept, ours win). */
export function withUtm(url: string, params: Record<string, string>): string {
  try {
    const u = new URL(url);
    for (const [k, v] of Object.entries(params)) if (v) u.searchParams.set(k, v);
    return u.toString();
  } catch {
    return url;
  }
}
