import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import {
  ga4Items,
  initiateCheckoutParams,
  isCheckoutSessionId,
  newPixelEventId,
  purchaseFromCheckout,
  type PendingCheckout,
} from './purchasePixel';
import { ga4EventName } from './pixels';

const pending: PendingCheckout = {
  eventId: 'ev-1',
  orgId: 'org-1',
  title: 'Night Shift',
  currency: 'USD',
  quantity: 2,
  value: 48.5,
  at: 0,
};

describe('purchase pixel after a paid checkout', () => {
  it('uses the real charged total from the session row', () => {
    const out = purchaseFromCheckout(
      { event_id: 'ev-1', org_id: 'org-1', quantity: 2, amount_cents: 5317, currency: 'usd' },
      pending,
    );
    expect(out).toEqual({
      orgId: 'org-1',
      params: {
        content_ids: ['ev-1'], content_name: 'Night Shift', value: 53.17, currency: 'USD', num_items: 2,
        // GA4 items: one line, unit price = total / quantity.
        items: [{ item_id: 'ev-1', item_name: 'Night Shift', quantity: 2, price: 26.59 }],
      },
    });
  });

  it('falls back to the pre-redirect estimate for guests (no readable row)', () => {
    expect(purchaseFromCheckout(null, pending)?.params).toMatchObject({ value: 48.5, currency: 'USD', num_items: 2 });
  });

  it('ignores a stash from a different event', () => {
    const out = purchaseFromCheckout(
      { event_id: 'ev-2', org_id: 'org-2', quantity: 1, amount_cents: 1000, currency: 'eur' },
      pending,
    );
    expect(out?.orgId).toBe('org-2');
    expect(out?.params).not.toHaveProperty('content_name');
    expect(out?.params).toMatchObject({ value: 10, currency: 'EUR' });
  });

  it('fires nothing when the org is unknown', () => {
    expect(purchaseFromCheckout(null, null)).toBeNull();
  });

  it('only accepts Stripe checkout session ids', () => {
    expect(isCheckoutSessionId('cs_test_a1B2c3D4e5')).toBe(true);
    expect(isCheckoutSessionId('{CHECKOUT_SESSION_ID}')).toBe(false);
    expect(isCheckoutSessionId(null)).toBe(false);
  });
});

describe('InitiateCheckout and GA4 items', () => {
  it('builds InitiateCheckout params from the pre-redirect stash', () => {
    const { at: _at, ...p } = pending;
    expect(initiateCheckoutParams(p)).toEqual({
      content_ids: ['ev-1'], content_name: 'Night Shift', currency: 'USD', num_items: 2, value: 48.5,
      items: [{ item_id: 'ev-1', item_name: 'Night Shift', quantity: 2, price: 24.25 }],
    });
    const { value: _v, ...noValue } = p;
    expect(initiateCheckoutParams(noValue).items).toEqual([{ item_id: 'ev-1', item_name: 'Night Shift', quantity: 2 }]);
  });

  it('gives each checkout its own event id', () => {
    const a = newPixelEventId();
    expect(a).toMatch(/^[A-Za-z0-9_-]{8,}$/);
    expect(newPixelEventId()).not.toBe(a);
  });

  it('keeps a free order\'s item at price 0 and never divides by zero', () => {
    expect(ga4Items('ev', 'T', 3, 0)).toEqual([{ item_id: 'ev', item_name: 'T', quantity: 3, price: 0 }]);
    expect(ga4Items('ev', undefined, 0, 10)).toEqual([{ item_id: 'ev', quantity: 1 }]);
  });

  it('maps InitiateCheckout to GA4 begin_checkout', () => {
    expect(ga4EventName('InitiateCheckout')).toBe('begin_checkout');
    expect(ga4EventName('Purchase')).toBe('purchase');
    expect(ga4EventName('ViewContent')).toBe('viewcontent');
  });
});
