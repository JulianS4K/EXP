import { describe, expect, it } from 'vitest';
import { hasPaidPrice, paidNeedsConnect } from './payments';

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

describe('paidNeedsConnect', () => {
  it("warns for priced tiers when the org can't take payments yet", () => {
    expect(paidNeedsConnect([0, 25], false, true)).toBe(true);
  });
  it('stays quiet when connected, unknown, free-only or payments are off platform-wide', () => {
    expect(paidNeedsConnect([25], true, true)).toBe(false);
    expect(paidNeedsConnect([25], null, true)).toBe(false);
    expect(paidNeedsConnect([0, '0'], false, true)).toBe(false);
    expect(paidNeedsConnect([25], false, false)).toBe(false);
  });
});
