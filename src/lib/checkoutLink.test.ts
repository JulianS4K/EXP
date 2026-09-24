import { describe, expect, it } from 'vitest';
import { buildCheckoutLink, parseCheckoutLink } from './checkoutLink';
import { withAttribution } from './attribution';

const T = '11111111-1111-4111-8111-111111111111';
const A = '22222222-2222-4222-8222-222222222222';

describe('parseCheckoutLink', () => {
  it("reads Meta's encoded products + coupon format", () => {
    const p = parseCheckoutLink(`?products=${T}%3A3%2C${A}%3A1&coupon=SUMMER20&cart_origin=instagram&fbclid=abc_123`);
    expect(p.items).toEqual([{ id: T, quantity: 3 }, { id: A, quantity: 1 }]);
    expect(p.coupon).toBe('SUMMER20');
    expect(p.attribution).toEqual({ cart_origin: 'instagram', fbclid: 'abc_123' });
    expect(p.rejected).toEqual([]);
  });
  it('defaults quantity to 1, merges duplicates, caps at 10', () => {
    const p = parseCheckoutLink(`?products=${T},${T}:4,${T.toUpperCase()}:9`);
    expect(p.items).toEqual([{ id: T, quantity: 10 }]);
  });
  it('drops malformed entries and coupons', () => {
    const p = parseCheckoutLink(`?products=nope:1,${T}:0,${T}:1:2,${A}:2&coupon=<b>`);
    expect(p.items).toEqual([{ id: A, quantity: 2 }]);
    expect(p.coupon).toBeUndefined();
    expect(p.rejected).toHaveLength(4);
  });
  it('keeps promoter and UTM tags, sanitized', () => {
    const p = parseCheckoutLink(`?products=${T}&promoter=dj-kay&utm_source=instagram&utm_medium=story&utm_campaign=%3Cx%3Efall`);
    expect(p.attribution).toEqual({ promoter: 'dj-kay', utm_source: 'instagram', utm_medium: 'story', utm_campaign: 'xfall' });
  });
  it('refuses a bad promoter code and unknown cart_origin', () => {
    const p = parseCheckoutLink(`?products=${T}&promoter=a%20b&cart_origin=tiktok`);
    expect(p.attribution).toEqual({});
  });
  it('handles an empty link', () => {
    expect(parseCheckoutLink('').items).toEqual([]);
  });
});

describe('buildCheckoutLink', () => {
  it('round-trips through the parser', () => {
    const url = buildCheckoutLink('https://exos.example/bridge/checkout', {
      tierId: T, quantity: 2, addons: [{ id: A, quantity: 1 }, { id: A, quantity: 0 }], coupon: 'VIP',
      attribution: { promoter: 'dj-kay', utm_source: 'instagram', utm_medium: 'bio' },
    });
    const p = parseCheckoutLink(new URL(url).search);
    expect(p.items).toEqual([{ id: T, quantity: 2 }, { id: A, quantity: 1 }]);
    expect(p.coupon).toBe('VIP');
    expect(p.attribution).toEqual({ promoter: 'dj-kay', utm_source: 'instagram', utm_medium: 'bio' });
  });
});

describe('withAttribution', () => {
  it('sets params and replaces existing ones', () => {
    expect(withAttribution('https://exos.example/bridge/event/1?utm_source=old', { utm_source: 'instagram', promoter: 'p1' }))
      .toBe('https://exos.example/bridge/event/1?utm_source=instagram&promoter=p1');
  });
});

import { resolveCheckout } from './checkoutLink';

describe('resolveCheckout', () => {
  const E = '33333333-3333-4333-8333-333333333333';
  const E2 = '44444444-4444-4444-8444-444444444444';
  const H = '55555555-5555-4555-8555-555555555555';
  it('finds the event from the tier and keeps its add-ons', () => {
    const r = resolveCheckout(parseCheckoutLink(`?products=${T}:2,${A}:1&coupon=VIP`),
      [{ id: T, event_id: E }], [{ id: A, event_id: E }]);
    expect(r).toEqual({ ok: true, eventId: E, notes: [],
      prefill: { tierId: T, quantity: 2, addons: { [A]: 1 }, coupon: 'VIP' } });
  });
  it('uses a hidden tier only when the link names its event', () => {
    const named = resolveCheckout(parseCheckoutLink(`?event=${E}&products=${H}:1&coupon=VIP`), [], []);
    expect(named.ok && named.prefill.tierId).toBe(H);
    const unnamed = resolveCheckout(parseCheckoutLink(`?products=${H}:1`), [], []);
    expect(unnamed.ok).toBe(false);
  });
  it('drops add-ons and tiers from another event', () => {
    const r = resolveCheckout(parseCheckoutLink(`?products=${T}:1,${H}:1,${A}:1`),
      [{ id: T, event_id: E }, { id: H, event_id: E2 }], [{ id: A, event_id: E2 }]);
    expect(r.ok && r.prefill.addons).toEqual({});
    expect(r.ok && r.notes).toContain('Items from another event were left out.');
  });
  it('refuses an empty link', () => {
    expect(resolveCheckout(parseCheckoutLink(''), [], []).ok).toBe(false);
  });
});
