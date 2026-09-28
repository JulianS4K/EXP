import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { voucherUnitPrice } from '../../supabase/functions/_shared/pricing.ts';
import { quotaInputError } from './quotas';
import { discountLabel } from '../components/VoucherField';

describe('voucherUnitPrice (shared by exos-checkout and the event page)', () => {
  it('leaves the price alone without a rule', () => {
    expect(voucherUnitPrice(40, null)).toBe(40);
    expect(voucherUnitPrice(40, {})).toBe(40);
  });
  it('pins a set price', () => {
    expect(voucherUnitPrice(40, { overridePrice: 25 })).toBe(25);
    expect(voucherUnitPrice(40, { overridePrice: 0 })).toBe(0);
  });
  it('takes a percent off, rounded to the cent', () => {
    expect(voucherUnitPrice(40, { discountPercent: 20 })).toBe(32);
    expect(voucherUnitPrice(10.05, { discountPercent: 15 })).toBe(8.54); // 1005 * 0.85 = 854.25
    expect(voucherUnitPrice(19.99, { discountPercent: 33.33 })).toBe(13.33);
  });
  it('takes an amount off, never below 0', () => {
    expect(voucherUnitPrice(40, { discountAmount: 5 })).toBe(35);
    expect(voucherUnitPrice(4, { discountAmount: 5 })).toBe(0);
  });
  it('ignores out-of-range rules the database would refuse', () => {
    expect(voucherUnitPrice(40, { discountPercent: 0 })).toBe(40);
    expect(voucherUnitPrice(40, { discountPercent: 100 })).toBe(40);
    expect(voucherUnitPrice(40, { discountAmount: -3 })).toBe(40);
  });
  it('a pinned price wins over a discount', () => {
    expect(voucherUnitPrice(40, { overridePrice: 30, discountPercent: 50 })).toBe(30);
  });
  it('works in whole cents for every percent', () => {
    for (let p = 1; p < 100; p++) {
      const cents = voucherUnitPrice(12.34, { discountPercent: p }) * 100;
      expect(Math.abs(cents - Math.round(cents))).toBeLessThan(1e-6);
    }
  });
});

describe('discountLabel', () => {
  it('reads the rule', () => {
    expect(discountLabel({ discountPercent: 20 })).toBe('20% off');
    expect(discountLabel({ discountPercent: 12.5 })).toBe('12.5% off');
    expect(discountLabel({ discountAmount: 5 })).toBe('$5.00 off');
    expect(discountLabel({})).toBeNull();
  });
});

describe('quotaInputError', () => {
  const ok = { name: 'Standing', size: 400, closed: false, tierIds: ['t1'] };
  it('accepts a named quota with ticket types', () => {
    expect(quotaInputError(ok)).toBeNull();
    expect(quotaInputError({ ...ok, size: null })).toBeNull();
    expect(quotaInputError({ ...ok, size: 0 })).toBeNull();
  });
  it('refuses a blank name, a bad size or no ticket types', () => {
    expect(quotaInputError({ ...ok, name: '  ' })).toMatch(/name/);
    expect(quotaInputError({ ...ok, size: -1 })).toMatch(/Size/);
    expect(quotaInputError({ ...ok, size: 2.5 })).toMatch(/Size/);
    expect(quotaInputError({ ...ok, tierIds: [] })).toMatch(/ticket type/);
  });
});
