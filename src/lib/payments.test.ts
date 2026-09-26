import { describe, expect, it } from 'vitest';
import { hasPaidPrice } from './payments';

describe('hasPaidPrice', () => {
  it('spots any priced tier', () => {
    expect(hasPaidPrice([0, '0', '12.50'])).toBe(true);
    expect(hasPaidPrice([5])).toBe(true);
  });
  it('treats free, blank and junk as unpriced', () => {
    expect(hasPaidPrice([0, '0', '', null, undefined, 'abc', -3])).toBe(false);
    expect(hasPaidPrice([])).toBe(false);
  });
});
