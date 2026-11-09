// Inbound booking requests (mig 20261102130000, docs/templates-inbound.md):
// the public form's input as the exos_inbound_submit payload, and the
// review actions each role gets. Pure; the database checks everything again.

export const INBOUND_STATUSES = ['new', 'reviewing', 'accepted', 'declined'] as const;
export type InboundStatus = (typeof INBOUND_STATUSES)[number];
export const CONTACT_ROLES = ['artist', 'agent', 'manager', 'promoter', 'other'] as const;
export const LINK_KINDS = ['spotify', 'instagram', 'website', 'youtube', 'tiktok', 'bandcamp', 'soundcloud'] as const;

/** The 16 KB cap of exos_inbound_submit, in UTF-8 bytes of the JSON body. */
export const MAX_SUBMISSION_BYTES = 16 * 1024;

export interface InboundForm {
  artist_name: string;
  contact_name: string;
  contact_role: string;
  email: string;
  phone: string;
  message: string;
  links: Partial<Record<(typeof LINK_KINDS)[number], string>>;
  genres: string;
  venue_id: string;
  preferred_dates: string[];
  dates_flexible: boolean;
  expected_draw: string;
  /** The honeypot: a hidden field people never fill. */
  homepage: string;
}

export function emptyInboundForm(): InboundForm {
  return {
    artist_name: '', contact_name: '', contact_role: 'artist', email: '', phone: '', message: '', links: {},
    genres: '', venue_id: '', preferred_dates: [], dates_flexible: true, expected_draw: '', homepage: '',
  };
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** The form as the RPC payload, or the first problem to show. */
export function inboundPayload(f: InboundForm): { ok: true; payload: Record<string, unknown> } | { ok: false; error: string } {
  const artist = f.artist_name.trim();
  if (!artist) return { ok: false, error: 'Enter the act\'s name.' };
  if (artist.length > 150) return { ok: false, error: 'The act\'s name is at most 150 characters.' };
  const email = f.email.trim().toLowerCase();
  if (!EMAIL_RE.test(email) || email.length > 200) return { ok: false, error: 'Enter a valid email address so the venue can reply.' };
  if (f.message.length > 5000) return { ok: false, error: 'The message is at most 5000 characters.' };
  const links: Record<string, string> = {};
  for (const k of LINK_KINDS) {
    const v = (f.links[k] ?? '').trim();
    if (!v) continue;
    if (!/^https:\/\/\S{3,}$/.test(v) || v.length > 300) return { ok: false, error: `The ${k} link must start with https://` };
    links[k] = v;
  }
  const genres = f.genres.split(',').map((g) => g.trim()).filter(Boolean);
  if (genres.length > 10 || genres.some((g) => g.length > 40)) return { ok: false, error: 'Up to 10 genres, each at most 40 characters.' };
  const dates = [...new Set(f.preferred_dates.filter((d) => DATE_RE.test(d)))].sort();
  if (dates.length > 10) return { ok: false, error: 'Up to 10 preferred dates.' };
  let draw: number | undefined;
  if (f.expected_draw.trim()) {
    draw = Number(f.expected_draw.trim());
    if (!Number.isInteger(draw) || draw < 0 || draw > 1_000_000) return { ok: false, error: 'Expected draw is a whole number.' };
  }
  const payload: Record<string, unknown> = {
    artist_name: artist, email, contact_role: CONTACT_ROLES.includes(f.contact_role as never) ? f.contact_role : 'other',
    dates_flexible: f.dates_flexible,
  };
  if (f.contact_name.trim()) payload.contact_name = f.contact_name.trim().slice(0, 100);
  if (f.phone.trim()) payload.phone = f.phone.trim().slice(0, 40);
  if (f.message.trim()) payload.message = f.message.trim();
  if (Object.keys(links).length) payload.links = links;
  if (genres.length) payload.genres = genres;
  if (f.venue_id) payload.venue_id = f.venue_id;
  if (dates.length) payload.preferred_dates = dates;
  if (draw !== undefined) payload.expected_draw = draw;
  // Sent as typed: the server drops the request when it's filled.
  if (f.homepage) payload.homepage = f.homepage;
  if (new TextEncoder().encode(JSON.stringify(payload)).length > MAX_SUBMISSION_BYTES) {
    return { ok: false, error: 'That is too long to send; shorten the message.' };
  }
  return { ok: true, payload };
}

/** A server error from the form, as a sentence for the visitor. */
export function inboundErrorMessage(e: { code?: string; message?: string } | null | undefined): string {
  if (e?.code === '54000') return e.message ? cap(e.message) : 'Too many requests; try again later.';
  if (e?.code === 'P0002') return 'This venue isn\'t taking booking requests online right now.';
  if (e?.code === '22023' && e.message) return cap(e.message);
  return 'Something went wrong sending your request. Try again in a minute.';
}

function cap(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? '' : '.');
}

export interface InboundActions {
  review: boolean;
  hold: boolean;
  delete: boolean;
  settings: boolean;
}

/** Content staff review; owners and managers also hold dates, delete and set up the form. */
export function inboundActions(role: string | null | undefined, isAdmin = false, hasHold = false): InboundActions {
  const staff = isAdmin || role === 'owner' || role === 'manager';
  return { review: staff || role === 'content', hold: staff && !hasHold, delete: staff, settings: staff };
}

/** The public form's address for an org slug. */
export function inboundFormPath(slug: string): string {
  return `/book/${encodeURIComponent(slug)}`;
}
