// Offer, budget, finance and deal request bodies for the partner API
// (exos-api), migs 20261031100000 / 20261031100500, docs/offers-settlements.md
// and docs/api/{offers,budgets,finance,settlements,deals}.json.
//
// The database is the authority (triggers, checks and the offer / settlement
// functions validate again); these parsers pick the columns a route may write,
// accept Opendate's wrapped bodies ({ v3_offer: {...} }, { finance_item: {...} })
// and never let a body choose org_id, ids or authorship.
//
// Pure TypeScript, imported by vitest (src/lib/apiFinance.test.ts).

import { BodyError, isIsoDate, isUuid } from './booking.ts';

type Body = Record<string, unknown>;
type Row = Record<string, unknown>;

/** An Opendate-style wrapped body ({ offer: {...} }) or the plain one. */
export function unwrapBody(raw: unknown, ...wrappers: string[]): Body {
  if (raw === null || raw === undefined) return {};
  if (typeof raw !== 'object' || Array.isArray(raw)) throw new BodyError('The body must be a JSON object.');
  const b = raw as Body;
  for (const w of wrappers) {
    const inner = b[w];
    if (inner && typeof inner === 'object' && !Array.isArray(inner)) return inner as Body;
  }
  return b;
}

const has = (b: Body, k: string) => Object.prototype.hasOwnProperty.call(b, k) && b[k] !== undefined;

function text(v: unknown, field: string, max: number, required = false): string {
  if (v === null || v === undefined) {
    if (required) throw new BodyError(`${field} is required.`);
    return '';
  }
  if (typeof v !== 'string') throw new BodyError(`${field} must be a string.`);
  const s = v.trim();
  if (required && !s) throw new BodyError(`${field} is required.`);
  if (s.length > max) throw new BodyError(`${field} must be at most ${max} characters.`);
  return s;
}

/** Whole cents (>= 0); a numeric string is fine. null when allowed. */
export function cents(v: unknown, field: string, nullable = false): number | null {
  if (v === null || v === '') {
    if (nullable) return null;
    throw new BodyError(`${field} is required.`);
  }
  const n = typeof v === 'string' && /^\d+$/.test(v.trim()) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isSafeInteger(n) || n < 0 || n > 100_000_000_000) {
    throw new BodyError(`${field} must be a whole number of cents, 0 or more.`);
  }
  return n;
}

function percent(v: unknown, field: string): number {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 100) throw new BodyError(`${field} must be a percentage from 0 to 100.`);
  return n;
}

function oneOf<T extends string>(v: unknown, field: string, allowed: readonly T[]): T {
  if (typeof v !== 'string' || !(allowed as readonly string[]).includes(v)) throw new BodyError(`${field} must be one of ${allowed.join(', ')}.`);
  return v as T;
}

function uuidOrNull(v: unknown, field: string): string | null {
  if (v === null || v === '') return null;
  if (!isUuid(v)) throw new BodyError(`${field} must be an id.`);
  return v;
}

function nothing(row: Row): Row {
  if (Object.keys(row).length === 0) throw new BodyError('Nothing to update.');
  return row;
}

export const OFFER_STATUS_FILTER = ['draft', 'sent', 'accepted', 'declined', 'expired', 'cancelled'] as const;
export const LINE_KINDS = ['income', 'expense'] as const;
export const CATEGORY_KINDS = ['income', 'expense', 'both'] as const;
export const GL_KINDS = ['income', 'expense', 'asset', 'liability', 'equity'] as const;
export const DEAL_KINDS = ['sales', 'fundraising'] as const;

/**
 * An offer body for _exos_offer_save: the documented fields only, with
 * Opendate's spellings (event_name → title, dollar_amount → guarantee in
 * cents, upside_percentage → percentage, v3_budget_id → budget_id).
 */
