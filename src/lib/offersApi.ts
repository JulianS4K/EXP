// Offers, budgets, finance, settlements, P&L and ticket counts: the
// dashboard's data layer (migs 20261031100000 / 20261031100500,
// docs/offers-settlements.md). The maths is ./dealMath.ts.
//
// Offers and settlements are written only through the exos_offer_* /
// exos_settlement_* functions (state machine, link tokens, webhooks, mail).
// Budgets, budget lines, pools, templates, deals, finance categories, GL
// codes and finance items are rows the signed-in user writes directly; RLS
// and triggers decide (owner / manager; finance for categories, codes and
// items). Everything here is visible to owner, manager and finance only.

import { supabase } from './supabase';
import type { SettlementInputs, TermsJson } from './dealMath';

export type OfferStatus = 'draft' | 'sent' | 'accepted' | 'declined' | 'expired' | 'cancelled';
export type ActType = 'headliner' | 'co_headliner' | 'support' | 'opener' | 'other';

export interface OfferRow {
  id: string;
  org_id: string;
  budget_id: string;
  title: string;
  status: OfferStatus;
  hold_id: string | null;
  event_id: string | null;
  venue_id: string | null;
  room_id: string | null;
  dates: string[];
  currency: string;
  artist_id: string | null;
  artist_name: string;
  act_type: ActType;
  terms: TermsJson;
  pool_share_percent: number | null;
  agent_name: string | null;
  agent_email: string | null;
  agent_company: string | null;
  agent_phone: string | null;
  boilerplate: string;
  notes: string;
  template_id: string | null;
  import_id: string | null;
  expires_at: string | null;
  sent_at: string | null;
  sent_to: string | null;
  response: { action: string; name?: string | null; note?: string | null; at?: string; via?: string; ip?: string | null } | null;
  history: { at: string; action: string; by?: string | null; via?: string; to?: string; note?: string; name?: string }[];
  created_via: string;
  created_at: string;
  updated_at: string;
}

export interface BudgetRow {
  id: string;
  org_id: string;
  name: string;
  currency: string;
  venue_id: string | null;
  hold_id: string | null;
  event_id: string | null;
  capacity: number;
  average_price_cents: number;
  sell_through_percent: number;
  notes: string;
}

export interface BudgetLineRow {
  id: string;
  budget_id: string;
  category_id: string | null;
  kind: 'income' | 'expense';
  label: string;
  amount_cents: number;
  position: number;
}

export interface PoolRow {
  id: string;
  budget_id: string;
  mode: 'independent' | 'pool';
  terms: TermsJson;
}

export interface TemplateRow {
  id: string;
  org_id: string;
  name: string;
  currency: string;
  terms: TermsJson;
  boilerplate: string;
  budget_lines: { category_key?: string; category_id?: string; kind: string; label: string; amount_cents: number }[];
  capacity: number | null;
  average_price_cents: number | null;
  sell_through_percent: number | null;
  expires_in_days: number | null;
}

export interface CategoryRow {
  id: string;
  org_id: string;
  key: string | null;
  name: string;
  kind: 'income' | 'expense' | 'both';
  system: boolean;
  gl_code_id: string | null;
  position: number;
}

export interface GlCodeRow {
  id: string;
  org_id: string;
  code: string;
  name: string;
  kind: string;
  description: string;
  discarded_at: string | null;
}

export interface FinanceItemRow {
  id: string;
  event_id: string;
  category_id: string | null;
  kind: 'income' | 'expense';
  label: string;
  amount_cents: number;
  forecast_cents: number | null;
  estimate_cents: number | null;
  actual_cents: number | null;
  notes: string;
  auto: string | null;
}

export interface DealRow {
  id: string;
  org_id: string;
  name: string;
  deal_type: 'sales' | 'fundraising';
  stage: string;
  status: 'open' | 'won' | 'lost';
  amount_cents: number;
  currency: string;
  probability: number | null;
  expected_close_on: string | null;
  contact_name: string | null;
  contact_email: string | null;
  company: string | null;
  notes: string;
}

export interface AdjustmentInput {
  id?: string;
  offer_id: string | null;
  label: string;
  amount_cents: number;
  reason: string;
}

export interface SettlementState {
  event_id: string;
  status: 'draft' | 'finalized';
  adjustments: (AdjustmentInput & { id: string; by?: string | null; at?: string })[];
  deposits_paid: Record<string, boolean>;
  venue_share_percent: number;
  venue_deposit_paid_cents: number | null;
  finalized_at: string | null;
  emailed_to: string[];
  revision: number;
  inputs: SettlementInputs;
  link_path?: string;
}

