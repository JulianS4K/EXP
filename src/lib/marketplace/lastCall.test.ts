import { describe, expect, it, vi } from 'vitest';

vi.mock('../supabase', () => ({ supabase: {} }));

import {
  isLastCall, lastCallText, parseLastCallStatus, parsePublicSale, parseThresholdInput, sellsElsewhere, thresholdLine,
} from './lastCall';
import { parseSalesRules, RESALE_CONSENT_VERSION, salesRulesLine } from './resaleConsent';

describe('last call (mig 20261029100000)', () => {
  it('is on at or below the threshold; 0 is off; no limit never', () => {
    expect(isLastCall(11, 10)).toBe(false);
    expect(isLastCall(10, 10)).toBe(true);
    expect(isLastCall(0, 10)).toBe(true);
    expect(isLastCall(0, 0)).toBe(false);
    expect(isLastCall(null, 10)).toBe(false);
  });

  it('reads a threshold from the editor', () => {
    expect(parseThresholdInput('')).toBeNull();
    expect(parseThresholdInput(' 12 ')).toBe(12);
    expect(parseThresholdInput('0')).toBe(0);
    expect(parseThresholdInput('10000')).toBe(10000);
    expect(parseThresholdInput('10001')).toBeUndefined();
    expect(parseThresholdInput('-1')).toBeUndefined();
    expect(parseThresholdInput('2.5')).toBeUndefined();
  });

  it('words the status', () => {
    const s = parseLastCallStatus({
      active: true, remaining: 8, threshold: 10, threshold_source: 'platform', event_threshold: null, org_threshold: null,
      platform_threshold: 10, primary_source: 'eventbrite', primary_url: 'https://www.eventbrite.com/e/1', can_manage: true,
    })!;
    expect(s.active && s.primary === 'eventbrite' && s.primaryUrl === 'https://www.eventbrite.com/e/1').toBe(true);
    expect(lastCallText(s)).toBe('Last call: selling only on Eventbrite (8 left)');
    expect(thresholdLine(s)).toContain('At 10 tickets left (the default), only Eventbrite sells');
    expect(thresholdLine({ ...s, threshold: 0 })).toContain('off');
    expect(parseLastCallStatus({ primary_source: 'x', primary_url: 'http://bad' })).toMatchObject({ primary: 'exos', primaryUrl: null, threshold: 10 });
    expect(parseLastCallStatus(null)).toBeNull();
  });

  it('tells the storefront when to send buyers elsewhere', () => {
    expect(sellsElsewhere(parsePublicSale({ last_call: true, sells_on: 'luma', sells_on_url: 'https://luma.com/x' }))).toBe(true);
    expect(sellsElsewhere(parsePublicSale({ last_call: true, sells_on: 'exos', sells_on_url: null }))).toBe(false);
    expect(sellsElsewhere(parsePublicSale({ last_call: false, sells_on: 'exos' }))).toBe(false);
    expect(sellsElsewhere(null)).toBe(false);
    expect(parsePublicSale({ last_call: true, sells_on: 'eventbrite', sells_on_url: 'javascript:alert(1)' })?.sellsOnUrl).toBeNull();
  });
});

describe('the resale opt-in (mig 20261029090000)', () => {
  it('carries the version the server checks', () => {
    expect(RESALE_CONSENT_VERSION).toBe('2026-10-29');
  });

  it('words where an event stands', () => {
    const base = {
      max_capacity: 120, capacity_bounded: true, free_tier_max_capacity: 150, free_tier: true, consent_required: true,
      consent_version: '2026-10-29', consent: null, last_revoked: null, resale_unlocked: false, locked_reason: 'x', can_manage: true,
    };
    expect(salesRulesLine(parseSalesRules(base)!)).toMatch(/^Free tier: a max capacity of 120/);
    expect(salesRulesLine(parseSalesRules({ ...base, free_tier: false, capacity_bounded: false, max_capacity: 100 })!))
      .toMatch(/needs a max capacity over 150/);
    const big = { ...base, max_capacity: 300, free_tier: false };
    expect(salesRulesLine(parseSalesRules(big)!)).toBe('Resale is off until you opt in below.');
    expect(salesRulesLine(parseSalesRules({ ...big, last_revoked: { revoked_at: 'x', reason: 'capacity_dropped' } })!))
      .toMatch(/dropped to the free tier/);
    const on = parseSalesRules({ ...big, resale_unlocked: true, consent: { given_at: '2026-10-29T10:00:00Z', given_by_email: 'a@b.c', version: '2026-10-29', max_capacity_at_consent: 300 } })!;
    expect(on.consent?.givenByEmail).toBe('a@b.c');
    expect(salesRulesLine(on)).toBe('Resale is on for this event.');
  });
});
