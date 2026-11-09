// Promoters: an organizer's street team (mig 20260924233000). Each has a code
// (what ?promoter= carries, so every free and paid ticket through their links
// is credited) and a private kit link (/p/:token) showing their own sales.

import { supabase } from './supabase';
import type { SocialHandles } from './socialTags';
import type { CommissionRow } from './commissions';

export interface Promoter {
  id: string;
  orgId: string;
  code: string;
  name: string;
  email: string | null;
  status: 'active' | 'paused';
  kitToken: string;
  socials: SocialHandles;
  allowTagging: boolean;
}

export interface PromoterStat {
  promoterId: string;
  code: string;
  name: string;
  status: 'active' | 'paused';
  tickets: number;
  gross: number;
}

export interface PromoterKitData {
  promoter: { name: string; code: string; socials?: SocialHandles; allow_tagging?: boolean };
  org: { id: string; name: string; slug: string };
  events: { event_id: string; name: string; starts_at: string | null; tickets: number; gross: number; currency: string | null }[];
}

export { codeFromName } from './shareLinks';

export async function listPromoters(orgId: string): Promise<Promoter[]> {
  const { data, error } = await supabase
    .from('exos_promoters')
    .select('id, org_id, code, name, email, status, kit_token, socials, allow_tagging')
    .eq('org_id', orgId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, orgId: r.org_id, code: r.code, name: r.name, email: r.email, status: r.status, kitToken: r.kit_token,
    socials: r.socials ?? {}, allowTagging: r.allow_tagging !== false,
  }));
}

export async function upsertPromoter(
  orgId: string,
  input: { code: string; name: string; email?: string; socials?: SocialHandles; allowTagging?: boolean },
): Promise<string> {
  const { data, error } = await supabase.rpc('exos_upsert_promoter', {
    p_org_id: orgId, p_code: input.code, p_name: input.name, p_email: input.email || null,
    // Only sent when set, so leaving them out keeps what's stored.
    ...(input.socials ? { p_socials: input.socials } : {}),
    ...(input.allowTagging !== undefined ? { p_allow_tagging: input.allowTagging } : {}),
  });
  if (error) throw error;
  return data as string;
}

export async function setPromoterStatus(promoterId: string, status: 'active' | 'paused', rotateToken = false): Promise<void> {
  const { error } = await supabase.rpc('exos_set_promoter_status', {
    p_promoter_id: promoterId, p_status: status, p_rotate_token: rotateToken,
  });
  if (error) throw error;
}

export async function orgPromoterStats(orgId: string, eventId?: string): Promise<PromoterStat[]> {
  const { data, error } = await supabase.rpc('exos_org_promoter_stats', { p_org_id: orgId, p_event_id: eventId ?? null });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    promoterId: r.promoter_id, code: r.code, name: r.name, status: r.status,
    tickets: Number(r.tickets) || 0, gross: Number(r.gross) || 0,
  }));
}

export async function getPromoterKit(token: string): Promise<PromoterKitData | null> {
  const { data, error } = await supabase.rpc('exos_promoter_kit', { p_token: token });
  if (error || !data) return null;
  return data as PromoterKitData;
}

export interface PublicPromoterCard {
  /** socials is empty unless the promoter allows tagging. */
  promoter: { name: string; code: string; socials?: SocialHandles };
  org: { id: string; name: string; slug: string };
}

// The link-in-bio page's header: the promoter's display name, active only.
export async function getPublicPromoter(orgSlug: string, code: string): Promise<PublicPromoterCard | null> {
  const { data, error } = await supabase.rpc('exos_public_promoter', { p_org_slug: orgSlug, p_code: code });
  if (error || !data) return null;
  return data as PublicPromoterCard;
}

// The promoter sets their own handles and tagging switch from their kit page.
export async function setPromoterSocials(token: string, socials: SocialHandles, allowTagging: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_promoter_set_socials', {
    p_token: token, p_socials: socials, p_allow_tagging: allowTagging,
  });
  if (error) throw error;
}

// One public link a promoter can put in their Instagram / TikTok bio.
export function linkInBioPath(orgSlug: string, code: string): string {
  return `l/${encodeURIComponent(orgSlug)}/${encodeURIComponent(code)}`;
}

