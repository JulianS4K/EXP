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
  terms: { rate_bps: number; flat_cents: number };
  totals: PromoterEarningsTotals[];
  events: {
    event_id: string; name: string; starts_at: string | null; currency: string; rate_bps: number; flat_cents: number;
    tickets: number; base_cents: number; accrued_cents: number; paid_cents: number; reversed_cents: number;
  }[];
  payouts: { paid_on: string; amount_cents: number; currency: string; method: string; sales: number }[];
}

// The promoter's own earnings for the portal (token-gated, anon-callable).
export async function getPromoterEarnings(token: string): Promise<PromoterEarnings | null> {
  const { data, error } = await supabase.rpc('exos_promoter_earnings', { p_token: token });
  if (error || !data) return null;
  return data as PromoterEarnings;
}