export function offerBody(raw: unknown, create: boolean): Body {
  const b = unwrapBody(raw, 'offer', 'v3_offer');
  const out: Body = {};
  const keys = ['title', 'artist_id', 'artist_name', 'act_type', 'dates', 'hold_id', 'event_id', 'venue_id', 'room_id',
    'terms', 'pool_share_percent', 'agent', 'boilerplate', 'notes', 'expires_at', 'budget_id'];
  if (create) keys.push('budget', 'template_id');
  for (const k of keys) if (has(b, k)) out[k] = b[k];
  if (!has(out, 'title') && typeof b.event_name === 'string') out.title = b.event_name;
  if (!has(out, 'budget_id') && has(b, 'v3_budget_id')) out.budget_id = b.v3_budget_id;
  if (!has(out, 'hold_id') && has(b, 'calendar_event_id')) out.hold_id = b.calendar_event_id;
  if (!has(out, 'pool_share_percent') && has(b, 'pool_percentage')) out.pool_share_percent = b.pool_percentage;
  if (has(b, 'dollar_amount') || has(b, 'upside_percentage')) {
    const terms = (typeof out.terms === 'object' && out.terms && !Array.isArray(out.terms)) ? { ...(out.terms as Body) } : {};
    if (has(b, 'dollar_amount') && !has(terms, 'guarantee_cents')) {
      const d = Number(b.dollar_amount);
      if (!Number.isFinite(d) || d < 0) throw new BodyError('dollar_amount must be an amount, 0 or more.');
      terms.guarantee_cents = Math.round(d * 100);
    }
    if (has(b, 'upside_percentage') && !has(terms, 'percentage')) terms.percentage = percent(b.upside_percentage, 'upside_percentage');
    out.terms = terms;
  }
  if (!create && Object.keys(out).length === 0) throw new BodyError('Nothing to update.');
  return out;
}

/** exos_offer_templates columns. */
export function templateBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'offer_template', 'v3_offer_template');
  const row: Row = {};
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 100, true);
  if (has(b, 'currency')) {
    const c = text(b.currency, 'currency', 3).toUpperCase();
    if (!/^[A-Z]{3}$/.test(c)) throw new BodyError('currency must be a 3-letter ISO 4217 code.');
    row.currency = c;
  }
  if (has(b, 'terms')) {
    if (typeof b.terms !== 'object' || b.terms === null || Array.isArray(b.terms)) throw new BodyError('terms must be an object.');
    row.terms = b.terms;
  }
  if (has(b, 'boilerplate')) row.boilerplate = text(b.boilerplate, 'boilerplate', 10_000);
  if (has(b, 'budget_lines')) {
    if (!Array.isArray(b.budget_lines) || b.budget_lines.length > 50) throw new BodyError('budget_lines must be a list of at most 50 lines.');
    row.budget_lines = b.budget_lines;
  }
  for (const k of ['capacity', 'average_price_cents'] as const) if (has(b, k)) row[k] = cents(b[k], k, true);
  if (has(b, 'sell_through_percent')) row.sell_through_percent = b.sell_through_percent === null ? null : percent(b.sell_through_percent, 'sell_through_percent');
  if (has(b, 'expires_in_days')) {
    const d = b.expires_in_days;
    if (d !== null && (typeof d !== 'number' || !Number.isInteger(d) || d < 1 || d > 365)) throw new BodyError('expires_in_days must be 1 to 365.');
    row.expires_in_days = d;
  }
  return partial ? nothing(row) : row;
}

/** exos_budgets columns a PATCH may change. */
export function budgetPatch(raw: unknown): Row {
  const b = unwrapBody(raw, 'budget', 'v3_budget');
  const row: Row = {};
  if (has(b, 'name')) row.name = text(b.name, 'name', 150, true);
  for (const k of ['capacity', 'average_price_cents'] as const) if (has(b, k)) row[k] = cents(b[k], k);
  if (has(b, 'sell_through_percent')) row.sell_through_percent = percent(b.sell_through_percent, 'sell_through_percent');
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 2000);
  if (has(b, 'venue_id')) row.venue_id = uuidOrNull(b.venue_id, 'venue_id');
  if (has(b, 'event_id')) row.event_id = uuidOrNull(b.event_id, 'event_id');
  return nothing(row);
}

