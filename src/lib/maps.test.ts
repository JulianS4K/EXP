import { describe, expect, it } from 'vitest';
import { directionsUrl, embedUrl, venueQuery } from './maps';

describe('venueQuery', () => {
  it('joins the venue name and address parts', () => {
    expect(venueQuery('Elsewhere', { street: '599 Johnson Ave', city: 'Brooklyn', region: 'NY', postal: '11237' }))
      .toBe('Elsewhere, 599 Johnson Ave, Brooklyn, NY, 11237');
  });
  it('uses the name alone when there is no address', () => {
    expect(venueQuery('Brooklyn Steel')).toBe('Brooklyn Steel');
  });
  it('returns null for nothing mappable', () => {
    expect(venueQuery('')).toBeNull();
    expect(venueQuery('TBA')).toBeNull();
    expect(venueQuery('Secret location', {})).toBeNull();
    expect(venueQuery(undefined, { city: ' ' })).toBeNull();
  });
  it('still maps a secret-named venue once an address is given', () => {
    expect(venueQuery('TBA', { city: 'Queens' })).toBe('TBA, Queens');
  });
});

describe('map URLs', () => {
  it('encodes the query', () => {
    expect(directionsUrl('Le Poisson Rouge, 158 Bleecker St')).toBe(
      'https://www.google.com/maps/dir/?api=1&destination=Le%20Poisson%20Rouge%2C%20158%20Bleecker%20St',
    );
    expect(embedUrl('A&B', 'k 1')).toBe('https://www.google.com/maps/embed/v1/place?key=k%201&q=A%26B');
  });
});
