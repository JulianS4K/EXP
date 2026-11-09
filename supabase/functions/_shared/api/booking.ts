// Booking request bodies and views for the partner API (exos-api), mig
// 20261030100000, docs/booking.md and docs/api/{venues,holds,schedule}.json.
//
// The database is the authority (checks, triggers and the hold functions
// validate everything again); these parsers turn a JSON body into the columns
// a route may write, refuse unknown shapes early with a readable message, and
// never let a body choose org_id, ids, authorship or the hold links.
//
// Pure TypeScript, imported by vitest (src/lib/apiBooking.test.ts).

export class BodyError extends Error {}

export const VENUE_RELATIONSHIPS = ['owned', 'rented', 'partner'] as const;
export const SHOW_ACTIVITY_KINDS = [
  'announce', 'load_in', 'soundcheck', 'doors', 'set', 'changeover', 'curfew', 'load_out', 'other',
] as const;
export const CONTACT_ROLES = ['promoter', 'agent', 'production', 'settlement', 'other'] as const;
export const HOLD_STATUSES = ['active', 'cleared', 'converted'] as const;

export const KIND_NAMES: Record<(typeof SHOW_ACTIVITY_KINDS)[number], string> = {
  announce: 'Announce',
  load_in: 'Load in',
  soundcheck: 'Soundcheck',
  doors: 'Doors',
  set: 'Set',
  changeover: 'Changeover',
  curfew: 'Curfew',
  load_out: 'Load out',
  other: 'Other',
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

type Body = Record<string, unknown>;
type Row = Record<string, unknown>;

export function isUuid(s: unknown): s is string {
  return typeof s === 'string' && UUID_RE.test(s);
}

/** A real calendar date written YYYY-MM-DD. */
export function isIsoDate(s: unknown): s is string {
  if (typeof s !== 'string') return false;
  const m = DATE_RE.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

/** The request body as an object, or a 400. */
export function bodyObject(raw: unknown): Body {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw new BodyError('The body must be a JSON object.');
  return raw as Body;
}

function has(b: Body, k: string): boolean {
  return Object.prototype.hasOwnProperty.call(b, k) && b[k] !== undefined;
}

function text(v: unknown, field: string, max: number, opts: { required?: boolean } = {}): string {
  if (v === null || v === undefined) {
    if (opts.required) throw new BodyError(`${field} is required.`);
    return '';
  }
  if (typeof v !== 'string') throw new BodyError(`${field} must be a string.`);
  const s = v.trim();
  if (opts.required && !s) throw new BodyError(`${field} is required.`);
  if (s.length > max) throw new BodyError(`${field} must be at most ${max} characters.`);
  return s;
}

function optText(v: unknown, field: string, max: number): string | null {
  return text(v, field, max) || null;
}

function wholeNumber(v: unknown, field: string, min: number, max: number): number | null {
  if (v === null || v === '') return null;
  const n = typeof v === 'string' && /^\d+$/.test(v) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < min || n > max) {
    throw new BodyError(`${field} must be a whole number from ${min} to ${max}.`);
  }
  return n;
}

function bool(v: unknown, field: string): boolean {
  if (typeof v !== 'boolean') throw new BodyError(`${field} must be true or false.`);
  return v;
}

function oneOf<T extends string>(v: unknown, field: string, allowed: readonly T[]): T {
  if (typeof v !== 'string' || !(allowed as readonly string[]).includes(v)) {
    throw new BodyError(`${field} must be one of ${allowed.join(', ')}.`);
  }
  return v as T;
}

function email(v: unknown, field: string): string | null {
  const s = text(v, field, 200).toLowerCase();
  if (s && !EMAIL_RE.test(s)) throw new BodyError(`${field} must be a valid address.`);
  return s || null;
}

/** An ISO 8601 time (with a date), as an ISO string in UTC. */
export function isoTime(v: unknown, field: string): string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v) || Number.isNaN(Date.parse(v))) {
    throw new BodyError(`${field} must be an ISO 8601 time, e.g. 2026-11-14T19:00:00-06:00.`);
  }
  return new Date(v).toISOString();
}

