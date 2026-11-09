// Request shapes for the box-office routes of exos-api (mig 20261105120000,
// exos-api/boxOffice.ts): printed tickets, membership reservations, staff
// shifts and retagging. Opendate-style wrapped bodies
// ({ membership_reservation: { … } }, membership_reservation[email]=…) are
// read the same as flat ones. Only shapes are checked here; the SQL decides.
//
// Pure TypeScript, imported by vitest.

import { printCodeTicketId } from '../print/tickets.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class BoxError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function unwrap(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const inner = body[wrapper];
  return inner && typeof inner === 'object' && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

function optText(b: Record<string, unknown>, k: string, max: number): string | undefined {
  const v = b[k];
  if (v === undefined || v === null || v === '') return undefined;
  if (typeof v !== 'string') throw new BoxError(400, `${k} must be text.`);
  if (v.length > max) throw new BoxError(400, `${k} is at most ${max} characters.`);
  return v;
}

function optUuid(b: Record<string, unknown>, k: string): string | null {
  const v = b[k];
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || !UUID_RE.test(v)) throw new BoxError(400, `${k} must be a UUID.`);
  return v.toLowerCase();
}

const truthy = (v: unknown) => v === true || v === 'true' || v === '1';

/** The ticket a path segment names: its id, its app code (T-…) or its print code (P-…). */
export function printTicketId(segment: string | undefined): string | null {
  const s = (segment ?? '').trim();
  if (UUID_RE.test(s)) return s.toLowerCase();
  const t = /^T-([0-9a-f-]{36}):/i.exec(s);
  if (t && UUID_RE.test(t[1])) return t[1].toLowerCase();
  return printCodeTicketId(s);
}

/** POST …/reservations: what the SQL takes. A card reader or a gift is refused, not ignored. */
export function reservationFields(body: Record<string, unknown>): Record<string, string> {
  const b = unwrap(body, 'membership_reservation');
  if (truthy(b.use_card_reader)) {
    throw new BoxError(400, 'card readers are not supported: take the card on your own terminal and send payment_method external.');
  }
  if (b.gift !== undefined && b.gift !== null && b.gift !== '') {
    throw new BoxError(400, 'gift memberships are sold online, not at the box office.');
  }
  const email = optText(b, 'email', 254);
  if (!email) throw new BoxError(400, 'email is required.');
  const out: Record<string, string> = { email };
  for (const [k, max] of [['first_name', 60], ['last_name', 60], ['payment_reference', 255], ['device_name', 255]] as const) {
    const v = optText(b, k, max);
    if (v !== undefined) out[k] = v;
  }
  const pm = optText(b, 'payment_method', 20);
  if (pm !== undefined) {
    if (!['cash', 'check', 'external'].includes(pm)) throw new BoxError(400, 'payment_method must be cash, check or external.');
    out.payment_method = pm;
  }
  return out;
}

/** PUT …/capacity: { capacity: 1-1000000 | null }. */
export function capacityBody(body: Record<string, unknown>): { capacity: number | null } {
  if (!('capacity' in body)) throw new BoxError(400, 'capacity is required (a number, or null for no limit).');
  const v = body.capacity;
  if (v === null || v === '') return { capacity: null };
  const n = typeof v === 'string' && /^[0-9]+$/.test(v) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < 1 || n > 1_000_000) {
    throw new BoxError(400, 'capacity must be a whole number from 1 to 1000000, or null for no limit.');
  }
  return { capacity: n };
}

/** POST /staff-shifts/clock-in and clock-out. */
export function clockBody(body: Record<string, unknown>): { event_id: string | null; device_id: string | null; note: string | null } {
  const b = unwrap(body, 'staff_shift');
  return { event_id: optUuid(b, 'event_id'), device_id: optUuid(b, 'device_id'), note: optText(b, 'note', 300) ?? null };
}

function isoParam(q: URLSearchParams, k: string): string | null {
  const v = q.get(k);
  if (v === null || v === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v) || Number.isNaN(Date.parse(v))) {
    throw new BoxError(400, `${k} must be an ISO 8601 date or time.`);
  }
  return new Date(v).toISOString();
}

/** GET /staff-shifts?from=&to=: the window (the SQL defaults: the last 7 days; at most 92). */
export function shiftWindow(q: URLSearchParams): { from: string | null; to: string | null } {
  return { from: isoParam(q, 'from'), to: isoParam(q, 'to') };
}

/** PUT /tagged-items/:id: { tag_id } or { tag_attributes: { name } } (tag_name too). */
export function retagBody(body: Record<string, unknown>): { tag_id: string | null; tag_name: string | null } {
  const b = unwrap(body, 'tagged_item');
  const attrs = b.tag_attributes && typeof b.tag_attributes === 'object' ? b.tag_attributes as Record<string, unknown> : {};
  const tag = optUuid(b, 'tag_id');
  const name = optText(attrs, 'name', 60) ?? optText(b, 'tag_name', 60) ?? null;
  if (!tag && !name) throw new BoxError(400, 'give tag_id or tag_attributes[name].');
  return { tag_id: tag, tag_name: tag ? null : name };
}
