import { describe, expect, it } from 'vitest';
import {
  checkoutPaymentMethodTypes,
  DELAYED_METHODS,
  isPaymentMethodTypeRejection,
  linkEnabled,
} from '../../supabase/functions/_shared/checkoutMethods.ts';

describe('checkout payment methods (exos-checkout)', () => {
  it('offers card + Link by default, Cash App Pay when switched on', () => {
    expect(checkoutPaymentMethodTypes({ cashApp: false, link: true })).toEqual(['card', 'link']);
    expect(checkoutPaymentMethodTypes({ cashApp: true, link: true })).toEqual(['card', 'link', 'cashapp']);
    expect(checkoutPaymentMethodTypes({ cashApp: false, link: false })).toEqual(['card']);
    expect(checkoutPaymentMethodTypes({ cashApp: true, link: false })).toEqual(['card', 'cashapp']);
  });

  it('never offers a delayed method (ACH would also turn Link bank payments into ACH)', () => {
    for (const cashApp of [true, false]) {
      for (const link of [true, false]) {
        const types: string[] = checkoutPaymentMethodTypes({ cashApp, link });
        expect(types[0]).toBe('card'); // Stripe needs card next to link
        for (const t of types) expect(DELAYED_METHODS).not.toContain(t);
        expect(types).not.toContain('us_bank_account');
      }
    }
  });

  it('Link is on unless EXOS_STRIPE_LINK=off', () => {
    expect(linkEnabled(() => undefined)).toBe(true);
    expect(linkEnabled(() => 'on')).toBe(true);
    expect(linkEnabled(() => ' OFF ')).toBe(false);
    expect(linkEnabled((k) => (k === 'EXOS_STRIPE_LINK' ? 'off' : 'on'))).toBe(false);
  });

  it('retries without Link only when Stripe refused a payment method type', () => {
    expect(isPaymentMethodTypeRejection({ type: 'StripeInvalidRequestError', param: 'payment_method_types' })).toBe(true);
    expect(isPaymentMethodTypeRejection({ type: 'StripeInvalidRequestError', raw: { param: 'payment_method_types[1]' } })).toBe(true);
    expect(isPaymentMethodTypeRejection({ type: 'StripeInvalidRequestError', param: 'line_items' })).toBe(false);
    expect(isPaymentMethodTypeRejection({ type: 'StripeConnectionError' })).toBe(false);
    expect(isPaymentMethodTypeRejection(new Error('boom'))).toBe(false);
    expect(isPaymentMethodTypeRejection(null)).toBe(false);
  });
});