// --- Commissions (mig 20260926020000) ---------------------------------------
// Math lives in ./commissions.ts (pure, tested); these are the RPC wrappers.
// All amounts are integer cents.

export interface PromoterCommissionSummary {
  promoterId: string;
  code: string;
  name: string;
  status: 'active' | 'paused';
  rateBps: number;
  flatCents: number;
  /** null for a promoter with no paid sales yet. */
  currency: string | null;
  tickets: number;
  grossCents: number;
  baseCents: number;
  accruedCents: number;
  reversedCents: number;
  paidCents: number;
  clawbackCents: number;
  owedCents: number;
}

export async function orgPromoterCommissions(orgId: string, eventId?: string): Promise<PromoterCommissionSummary[]> {
  const { data, error } = await supabase.rpc('exos_org_promoter_commissions', { p_org_id: orgId, p_event_id: eventId ?? null });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    promoterId: r.promoter_id, code: r.code, name: r.name, status: r.status,
    rateBps: Number(r.rate_bps) || 0, flatCents: Number(r.flat_cents) || 0, currency: r.currency ?? null,
    tickets: Number(r.tickets) || 0, grossCents: Number(r.gross_cents) || 0, baseCents: Number(r.base_cents) || 0,
    accruedCents: Number(r.accrued_cents) || 0, reversedCents: Number(r.reversed_cents) || 0,
    paidCents: Number(r.paid_cents) || 0, clawbackCents: Number(r.clawback_cents) || 0, owedCents: Number(r.owed_cents) || 0,
  }));
}

export interface PromoterEventTerms { promoterId: string; eventId: string; rateBps: number; flatCents: number }

export async function listPromoterEventTerms(orgId: string): Promise<PromoterEventTerms[]> {
  const { data, error } = await supabase
    .from('exos_promoter_event_terms')
    .select('promoter_id, event_id, rate_bps, flat_cents')
    .eq('org_id', orgId);
  if (error) throw error;
  return (data ?? []).map((r: any) => ({ promoterId: r.promoter_id, eventId: r.event_id, rateBps: r.rate_bps, flatCents: r.flat_cents }));
}

/** eventId omitted: the promoter's default. eventId with both null: remove that event's override.
 *  repriceAccrued re-prices sales not yet paid. Returns how many were re-priced. */
export async function setPromoterTerms(
  promoterId: string,
  terms: { rateBps: number | null; flatCents: number | null },
  opts: { eventId?: string; repriceAccrued?: boolean } = {},
): Promise<number> {
  const { data, error } = await supabase.rpc('exos_set_promoter_terms', {
    p_promoter_id: promoterId, p_rate_bps: terms.rateBps, p_flat_cents: terms.flatCents,
    p_event_id: opts.eventId ?? null, p_reprice_accrued: !!opts.repriceAccrued,
  });
  if (error) throw error;
  return Number(data) || 0;
}

export interface UnpaidCommission extends CommissionRow {
  eventId: string;
  eventName: string | null;
  baseCents: number;
  accruedAt: string;
}

// Rows a payout can cover (staff read through RLS; no buyer data selected).
export async function listUnpaidCommissions(promoterId: string): Promise<UnpaidCommission[]> {
  const { data, error } = await supabase
    .from('exos_promoter_commissions')
    .select('id, event_id, currency, base_cents, commission_cents, status, payout_id, recovered_payout_id, accrued_at, exos_events(name)')
    .eq('promoter_id', promoterId)
    .eq('status', 'accrued')
    .order('accrued_at', { ascending: true })
    .limit(2000);
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, eventId: r.event_id, eventName: r.exos_events?.name ?? null, currency: r.currency,
    baseCents: r.base_cents, commissionCents: r.commission_cents, status: r.status,
    payoutId: r.payout_id, recoveredPayoutId: r.recovered_payout_id, accruedAt: r.accrued_at,
  }));
}

export async function recordPromoterPayout(input: {
  promoterId: string; commissionIds: string[]; amountCents: number; method: string; note?: string; paidOn?: string;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_record_promoter_payout', {
    p_promoter_id: input.promoterId, p_commission_ids: input.commissionIds, p_amount_cents: input.amountCents,
    p_method: input.method, p_note: input.note || null, p_paid_on: input.paidOn || null,
  });
  if (error) throw error;
  return data as string;
}

