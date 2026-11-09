// Template, rental invoice and inbound-submission bodies for the partner API
// (exos-api), mig 20261102130000, docs/templates-inbound.md and
// docs/api/templates.json / inbound-submissions.json.
//
// The database is the authority (triggers and the _exos_* cores validate
// everything again); these turn a JSON or form body into the fields a route
// may write, accept Opendate's wrapped bodies and field names, and refuse
// unknown fields early with a readable message. A body never chooses org_id,
// ids, numbers, totals or authorship.
//
// Pure TypeScript, imported by vitest (src/lib/apiTemplates.test.ts).

import { BodyError, isUuid } from './booking.ts';
import { unwrapBody } from './finance.ts';

type Body = Record<string, unknown>;

const has = (b: Body, k: string) => Object.prototype.hasOwnProperty.call(b, k) && b[k] !== undefined;

/** Keep only `allowed` keys (after renaming `aliases`); refuse any other key that isn't in `ignored`. */
function pick(b: Body, allowed: readonly string[], aliases: Record<string, string> = {}, ignored: readonly string[] = []): Body {
  const out: Body = {};
  for (const [k0, v] of Object.entries(b)) {
    if (v === undefined) continue;
    const k = aliases[k0] ?? k0;
    if (allowed.includes(k)) out[k] = v;
    else if (!ignored.includes(k0)) throw new BodyError(`Unknown or read-only field: ${k0.slice(0, 60)}.`);
  }
  return out;
}

function str(b: Body, k: string, max: number, required = false): void {
  if (!has(b, k)) {
    if (required) throw new BodyError(`${k} is required.`);
    return;
  }
  const v = b[k];
  if (v === null && !required) return;
  if (typeof v !== 'string') throw new BodyError(`${k} must be a string.`);
  if (required && !v.trim()) throw new BodyError(`${k} is required.`);
  if (v.length > max) throw new BodyError(`${k} must be at most ${max} characters.`);
}

function intIn(b: Body, k: string, min: number, max: number): void {
  if (!has(b, k) || b[k] === null) return;
  const n = typeof b[k] === 'string' && /^-?\d+$/.test(b[k] as string) ? Number(b[k]) : b[k];
  if (typeof n !== 'number' || !Number.isInteger(n) || n < min || n > max) {
    throw new BodyError(`${k} must be a whole number from ${min} to ${max}.`);
  }
  b[k] = n;
}

function list(b: Body, k: string, max: number): void {
  if (!has(b, k)) return;
  if (!Array.isArray(b[k])) throw new BodyError(`${k} must be a list.`);
  if ((b[k] as unknown[]).length > max) throw new BodyError(`${k} takes at most ${max} entries.`);
}

const STATUSES = ['active', 'archived'];

function status(b: Body): void {
  if (has(b, 'status') && !STATUSES.includes(b.status as string)) throw new BodyError('status must be active or archived.');
}

// ---- Event templates ---------------------------------------------------------

export const EVENT_TEMPLATE_FIELDS = [
  'name', 'status', 'event_name', 'description', 'capacity', 'doors_offset_minutes', 'duration_minutes',
  'event_fields', 'tiers', 'fee_rules', 'inherit_org_fees',
] as const;

/** POST / PATCH /event-templates. On create, `from_event_id` snapshots one of your events instead. */
export function eventTemplateBody(raw: unknown, patch: boolean): { row: Body; fromEventId: string | null } {
  const b = unwrapBody(raw, 'event_template');
  const fromEventId = !patch && has(b, 'from_event_id') ? b.from_event_id : null;
  if (fromEventId !== null && !isUuid(fromEventId)) throw new BodyError('from_event_id must be a UUID.');
  const rest = { ...b };
  delete rest.from_event_id;
  const row = pick(rest, EVENT_TEMPLATE_FIELDS, { ticket_types: 'tiers' }, ['team_id']);
  if (fromEventId) {
    const extra = Object.keys(row).filter((k) => k !== 'name');
    if (extra.length) throw new BodyError('With from_event_id, only name may be sent (the rest comes from the event).');
    str(row, 'name', 100);
    return { row, fromEventId: fromEventId as string };
  }
  str(row, 'name', 100, !patch);
  str(row, 'event_name', 200);
  str(row, 'description', 20000);
  status(row);
  intIn(row, 'capacity', 0, 1_000_000);
  intIn(row, 'doors_offset_minutes', 0, 1440);
  intIn(row, 'duration_minutes', 1, 10080);
  if (has(row, 'event_fields') && (row.event_fields === null || typeof row.event_fields !== 'object' || Array.isArray(row.event_fields))) {
    throw new BodyError('event_fields must be an object.');
  }
  list(row, 'tiers', 50);
  list(row, 'fee_rules', 25);
  if (has(row, 'inherit_org_fees') && typeof row.inherit_org_fees !== 'boolean') throw new BodyError('inherit_org_fees must be true or false.');
  for (const k of ['description'] as const) if (row[k] === null) row[k] = '';
  return { row, fromEventId: null };
}

