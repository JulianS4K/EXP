// Request parsing for the partner contract (exos-api /public/…, organizer
// reservations). docs/partner-sales.md.
//
// Partners send Opendate's shapes: `ticket_reservation[...]` (or `comp[...]`)
// nested in JSON, Rails-style form fields (decoded by _shared/api/body.ts
// formBody into the same flat object), or flat JSON. This turns any of them
// into the arguments the SQL core takes (_exos_partner_reserve & co, mig
// 20261031130000), and validates every field first so the database only ever
// sees clean values.
//
// Pure TypeScript, imported by vitest.

export const PARTNER_KEY_RE = /^dk_live_[0-9a-f]{48}$/;
export const RESERVATION_TOKEN_RE = /^rsv_[A-Za-z0-9_-]{43}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;
const EXTERNAL_RE = /^[A-Za-z0-9_.:#/-]{1,128}$/;

export class ParamError extends Error {}

/** The partner key from ?shared_key=, X-Shared-Key or a bearer header ('' when none). */
export function presentedPartnerKey(q: URLSearchParams, header: (name: string) => string | null): string {
  const fromQuery = q.get('shared_key');
  if (fromQuery) return fromQuery.trim();
  const fromHeader = header('x-shared-key');
  if (fromHeader) return fromHeader.trim();
  const auth = header('authorization') ?? '';
  return auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
}

/**
 * A Rails-style form body with nesting: `a[b][0][c]=v` -> { a: { b: { 0: { c: v } } } }.
 * `a[b][][c]=v` numbers the elements itself (a new one starts when the key is
 * already set on the last), so lists come out as { 0: …, 1: … } objects, which
 * parseOrderItems reads like arrays. At most 6 levels and 200 fields; other
 * keys are dropped. (_shared/api/body.ts formBody keeps one level only, which
 * the order items of a reservation need more than.)
 */
export function railsFormBody(text: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  let n = 0;
  for (const [key, value] of new URLSearchParams(text)) {
    if (++n > 200) break;
    const m = /^([A-Za-z_]{1,40})((?:\[[A-Za-z0-9_]{0,40}\]){0,5})$/.exec(key);
    if (!m) continue;
    const path = [m[1], ...[...m[2].matchAll(/\[([A-Za-z0-9_]{0,40})\]/g)].map((x) => x[1])];
    if (path.some((x) => x === '__proto__' || x === 'constructor' || x === 'prototype')) continue;
    let node = out;
    for (let i = 0; i < path.length; i++) {
      let seg = path[i];
      const last = i === path.length - 1;
      if (seg === '') {
        const count = Object.keys(node).filter((k) => /^\d+$/.test(k)).length;
        const prev = node[String(count - 1)];
        const next = path[i + 1];
        const reuse = count > 0 && !last && next !== undefined && prev && typeof prev === 'object' && !(next in prev);
        seg = String(reuse ? count - 1 : count);
      }
      if (last) { node[seg] = value; break; }
      const cur = node[seg];
      if (!cur || typeof cur !== 'object') node[seg] = {};
      node = node[seg] as Record<string, unknown>;
    }
  }
  return out;
}

/** The `ticket_reservation` (or `comp`) object of a body, else the body itself. */
export function unwrapParams(body: unknown, wrapper: string): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return {};
  const b = body as Record<string, unknown>;
  const nested = b[wrapper];
  if (nested && typeof nested === 'object' && !Array.isArray(nested)) return nested as Record<string, unknown>;
  return b;
}

export function boolParam(v: unknown, field: string): boolean | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  if (v === true || v === 'true' || v === '1' || v === 1) return true;
  if (v === false || v === 'false' || v === '0' || v === 0) return false;
  throw new ParamError(`${field} must be true or false.`);
}

export interface OrderItem { ticket_type_id: string; quantity: number }

/**
 * `order_items_attributes`: a list (or Rails' { "0": {...} } hash) of
 * { ticket_type_id, quantity }, 1-10 lines, 1-100 each.
 */
export function parseOrderItems(raw: unknown): OrderItem[] {
  const list = Array.isArray(raw) ? raw : raw && typeof raw === 'object' ? Object.values(raw as object) : null;
  if (!list || list.length === 0 || list.length > 10) {
    throw new ParamError('order_items_attributes must list 1-10 { ticket_type_id, quantity }.');
  }
  return list.map((x) => {
    const r = (x ?? {}) as Record<string, unknown>;
    const id = String(r.ticket_type_id ?? r.ticketTypeId ?? r.tier_id ?? '');
    const q = typeof r.quantity === 'string' && /^\d{1,3}$/.test(r.quantity) ? Number(r.quantity) : r.quantity;
    if (!UUID_RE.test(id)) throw new ParamError('Each order item needs a ticket_type_id.');
    if (typeof q !== 'number' || !Number.isInteger(q) || q < 1 || q > 100) {
      throw new ParamError('Each order item needs a quantity of 1-100.');
    }
    return { ticket_type_id: id.toLowerCase(), quantity: q };
  });
}

