// Giving tables (/orgs/:orgId/giving, mig 20261102110000): the Supabase calls.
// Reads go through RLS (owner / manager / finance); writes through the
// role-checked RPCs, and the two that touch Stripe (completing a campaign,
// cancelling a monthly gift) through exos-commerce. Pure logic:
// ./givingTables.ts.

import { supabase } from './supabase';
import type { CampaignRow, DonationRow, ImportCard, ImportedCardRow, RecurringRow } from './givingTables';

async function fnError(error: unknown, fallback: string): Promise<Error> {
  let payload: { error?: string } | null = null;
  try { payload = await (error as { context?: Response }).context?.json(); } catch { /* not JSON */ }
  return new Error(payload?.error || (error as { message?: string })?.message || fallback);
}

async function commerce<T>(body: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await supabase.functions.invoke('exos-commerce', { body });
  if (error) throw await fnError(error, fallback);
  return data as T;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

/** Campaigns with their totals (net of offline refunds) and how many monthly gifts bill. */
export async function listCampaignRows(orgId: string): Promise<{ rows: CampaignRow[]; monthly: Record<string, number> }> {
  const [c, d, r] = await Promise.all([
    supabase.from('exos_giving_campaigns')
      .select('id, name, slug, currency, goal_cents, active, completed_at, starts_at, ends_at, created_at, checkout_add_on, description, tax_receipt_text')
      .eq('org_id', orgId).order('created_at', { ascending: false }).limit(1000),
    supabase.from('exos_donations').select('campaign_id, amount_cents, refunded_cents, status').eq('org_id', orgId).limit(50000),
    supabase.from('exos_recurring_donations').select('campaign_id, status').eq('org_id', orgId).limit(50000),
  ]);
  if (c.error) throw c.error;
  const totals = new Map<string, { raised: number; n: number }>();
  for (const x of (d.data ?? []) as { campaign_id: string; amount_cents: number; refunded_cents: number; status: string }[]) {
    if (x.status !== 'received') continue;
    const t = totals.get(x.campaign_id) ?? { raised: 0, n: 0 };
    t.raised += Math.max(0, x.amount_cents - (x.refunded_cents ?? 0));
    t.n += 1;
    totals.set(x.campaign_id, t);
  }
  const monthly: Record<string, number> = {};
  for (const x of (r.data ?? []) as { campaign_id: string }[]) monthly[x.campaign_id] = (monthly[x.campaign_id] ?? 0) + 1;
  const rows = ((c.data ?? []) as Omit<CampaignRow, 'raised_cents' | 'donation_count'>[]).map((x) => ({
    ...x, raised_cents: totals.get(x.id)?.raised ?? 0, donation_count: totals.get(x.id)?.n ?? 0,
  }));
  return { rows, monthly };
}

export type CampaignOp = 'create' | 'update' | 'activate' | 'delete';
export async function campaignOp(op: CampaignOp, args: { id?: string; orgId?: string; body?: Record<string, unknown> }): Promise<unknown> {
  return rpc('exos_giving_campaign_op', { p_op: op, p_id: args.id ?? null, p_body: args.body ?? {}, p_org_id: args.orgId ?? null });
}

/** Close a campaign for good; exos-commerce also cancels its monthly gifts in Stripe. */
export async function completeCampaign(id: string): Promise<{ not_cancelled: string[] }> {
  return commerce({ action: 'complete_campaign', campaign_id: id }, 'Could not complete the campaign.');
}

export async function listDonationRows(orgId: string): Promise<DonationRow[]> {
  const { data, error } = await supabase.from('exos_donations')
    .select('id, campaign_id, amount_cents, cover_fees_cents, total_cents, refunded_cents, currency, method, status, donor_name, ' +
      'donor_email, anonymous, session_id, recurring_id, payment_intent, receipt_number, created_at')
    .eq('org_id', orgId).order('created_at', { ascending: false }).limit(5000);
  if (error) throw error;
  return (data ?? []) as unknown as DonationRow[];
}

export async function deleteDonation(id: string): Promise<void> {
  await rpc('exos_donation_delete', { p_id: id });
}

export async function offlineRefund(id: string, p: { amountCents?: number; reference?: string; method?: string; note?: string }): Promise<unknown> {
  return rpc('exos_donation_offline_refund', {
    p_id: id, p_amount_cents: p.amountCents ?? null, p_reference: p.reference || null, p_method: p.method ?? null, p_note: p.note || null,
  });
}

export async function listRecurringRows(orgId: string): Promise<RecurringRow[]> {
  const { data, error } = await supabase.from('exos_recurring_donations')
    .select('id, campaign_id, amount_cents, cover_fees_cents, currency, status, donor_name, donor_email, current_period_end, ' +
      'last_paid_at, failed_payments, cancel_requested_at, created_at')
    .eq('org_id', orgId).order('created_at', { ascending: false }).limit(5000);
  if (error) throw error;
  return (data ?? []) as unknown as RecurringRow[];
}

/** The donor updates a monthly gift's card (Stripe's billing portal); the
 *  "update your card" mail links here (mig 20261105100000). */
export async function openDonationPortal(recurringId: string, returnUrl: string): Promise<string> {
  const d = await commerce<{ url?: string }>({ action: 'recurring_donation_portal', recurring_id: recurringId, return_url: returnUrl },
    'Could not open billing.');
  if (!d?.url) throw new Error('Could not open billing.');
  return d.url;
}

export async function cancelRecurring(id: string): Promise<unknown> {
  return commerce({ action: 'cancel_recurring_donation', recurring_id: id }, 'Could not cancel the monthly gift.');
}

export async function listImportedCards(orgId: string): Promise<ImportedCardRow[]> {
  const { data, error } = await supabase.from('exos_gift_cards')
    .select('id, last4, currency, initial_cents, balance_cents, status, external_source, recipient_email, expires_at, created_at')
    .eq('org_id', orgId).eq('source', 'import').order('created_at', { ascending: false }).limit(10000);
  if (error) throw error;
  return (data ?? []) as unknown as ImportedCardRow[];
}

export interface ImportResult {
  import_id: string; fresh: boolean; created: number; duplicates: number; errors: number; imported_cents: number;
  rows: { row: number; status: 'created' | 'duplicate' | 'error'; last4?: string; error?: string }[];
}
export async function importGiftCards(orgId: string, source: string, cards: ImportCard[], key: string): Promise<ImportResult> {
  return rpc('exos_gift_card_import', { p_org_id: orgId, p_source: source, p_cards: cards, p_key: key });
}
