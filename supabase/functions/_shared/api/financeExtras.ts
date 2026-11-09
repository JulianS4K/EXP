// Deal brackets, ledger-code assignments and backfills, imported ledger
// entries, reporting rows and the cash summary: request bodies and query
// parameters for the partner API (exos-api), mig 20261102120000,
// docs/api/finance-extras.json.
//
// The database is the authority (triggers and checks validate again); these
// parsers pick what a route may write, accept Opendate's wrapped bodies
// ({ v3_deal_bracket: {...} }, { general_ledger_code_assignment: {...} }) and
// Opendate's field names where they mean the same thing, and never let a
// body choose org_id, ids or authorship.
//
// Pure TypeScript, imported by vitest (src/lib/apiFinanceExtras.test.ts).

import { BodyError, isUuid } from './booking.ts';
import { unwrapBody } from './finance.ts';

type Row = Record<string, unknown>;

export const BRACKET_BASES = ['amount', 'tickets'] as const;
/** Opendate's deal_bracket_basis names for ours. */
const OPENDATE_BASIS: Record<string, string> = { gross_ticket_sales: 'amount', ticket_count: 'tickets' };

export const REVENUE_TYPES = [
  'tickets', 'fees', 'tax', 'donations', 'refunds', 'platform_fees', 'pos', 'payouts',
  'box_office', 'bar', 'merchandise', 'membership', 'delivery', 'ticket_insurance', 'gift_cards', 'other',
] as const;
export const IMPORT_SOURCES = [
  'box_office', 'bar', 'merchandise', 'donations', 'membership', 'delivery', 'ticket_insurance', 'gift_cards', 'other',
] as const;
export const REPORTING_SOURCE_TYPES = ['order', 'refund', 'pos', 'payout', 'imported'] as const;
export const MAX_IMPORT_ENTRIES = 500;

const has = (b: Row, k: string) => Object.prototype.hasOwnProperty.call(b, k) && b[k] !== undefined;

function wholeNumber(v: unknown, field: string, max: number): number {
  const n = typeof v === 'string' && /^\d+$/.test(v.trim()) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isSafeInteger(n) || n < 0 || n > max) throw new BodyError(`${field} must be a whole number from 0 to ${max}.`);
  return n;
}

function percentage(v: unknown, field: string): number {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 100 || Math.abs(n * 1000 - Math.round(n * 1000)) > 1e-6) {
    throw new BodyError(`${field} must be a percentage from 0 to 100 (at most 3 decimals).`);
  }
  return n;
}

/** A deal bracket's columns. Create needs offer_id, threshold and percentage. */
export function bracketBody(raw: unknown, create: boolean): { offerId: string | null; row: Row } {
  const b = unwrapBody(raw, 'deal_bracket', 'v3_deal_bracket');
  const row: Row = {};
  let offerId: string | null = null;
  const offer = b.offer_id ?? b.v3_offer_id;
  if (create) {
    if (!isUuid(offer)) throw new BodyError('offer_id is required (the offer the bracket belongs to).');
    offerId = offer;
  } else if (offer !== undefined) {
    // A bracket never moves (Opendate ignores v3_budget_id on update; so do we).
    throw new BodyError('A bracket can\'t move to another offer.');
  }
  const basisRaw = b.basis ?? b.deal_bracket_basis;
  if (basisRaw !== undefined) {
    const v = typeof basisRaw === 'string' ? (OPENDATE_BASIS[basisRaw] ?? basisRaw) : basisRaw;
    if (!(BRACKET_BASES as readonly unknown[]).includes(v)) throw new BodyError('basis must be amount or tickets.');
    row.basis = v;
  }
  if (has(b, 'threshold')) row.threshold = wholeNumber(b.threshold, 'threshold', 100_000_000_000);
  else if (create) throw new BodyError('threshold is required: the cents (amount) or paid tickets (tickets) from which the percentage applies.');
  const pct = b.percentage ?? b.upside_percentage;
  if (pct !== undefined) row.percentage = percentage(pct, 'percentage');
  else if (create) throw new BodyError('percentage is required.');
  if (!create && Object.keys(row).length === 0) throw new BodyError('Nothing to update.');
  return { offerId, row };
}