/** exos_budget_lines columns. */
export function budgetLineBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'line', 'v3_budget_line_item');
  const row: Row = {};
  if (!partial || has(b, 'label') || has(b, 'name')) row.label = text(b.label ?? b.name, 'label', 120, true);
  if (!partial || has(b, 'kind')) row.kind = has(b, 'kind') ? oneOf(b.kind, 'kind', LINE_KINDS) : 'expense';
  if (!partial || has(b, 'amount_cents')) row.amount_cents = has(b, 'amount_cents') ? cents(b.amount_cents, 'amount_cents') : 0;
  if (has(b, 'category_id')) row.category_id = uuidOrNull(b.category_id, 'category_id');
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 500);
  if (has(b, 'position')) {
    if (typeof b.position !== 'number' || !Number.isInteger(b.position) || b.position < 0 || b.position > 1000) {
      throw new BodyError('position must be 0 to 1000.');
    }
    row.position = b.position;
  }
  return partial ? nothing(row) : row;
}

/** POST /offer-pools and PATCH /offer-pools/:id: { offer_id | budget_id, mode, terms }. */
export function poolBody(raw: unknown, create: boolean): { offerId: string | null; budgetId: string | null; mode: string | null; terms: Body | null } {
  const b = unwrapBody(raw, 'offer_pool', 'v3_offer_pool');
  const offerId = create ? uuidOrNull(b.offer_id ?? b.v3_offer_id ?? null, 'offer_id') : null;
  const budgetId = create ? uuidOrNull(b.budget_id ?? null, 'budget_id') : null;
  if (create && !offerId && !budgetId) throw new BodyError('offer_id or budget_id is required.');
  const mode = has(b, 'mode') ? oneOf(b.mode, 'mode', ['independent', 'pool'] as const) : null;
  let terms: Body | null = null;
  if (has(b, 'terms')) {
    if (typeof b.terms !== 'object' || b.terms === null || Array.isArray(b.terms)) throw new BodyError('terms must be an object.');
    terms = b.terms as Body;
  }
  if (!create && mode === null && terms === null) throw new BodyError('Nothing to update.');
  return { offerId, budgetId, mode, terms };
}

/** exos_finance_categories columns (never key or system). */
export function categoryBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'finance_category');
  const row: Row = {};
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 60, true);
  if (!partial || has(b, 'kind')) row.kind = oneOf(b.kind ?? 'expense', 'kind', CATEGORY_KINDS);
  if (has(b, 'gl_code_id')) row.gl_code_id = uuidOrNull(b.gl_code_id, 'gl_code_id');
  if (has(b, 'position')) {
    if (typeof b.position !== 'number' || !Number.isInteger(b.position) || b.position < 0 || b.position > 1000) {
      throw new BodyError('position must be 0 to 1000.');
    }
    row.position = b.position;
  }
  return partial ? nothing(row) : row;
}

/** exos_gl_codes columns. */
export function glCodeBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'general_ledger_code', 'gl_code');
  const row: Row = {};
  if (!partial || has(b, 'code')) {
    const c = text(b.code, 'code', 24, true);
    if (!/^[A-Za-z0-9][A-Za-z0-9.-]{0,23}$/.test(c)) throw new BodyError('code is letters, digits, dots and dashes (at most 24).');
    row.code = c;
  }
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 100, true);
  if (has(b, 'kind')) row.kind = oneOf(b.kind, 'kind', GL_KINDS);
  if (has(b, 'description')) row.description = text(b.description, 'description', 500);
  return partial ? nothing(row) : row;
}

/** exos_finance_items columns (never auto). */
export function financeItemBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'finance_item');
  const row: Row = {};
  if (!partial || has(b, 'label') || has(b, 'name')) row.label = text(b.label ?? b.name, 'label', 120, true);
  if (!partial || has(b, 'kind')) row.kind = has(b, 'kind') ? oneOf(b.kind, 'kind', LINE_KINDS) : 'expense';
  if (!partial || has(b, 'amount_cents')) row.amount_cents = has(b, 'amount_cents') ? cents(b.amount_cents, 'amount_cents') : 0;
  for (const k of ['forecast_cents', 'estimate_cents', 'actual_cents'] as const) if (has(b, k)) row[k] = cents(b[k], k, true);
  if (has(b, 'category_id')) row.category_id = uuidOrNull(b.category_id, 'category_id');
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 1000);
  return partial ? nothing(row) : row;
}

