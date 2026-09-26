import { describe, expect, it } from 'vitest';
import { autoTicketType } from './tierType';

describe('autoTicketType', () => {
  it('turns a $0 paid tier free', () => {
    expect(autoTicketType('paid', '0')).toBe('free');
    expect(autoTicketType('paid', 0)).toBe('free');
    expect(autoTicketType('paid', '0.00')).toBe('free');
  });
  it('turns a priced free tier paid', () => {
    expect(autoTicketType('free', '25')).toBe('paid');
  });
  it('leaves donation tiers and blank prices alone', () => {
    expect(autoTicketType('donation', '0')).toBe('donation');
    expect(autoTicketType('paid', '')).toBe('paid');
    expect(autoTicketType('free', '')).toBe('free');
    expect(autoTicketType('paid', 'abc')).toBe('paid');
  });
  it('keeps a priced paid tier paid', () => {
    expect(autoTicketType('paid', '10')).toBe('paid');
  });
});
