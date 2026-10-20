import { describe, expect, it } from 'vitest';
import { backFallback, hasInAppHistory } from './backNav';

describe('back navigation', () => {
  it('goes back only with an in-app page behind', () => {
    expect(hasInAppHistory({ idx: 2, key: 'k' })).toBe(true);
    expect(hasInAppHistory({ idx: 0, key: 'k' })).toBe(false); // opened from a link
    expect(hasInAppHistory(null)).toBe(false);
    expect(hasInAppHistory({})).toBe(false);
  });

  it('falls back to the storefront, else home', () => {
    expect(backFallback('night-owls')).toBe('/o/night-owls');
    expect(backFallback('  ')).toBe('/');
    expect(backFallback(undefined)).toBe('/');
  });
});
