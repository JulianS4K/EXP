// Gift cards, giving, passes and memberships in the SPA (docs/gift-cards.md,
// docs/giving.md, docs/memberships.md). The maths is shared with the edge
// functions (supabase/functions/_shared/commerce.ts); this file adds the
// Supabase calls and the CSV export. RLS and the definer RPCs decide who may
// do what; nothing here is trusted for money.

import { supabase } from './supabase';
import { toCsv } from './csv';

export * from '../../supabase/functions/_shared/commerce.ts';
import { passCreditsLeft, type PassEligibility } from '../../supabase/functions/_shared/commerce.ts';

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
  /** The open POS drawer the sale went into (till reconciliation). */
  drawerId?: string;
}): Promise<{ card_id: string; code: string | null; last4: string; balance_cents: number; fresh: boolean }> {
  const { data, error } = await supabase.rpc('exos_gift_card_issue', {
    p_org_id: input.orgId, p_amount_cents: input.amountCents, p_payment_method: input.paymentMethod,
    p_product_id: input.productId ?? null, p_currency: input.currency ?? 'usd',
    p_recipient_email: input.recipientEmail || null, p_recipient_name: input.recipientName || null,
    p_message: input.message || null, p_purchaser_email: null, p_external_id: input.externalId || null,
    p_source: input.source ?? 'box_office', p_drawer_id: input.drawerId ?? null,
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

// ---------------------------------------------------------------------------
// Passes and memberships (mig 20261030130500)
// ---------------------------------------------------------------------------
export interface PassProduct {
  id: string; org_id: string; kind: 'season' | 'flex'; name: string; description: string | null; image_url: string | null;
  price_cents: number; currency: string; credits: number | null; per_event_limit: number | null; event_ids: string[];
  date_from: string | null; date_to: string | null; tier_ids?: string[]; valid_until: string | null; sales_end?: string | null;
  max_sold?: number | null; sold?: number; active?: boolean; sold_out?: boolean; org_slug?: string; org_name?: string;
}

export interface MembershipProduct {
  id: string; org_id: string; name: string; description: string | null; image_url: string | null; price_cents: number;
  currency: string; billing: 'month' | 'year' | 'once'; duration_days: number; discount_percent: number; presale: boolean;
  free_tickets_per_period: number; guest_allowance: number; household_seats: number; giftable: boolean; active?: boolean;
  org_slug?: string; org_name?: string;
}

export interface MyPass {
  id: string; org_id: string; org_name: string; kind: 'season' | 'flex'; name: string; credits_total: number | null;
  credits_used: number; per_event_limit: number | null; eligibility: PassEligibility; valid_until: string | null; status: string;
}

export interface MyMembership {
  id: string; org_id: string; org_name: string; product_name: string; billing: string | null; status: string;
  current_period_end: string | null; cancel_at_period_end: boolean; benefits: Record<string, unknown>; shared: boolean;
  household: string[] | null; free_used_this_period: number; can_manage_billing: boolean;
}

export async function publicPassProducts(orgSlug: string): Promise<PassProduct[]> {
  const { data, error } = await supabase.from('exos_public_pass_products').select('*').eq('org_slug', orgSlug);
  if (error) throw error;
  return (data ?? []) as PassProduct[];
}

export async function publicMembershipProducts(orgSlug: string): Promise<MembershipProduct[]> {
  const { data, error } = await supabase.from('exos_public_membership_products').select('*').eq('org_slug', orgSlug);
  if (error) throw error;
  return (data ?? []) as MembershipProduct[];
}

export async function listPassProducts(orgId: string): Promise<PassProduct[]> {
  const { data, error } = await supabase.from('exos_pass_products').select('*').eq('org_id', orgId).order('created_at');
  if (error) throw error;
  return (data ?? []) as PassProduct[];
}

export async function listMembershipProducts(orgId: string): Promise<MembershipProduct[]> {
  const { data, error } = await supabase.from('exos_membership_products').select('*').eq('org_id', orgId).order('created_at');
  if (error) throw error;
  return (data ?? []) as MembershipProduct[];
}

export async function savePassProduct(p: Partial<PassProduct> & { org_id: string; name: string; kind: 'season' | 'flex'; price_cents: number }): Promise<void> {
  const row = {
    org_id: p.org_id, kind: p.kind, name: p.name, description: p.description ?? null, image_url: p.image_url ?? null,
    price_cents: p.price_cents, currency: p.currency ?? 'usd', credits: p.kind === 'flex' ? p.credits ?? 1 : null,
    per_event_limit: p.per_event_limit ?? null, event_ids: p.event_ids ?? [], date_from: p.date_from ?? null,
    date_to: p.date_to ?? null, tier_ids: p.tier_ids ?? [], valid_until: p.valid_until ?? null,
    sales_end: p.sales_end ?? null, max_sold: p.max_sold ?? null, active: p.active ?? true,
  };
  const { error } = p.id
    ? await supabase.from('exos_pass_products').update(row).eq('id', p.id)
    : await supabase.from('exos_pass_products').insert(row);
  if (error) throw error;
}

export async function saveMembershipProduct(p: Partial<MembershipProduct> & { org_id: string; name: string; price_cents: number; billing: 'month' | 'year' | 'once' }): Promise<void> {
  const row: Record<string, unknown> = {
    org_id: p.org_id, name: p.name, description: p.description ?? null, image_url: p.image_url ?? null,
    price_cents: p.price_cents, currency: p.currency ?? 'usd', duration_days: p.duration_days ?? 365,
    discount_percent: p.discount_percent ?? 0, presale: p.presale ?? false,
    free_tickets_per_period: p.free_tickets_per_period ?? 0, guest_allowance: p.guest_allowance ?? 0,
    household_seats: p.household_seats ?? 0, giftable: p.giftable ?? true, active: p.active ?? true,
  };
  if (!p.id) row.billing = p.billing;
  const { error } = p.id
    ? await supabase.from('exos_membership_products').update(row).eq('id', p.id)
    : await supabase.from('exos_membership_products').insert(row);
  if (error) throw error;
}

export async function buyPass(input: { productId: string; email?: string; successUrl: string; cancelUrl: string }): Promise<string> {
  const d = await commerce<{ url?: string }>({
    action: 'buy_pass', product_id: input.productId, email: input.email || undefined,
    success_url: input.successUrl, cancel_url: input.cancelUrl,
  }, 'Could not start checkout.');
  if (!d?.url) throw new Error('Could not start checkout.');
  return d.url;
}

export async function buyMembership(input: {
  productId: string; giftToEmail?: string; giftMessage?: string; giftFromName?: string; successUrl: string; cancelUrl: string;
}): Promise<string> {
  const d = await commerce<{ url?: string }>({
    action: 'buy_membership', product_id: input.productId, gift_to_email: input.giftToEmail || undefined,
    gift_message: input.giftMessage || undefined, gift_from_name: input.giftFromName || undefined,
    success_url: input.successUrl, cancel_url: input.cancelUrl,
  }, 'Could not start checkout.');
  if (!d?.url) throw new Error('Could not start checkout.');
  return d.url;
}

export async function openBillingPortal(membershipId: string, returnUrl: string): Promise<string> {
  const d = await commerce<{ url?: string }>({ action: 'membership_portal', membership_id: membershipId, return_url: returnUrl },
    'Could not open billing.');
  if (!d?.url) throw new Error('Could not open billing.');
  return d.url;
}

export async function myPasses(): Promise<MyPass[]> {
  await supabase.rpc('exos_claim_my_passes');
  const { data, error } = await supabase.rpc('exos_my_passes');
  if (error) throw error;
  return (data ?? []) as MyPass[];
}

export async function myMemberships(): Promise<MyMembership[]> {
  const { data, error } = await supabase.rpc('exos_my_memberships');
  if (error) throw error;
  return (data ?? []) as MyMembership[];
}

export interface MemberBenefit { membership_id: string; product_name: string; discount_percent: number; guest_allowance: number; presale: boolean }

export async function myMemberBenefit(orgId: string): Promise<MemberBenefit | null> {
  const { data, error } = await supabase.rpc('exos_my_member_benefit', { p_org_id: orgId });
  if (error) return null;
  return (data as MemberBenefit | null) ?? null;
}

export type RedeemResult = { session_id: string; ticket_ids?: string[]; error?: string; fresh?: boolean };

export async function redeemPass(passId: string, eventId: string, tierId: string, quantity: number, requestId: string): Promise<RedeemResult> {
  const { data, error } = await supabase.rpc('exos_pass_redeem', {
    p_pass_id: passId, p_event_id: eventId, p_tier_id: tierId, p_quantity: quantity, p_request_id: requestId,
  });
  if (error) throw error;
  return data as RedeemResult;
}

export async function redeemMemberFree(membershipId: string, eventId: string, tierId: string, quantity: number, requestId: string): Promise<RedeemResult> {
  const { data, error } = await supabase.rpc('exos_membership_redeem', {
    p_membership_id: membershipId, p_event_id: eventId, p_tier_id: tierId, p_quantity: quantity, p_request_id: requestId,
  });
  if (error) throw error;
  return data as RedeemResult;
}

export async function claimMembershipGift(token: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_membership_claim_gift', { p_token: token });
  if (error) throw error;
  return data as string;
}

export async function setHousehold(membershipId: string, email: string, add: boolean): Promise<number> {
  const { data, error } = await supabase.rpc('exos_membership_household_set', { p_membership_id: membershipId, p_email: email, p_add: add });
  if (error) throw error;
  return data as number;
}

export async function giftMembership(productId: string, toEmail: string, fromName?: string, message?: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_membership_gift', {
    p_product_id: productId, p_to_email: toEmail, p_from_name: fromName ?? null, p_message: message ?? null,
  });
  if (error) throw error;
  return data as string;
}

export async function setMemberPresale(eventId: string, startsAt: string | null, endsAt: string | null, tierIds: string[] = [], productIds: string[] = []): Promise<void> {
  const { error } = await supabase.rpc('exos_set_member_presale', {
    p_event_id: eventId, p_starts_at: startsAt, p_ends_at: endsAt, p_tier_ids: tierIds, p_product_ids: productIds,
  });
  if (error) throw error;
}

export async function scanMembershipCard(orgId: string, membershipId: string): Promise<Record<string, unknown>> {
  const { data, error } = await supabase.rpc('exos_membership_scan', { p_org_id: orgId, p_membership_id: membershipId });
  if (error) throw error;
  return data as Record<string, unknown>;
}

/** Plain words for a pass's admissions left. */
export function passLeftLabel(p: { credits_total: number | null; credits_used: number }): string {
  const left = passCreditsLeft(p.credits_total, p.credits_used);
  return left === null ? 'one per event' : `${left} admission${left === 1 ? '' : 's'} left`;
}
