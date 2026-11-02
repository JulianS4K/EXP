// Order and ticket edits (mig 20261102140000): request bodies for the API's
// PUT /v1/orders/:id, POST /v1/orders/:id/send-receipt and PUT
// /v1/tickets/:id, Opendate-style ({ order: { first_name } }) or flat. The
// database (exos_order_update / exos_ticket_update) re-checks everything;
// this only shapes the request and answers a clear 400 before a round trip.
// Pure, no imports.

export class EditError extends Error {}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const PHONE_RE = /^[0-9+() .-]{3,32}$/;

/** What an order edit may change. */
export const ORDER_EDIT_FIELDS = ['first_name', 'last_name', 'email', 'phone_number', 'notes'] as const;
export type OrderEditField = (typeof ORDER_EDIT_FIELDS)[number];
/** Never through an edit: these move money or tickets. */
const MONEY_FIELDS = new Set(['amount', 'amount_cents', 'total', 'price', 'price_paid', 'quantity', 'tickets', 'tier_id',
  'ticket_type_id', 'status', 'currency', 'tax_cents', 'fees', 'refund']);

function unwrap(body: Record<string, unknown>, key: string): Record<string, unknown> {
  const inner = body[key];
  return inner && typeof inner === 'object' && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

/** A string field: null clears it; anything but a string or number is undefined (refused). */
function str(v: unknown): string | null | undefined {
  if (v === null) return null;
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return String(v);
  return undefined;
}

/** The fields to send to exos_order_update. Unknown keys are refused. */
export function orderEditFields(body: Record<string, unknown>): Partial<Record<OrderEditField, string | null>> {
  const b = unwrap(body, 'order');
  const out: Partial<Record<OrderEditField, string | null>> = {};
  for (const [k0, v] of Object.entries(b)) {
    const k = k0 === 'phone' ? 'phone_number' : k0;
    if (k === 'event_id' || k === 'confirm_id' || k === 'id') continue;
    if (MONEY_FIELDS.has(k)) throw new EditError(`${k0} can't be changed on an order: refund or reissue instead.`);
    if (!(ORDER_EDIT_FIELDS as readonly string[]).includes(k)) {
      throw new EditError(`${k0} can't be changed on an order (first_name, last_name, email, phone_number, notes).`);
    }
    const s = str(v);
    if (s === undefined) throw new EditError(`${k0} must be a string.`);
    out[k as OrderEditField] = s === null ? null : s.trim();
  }
  if (Object.keys(out).length === 0) throw new EditError('nothing to change: send first_name, last_name, email, phone_number or notes.');
  if ('email' in out && (!out.email || !EMAIL_RE.test(out.email) || out.email.length > 254)) {
    throw new EditError('email is not an email address.');
  }
  if (out.phone_number && !PHONE_RE.test(out.phone_number)) throw new EditError('phone_number is not a phone number.');
  for (const k of ['first_name', 'last_name'] as const) {
    if ((out[k]?.length ?? 0) > 60) throw new EditError(`${k} is at most 60 characters.`);
  }
  if ((out.notes?.length ?? 0) > 1000) throw new EditError('notes are at most 1000 characters.');
  return out;
}

/** The fields to send to exos_ticket_update: the attendee name (and the holder's email, which can't change). */
export function ticketEditFields(body: Record<string, unknown>): Record<string, string | null> {
  const b = unwrap(body, 'ticket');
  const out: Record<string, string | null> = {};
  for (const [k, v] of Object.entries(b)) {
    if (k === 'event_id' || k === 'confirm_id' || k === 'id' || k === 'barcode') continue;
    if (!['attendee_name', 'name', 'first_name', 'last_name', 'email', 'attendee_email'].includes(k)) {
      throw new EditError(k === 'checked_in_at'
        ? 'check a ticket in with POST /v1/tickets/:id/check-in.'
        : `${k} can't be changed on a ticket (attendee_name, or first_name + last_name).`);
    }
    const s = str(v);
    if (s === undefined) throw new EditError(`${k} must be a string.`);
    out[k] = s === null ? null : s.trim();
  }
  if (Object.keys(out).length === 0) throw new EditError('nothing to change: send attendee_name (or first_name and last_name).');
  return out;
}

/** The receipt's destination: null = the email on the order. */
export function receiptEmail(body: Record<string, unknown>): string | null {
  const b = unwrap(body, 'order');
  const v = b.email ?? body.email;
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || !EMAIL_RE.test(v.trim()) || v.trim().length > 254) throw new EditError('email is not an email address.');
  return v.trim();
}

/**
 * The ticket id in a path segment: the id itself, or the id inside a door
 * code (T-<ticket>:<owner>:<window>:<mac>, what Opendate calls the barcode).
 * Null when it is neither. Only finds the ticket; nothing here verifies a code.
 */
export function ticketIdFrom(segment: string): string | null {
  const s = segment.trim();
  if (UUID_RE.test(s)) return s.toLowerCase();
  const m = /^T-([0-9a-f-]{36}):/i.exec(s);
  return m && UUID_RE.test(m[1]) ? m[1].toLowerCase() : null;
}
