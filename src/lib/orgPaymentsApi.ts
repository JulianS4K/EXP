import { supabase } from './supabase';

/**
 * Whether the org's Stripe Connect account can take payments
 * (exos_org_payments_ready, mig 20261021110000; any org staff role). null when
 * it can't be told (the RPC isn't deployed yet or refused).
 */
export async function getOrgPaymentsReady(orgId: string): Promise<boolean | null> {
  const { data, error } = await supabase.rpc('exos_org_payments_ready', { p_org_id: orgId });
  if (error) {
    console.warn('exos_org_payments_ready unavailable:', error.message);
    return null;
  }
  return data === true;
}
