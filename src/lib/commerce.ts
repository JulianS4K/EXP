// Gift cards, giving, passes and memberships in the SPA (docs/gift-cards.md,
// docs/giving.md, docs/memberships.md). The maths is shared with the edge
// functions (supabase/functions/_shared/commerce.ts); this file adds the
// Supabase calls and the CSV export. RLS and the definer RPCs decide who may
// do what; nothing here is trusted for money.

import { supabase } from './supabase';
import { toCsv } from './csv';

export * from '../../supabase/functions/_shared/commerce.ts';

/** The function's own error message, if any. */
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

// ---------------------------------------------------------------------------
// Gift cards
// ---------------------------------------------------------------------------
export interface GiftCardProduct {
  id: string;
  org_id: string;
  name: string;
  description: string | null;
  currency: string;
  amount_type: 'fixed' | 'open';
  amounts_cents: number[];
  min_cents: number | null;
  max_cents: number | null;
  image_url: string | null;
  expiry_months: number | null;
  active?: boolean;
  org_slug?: string;
  org_name?: string;
}

export interface GiftCardRow {
  id: string;
  last4: string;
  currency: string;
  initial_cents: number;
  balance_cents: number;
  status: 'active' | 'voided';
  source: string;
  payment_method: string;
  recipient_email: string | null;
  purchaser_email: string | null;
  expires_at: string | null;
  created_at: string;
}

export async function listGiftCardProducts(orgId: string): Promise<GiftCardProduct[]> {
  const { data, error } = await supabase.from('exos_gift_card_products')
    .select('id, org_id, name, description, currency, amount_type, amounts_cents, min_cents, max_cents, image_url, expiry_months, active')
    .eq('org_id', orgId).order('created_at');
  if (error) throw error;
  return (data ?? []) as GiftCardProduct[];
}

export async function publicGiftCardProducts(orgSlug: string): Promise<GiftCardProduct[]> {
  const { data, error } = await supabase.from('exos_public_gift_card_products').select('*').eq('org_slug', orgSlug);
  if (error) throw error;
  return (data ?? []) as GiftCardProduct[];
}

export async function saveGiftCardProduct(p: Partial<GiftCardProduct> & { org_id: string; name: string }): Promise<void> {
  const row = {
    org_id: p.org_id, name: p.name, description: p.description ?? null, currency: p.currency ?? 'usd',
    amount_type: p.amount_type ?? 'fixed', amounts_cents: p.amounts_cents ?? [],
    min_cents: p.min_cents ?? null, max_cents: p.max_cents ?? null, image_url: p.image_url ?? null,
    expiry_months: p.expiry_months ?? null, active: p.active ?? true,
  };
  const { error } = p.id
    ? await supabase.from('exos_gift_card_products').update(row).eq('id', p.id)
    : await supabase.from('exos_gift_card_products').insert(row);
  if (error) throw error;
}

export async function listGiftCards(orgId: string, limit = 100): Promise<GiftCardRow[]> {
  const { data, error } = await supabase.from('exos_gift_cards')
    .select('id, last4, currency, initial_cents, balance_cents, status, source, payment_method, recipient_email, purchaser_email, expires_at, created_at')
    .eq('org_id', orgId).order('created_at', { ascending: false }).limit(limit);
  if (error) throw error;
  return (data ?? []) as GiftCardRow[];
}

/** Box office / dashboard sale. The code comes back once (and is emailed). */
export async function issueGiftCard(input: {
  orgId: string; amountCents: number; paymentMethod: 'cash' | 'check' | 'comp' | 'card';
  productId?: string | null; currency?: string; recipientEmail?: string; recipientName?: string; message?: string;
  externalId?: string; source?: 'box_office' | 'dashboard';
}): Promise<{ card_id: string; code: string | null; last4: string; balance_cents: number; fresh: boolean }> {
  const { data, error } = await supabase.rpc('exos_gift_card_issue', {
    p_org_id: input.orgId, p_amount_cents: input.amountCents, p_payment_method: input.paymentMethod,
    p_product_id: input.productId ?? null, p_currency: input.currency ?? 'usd',
    p_recipient_email: input.recipientEmail || null, p_recipient_name: input.recipientName || null,
    p_message: input.message || null, p_purchaser_email: null, p_external_id: input.externalId || null,
    p_source: input.source ?? 'box_office',
  });
  if (error) throw error;
  return data as { card_id: string; code: string | null; last4: string; balance_cents: number; fresh: boolean };
}