function nothing(row: Row): Row {
  if (Object.keys(row).length === 0) throw new BodyError('Nothing to update.');
  return row;
}

// -- Venues ----------------------------------------------------------------------

const ADDRESS_KEYS = ['street', 'city', 'region', 'country', 'postal'] as const;

function address(v: unknown): Row | null {
  if (v === null) return null;
  if (typeof v !== 'object' || Array.isArray(v)) throw new BodyError('address must be an object.');
  const a = v as Body;
  const out: Row = {};
  for (const k of ADDRESS_KEYS) {
    const s = text(a[k], `address.${k}`, 120);
    if (s) out[k] = s;
  }
  return Object.keys(out).length ? out : null;
}

/** exos_venues columns from a body. `partial` = PATCH (absent fields untouched). */
export function parseVenue(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const row: Row = {};
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 100, { required: true });
  if (has(b, 'address')) row.address = address(b.address);
  const tz = has(b, 'timezone') ? b.timezone : b.time_zone;
  if (tz !== undefined) row.timezone = optText(tz, 'timezone', 64);
  if (has(b, 'capacity')) row.capacity = wholeNumber(b.capacity, 'capacity', 0, 1_000_000);
  if (has(b, 'website')) {
    const w = text(b.website, 'website', 300);
    if (w) {
      let u: URL;
      try {
        u = new URL(w);
      } catch {
        throw new BodyError('website must be an https URL.');
      }
      if (u.protocol !== 'https:') throw new BodyError('website must be an https URL.');
      row.website = u.toString();
    } else row.website = null;
  }
  if (has(b, 'permalink')) {
    const p = text(b.permalink, 'permalink', 60).toLowerCase();
    if (p && !/^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$/.test(p)) {
      throw new BodyError('permalink must be lowercase letters, digits and dashes (at most 60).');
    }
    row.permalink = p || null;
  }
  if (has(b, 'relationship')) row.relationship = oneOf(b.relationship, 'relationship', VENUE_RELATIONSHIPS);
  if (has(b, 'contact')) {
    if (b.contact === null) {
      row.contact_name = null;
      row.contact_email = null;
      row.contact_phone = null;
    } else {
      if (typeof b.contact !== 'object' || Array.isArray(b.contact)) throw new BodyError('contact must be an object.');
      const c = b.contact as Body;
      row.contact_name = optText(c.name, 'contact.name', 100);
      row.contact_email = email(c.email, 'contact.email');
      row.contact_phone = optText(c.phone, 'contact.phone', 40);
    }
  }
  if (has(b, 'notes')) row.notes = optText(b.notes, 'notes', 2000);
  return partial ? nothing(row) : row;
}

export const VENUE_COLS =
  'id, name, address, timezone, capacity, website, permalink, relationship, contact_name, contact_email, ' +
  'contact_phone, notes, created_at, updated_at';

