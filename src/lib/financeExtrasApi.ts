// Deal brackets, ledger codes per revenue type, per-event overrides and
// backfills, imported ledger entries, reporting rows and the cash summary:
// the dashboard's data layer (mig 20261102120000). Table logic is
// ./financeTables.ts; the bracket maths ./dealMath.ts.
//
// Brackets (owner / manager), revenue codes and overrides (owner / manager /
// finance) are rows the signed-in user writes; RLS and triggers decide.
// Imports, backfills and the cash summary run through the exos_* functions.
// Reporting rows are read-only. Everything is visible to owner, manager and
// finance only.

import { supabase } from './supabase';
import type { BracketBasis } from './dealMath';

export interface BracketRow {
  id: string;
  offer_id: string;
  basis: BracketBasis;
  threshold: number;
  percentage: number;
}

export interface RevenueCodeRow {
  revenue_type: string;
  gl_code_id: string;
}

export interface AssignmentRow {
  id: string;
  event_id: string;
  revenue_type: string;
  gl_code_id: string;
}

export interface ImportedEntryRow {
  id: string;
  event_id: string | null;
  source: string;
  description: string;
  amount_cents: number;
  tax_amount_cents: number;
  currency: string;
  gl_code: string | null;
  tax_gl_code: string | null;
  posted_at: string;
  source_system: string;
  source_line_id: string;
  source_order_id: string | null;
  import_run_id: string | null;
  created_via: string;
  created_at: string;
}

export interface ReportingRow {
  id: string;
  event_id: string | null;
  source_type: string;
  source_id: string;
  revenue_type: string;
  occurred_at: string;
  currency: string;
  amount_cents: number;
  payment_method: string | null;
  description: string;
  gl_code_id: string | null;
  gl_code: string | null;
  imported: boolean;
  tagged_at: string;
}

export interface CashSummary {
  event_id: string;
  currency: string;
  orders: number;
  gross_cents: number;
  fees: { buyer_fees_cents: number; absorbed_fees_cents: number; platform_fees_cents: number; processor_fees_cents: number };
  fees_cents: number;
  tax_cents: number;
  refunds_cents: number;
  net_cents: number;
  online: { gross_cents: number; tax_cents: number; refunds_cents: number };
  pos: { gross_cents: number; tax_cents: number; refunds_cents: number; tips_cents: number };
  by_payment_method: { method: string; orders: number; gross_cents: number; refunds_cents: number; net_cents: number }[];
  comps: { tickets: number; pos_cents: number };
  payouts: { stripe_transferred_cents: number; stripe_pending_cents: number; paypal_owed_cents: number; paypal_held_cents: number };
}

export interface BackfillResult { created: number; retagged: number; removed: number; rows: number }
export interface ImportResult {
  created: number;
  exists: number;
  errors: number;
  results: { index: number; status: 'created' | 'exists' | 'error'; id?: string; error?: string }[];
}

function ok<T>(r: { data: T | null; error: { message: string } | null }): T {
  if (r.error) throw new Error(r.error.message);
  return r.data as T;
}

const db = supabase;

// ── Brackets ────────────────────────────────────────────────────────────────

export async function listBrackets(offerId: string): Promise<BracketRow[]> {
  const rows = ok<BracketRow[]>(await db.from('exos_deal_brackets').select('id, offer_id, basis, threshold, percentage')
    .eq('offer_id', offerId).order('threshold'));
  return (rows ?? []).map((r) => ({ ...r, threshold: Number(r.threshold), percentage: Number(r.percentage) }));
}

export async function saveBracket(offerId: string, b: { basis: BracketBasis; threshold: number; percentage: number }, id?: string): Promise<void> {
  if (id) ok(await db.from('exos_deal_brackets').update(b).eq('id', id));
  else ok(await db.from('exos_deal_brackets').insert({ ...b, offer_id: offerId }));
}

export async function deleteBracket(id: string): Promise<void> {
  ok(await db.from('exos_deal_brackets').delete().eq('id', id));
}

// ── Ledger codes ──────────────────────────────────────────────────────────────