export async function voidGiftCard(cardId: string, note?: string): Promise<void> {
  const { error } = await supabase.rpc('exos_gift_card_void', { p_card_id: cardId, p_note: note ?? null });
  if (error) throw error;
}

export async function reissueGiftCardCode(cardId: string): Promise<{ code: string; last4: string }> {
  const { data, error } = await supabase.rpc('exos_gift_card_reissue_code', { p_card_id: cardId, p_notify: true });
  if (error) throw error;
  return data as { code: string; last4: string };
}

export interface GiftCardBalance {
  last4: string; balance_cents: number; initial_cents?: number; currency: string; org_name: string | null;
  expires_at: string | null;
}

/** Balance by code, signed in or out (exos-commerce rate-limits per account / network). */
export async function giftCardBalance(code: string): Promise<GiftCardBalance> {
  return commerce<GiftCardBalance>({ action: 'gift_card_balance', code }, 'Could not check that gift card.');
}

export async function buyGiftCard(input: {
  productId: string; amountCents: number; recipientEmail?: string; recipientName?: string; message?: string;
  email?: string; successUrl: string; cancelUrl: string;
}): Promise<string> {
  const d = await commerce<{ url?: string }>({
    action: 'buy_gift_card', product_id: input.productId, amount_cents: input.amountCents,
    recipient_email: input.recipientEmail || undefined, recipient_name: input.recipientName || undefined,
    message: input.message || undefined, email: input.email || undefined,
    success_url: input.successUrl, cancel_url: input.cancelUrl,
  }, 'Could not start checkout.');
  if (!d?.url) throw new Error('Could not start checkout.');
  return d.url;
}

export async function myGiftCards(): Promise<(GiftCardRow & { org_name: string; sent_to_me: boolean })[]> {
  const { data, error } = await supabase.rpc('exos_my_gift_cards');
  if (error) throw error;
  return (data ?? []) as (GiftCardRow & { org_name: string; sent_to_me: boolean })[];
}

// ---------------------------------------------------------------------------
// Giving
// ---------------------------------------------------------------------------
export interface GivingCampaign {
  id: string;
  org_id: string;
  name: string;
  slug: string;
  description: string | null;
  image_url: string | null;
  currency: string;
  goal_cents: number;
  starts_at: string | null;
  ends_at: string | null;
  suggested_cents: number[];
  cover_fees: boolean;
  cover_fees_bps: number;
  checkout_add_on: boolean;
  round_up: boolean;
  tax_receipt_text?: string | null;
  active?: boolean;
  // Public view only.
  org_slug?: string;
  org_name?: string;
  open?: boolean;
  raised_cents?: number;
  donation_count?: number;
}

export async function listCampaigns(orgId: string): Promise<GivingCampaign[]> {
  const { data, error } = await supabase.from('exos_giving_campaigns').select('*').eq('org_id', orgId).order('created_at');
  if (error) throw error;
  return (data ?? []) as GivingCampaign[];
}

export async function saveCampaign(c: Partial<GivingCampaign> & { org_id: string; name: string; slug: string }): Promise<void> {
  const row = {
    org_id: c.org_id, name: c.name, slug: c.slug, description: c.description ?? null, image_url: c.image_url ?? null,
    currency: c.currency ?? 'usd', goal_cents: c.goal_cents ?? 0, starts_at: c.starts_at ?? null, ends_at: c.ends_at ?? null,
    suggested_cents: c.suggested_cents ?? [1000, 2500, 5000, 10000], cover_fees: c.cover_fees ?? true,
    cover_fees_bps: c.cover_fees_bps ?? 300, checkout_add_on: c.checkout_add_on ?? false, round_up: c.round_up ?? false,
    tax_receipt_text: c.tax_receipt_text ?? null, active: c.active ?? true,
  };
  const { error } = c.id
    ? await supabase.from('exos_giving_campaigns').update(row).eq('id', c.id)
    : await supabase.from('exos_giving_campaigns').insert(row);
  if (error) throw error;
}

