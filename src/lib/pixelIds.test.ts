import { describe, expect, it } from 'vitest';
import { cleanPixelId, invalidPixelKeys, isValidPixelId, pixelIdExample, xEventMatchesPixel, type PixelKey } from './pixelIds';

describe('pixel id formats', () => {
  const keys: PixelKey[] = ['meta', 'ga4', 'tiktok', 'reddit', 'snap', 'x', 'xViewContent', 'xInitiateCheckout', 'xPurchase'];

  it.each(keys)('accepts its own example and an empty value (%s)', (k) => {
    expect(isValidPixelId(k, pixelIdExample(k))).toBe(true);
    expect(isValidPixelId(k, '')).toBe(true);
    expect(isValidPixelId(k, undefined)).toBe(true);
  });

  it.each([
    ['meta', 'abc123'],
    ['ga4', 'UA-12345-1'],
    ['ga4', 'g-abc123'],
    ['tiktok', 'C4AB"CD'],
    ['reddit', 'b2_abc123'],
    ['reddit', 'a2_'],
    ['snap', 'not-a-uuid'],
    ['x', 'tw-o8z6j-o8z21'],
    ['xPurchase', 'o8z21'],
    ['xPurchase', 'tw-o8z6j'],
  ] as [PixelKey, string][])('rejects %s = %s', (k, v) => {
    expect(isValidPixelId(k, v)).toBe(false);
    expect(cleanPixelId(k, v)).toBeUndefined();
  });

  it('trims before checking', () => {
    expect(cleanPixelId('reddit', '  t2_abc123 ')).toBe('t2_abc123');
    expect(cleanPixelId('snap', 42)).toBeUndefined();
  });

  it('lists the malformed keys', () => {
    expect(invalidPixelKeys({ meta: '123456789012345', ga4: 'nope', reddit: 'a2_ok123', x: 'tw-a-b' })).toEqual(['ga4', 'x']);
    expect(invalidPixelKeys(undefined)).toEqual([]);
  });

  it('checks that an X event belongs to the X pixel', () => {
    expect(xEventMatchesPixel('o8z6j', 'tw-o8z6j-o8z21')).toBe(true);
    expect(xEventMatchesPixel('O8Z6J', 'tw-o8z6j-o8z21')).toBe(true);
    expect(xEventMatchesPixel('abcde', 'tw-o8z6j-o8z21')).toBe(false);
    expect(xEventMatchesPixel(undefined, 'tw-o8z6j-o8z21')).toBe(true);
  });
});