/** POST /event-templates/:id/events: { name?, starts_at?, timezone?, exos_venue_id?, exos_room_id? }. */
export function eventFromTemplateBody(raw: unknown): Body {
  const b = pick(unwrapBody(raw, 'event'), ['name', 'starts_at', 'timezone', 'exos_venue_id', 'exos_room_id'],
    { venue_id: 'exos_venue_id', room_id: 'exos_room_id' });
  str(b, 'name', 200);
  str(b, 'timezone', 64);
  if (has(b, 'starts_at') && b.starts_at !== null && (typeof b.starts_at !== 'string' || Number.isNaN(Date.parse(b.starts_at)))) {
    throw new BodyError('starts_at must be an ISO 8601 time.');
  }
  for (const k of ['exos_venue_id', 'exos_room_id']) {
    if (has(b, k) && b[k] !== null && !isUuid(b[k])) throw new BodyError(`${k} must be a UUID.`);
  }
  return b;
}

// ---- Note templates ------------------------------------------------------------

export function noteTemplateBody(raw: unknown, patch: boolean): Body {
  const b = pick(unwrapBody(raw, 'note_template'), ['title', 'body', 'status'], {}, ['team_id']);
  str(b, 'title', 100, !patch);
  str(b, 'body', 5000, !patch);
  status(b);
  return b;
}

// ---- Rental invoice templates and invoices ---------------------------------------

const RENTAL_ALIASES: Record<string, string> = {
  terms_and_conditions: 'terms',
  rental_invoice_items: 'items',
  rental_invoice_items_attributes: 'items',
  deposits_attributes: 'deposits',
  rental_invoice_tax_fees: 'tax_fees',
  rental_invoice_tax_fees_attributes: 'tax_fees',
};
// Opendate fields that Exos sets itself (the key's org and creator, the type).
const RENTAL_IGNORED = ['team_id', 'team_membership_id', 'type', 'organization_id'];

export const RENTAL_TEMPLATE_FIELDS = [
  'title', 'status', 'currency', 'payee_name', 'notes', 'terms', 'attendance_count', 'discount_cents', 'items',
  'deposits', 'tax_fees',
] as const;

export function rentalTemplateBody(raw: unknown, patch: boolean): Body {
  const b = pick(unwrapBody(raw, 'rental_invoice_template'), RENTAL_TEMPLATE_FIELDS, RENTAL_ALIASES, RENTAL_IGNORED);
  str(b, 'title', 100, !patch);
  status(b);
  if (has(b, 'currency')) {
    if (typeof b.currency !== 'string' || !/^[A-Za-z]{3}$/.test(b.currency)) throw new BodyError('currency must be a 3-letter code.');
    b.currency = b.currency.toUpperCase();
  }
  str(b, 'payee_name', 200);
  str(b, 'notes', 10000);
  str(b, 'terms', 20000);
  for (const k of ['notes', 'terms']) if (b[k] === null) b[k] = '';
  intIn(b, 'attendance_count', 0, 1_000_000);
  intIn(b, 'discount_cents', 0, 100_000_000_000);
  if (b.discount_cents === null) b.discount_cents = 0;
  list(b, 'items', 100);
  list(b, 'deposits', 10);
  list(b, 'tax_fees', 10);
  return b;
}

export const RENTAL_INVOICE_FIELDS = [
  'title', 'currency', 'payee_name', 'bill_to_name', 'bill_to_email', 'notes', 'terms', 'attendance_count',
  'discount_cents', 'items', 'deposits', 'tax_fees', 'hold_id', 'hold_position_id', 'venue_id', 'room_id',
  'rental_date', 'event_id', 'due_on',
] as const;