/** Attendee and bookkeeping fields, as the SQL core's p_attrs (only those sent). */
export function reservationAttrs(p: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of ['first_name', 'last_name'] as const) {
    const v = p[k] ?? p[k === 'first_name' ? 'firstName' : 'lastName'];
    if (v === undefined) continue;
    if (v === null || v === '') { out[k] = null; continue; }
    if (typeof v !== 'string' || v.trim().length > 60) throw new ParamError(`${k} must be at most 60 characters.`);
    out[k] = v.trim();
  }
  if (p.email !== undefined) {
    const e = p.email;
    if (e === null || e === '') out.email = null;
    else if (typeof e !== 'string' || e.length > 254 || !EMAIL_RE.test(e.trim())) throw new ParamError('email is not a valid address.');
    else out.email = e.trim().toLowerCase();
  }
  const send = boolParam(p.should_send_ticket_email, 'should_send_ticket_email');
  if (send !== undefined) out.should_send_ticket_email = send;
  const ext = p.stubhub_transaction_id ?? p.external_order_id ?? p.external_id;
  if (ext !== undefined) {
    if (ext === null || ext === '') out.external_id = null;
    else if (!EXTERNAL_RE.test(String(ext).trim())) {
      throw new ParamError('stubhub_transaction_id must be at most 128 letters, digits or . _ - : # /.');
    } else out.external_id = String(ext).trim();
  }
  if (p.cash_paid !== undefined && p.cash_paid !== null && p.cash_paid !== '') {
    const n = typeof p.cash_paid === 'string' ? Number(p.cash_paid) : p.cash_paid;
    if (typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 10_000_000) {
      throw new ParamError('cash_paid must be a non-negative amount.');
    }
    out.cash_paid_cents = Math.round(n * 100);
  }
  const reason = p.comp_reason ?? p.reason;
  if (reason !== undefined && reason !== null && reason !== '') {
    if (typeof reason !== 'string' || reason.length > 200) throw new ParamError('comp_reason is at most 200 characters.');
    out.comp_reason = reason.trim();
  }
  return out;
}

/** Opendate's Ransack-style filter value: q[name] (flat) or q.name. */
function qValue(q: URLSearchParams, name: string): string | undefined {
  const v = q.get(`q[${name}]`);
  if (v === null || v.trim() === '') return undefined;
  return v.trim();
}

function isoDate(v: string | undefined, name: string): string | undefined {
  if (v === undefined) return undefined;
  if (!/^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v) || Number.isNaN(Date.parse(v))) {
    throw new ParamError(`q[${name}] must be an ISO 8601 date or time.`);
  }
  return new Date(v).toISOString();
}

/** GET /public/orders filters, as _exos_partner_orders takes them. */
export function orderFilters(q: URLSearchParams): Record<string, string> {
  const out: Record<string, string> = {};
  const ev = qValue(q, 'calendar_event_id_eq') ?? qValue(q, 'confirm_id_eq') ?? qValue(q, 'event_id_eq');
  if (ev !== undefined) {
    if (!UUID_RE.test(ev)) throw new ParamError('q[calendar_event_id_eq] must be an event id.');
    out.event_id = ev.toLowerCase();
  }
  const email = qValue(q, 'email_eq');
  if (email !== undefined) out.email = email.toLowerCase();
  const ext = qValue(q, 'stubhub_transaction_id_eq');
  if (ext !== undefined) out.external_id = ext;
  for (const [k, name] of [['created_gte', 'created_at_gteq'], ['created_lte', 'created_at_lteq'], ['updated_gte', 'updated_at_gteq']] as const) {
    const v = isoDate(qValue(q, name), name);
    if (v !== undefined) out[k] = v;
  }
  return out;
}

export const OPENDATE_PER_PAGE_DEFAULT = 25;
export const OPENDATE_PER_PAGE_MAX = 250;

/** page / per_page for an Opendate envelope (per_page 1-250, default 25). */
export function opendatePage(q: URLSearchParams): { page: number; perPage: number } {
  const int = (raw: string | null, name: string, def: number, max: number) => {
    if (raw === null || raw === '') return def;
    if (!/^\d{1,6}$/.test(raw) || Number(raw) < 1) throw new ParamError(`${name} must be a positive whole number.`);
    return Math.min(Number(raw), max);
  };
  return {
    page: int(q.get('page'), 'page', 1, 100_000),
    perPage: int(q.get('per_page'), 'per_page', OPENDATE_PER_PAGE_DEFAULT, OPENDATE_PER_PAGE_MAX),
  };
}
