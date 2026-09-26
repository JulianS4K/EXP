// Fan referral rewards (mig 20260926030000): pure logic shared by the
// organizer rule editor and the fan's progress card. The database is the
// authority (issuance, revocation, caps); these helpers mirror its rules so
// the UI can explain them before a save.

import { formatCurrency } from './utils';
//
// Money: rule values are integer cents (price / amount off) or a whole
// percent. Tier prices and voucher price overrides are dollars, as in
// exos_ticket_tiers.price.

export type RewardKind = 'price' | 'percent_off' | 'amount_off';

export interface RewardRuleDraft {
  enabled: boolean;
  everyN: number;
  maxRewardsPerFan: number;
  countFreeClaims: boolean;
  /** null = the referral's own event. */
  rewardEventId: string | null;
  /** null = any ticket type (only for kind 'price'). */
  rewardTierId: string | null;
  kind: RewardKind;
  /** cents for 'price' / 'amount_off', 1-100 for 'percent_off'. */
  value: number;
  bypassCapacity: boolean;
}

export interface RewardRule extends RewardRuleDraft {
  id: string;
  orgId: string;
  eventId: string | null;
}

export const DEFAULT_RULE: RewardRuleDraft = {
  enabled: true,
  everyN: 3,
  maxRewardsPerFan: 1,
  countFreeClaims: true,
  rewardEventId: null,
  rewardTierId: null,
  kind: 'price',
  value: 0,
  bypassCapacity: false,
};

/** Stripe's minimum charge; a pinned price under it becomes free (same as SQL). */
export const MIN_CHARGE = 0.5;

/** A rule row as exos_get_referral_reward_rule returns it (snake_case jsonb). */
export function parseRule(row: unknown): RewardRule | null {
  if (!row || typeof row !== 'object') return null;
  const r = row as Record<string, unknown>;
  if (typeof r.id !== 'string') return null;
  const kind = r.reward_kind === 'percent_off' || r.reward_kind === 'amount_off' ? r.reward_kind : 'price';
  return {
    id: r.id,
    orgId: String(r.org_id ?? ''),
    eventId: typeof r.event_id === 'string' ? r.event_id : null,
    enabled: r.enabled !== false,
    everyN: Number(r.every_n) || 1,
    maxRewardsPerFan: Number(r.max_rewards_per_fan) || 1,
    countFreeClaims: r.count_free_claims !== false,
    rewardEventId: typeof r.reward_event_id === 'string' ? r.reward_event_id : null,
    rewardTierId: typeof r.reward_tier_id === 'string' ? r.reward_tier_id : null,
    kind,
    value: Number(r.reward_value) || 0,
    bypassCapacity: r.bypass_capacity === true,
  };
}

export function toDraft(rule: RewardRule | null): RewardRuleDraft {
  if (!rule) return { ...DEFAULT_RULE };
  const { id: _id, orgId: _o, eventId: _e, ...draft } = rule;
  return draft;
}

/** The first problem with a draft (same limits as exos_set_referral_reward_rule), or null. */
export function validateRuleDraft(d: RewardRuleDraft, opts: { orgDefault?: boolean } = {}): string | null {
  if (!Number.isInteger(d.everyN) || d.everyN < 1 || d.everyN > 100) return 'Friends per reward must be 1-100.';
  if (!Number.isInteger(d.maxRewardsPerFan) || d.maxRewardsPerFan < 1 || d.maxRewardsPerFan > 20) {
    return 'Rewards per fan must be 1-20.';
  }
  if (!Number.isInteger(d.value) || d.value < 0) return 'Enter a whole amount.';
  if (d.kind === 'percent_off' && (d.value < 1 || d.value > 100)) return 'Percent off must be 1-100.';
  if (d.kind === 'amount_off' && d.value < 1) return 'Enter an amount off.';
  if (d.kind !== 'price' && !d.rewardTierId) return 'Pick a ticket type for a discount.';
  if (opts.orgDefault && d.rewardTierId && !d.rewardEventId) return 'Pick the event the ticket type belongs to.';
  return null;
}

/** The per-ticket price a reward voucher pins, in dollars (mirrors the SQL sync). */
export function rewardPrice(kind: RewardKind, value: number, tierPrice: number): number {
  let price: number;
  if (kind === 'price') price = value / 100;
  else if (kind === 'percent_off') price = Math.round(tierPrice * (100 - value)) / 100;
  else price = Math.max(0, tierPrice - value / 100);
  price = Math.round(price * 100) / 100;
  return price > 0 && price < MIN_CHARGE ? 0 : price;
}

/** "a free ticket", "50% off", "$5.00 off", "a $10.00 ticket". */
export function describeReward(
  kind: RewardKind, value: number, opts: { currency?: string; tierName?: string | null } = {},
): string {
  const money = (cents: number) => formatCurrency(cents / 100, opts.currency);
  const tier = opts.tierName ? ` (${opts.tierName})` : '';
  if (kind === 'percent_off') return value >= 100 ? `a free ticket${tier}` : `${value}% off a ticket${tier}`;
  if (kind === 'amount_off') return `${money(value)} off a ticket${tier}`;
  return value === 0 ? `a free ticket${tier}` : `a ${money(value)} ticket${tier}`;
}

export interface ProgressSummary {
  /** Counted tickets needed for the next reward, or null when capped / no rule. */
  nextThreshold: number | null;
  /** How many more tickets until then (0 when capped). */
  remaining: number;
  /** Rewards the count has earned so far (before the cap). */
  earned: number;
  capped: boolean;
}

export function progressSummary(counted: number, everyN: number, maxRewards: number): ProgressSummary {
  const n = Math.max(1, Math.floor(everyN));
  const c = Math.max(0, Math.floor(counted));
  const earned = Math.min(Math.floor(c / n), maxRewards);
  const capped = earned >= maxRewards;
  const nextThreshold = capped ? null : (Math.floor(c / n) + 1) * n;
  return { nextThreshold, remaining: nextThreshold == null ? 0 : nextThreshold - c, earned, capped };
}