export function venueView(r: Row) {
  const contact = r.contact_name || r.contact_email || r.contact_phone
    ? { name: r.contact_name ?? null, email: r.contact_email ?? null, phone: r.contact_phone ?? null }
    : null;
  return {
    id: r.id,
    name: r.name,
    address: r.address ?? null,
    timezone: r.timezone ?? null,
    capacity: r.capacity ?? null,
    website: r.website ?? null,
    permalink: r.permalink ?? null,
    relationship: r.relationship ?? 'owned',
    contact,
    notes: r.notes ?? null,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
}

// -- Rooms -----------------------------------------------------------------------

export const ROOM_COLS = 'id, venue_id, name, capacity, color, notes, sort_order, created_at, updated_at';

export function parseRoom(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const row: Row = {};
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 100, { required: true });
  if (has(b, 'capacity')) row.capacity = wholeNumber(b.capacity, 'capacity', 0, 1_000_000);
  const color = has(b, 'color') ? b.color : b.calendar_color_hex;
  if (color !== undefined) {
    const c = text(color, 'color', 7);
    if (c && !/^#[0-9a-fA-F]{6}$/.test(c)) throw new BodyError('color must be a hex color like #ff5733.');
    row.color = c || null;
  }
  if (has(b, 'notes')) row.notes = optText(b.notes, 'notes', 1000);
  if (has(b, 'sort_order')) row.sort_order = wholeNumber(b.sort_order, 'sort_order', 0, 1000) ?? 0;
  return partial ? nothing(row) : row;
}

// -- Show activities ---------------------------------------------------------------

export const ACTIVITY_COLS = 'id, event_id, kind, name, starts_at, ends_at, notes, is_set, show_in_advance, created_at, updated_at';

/**
 * exos_show_activities columns. `start_time` / `set` are accepted as aliases
 * of starts_at / is_set. A new row without a name takes its kind's name.
 */
export function parseActivity(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const row: Row = {};
  if (!partial || has(b, 'kind')) row.kind = oneOf(b.kind ?? 'other', 'kind', SHOW_ACTIVITY_KINDS);
  if (has(b, 'name')) row.name = text(b.name, 'name', 80) || KIND_NAMES[(row.kind ?? 'other') as keyof typeof KIND_NAMES];
  else if (!partial) row.name = KIND_NAMES[row.kind as keyof typeof KIND_NAMES];
  const starts = has(b, 'starts_at') ? b.starts_at : b.start_time;
  if (starts !== undefined) row.starts_at = isoTime(starts, 'starts_at');
  else if (!partial) throw new BodyError('starts_at is required.');
  if (has(b, 'ends_at')) row.ends_at = b.ends_at === null ? null : isoTime(b.ends_at, 'ends_at');
  if (typeof row.ends_at === 'string' && typeof row.starts_at === 'string' && row.ends_at < row.starts_at) {
    throw new BodyError('ends_at must not be before starts_at.');
  }
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 500);
  const set = has(b, 'is_set') ? b.is_set : b.set;
  if (set !== undefined) row.is_set = bool(set, 'is_set');
  if (has(b, 'show_in_advance')) row.show_in_advance = bool(b.show_in_advance, 'show_in_advance');
  return partial ? nothing(row) : row;
}

// -- Notes and contacts -----------------------------------------------------------------

export const NOTE_COLS = 'id, event_id, body, author_id, author_name, created_at, updated_at';
export const CONTACT_COLS = 'id, event_id, role, title, name, email, phone, company, notes, created_at, updated_at';

export function parseNote(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const row: Row = {};
  if (!partial || has(b, 'body')) row.body = text(b.body, 'body', 5000, { required: true });
  if (has(b, 'author_name')) row.author_name = text(b.author_name, 'author_name', 100);
  else if (!partial) row.author_name = 'API';
  return partial ? nothing(row) : row;
}

export function parseContact(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const row: Row = {};
  if (!partial || has(b, 'role')) row.role = oneOf(b.role ?? 'other', 'role', CONTACT_ROLES);
  if (has(b, 'title')) row.title = optText(b.title, 'title', 80);
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 100, { required: true });
  if (has(b, 'email')) row.email = email(b.email, 'email');
  if (has(b, 'phone')) row.phone = optText(b.phone, 'phone', 40);
  if (has(b, 'company')) row.company = optText(b.company, 'company', 100);
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 500);
  return partial ? nothing(row) : row;
}

// -- Holds ---------------------------------------------------------------------------

export interface HoldFilters {
  from: string | null;
  to: string | null;
  venueId: string | null;
  roomId: string | null;
  status: (typeof HOLD_STATUSES)[number] | null;
  q: string | null;
}

