import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { isCheckoutSessionId, purchaseFromCheckout, type PendingCheckout } from './purchasePixel';

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
      params: { content_ids: ['ev-1'], content_name: 'Night Shift', value: 53.17, currency: 'USD', num_items: 2 },
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
