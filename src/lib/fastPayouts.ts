// Fast payouts for organizers (mig 20261102150000, docs/payouts.md "Instant
// payouts"): Stripe Instant Payouts through exos-instant-payouts (org owner,
// off unless EXOS_INSTANT_PAYOUTS=on) and the "money so far" read. The fee
// math is shared with the function (supabase/functions/_shared/payouts/instant.ts).

import { supabase } from './supabase';
import { normalizeMoneySoFar, type MoneySoFar } from './moneySoFar';

export { instantFeeCents, maxInstantPayout } from '../../supabase/functions/_shared/payouts/instant.ts';

export interface InstantQuote {
  enabled: boolean;
  eligible?: boolean;
  reason?: string | null;
  fee_bps: number;
  fee_min_cents: number;
  balances?: { currency: string; instant_available_cents: number; max_payout_cents: number; fee_at_max_cents: number }[];
}

/** null when the function isn't deployed or the caller isn't the org owner. */
export async function instantQuote(orgId: string): Promise<InstantQuote | null> {
  const { data, error } = await supabase.functions.invoke('exos-instant-payouts/quote', { body: { org_id: orgId } });
  if (error || !data) return null;
  return data as InstantQuote;
}

export async function requestInstantPayout(input: { orgId: string; amountCents: number; currency: string; key: string }):
  Promise<{ status: string; payout_id?: string; arrival_date?: number; error?: string }> {
  const { data, error } = await supabase.functions.invoke('exos-instant-payouts/send', {
    body: { org_id: input.orgId, amount_cents: input.amountCents, currency: input.currency, idempotency_key: input.key },
  });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    const body = ctx && typeof ctx.json === 'function' ? await ctx.json().catch(() => null) : null;
    throw new Error(body?.error || error.message || 'Could not request the payout.');
  }
  return data as { status: string; payout_id?: string; arrival_date?: number };
}

export interface InstantPayoutRow {
  id: string; currency: string; amountCents: number; feeEstimateCents: number; status: string;
  stripePayoutId: string | null; error: string | null; createdAt: string;
}

/** Owner / finance read their org's requests (RLS). */
export async function listInstantPayouts(orgId: string): Promise<InstantPayoutRow[]> {
  const { data, error } = await supabase
    .from('exos_org_instant_payouts')
    .select('id, currency, amount_cents, fee_estimate_cents, status, stripe_payout_id, error, created_at')
    .eq('org_id', orgId)
    .order('created_at', { ascending: false })
    .limit(20);
  if (error) return [];
  return (data ?? []).map((r: any) => ({
    id: r.id, currency: r.currency, amountCents: r.amount_cents, feeEstimateCents: r.fee_estimate_cents, status: r.status,
    stripePayoutId: r.stripe_payout_id, error: r.error, createdAt: r.created_at,
  }));
}

/** The end-of-night money summary; null before the migration or for other roles. */
export async function getMoneySoFar(eventId: string): Promise<MoneySoFar | null> {
  const { data, error } = await supabase.rpc('exos_event_money_so_far', { p_event_id: eventId });
  if (error) return null;
  return normalizeMoneySoFar(data);
}