export interface PromoterEarningsTotals {
  currency: string; tickets: number; accrued_cents: number; paid_cents: number;
  reversed_cents: number; clawback_cents: number; owed_cents: number;
}
export interface PromoterEarnings {
  promoter: { name: string; code: string };
  terms: { rate_bps: number; flat_cents: number; step_after?: number | null; step_rate_bps?: number | null; step_flat_cents?: number | null };
  /** mig 20261102150000: whether the org pays by Stripe, and this promoter's account. */
  payout_account?: { transfers_enabled: boolean; connected: boolean; ready: boolean };
  totals: (PromoterEarningsTotals & { sales_cents?: number; processing_cents?: number })[];
  events: {
    event_id: string; name: string; starts_at: string | null; currency: string; rate_bps: number; flat_cents: number;
    step_after?: number | null; step_rate_bps?: number | null; step_flat_cents?: number | null;
    tickets: number; base_cents: number; accrued_cents: number; paid_cents: number; reversed_cents: number;
  }[];
  payouts: { paid_on: string; amount_cents: number; currency: string; method: string; sales: number; via?: 'manual' | 'stripe'; status?: 'paid' | 'processing' }[];
  as_of?: string;
}

// The promoter's own earnings for the portal (token-gated, anon-callable).
export async function getPromoterEarnings(token: string): Promise<PromoterEarnings | null> {
  const { data, error } = await supabase.rpc('exos_promoter_earnings', { p_token: token });
  if (error || !data) return null;
  return data as PromoterEarnings;
}

// --- Kickbacks paid out (mig 20261102150000) ---------------------------------
// Step terms, idempotent settling (manual or Stripe), the promoter's payout
// account and leaderboard. The money rules live in SQL; these are wrappers.

/** Set (after >= 1) or clear (after null) the step on the default or one event's terms. */
export async function setPromoterStep(
  promoterId: string,
  step: { after: number | null; rateBps: number; flatCents: number },
  opts: { eventId?: string; repriceAccrued?: boolean } = {},
): Promise<number> {
  const { data, error } = await supabase.rpc('exos_set_promoter_step', {
    p_promoter_id: promoterId, p_after: step.after, p_rate_bps: step.rateBps, p_flat_cents: step.flatCents,
    p_event_id: opts.eventId ?? null, p_reprice_accrued: !!opts.repriceAccrued,
  });
  if (error) throw error;
  return Number(data) || 0;
}

export interface PromoterStepRow { promoterId: string; after: number | null; rateBps: number | null; flatCents: number | null }

/** Each promoter's default step (staff read through RLS); empty before the migration. */
export async function listPromoterSteps(orgId: string): Promise<PromoterStepRow[]> {
  const { data, error } = await supabase
    .from('exos_promoters').select('id, step_after, step_rate_bps, step_flat_cents').eq('org_id', orgId);
  if (error) return [];
  return (data ?? []).map((r: any) => ({ promoterId: r.id, after: r.step_after, rateBps: r.step_rate_bps, flatCents: r.step_flat_cents }));
}

export interface SettleRow extends UnpaidCommission { stepped: boolean; fundable: boolean }

/** Unpaid sales with whether each can go out by Stripe transfer. */
export async function listSettleRows(promoterId: string): Promise<SettleRow[]> {
  const { data, error } = await supabase.rpc('exos_promoter_unpaid', { p_promoter_id: promoterId });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, eventId: r.event_id, eventName: r.event_name ?? null, currency: r.currency, baseCents: r.base_cents,
    commissionCents: r.commission_cents, status: 'accrued' as const, payoutId: null, recoveredPayoutId: null,
    accruedAt: r.accrued_at, stepped: !!r.stepped, fundable: !!r.fundable,
  }));
}

export interface SettleResult { payoutId: string; replayed: boolean; via: 'manual' | 'stripe'; transferStatus: string | null }

/** Settle selected sales. The same key returns the same payout (safe to retry). */
export async function settlePromoter(input: {
  promoterId: string; commissionIds: string[]; amountCents: number; method: string; key: string;
  via: 'manual' | 'stripe'; note?: string; paidOn?: string;
}): Promise<SettleResult> {
  const { data, error } = await supabase.rpc('exos_settle_promoter', {
    p_promoter_id: input.promoterId, p_commission_ids: input.commissionIds, p_amount_cents: input.amountCents,
    p_method: input.method, p_idempotency_key: input.key, p_via: input.via,
    p_note: input.note || null, p_paid_on: input.paidOn || null,
  });
  if (error) throw error;
  const d = data as any;
  return { payoutId: d.payout_id, replayed: !!d.replayed, via: d.via, transferStatus: d.transfer_status ?? null };
}