/** exos_crm_deals columns. */
export function dealBody(raw: unknown, partial: boolean): Row {
  const b = unwrapBody(raw, 'deal');
  const row: Row = {};
  if (!partial || has(b, 'name')) row.name = text(b.name, 'name', 150, true);
  if (has(b, 'deal_type')) row.deal_type = oneOf(b.deal_type, 'deal_type', DEAL_KINDS);
  if (has(b, 'stage')) row.stage = text(b.stage, 'stage', 40, true);
  else if (!partial && row.deal_type === 'fundraising') row.stage = 'identification';
  if (has(b, 'amount_cents')) row.amount_cents = cents(b.amount_cents, 'amount_cents');
  if (has(b, 'currency')) {
    const c = text(b.currency, 'currency', 3).toUpperCase();
    if (!/^[A-Z]{3}$/.test(c)) throw new BodyError('currency must be a 3-letter ISO 4217 code.');
    row.currency = c;
  }
  if (has(b, 'probability')) {
    const p = b.probability;
    if (p !== null && (typeof p !== 'number' || !Number.isInteger(p) || p < 0 || p > 100)) throw new BodyError('probability must be a whole number 0 to 100.');
    row.probability = p;
  }
  if (has(b, 'expected_close_on')) {
    if (b.expected_close_on !== null && !isIsoDate(b.expected_close_on)) throw new BodyError('expected_close_on must be YYYY-MM-DD.');
    row.expected_close_on = b.expected_close_on;
  }
  for (const k of ['owner_user_id', 'offer_id', 'event_id'] as const) if (has(b, k)) row[k] = uuidOrNull(b[k], k);
  if (has(b, 'contact_name')) row.contact_name = text(b.contact_name, 'contact_name', 100) || null;
  if (has(b, 'contact_email')) row.contact_email = text(b.contact_email, 'contact_email', 200) || null;
  if (has(b, 'company')) row.company = text(b.company, 'company', 100) || null;
  if (has(b, 'notes')) row.notes = text(b.notes, 'notes', 4000);
  return partial ? nothing(row) : row;
}

/** ?from=&to= (dates, at most 366 days apart; default: the next 90 days from today). */
export function pnlRange(q: URLSearchParams, today: string): { from: string; to: string } {
  const from = q.get('from') ?? today;
  const to = q.get('to') ?? new Date(Date.parse(`${from}T00:00:00Z`) + 90 * 86_400_000).toISOString().slice(0, 10);
  if (!isIsoDate(from) || !isIsoDate(to)) throw new BodyError('from and to must be YYYY-MM-DD dates.');
  const days = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
  if (days < 0 || days > 366) throw new BodyError('to must be on or after from, at most 366 days later.');
  return { from, to };
}

/** The settlement PATCH body: adjustments, deposits_paid, venue, and an optional revision. */
export function settlementPatch(raw: unknown): { patch: Body; revision: number | null } {
  const b = unwrapBody(raw, 'settlement');
  const patch: Body = {};
  for (const k of ['adjustments', 'deposits_paid', 'venue']) if (has(b, k)) patch[k] = b[k];
  if (Object.keys(patch).length === 0) throw new BodyError('Nothing to update.');
  let revision: number | null = null;
  if (has(b, 'revision')) {
    if (typeof b.revision !== 'number' || !Number.isInteger(b.revision) || b.revision < 0) throw new BodyError('revision must be a whole number.');
    revision = b.revision;
  }
  return { patch, revision };
}

/** The ticket-count schedule PATCH body. */
export function ticketCountsBody(raw: unknown): Body {
  const b = unwrapBody(raw, 'ticket_counts');
  const out: Body = {};
  for (const k of ['enabled', 'frequency', 'send_time', 'weekday', 'recipients']) if (has(b, k)) out[k] = b[k];
  if (Object.keys(out).length === 0) throw new BodyError('Nothing to update.');
  return out;
}