/** ?from=&to=&venue_id=&room_id=&status=&q= for GET /holds. */
export function parseHoldFilters(q: URLSearchParams): HoldFilters {
  const date = (name: string) => {
    const v = q.get(name);
    if (v === null || v === '') return null;
    if (!isIsoDate(v)) throw new BodyError(`${name} must be a date written YYYY-MM-DD.`);
    return v;
  };
  const id = (...names: string[]) => {
    for (const n of names) {
      const v = q.get(n);
      if (v === null || v === '') continue;
      if (!isUuid(v)) throw new BodyError(`${names[0]} must be a UUID.`);
      return v;
    }
    return null;
  };
  const from = date('from');
  const to = date('to');
  if (from && to && to < from) throw new BodyError('to must not be before from.');
  const s = q.get('status');
  const status = s === null || s === '' ? null : oneOf(s, 'status', HOLD_STATUSES);
  const text = (q.get('q') ?? q.get('title') ?? '').trim();
  if (text.length > 100) throw new BodyError('q must be at most 100 characters.');
  return { from, to, venueId: id('venue_id', 'q[venue_id_eq]'), roomId: id('room_id'), status, q: text || null };
}

/**
 * A hold body for the SQL functions: the keys they read, nothing else
 * (org, authorship and status are never taken from a body).
 */
export function holdBody(raw: unknown, partial: boolean): Row {
  const b = bodyObject(raw);
  const keys = ['title', 'notes', 'artist_ids', 'announce_at', 'ticket_forecast', 'age_restriction', 'rental', 'positions'];
  const out: Row = {};
  for (const k of keys) if (has(b, k)) out[k] = b[k];
  if (!partial && !Array.isArray(out.positions)) throw new BodyError('positions must be a list of 1 to 30 nights.');
  return partial ? nothing(out) : out;
}

/** Convert args: position_id | date (+ room_id), time, title, capacity, clear_holds_on_day. */
export function convertBody(raw: unknown): Row {
  const b = raw === null || raw === undefined ? {} : bodyObject(raw);
  const out: Row = {};
  const pos = has(b, 'position_id') ? b.position_id : b.hold_position_id;
  if (pos !== undefined) {
    if (!isUuid(pos)) throw new BodyError('position_id must be a UUID.');
    out.position_id = pos;
  }
  for (const k of ['date', 'room_id', 'time', 'title', 'capacity', 'clear_holds_on_day']) if (has(b, k)) out[k] = b[k];
  return out;
}

/** position_ids (or Opendate's hold_position_ids) for POST /holds/:id/clear; null = every active night. */
export function clearBody(raw: unknown): string[] | null {
  const b = raw === null || raw === undefined ? {} : bodyObject(raw);
  const ids = has(b, 'position_ids') ? b.position_ids : b.hold_position_ids;
  if (ids === undefined || ids === null) return null;
  if (!Array.isArray(ids) || ids.length === 0 || ids.length > 30 || !ids.every(isUuid)) {
    throw new BodyError('position_ids must be a list of 1 to 30 position ids.');
  }
  return ids as string[];
}

// -- Database errors -------------------------------------------------------------------

/**
 * A Postgres / PostgREST error from the booking tables and functions as an
 * HTTP status and message (the SQL raises with these codes on purpose, mig
 * 20261030100000). null = not one of ours (a 500).
 */
export function bookingDbError(e: { code?: string; message?: string } | null | undefined): { status: number; message: string } | null {
  if (!e || typeof e.code !== 'string') return null;
  const msg = String(e.message ?? '').replace(/^exos_[a-z_]+:\s*/, '');
  const clean = msg ? msg.charAt(0).toUpperCase() + msg.slice(1) : 'Request refused.';
  switch (e.code) {
    case '22023': case '22P02': case '22007': case '22008': case '23514': case '23502': case '22001':
      return { status: 400, message: clean };
    case 'P0002':
      return { status: 404, message: clean };
    case '42501':
      return { status: 404, message: 'Not found.' };
    case '23505':
      return { status: 409, message: /duplicate key/.test(msg) ? 'That conflicts with an existing record (e.g. a permalink in use or a second doors row).' : clean };
    case '23503':
      return { status: 409, message: 'Still in use: holds or events point at it.' };
    case '55000': case '54000':
      return { status: 409, message: clean };
    default:
      return null;
  }
}