/** An event's ledger-code override: { revenue_type, gl_code_id } (update: gl_code_id only). */
export function assignmentBody(raw: unknown, create: boolean): Row {
  const b = unwrapBody(raw, 'general_ledger_code_assignment', 'gl_code_assignment');
  const row: Row = {};
  if (create) {
    const t = b.revenue_type ?? b.assignable_type;
    if (typeof t !== 'string' || !(REVENUE_TYPES as readonly string[]).includes(t)) {
      throw new BodyError(`revenue_type must be one of ${REVENUE_TYPES.join(', ')}.`);
    }
    row.revenue_type = t;
  } else if (has(b, 'revenue_type')) {
    throw new BodyError('An override can only be repointed to another code: delete it to change its type.');
  }
  const code = b.gl_code_id ?? b.general_ledger_code_id;
  if (!isUuid(code)) throw new BodyError('gl_code_id must be one of your ledger codes.');
  row.gl_code_id = code;
  return row;
}

/** The org's code for one revenue type: a code id, or null to clear it. */
export function revenueCodeBody(type: string, raw: unknown): { revenueType: string; glCodeId: string | null } {
  if (!(REVENUE_TYPES as readonly string[]).includes(type)) throw new BodyError(`revenue type must be one of ${REVENUE_TYPES.join(', ')}.`);
  const b = unwrapBody(raw, 'gl_revenue_code');
  const code = has(b, 'gl_code_id') ? b.gl_code_id : b.general_ledger_code_id;
  if (code === null) return { revenueType: type, glCodeId: null };
  if (!isUuid(code)) throw new BodyError('gl_code_id must be one of your ledger codes, or null to clear it.');
  return { revenueType: type, glCodeId: code };
}

/** The rows of a bulk import (1-500 objects; each is checked by the database). */
export function importBody(raw: unknown): Row[] {
  const b = Array.isArray(raw) ? { entries: raw } : unwrapBody(raw);
  const rows = b.entries ?? b.imported_ledger_entries;
  if (!Array.isArray(rows) || rows.length === 0) throw new BodyError('entries must be a list of 1 to 500 ledger entries.');
  if (rows.length > MAX_IMPORT_ENTRIES) throw new BodyError(`At most ${MAX_IMPORT_ENTRIES} entries per import.`);
  return rows.map((r, i) => {
    if (!r || typeof r !== 'object' || Array.isArray(r)) throw new BodyError(`entries[${i}] must be an object.`);
    const x = r as Row;
    // Opendate sends amount / tax_amount in major units; Exos takes cents only.
    if (has(x, 'amount') && !has(x, 'amount_cents')) throw new BodyError(`entries[${i}]: send amount_cents (whole cents), not amount.`);
    return x;
  });
}

const ISO = /^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:?\d{2})?)?$/;

/** An optional ISO date / time query parameter (first of the names given). */
export function isoParam(q: URLSearchParams, ...names: string[]): string | null {
  for (const n of names) {
    const v = q.get(n);
    if (v === null || v.trim() === '') continue;
    if (!ISO.test(v.trim()) || Number.isNaN(Date.parse(v.trim()))) throw new BodyError(`${n} must be an ISO 8601 date or time.`);
    return v.trim();
  }
  return null;
}

/** ?from / ?to (or Opendate's q[created_at_gt] / q[created_at_lt]) for the cash summary. */
export function cashRange(q: URLSearchParams): { from: string | null; to: string | null } {
  const from = isoParam(q, 'from', 'q[created_at_gt]');
  const to = isoParam(q, 'to', 'q[created_at_lt]');
  if (from && to && Date.parse(from) > Date.parse(to)) throw new BodyError('from must be before to.');
  return { from, to };
}

/** One of `allowed` from the query (first name given), or null. */
export function enumParam<T extends string>(q: URLSearchParams, allowed: readonly T[], ...names: string[]): T | null {
  for (const n of names) {
    const v = q.get(n);
    if (v === null || v === '') continue;
    if (!(allowed as readonly string[]).includes(v)) throw new BodyError(`${n} must be one of ${allowed.join(', ')}.`);
    return v as T;
  }
  return null;
}

/** An id from the query (first name given), or null. */
export function idParam(q: URLSearchParams, ...names: string[]): string | null {
  for (const n of names) {
    const v = q.get(n);
    if (v === null || v === '') continue;
    if (!isUuid(v)) throw new BodyError(`${n} must be an id.`);
    return v;
  }
  return null;
}