export async function listRevenueCodes(orgId: string): Promise<RevenueCodeRow[]> {
  return ok<RevenueCodeRow[]>(await db.from('exos_gl_revenue_codes').select('revenue_type, gl_code_id').eq('org_id', orgId)) ?? [];
}

export async function setRevenueCode(orgId: string, revenueType: string, glCodeId: string | null): Promise<void> {
  if (!glCodeId) ok(await db.from('exos_gl_revenue_codes').delete().eq('org_id', orgId).eq('revenue_type', revenueType));
  else ok(await db.from('exos_gl_revenue_codes').upsert({ org_id: orgId, revenue_type: revenueType, gl_code_id: glCodeId }, { onConflict: 'org_id,revenue_type' }));
}

export async function listAssignments(eventId: string): Promise<AssignmentRow[]> {
  return ok<AssignmentRow[]>(await db.from('exos_gl_code_assignments').select('id, event_id, revenue_type, gl_code_id')
    .eq('event_id', eventId).order('revenue_type')) ?? [];
}

export async function saveAssignment(eventId: string, revenueType: string, glCodeId: string, id?: string): Promise<void> {
  if (id) ok(await db.from('exos_gl_code_assignments').update({ gl_code_id: glCodeId }).eq('id', id));
  else ok(await db.from('exos_gl_code_assignments').insert({ event_id: eventId, revenue_type: revenueType, gl_code_id: glCodeId }));
}

export async function deleteAssignment(id: string): Promise<void> {
  ok(await db.from('exos_gl_code_assignments').delete().eq('id', id));
}

export async function backfillGlCodes(eventId: string): Promise<BackfillResult> {
  return ok<BackfillResult>(await db.rpc('exos_gl_backfill', { p_event_id: eventId }));
}

// ── Imports and reporting rows ─────────────────────────────────────────────────

/** The org's entries, newest posted first (at most `limit`; the table pages them). */
export async function listImportedEntries(orgId: string, limit = 2000): Promise<ImportedEntryRow[]> {
  return ok<ImportedEntryRow[]>(await db.from('exos_imported_ledger_entries')
    .select('id, event_id, source, description, amount_cents, tax_amount_cents, currency, gl_code, tax_gl_code, posted_at, source_system, source_line_id, source_order_id, import_run_id, created_via, created_at')
    .eq('org_id', orgId).order('posted_at', { ascending: false }).limit(limit)) ?? [];
}

export async function importLedgerEntries(orgId: string, rows: Record<string, unknown>[]): Promise<ImportResult> {
  return ok<ImportResult>(await db.rpc('exos_ledger_import', { p_org_id: orgId, p_rows: rows }));
}

export async function deleteImportedEntry(id: string): Promise<void> {
  ok(await db.from('exos_imported_ledger_entries').delete().eq('id', id));
}

/** The org's reporting rows in a date range (at most `limit`; the table pages them). */
export async function listReportingRows(orgId: string, from: string, to: string, limit = 5000): Promise<{ rows: ReportingRow[]; truncated: boolean }> {
  const rows = ok<ReportingRow[]>(await db.from('exos_reporting_rows')
    .select('id, event_id, source_type, source_id, revenue_type, occurred_at, currency, amount_cents, payment_method, description, gl_code_id, gl_code, imported, tagged_at')
    .eq('org_id', orgId).gte('occurred_at', from).lt('occurred_at', to).order('occurred_at', { ascending: false }).limit(limit + 1)) ?? [];
  return { rows: rows.slice(0, limit), truncated: rows.length > limit };
}

// ── Cash summary ────────────────────────────────────────────────────────────────

export async function getCashSummary(eventId: string, from?: string | null, to?: string | null): Promise<CashSummary> {
  return ok<CashSummary>(await db.rpc('exos_cash_summary', { p_event_id: eventId, p_from: from || null, p_to: to || null }));
}

/** The org's events for pickers (id, name, start), newest first. */
export async function listOrgEvents(orgId: string, limit = 500): Promise<{ id: string; name: string; starts_at: string | null }[]> {
  return ok<{ id: string; name: string; starts_at: string | null }[]>(await db.from('exos_events').select('id, name, starts_at')
    .eq('org_id', orgId).order('starts_at', { ascending: false }).limit(limit)) ?? [];
}
