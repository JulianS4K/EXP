// Fan referrals ("bring your friends", mig 20260924234500). A ticket holder
// gets a code per event; friends who buy through ?ref=<code> are counted.
// Rewards (mig 20260926030000): an organizer rule turns every N counted
// tickets into a voucher for the fan; pure logic lives in referralRewards.ts.

import { supabase } from './supabase';
import { parseRule, type RewardKind, type RewardRule, type RewardRuleDraft } from './referralRewards';

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

// ---- Rewards (mig 20260926030000) -----------------------------------------

export interface EarnedReward {
  id: string;
  milestone: number;
  threshold: number;
  status: 'issued' | 'revoked';
  /** Voucher code; null once revoked. */
  code: string | null;
  redeemed: boolean;
  free: boolean;
  price: number | null;
  tierId: string | null;
  tierName: string | null;
  eventId: string;
  eventName: string | null;
}

export interface ReferralProgress {
  code: string | null;
  counted: number;
  nextThreshold: number | null;
  emailConfirmed: boolean;
  rule: {
    everyN: number; maxRewards: number; countFreeClaims: boolean;
    kind: RewardKind; value: number;
    rewardEventId: string; rewardEventName: string | null; rewardTierName: string | null;
  } | null;
  rewards: EarnedReward[];
}

export async function myReferralProgress(eventId: string): Promise<ReferralProgress | null> {
  const { data, error } = await supabase.rpc('exos_my_referral_progress', { p_event_id: eventId });
  if (error || !data) return null;
  const d = data as ReferralProgress;
  return {
    ...d,
    counted: Number(d.counted) || 0,
    nextThreshold: d.nextThreshold == null ? null : Number(d.nextThreshold),
    rewards: Array.isArray(d.rewards) ? d.rewards : [],
  };
}

/** Claim a free reward: mints the ticket and returns its id. */
export async function redeemReferralReward(rewardId: string, tierId?: string | null): Promise<string> {
  const { data, error } = await supabase.rpc('exos_redeem_referral_reward', {
    p_reward_id: rewardId, p_tier_id: tierId ?? null,
  });
  if (error) throw error;
  return data as string;
}

export interface RewardEventOption {
  id: string;
  name: string | null;
  startsAt: string | null;
  tiers: { id: string; name: string | null; price: number; visibility: string | null }[];
}

export interface RewardRuleState {
  eventRule: RewardRule | null;
  orgDefault: RewardRule | null;
  applies: 'event' | 'org' | null;
  rewardOptions: RewardEventOption[];
}

export async function getRewardRule(eventId: string): Promise<RewardRuleState> {
  const { data, error } = await supabase.rpc('exos_get_referral_reward_rule', { p_event_id: eventId });
  if (error) throw error;
  const d = (data ?? {}) as Record<string, unknown>;
  return {
    eventRule: parseRule(d.eventRule),
    orgDefault: parseRule(d.orgDefault),
    applies: d.applies === 'event' || d.applies === 'org' ? d.applies : null,
    rewardOptions: Array.isArray(d.rewardOptions)
      ? (d.rewardOptions as RewardEventOption[]).map((o) => ({
          ...o, tiers: (o.tiers ?? []).map((t) => ({ ...t, price: Number(t.price) || 0 })),
        }))
      : [],
  };
}

/** Save the event's rule (eventId set) or the org default (eventId null, orgId set). */
export async function setRewardRule(
  target: { eventId: string | null; orgId?: string | null }, d: RewardRuleDraft,
): Promise<string> {
  const { data, error } = await supabase.rpc('exos_set_referral_reward_rule', {
    p_event_id: target.eventId,
    p_org_id: target.orgId ?? null,
    p_enabled: d.enabled,
    p_every_n: d.everyN,
    p_max_rewards_per_fan: d.maxRewardsPerFan,
    p_count_free_claims: d.countFreeClaims,
    p_reward_event_id: d.rewardEventId,
    p_reward_tier_id: d.rewardTierId,
    p_reward_kind: d.kind,
    p_reward_value: d.value,
    p_bypass_capacity: d.bypassCapacity,
  });
  if (error) throw error;
  return data as string;
}

export async function deleteRewardRule(ruleId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_delete_referral_reward_rule', { p_rule_id: ruleId });
  if (error) throw error;
}

export interface LeaderboardRow {
  rank: number;
  /** Display name or masked email; never the full address. */
  label: string;
  tickets: number;
  friends: number;
  rewardsIssued: number;
  rewardsRedeemed: number;
}

export async function referralLeaderboard(eventId: string, limit = 25): Promise<LeaderboardRow[]> {
  const { data, error } = await supabase.rpc('exos_referral_leaderboard', { p_event_id: eventId, p_limit: limit });
  if (error) throw error;
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    rank: Number(r.rank) || 0,
    label: String(r.label ?? 'Fan'),
    tickets: Number(r.tickets) || 0,
    friends: Number(r.friends) || 0,
    rewardsIssued: Number(r.rewards_issued) || 0,
    rewardsRedeemed: Number(r.rewards_redeemed) || 0,
  }));
}
