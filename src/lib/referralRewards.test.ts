import { describe, it, expect } from 'vitest';
import {
  DEFAULT_RULE, describeReward, parseRule, progressSummary, rewardPrice, toDraft, validateRuleDraft,
} from './referralRewards';

describe('rewardPrice', () => {
  it('pins a price in cents', () => {
    expect(rewardPrice('price', 0, 20)).toBe(0);
    expect(rewardPrice('price', 1000, 20)).toBe(10);
  });
  it('takes a percent off the tier price', () => {
    expect(rewardPrice('percent_off', 25, 40)).toBe(30);
    expect(rewardPrice('percent_off', 15, 19.99)).toBe(16.99);
    expect(rewardPrice('percent_off', 100, 40)).toBe(0);
  });
  it('takes an amount off, never below zero', () => {
    expect(rewardPrice('amount_off', 500, 20)).toBe(15);
    expect(rewardPrice('amount_off', 5000, 20)).toBe(0);
  });
  it('makes anything under the minimum charge free', () => {
    expect(rewardPrice('amount_off', 1980, 20)).toBe(0);
    expect(rewardPrice('price', 49, 20)).toBe(0);
    expect(rewardPrice('price', 50, 20)).toBe(0.5);
  });
});

describe('progressSummary', () => {
  it('points at the next multiple of N', () => {
    expect(progressSummary(0, 3, 2)).toEqual({ nextThreshold: 3, remaining: 3, earned: 0, capped: false });
    expect(progressSummary(4, 3, 2)).toEqual({ nextThreshold: 6, remaining: 2, earned: 1, capped: false });
  });
  it('stops at the cap', () => {
    expect(progressSummary(6, 3, 2)).toEqual({ nextThreshold: null, remaining: 0, earned: 2, capped: true });
    expect(progressSummary(20, 3, 2).earned).toBe(2);
  });
});

describe('validateRuleDraft', () => {
  it('accepts the default free-ticket rule', () => {
    expect(validateRuleDraft(DEFAULT_RULE)).toBeNull();
  });
  it('mirrors the server limits', () => {
    expect(validateRuleDraft({ ...DEFAULT_RULE, everyN: 0 })).toMatch(/1-100/);
    expect(validateRuleDraft({ ...DEFAULT_RULE, maxRewardsPerFan: 21 })).toMatch(/1-20/);
    expect(validateRuleDraft({ ...DEFAULT_RULE, kind: 'percent_off', value: 50 })).toMatch(/ticket type/);
    expect(validateRuleDraft({ ...DEFAULT_RULE, kind: 'percent_off', value: 101, rewardTierId: 't' })).toMatch(/1-100/);
    expect(validateRuleDraft({ ...DEFAULT_RULE, kind: 'amount_off', value: 0, rewardTierId: 't' })).toMatch(/amount/);
    expect(validateRuleDraft({ ...DEFAULT_RULE, rewardTierId: 't' }, { orgDefault: true })).toMatch(/event/);
  });
});

describe('describeReward', () => {
  it('reads plainly', () => {
    expect(describeReward('price', 0)).toBe('a free ticket');
    expect(describeReward('price', 1000, { tierName: 'GA' })).toBe('a $10.00 ticket (GA)');
    expect(describeReward('percent_off', 50)).toBe('50% off a ticket');
    expect(describeReward('amount_off', 500)).toBe('$5.00 off a ticket');
  });
});

describe('parseRule / toDraft', () => {
  it('maps the server row and back', () => {
    const rule = parseRule({
      id: 'r1', org_id: 'o1', event_id: 'e1', enabled: false, every_n: 2, max_rewards_per_fan: 3,
      count_free_claims: false, reward_event_id: null, reward_tier_id: 't1', reward_kind: 'percent_off',
      reward_value: 25, bypass_capacity: true,
    });
    expect(rule).toMatchObject({ id: 'r1', eventId: 'e1', enabled: false, everyN: 2, kind: 'percent_off', value: 25 });
    expect(toDraft(rule)).not.toHaveProperty('id');
    expect(toDraft(null)).toEqual(DEFAULT_RULE);
    expect(parseRule(null)).toBeNull();
  });
});
