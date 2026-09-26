import { describe, expect, it } from 'vitest';
import { contactHref, hasAccessInfo, normalizeNeeds, parseAccessibility, serializeAccessibility } from './accessibility';

describe('normalizeNeeds', () => {
  it('keeps known needs, deduped and sorted', () => {
    expect(normalizeNeeds(['wheelchair', 'asl', 'wheelchair', 'jetpack', 3])).toEqual(['asl', 'wheelchair']);
    expect(normalizeNeeds(null)).toEqual([]);
  });
});

describe('parseAccessibility', () => {
  it('drops unknown features and empty strings', () => {
    expect(parseAccessibility({ features: ['step_free', 'teleporter', 'step_free'], notes: '  ', contact: ' a@b.co ' }))
      .toEqual({ features: ['step_free'], contact: 'a@b.co' });
    expect(parseAccessibility('nope')).toEqual({});
    expect(parseAccessibility([])).toEqual({});
  });
  it('caps lengths to what the database accepts', () => {
    expect(serializeAccessibility({ notes: 'x'.repeat(600) }).notes).toHaveLength(500);
  });
});

describe('hasAccessInfo', () => {
  it('is false for an empty object', () => {
    expect(hasAccessInfo({})).toBe(false);
    expect(hasAccessInfo(undefined)).toBe(false);
    expect(hasAccessInfo({ features: ['asl'] })).toBe(true);
  });
});

describe('contactHref', () => {
  it('links emails and phone numbers only', () => {
    expect(contactHref('access@venue.com')).toBe('mailto:access@venue.com');
    expect(contactHref('+1 (212) 555-0100')).toBe('tel:+12125550100');
    expect(contactHref('Ask at the box office')).toBeNull();
  });
});
