// Fan referrals ("bring your friends", mig 20260924234500). A ticket holder
// gets a code per event; friends who buy through ?ref=<code> are counted.
// Tracking only: no reward is issued (docs/social.md).

import { supabase } from './supabase';

export interface ReferralStats { code: string; friends: number; tickets: number }

export async function myReferralCode(eventId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('exos_my_referral_code', { p_event_id: eventId });
  if (error) return null;
  return (data as string) ?? null;
}

export async function myReferralStats(eventId: string): Promise<ReferralStats | null> {
  const { data, error } = await supabase.rpc('exos_my_referral_stats', { p_event_id: eventId });
  if (error || !data) return null;
  const d = data as { code: string; friends: number; tickets: number };
  return { code: d.code, friends: Number(d.friends) || 0, tickets: Number(d.tickets) || 0 };
}

// Credit a just-finished free claim to the friend whose link brought the
// buyer. Paid orders are credited server-side at fulfillment. Best-effort.
export async function attachReferral(orderRef: string, code: string): Promise<void> {
  try {
    await supabase.rpc('exos_attach_referral', { p_order_ref: orderRef, p_code: code });
  } catch {
    /* the tickets are already issued; credit is a nice-to-have */
  }
}
