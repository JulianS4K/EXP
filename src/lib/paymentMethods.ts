// Org opt-ins for extra payment methods and the PayPal balance (mig
// 20261031220000). RLS: owner / manager switch them, finance reads.

import { supabase } from './supabase';

export interface OrgPaymentMethods {
  paypal: boolean;
  cashapp: boolean;
}

export async function getOrgPaymentMethods(orgId: string): Promise<OrgPaymentMethods> {
  const { data, error } = await supabase.from('exos_org_payment_methods')
    .select('paypal_enabled, cashapp_enabled').eq('org_id', orgId).maybeSingle();
  if (error) return { paypal: false, cashapp: false };
  const row = data as { paypal_enabled?: boolean; cashapp_enabled?: boolean } | null;
  return { paypal: row?.paypal_enabled === true, cashapp: row?.cashapp_enabled === true };
}

export async function saveOrgPaymentMethods(orgId: string, m: OrgPaymentMethods): Promise<void> {
  const { error } = await supabase.from('exos_org_payment_methods').upsert(
    { org_id: orgId, paypal_enabled: m.paypal, cashapp_enabled: m.cashapp },
    { onConflict: 'org_id' },
  );
  if (error) throw new Error(error.message || 'Could not save payment methods.');
}

export interface PayPalBalance {
  currency: string;
  owedCents: number;
  heldCents: number;
  remittedCents: number;
  balanceCents: number;
  orders: number;
}

/** What PayPal orders owe the org, less what was paid out by hand. */
export async function getPayPalBalances(orgId: string): Promise<PayPalBalance[]> {
  const { data, error } = await supabase.from('exos_paypal_org_balances')
    .select('currency, owed_cents, held_cents, remitted_cents, balance_cents, orders').eq('org_id', orgId);
  if (error) return [];
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    currency: String(r.currency ?? 'usd'),
    owedCents: Number(r.owed_cents ?? 0),
    heldCents: Number(r.held_cents ?? 0),
    remittedCents: Number(r.remitted_cents ?? 0),
    balanceCents: Number(r.balance_cents ?? 0),
    orders: Number(r.orders ?? 0),
  }));
}