export interface TicketCountsState {
  event_id: string;
  enabled: boolean;
  frequency: 'daily' | 'weekly';
  send_time: string;
  weekday: number;
  timezone: string | null;
  next_run_at: string | null;
  last_sent_at: string | null;
  last_sent_count: number;
  recipients: { id: string; name: string | null; email: string; role: string; source: string; opted_out_at: string | null }[];
  suggested: { name: string; email: string; role: string }[];
  preview: Record<string, unknown> | null;
}

/** The database's message without its prefix, first letter up. */
function clean(error: { message?: string; code?: string }): Error {
  let msg = String(error.message ?? 'Request failed').replace(/^exos_[a-z_]+:\s*/, '');
  if (/duplicate key value/.test(msg)) msg = /gl_codes/.test(msg) ? 'That ledger code is already in use.' : 'That clashes with an existing record.';
  if (/row-level security|permission denied/.test(msg)) msg = "You don't have access to do that.";
  return new Error(msg.charAt(0).toUpperCase() + msg.slice(1));
}

async function run<T>(p: PromiseLike<{ data: T; error: { message?: string; code?: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw clean(error);
  return data;
}

const OFFER_COLS =
  'id, org_id, budget_id, title, status, hold_id, event_id, venue_id, room_id, dates, currency, artist_id, artist_name, act_type, ' +
  'terms, pool_share_percent, agent_name, agent_email, agent_company, agent_phone, boilerplate, notes, template_id, import_id, ' +
  'expires_at, sent_at, sent_to, response, history, created_via, created_at, updated_at';

/** The status an offer reads as now (a sent offer past its expiry is expired). */
export function effectiveStatus(o: Pick<OfferRow, 'status' | 'expires_at'>, now = Date.now()): OfferStatus {
  return o.status === 'sent' && o.expires_at && Date.parse(o.expires_at) <= now ? 'expired' : o.status;
}

// ---- Offers ------------------------------------------------------------------------

export async function listOffers(orgId: string): Promise<OfferRow[]> {
  return (await run(supabase.from('exos_offers').select(OFFER_COLS).eq('org_id', orgId)
    .order('created_at', { ascending: false }).limit(500))) as unknown as OfferRow[];
}

export async function getOffer(offerId: string): Promise<OfferRow | null> {
  return (await run(supabase.from('exos_offers').select(OFFER_COLS).eq('id', offerId).maybeSingle())) as unknown as OfferRow | null;
}

export async function listOffersForBudget(budgetId: string): Promise<OfferRow[]> {
  return (await run(supabase.from('exos_offers').select(OFFER_COLS).eq('budget_id', budgetId).order('created_at'))) as unknown as OfferRow[];
}

export async function createOffer(orgId: string, body: Record<string, unknown>): Promise<{ id: string }> {
  return run(supabase.rpc('exos_offer_create', { p_org_id: orgId, p_offer: body }));
}

export async function updateOffer(offerId: string, patch: Record<string, unknown>): Promise<void> {
  await run(supabase.rpc('exos_offer_update', { p_offer_id: offerId, p_patch: patch }));
}

export async function sendOffer(offerId: string, to?: string): Promise<{ link_path: string }> {
  return run(supabase.rpc('exos_offer_send', { p_offer_id: offerId, p_to: to?.trim() || null }));
}

export async function recordOfferResponse(offerId: string, action: 'accept' | 'decline', name: string, note: string): Promise<void> {
  await run(supabase.rpc('exos_offer_record_response', { p_offer_id: offerId, p_action: action, p_name: name || null, p_note: note || null }));
}

export async function cancelOffer(offerId: string, note?: string): Promise<void> {
  await run(supabase.rpc('exos_offer_cancel', { p_offer_id: offerId, p_note: note || null }));
}

export async function deleteOffer(offerId: string): Promise<void> {
  await run(supabase.rpc('exos_offer_delete', { p_offer_id: offerId }));
}

export async function importOffers(orgId: string, fileName: string, rows: Record<string, unknown>[]): Promise<{
  id: string; status: string; created_count: number; errors: { row: number; error: string }[];
}> {
  return run(supabase.rpc('exos_offer_import', { p_org_id: orgId, p_file_name: fileName, p_rows: rows }));
}

// ---- The agent's link (no login) -----------------------------------------------------

export interface PublicOffer {
  id: string;
  title: string;
  status: OfferStatus;
  org: { name: string } | null;
  artist_name: string;
  act_type: string;
  dates: string[];
  currency: string;
  venue: { name: string; room: string | null; timezone: string | null } | null;
  terms: TermsJson;
  budget: { capacity: number; average_price_cents: number } | null;
  agent_name: string | null;
  boilerplate: string;
  expires_at: string | null;
  sent_at: string | null;
  response: { action: string; name: string | null; at: string } | null;
}

export async function getPublicOffer(offerId: string, token: string): Promise<PublicOffer> {
  return run(supabase.rpc('exos_offer_public', { p_offer_id: offerId, p_token: token }));
}

export async function respondToOffer(offerId: string, token: string, action: 'accept' | 'decline', name: string, note: string): Promise<PublicOffer> {
  return run(supabase.rpc('exos_offer_respond', { p_offer_id: offerId, p_token: token, p_action: action, p_name: name, p_note: note || null }));
}

// ---- Budgets, lines, pools, templates ------------------------------------------------------

export async function getBudget(budgetId: string): Promise<BudgetRow | null> {
  return (await run(supabase.from('exos_budgets').select('*').eq('id', budgetId).maybeSingle())) as BudgetRow | null;
}

export async function listBudgets(orgId: string): Promise<BudgetRow[]> {
  return (await run(supabase.from('exos_budgets').select('*').eq('org_id', orgId).order('created_at', { ascending: false }).limit(500))) as BudgetRow[];
}

export async function updateBudget(budgetId: string, patch: Partial<BudgetRow>): Promise<void> {
  await run(supabase.from('exos_budgets').update(patch).eq('id', budgetId));
}

export async function listBudgetLines(budgetId: string): Promise<BudgetLineRow[]> {
  return (await run(supabase.from('exos_budget_lines').select('*').eq('budget_id', budgetId).order('position').order('created_at'))) as BudgetLineRow[];
}

export async function addBudgetLine(orgId: string, budgetId: string, line: Omit<BudgetLineRow, 'id' | 'budget_id' | 'position'>): Promise<void> {
  await run(supabase.from('exos_budget_lines').insert({ ...line, org_id: orgId, budget_id: budgetId, position: 500 }));
}

export async function updateBudgetLine(lineId: string, patch: Partial<BudgetLineRow>): Promise<void> {
  await run(supabase.from('exos_budget_lines').update(patch).eq('id', lineId));
}

export async function deleteBudgetLine(lineId: string): Promise<void> {
  await run(supabase.from('exos_budget_lines').delete().eq('id', lineId));
}

export async function getPool(budgetId: string): Promise<PoolRow | null> {
  return (await run(supabase.from('exos_offer_pools').select('id, budget_id, mode, terms').eq('budget_id', budgetId).maybeSingle())) as PoolRow | null;
}

export async function savePool(budgetId: string, mode: 'independent' | 'pool', terms: TermsJson): Promise<void> {
  await run(supabase.rpc('exos_offer_pool_ensure', { p_budget_id: budgetId, p_mode: mode, p_terms: terms }));
}

export async function listTemplates(orgId: string): Promise<TemplateRow[]> {
  return (await run(supabase.from('exos_offer_templates').select('*').eq('org_id', orgId).order('name'))) as TemplateRow[];
}

export async function saveTemplate(orgId: string, t: Partial<TemplateRow>, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_offer_templates').update(t).eq('id', id));
  else await run(supabase.from('exos_offer_templates').insert({ ...t, org_id: orgId }));
}

export async function deleteTemplate(id: string): Promise<void> {
  await run(supabase.from('exos_offer_templates').delete().eq('id', id));
}

// ---- Deals -----------------------------------------------------------------------------------

export async function listDeals(orgId: string): Promise<DealRow[]> {
  return (await run(supabase.from('exos_crm_deals').select('*').eq('org_id', orgId).is('discarded_at', null)
    .order('created_at', { ascending: false }).limit(500))) as DealRow[];
}

export async function saveDeal(orgId: string, d: Partial<DealRow>, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_crm_deals').update(d).eq('id', id));
  else await run(supabase.from('exos_crm_deals').insert({ ...d, org_id: orgId }));
}

export async function discardDeal(id: string): Promise<void> {
  await run(supabase.from('exos_crm_deals').update({ discarded_at: new Date().toISOString() }).eq('id', id));
}

// ---- Finance categories, GL codes, items ---------------------------------------------------------

export async function listCategories(orgId: string): Promise<CategoryRow[]> {
  await run(supabase.rpc('exos_finance_categories_ensure', { p_org_id: orgId }));
  return (await run(supabase.from('exos_finance_categories').select('*').eq('org_id', orgId).order('position').order('name'))) as CategoryRow[];
}

export async function saveCategory(orgId: string, c: Partial<CategoryRow>, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_finance_categories').update(c).eq('id', id));
  else await run(supabase.from('exos_finance_categories').insert({ ...c, org_id: orgId }));
}

export async function deleteCategory(id: string): Promise<void> {
  await run(supabase.from('exos_finance_categories').delete().eq('id', id));
}

export async function listGlCodes(orgId: string): Promise<GlCodeRow[]> {
  return (await run(supabase.from('exos_gl_codes').select('*').eq('org_id', orgId).is('discarded_at', null).order('code'))) as GlCodeRow[];
}

export async function saveGlCode(orgId: string, g: Partial<GlCodeRow>, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_gl_codes').update(g).eq('id', id));
  else await run(supabase.from('exos_gl_codes').insert({ ...g, org_id: orgId }));
}

export async function discardGlCode(id: string): Promise<void> {
  await run(supabase.from('exos_gl_codes').update({ discarded_at: new Date().toISOString() }).eq('id', id));
}

export async function listFinanceItems(eventId: string): Promise<FinanceItemRow[]> {
  return (await run(supabase.from('exos_finance_items').select('*').eq('event_id', eventId).order('created_at'))) as FinanceItemRow[];
}

export async function saveFinanceItem(orgId: string, eventId: string, item: Partial<FinanceItemRow>, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_finance_items').update(item).eq('id', id));
  else await run(supabase.from('exos_finance_items').insert({ ...item, event_id: eventId, org_id: orgId }));
}

export async function deleteFinanceItem(id: string): Promise<void> {
  await run(supabase.from('exos_finance_items').delete().eq('id', id));
}

// ---- Settlement, P&L ----------------------------------------------------------------------------

export async function getSettlement(eventId: string): Promise<SettlementState> {
  return run(supabase.rpc('exos_settlement_get', { p_event_id: eventId }));
}

export async function updateSettlement(eventId: string, patch: Record<string, unknown>, revision?: number): Promise<SettlementState> {
  return run(supabase.rpc('exos_settlement_update', { p_event_id: eventId, p_patch: patch, p_revision: revision ?? null }));
}

export async function finalizeSettlement(eventId: string, revision?: number): Promise<SettlementState> {
  return run(supabase.rpc('exos_settlement_finalize', { p_event_id: eventId, p_revision: revision ?? null }));
}

export async function reopenSettlement(eventId: string): Promise<SettlementState> {
  return run(supabase.rpc('exos_settlement_reopen', { p_event_id: eventId }));
}

export async function getPublicSettlement(eventId: string, token: string): Promise<{ org: { name: string } | null; finalized_at: string; inputs: SettlementInputs }> {
  return run(supabase.rpc('exos_settlement_public', { p_event_id: eventId, p_token: token }));
}

export async function getPnlInputs(orgId: string, from: string, to: string): Promise<{
  from: string; to: string; truncated: boolean; shows: { event_id: string; finalized: boolean; inputs: SettlementInputs | null }[];
}> {
  return run(supabase.rpc('exos_pnl_inputs', { p_org_id: orgId, p_from: from, p_to: to }));
}

// ---- Ticket counts ------------------------------------------------------------------------------------

export async function getTicketCounts(eventId: string): Promise<TicketCountsState> {
  return run(supabase.rpc('exos_ticket_counts_get', { p_event_id: eventId }));
}

export async function saveTicketCounts(eventId: string, schedule: Record<string, unknown>): Promise<TicketCountsState> {
  return run(supabase.rpc('exos_ticket_counts_save', { p_event_id: eventId, p_schedule: schedule }));
}

export async function sendTicketCountsNow(eventId: string): Promise<{ queued: number }> {
  return run(supabase.rpc('exos_ticket_counts_send_now', { p_event_id: eventId }));
}

export async function ticketCountsOptOut(token: string, confirm: boolean): Promise<{
  event: { name: string; starts_at: string | null } | null; org: { name: string } | null; email: string; opted_out: boolean;
}> {
  return run(supabase.rpc('exos_ticket_counts_optout', { p_token: token, p_confirm: confirm }));
}

// ---- Downloads --------------------------------------------------------------------------------------------

/** Save bytes as a file in the browser. */
export function downloadBytes(bytes: Uint8Array, fileName: string, type: string): void {
  const blob = new Blob([bytes as unknown as BlobPart], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
