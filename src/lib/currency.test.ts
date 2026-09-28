import { describe, expect, it } from 'vitest';
import { CHECKOUT_CURRENCIES, isCheckoutCurrency } from './currency';

describe('checkout currencies', () => {
  it('are two-decimal only (amounts are major x 100)', () => {
    expect(CHECKOUT_CURRENCIES.map((c) => c.code)).not.toContain('JPY');
    expect(isCheckoutCurrency('usd')).toBe(true);
    expect(isCheckoutCurrency(' EUR ')).toBe(true);
    for (const zeroDecimal of ['JPY', 'KRW', 'VND', 'CLP']) expect(isCheckoutCurrency(zeroDecimal)).toBe(false);
    expect(isCheckoutCurrency(null)).toBe(false);
  });
});