/** POST (with template_id) / PATCH /rental-invoices: the draft's fields; the SQL core checks them again. */
export function rentalInvoiceBody(raw: unknown, patch: boolean): Body {
  const allowed = patch ? [...RENTAL_INVOICE_FIELDS] : [...RENTAL_INVOICE_FIELDS, 'template_id'];
  const b = pick(unwrapBody(raw, 'rental_invoice'), allowed,
    { ...RENTAL_ALIASES, calendar_event_id: 'event_id', venue_ownership_id: 'venue_id' }, RENTAL_IGNORED);
  for (const k of ['template_id', 'hold_id', 'hold_position_id', 'venue_id', 'room_id', 'event_id']) {
    if (has(b, k) && b[k] !== null && !isUuid(b[k])) throw new BodyError(`${k} must be a UUID.`);
  }
  if (!patch && !has(b, 'template_id')) str(b, 'title', 100, true);
  str(b, 'bill_to_email', 200);
  intIn(b, 'attendance_count', 0, 1_000_000);
  intIn(b, 'discount_cents', 0, 100_000_000_000);
  list(b, 'items', 100);
  return b;
}

// ---- Inbound submissions -----------------------------------------------------------

export const INBOUND_STATUSES = ['new', 'reviewing', 'accepted', 'declined'] as const;
const LINK_KEYS = ['spotify', 'instagram', 'website', 'youtube', 'tiktok', 'bandcamp', 'soundcloud'];

/**
 * POST /inbound-submissions (and the public form): Opendate's
 * inbound_submission[...] fields map on (name -> contact_name,
 * venue_ownership_id -> venue_id, spotify / instagram -> links).
 */
export function inboundBody(raw: unknown): Body {
  const b0 = unwrapBody(raw, 'inbound_submission');
  const links: Record<string, unknown> = {};
  const b: Body = {};
  for (const [k, v] of Object.entries(b0)) {
    if (v === undefined) continue;
    if (LINK_KEYS.includes(k)) {
      if (v !== null && v !== '') links[k] = v;
    } else if (k === 'links') {
      if (v !== null && (typeof v !== 'object' || Array.isArray(v))) throw new BodyError('links must be an object of https URLs.');
      Object.assign(links, v ?? {});
    } else if (k === 'team_id' || k === 'AppId') {
      // The key's org decides.
    } else {
      b[k === 'name' ? 'contact_name' : k === 'venue_ownership_id' ? 'venue_id' : k] = v;
    }
  }
  const out = pick(b, ['artist_name', 'contact_name', 'contact_role', 'email', 'phone', 'company', 'message', 'genres',
    'venue_id', 'preferred_dates', 'dates_flexible', 'expected_draw', 'homepage']);
  if (Object.keys(links).length) out.links = links;
  str(out, 'artist_name', 150, true);
  str(out, 'email', 200);
  str(out, 'message', 5000);
  if (typeof out.genres === 'string') out.genres = out.genres.split(',').map((g) => g.trim()).filter(Boolean);
  list(out, 'genres', 10);
  list(out, 'preferred_dates', 10);
  if (has(out, 'venue_id') && out.venue_id !== null && out.venue_id !== '' && !isUuid(out.venue_id)) {
    throw new BodyError('venue_id must be a UUID.');
  }
  if (out.venue_id === '') delete out.venue_id;
  if (typeof out.dates_flexible === 'string') out.dates_flexible = out.dates_flexible === 'true';
  intIn(out, 'expected_draw', 0, 1_000_000);
  return out;
}

/** PATCH /inbound-submissions/:id: { status?, staff_note? }. */
export function inboundPatch(raw: unknown): { status: string | null; staff_note: string | null } {
  const b = pick(unwrapBody(raw, 'inbound_submission'), ['status', 'staff_note']);
  if (!has(b, 'status') && !has(b, 'staff_note')) throw new BodyError('Send status and / or staff_note.');
  if (has(b, 'status') && !(INBOUND_STATUSES as readonly string[]).includes(b.status as string)) {
    throw new BodyError(`status must be one of ${INBOUND_STATUSES.join(', ')}.`);
  }
  str(b, 'staff_note', 2000);
  return { status: (b.status as string | undefined) ?? null, staff_note: (b.staff_note as string | undefined) ?? null };
}