export interface PromoterPayoutRow {
  id: string; currency: string; amountCents: number; method: string; paidOn: string; via: 'manual' | 'stripe';
  transferStatus: string | null; transferError: string | null; rowCount: number;
  /** Something to look at (e.g. Stripe sent after a cancel), mig 20261102150000. */
  alert: string | null;
}

export async function listPromoterPayouts(promoterId: string): Promise<PromoterPayoutRow[]> {
  const { data, error } = await supabase
    .from('exos_promoter_payouts')
    .select('id, currency, amount_cents, method, paid_on, via, transfer_status, transfer_error, row_count, alert')
    .eq('promoter_id', promoterId)
    .order('created_at', { ascending: false })
    .limit(20);
  if (error) return [];
  return (data ?? []).map((r: any) => ({
    id: r.id, currency: r.currency, amountCents: r.amount_cents, method: r.method, paidOn: r.paid_on,
    via: r.via ?? 'manual', transferStatus: r.transfer_status ?? null, transferError: r.transfer_error ?? null, rowCount: r.row_count,
    alert: r.alert ?? null,
  }));
}

async function payoutsFn(path: string, body: Record<string, unknown>): Promise<any> {
  const { data, error } = await supabase.functions.invoke(`exos-promoter-payouts/${path}`, { body });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    const parsed = ctx && typeof ctx.json === 'function' ? await ctx.json().catch(() => null) : null;
    throw new Error(parsed?.error || error.message || 'Something went wrong.');
  }
  return data;
}

/** Organizer: send (or dry-run) a Stripe payout the settle created. */
export const sendPromoterPayout = (payoutId: string): Promise<{ status: string; error?: string }> => payoutsFn('send', { payout_id: payoutId });
/** Organizer: cancel a Stripe payout that never went out. */
export const cancelPromoterPayout = (payoutId: string): Promise<{ status: string }> => payoutsFn('cancel', { payout_id: payoutId });
/** Promoter (kit token): the Stripe onboarding link for their payout account. */
export const promoterPayoutOnboarding = (token: string, returnUrl: string): Promise<{ url: string }> =>
  payoutsFn('onboard', { token, return_url: returnUrl, refresh_url: returnUrl });
/** Promoter: refresh the account state after onboarding. */
export const promoterPayoutStatus = (token: string): Promise<{ connected: boolean; ready: boolean }> => payoutsFn('status', { token });

/** Is Stripe payout to promoters on for this org? (staff read; false before the migration) */
export async function getPromoterStripeTransfers(orgId: string): Promise<boolean> {
  const { data, error } = await supabase.from('exos_org_promoter_payouts').select('stripe_transfers').eq('org_id', orgId).maybeSingle();
  if (error) return false;
  return !!data?.stripe_transfers;
}

/** Org owner only (the RPC refuses anyone else). */
export async function setPromoterStripeTransfers(orgId: string, enabled: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_set_promoter_stripe_transfers', { p_org_id: orgId, p_enabled: enabled });
  if (error) throw error;
}

/** Which promoters have a ready Stripe payout account (staff read). */
export async function listPromoterPayoutAccounts(orgId: string): Promise<Map<string, boolean>> {
  const { data, error } = await supabase.from('exos_promoter_stripe_accounts').select('promoter_id, transfers_active').eq('org_id', orgId);
  if (error) return new Map();
  return new Map((data ?? []).map((r: any) => [r.promoter_id as string, !!r.transfers_active]));
}

export interface LeaderboardEntry { rank: number; name: string; tickets: number; me: boolean }

/** The org's active promoters by tickets (token-gated, names + counts only). */
export async function promoterLeaderboard(token: string, eventId?: string): Promise<{ promoters: number; rows: LeaderboardEntry[] } | null> {
  const { data, error } = await supabase.rpc('exos_promoter_leaderboard', { p_token: token, p_event_id: eventId ?? null, p_limit: 10 });
  if (error || !data) return null;
  return data as { promoters: number; rows: LeaderboardEntry[] };
}