export async function publicCampaign(orgSlug: string, slug: string): Promise<GivingCampaign | null> {
  const { data, error } = await supabase.from('exos_public_giving_campaigns').select('*')
    .eq('org_slug', orgSlug).eq('slug', slug).maybeSingle();
  if (error) throw error;
  return (data as GivingCampaign | null) ?? null;
}

/** The campaign offered as add-a-donation at an event's checkout: the org's first open one in the currency. */
export async function checkoutDonationOption(orgId: string, currency: string): Promise<GivingCampaign | null> {
  const { data, error } = await supabase.from('exos_public_giving_campaigns').select('*')
    .eq('org_id', orgId).eq('checkout_add_on', true).eq('open', true).eq('currency', currency.toLowerCase()).limit(1);
  if (error) return null;
  return ((data ?? [])[0] as GivingCampaign | undefined) ?? null;
}

export async function donate(input: {
  campaignId: string; amountCents: number; coverFees: boolean; anonymous?: boolean; donorName?: string; note?: string;
  email?: string; successUrl: string; cancelUrl: string;
}): Promise<string> {
  const d = await commerce<{ url?: string }>({
    action: 'donate', campaign_id: input.campaignId, amount_cents: input.amountCents, cover_fees: input.coverFees,
    anonymous: input.anonymous ?? false, donor_name: input.donorName || undefined, note: input.note || undefined,
    email: input.email || undefined, success_url: input.successUrl, cancel_url: input.cancelUrl,
  }, 'Could not start checkout.');
  if (!d?.url) throw new Error('Could not start checkout.');
  return d.url;
}

export async function recordOfflineDonation(input: {
  campaignId: string; amountCents: number; method: 'cash' | 'check' | 'other'; donorName?: string; donorEmail?: string;
  anonymous?: boolean; note?: string; externalId?: string;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_record_offline_donation', {
    p_campaign_id: input.campaignId, p_amount_cents: input.amountCents, p_method: input.method,
    p_donor_name: input.donorName || null, p_donor_email: input.donorEmail || null, p_anonymous: input.anonymous ?? false,
    p_note: input.note || null, p_external_id: input.externalId || null,
  });
  if (error) throw error;
  return data as string;
}

export interface DonationExportRow {
  created_at: string; campaign: string; amount_cents: number; cover_fees_cents: number; total_cents: number;
  currency: string; method: string; donor_name: string | null; donor_email: string | null; anonymous: boolean;
  session_id: string | null; status: string; note: string | null; receipt_number: number | null;
}

export async function donationsExport(orgId: string, campaignId?: string): Promise<DonationExportRow[]> {
  const { data, error } = await supabase.rpc('exos_donations_export', { p_org_id: orgId, p_campaign_id: campaignId ?? null });
  if (error) throw error;
  return (data ?? []) as DonationExportRow[];
}

const major = (c: number) => (c / 100).toFixed(2);

/** The donations CSV (amounts in major units; formula cells escaped by csv.ts). */
export function donationsCsv(rows: DonationExportRow[]): string {
  return toCsv(
    ['date', 'campaign', 'amount', 'cover_fees', 'total', 'currency', 'method', 'donor_name', 'donor_email',
      'anonymous', 'order_id', 'status', 'note', 'receipt_number'],
    rows.map((r) => [r.created_at, r.campaign, major(r.amount_cents), major(r.cover_fees_cents), major(r.total_cents),
      r.currency.toUpperCase(), r.method, r.donor_name, r.donor_email, r.anonymous, r.session_id, r.status, r.note,
      r.receipt_number]),
  );
}

/** Progress bar share, 0-1 (0 with no goal). */
export function campaignProgress(raisedCents: number, goalCents: number): number {
  if (!(goalCents > 0)) return 0;
  return Math.min(1, Math.max(0, raisedCents / goalCents));
}
