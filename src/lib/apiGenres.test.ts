// Genre filters and the buyer-location / genre routes (mig 20261106140000).
import { describe, expect, it } from 'vitest';
import { genreFilter, genreKey, GenreParamError } from '../../supabase/functions/_shared/api/genres.ts';
import { PUBLIC_READS, PublicParamError, publicReadArgs } from '../../supabase/functions/_shared/api/publicDiscovery.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';
import { GeoGenreError, reportLimit, reportSince } from '../../supabase/functions/_shared/api/buyerLocations.ts';

const q = (s: string) => new URLSearchParams(s);

describe('genreKey', () => {
  it('compares any case and spacing, like exos_genre_key', () => {
    expect(genreKey('  Hip   Hop ')).toBe('hip hop');
    expect(genreKey('ＨＯＵＳＥ')).toBe('house'); // NFKC
    expect(genreKey('   ')).toBeNull();
    expect(genreKey(null)).toBeNull();
    expect(genreKey('x'.repeat(60))).toHaveLength(40);
  });
});

describe('genreFilter', () => {
  it('reads genre, genres (comma or repeated) and genres[] together', () => {
    expect(genreFilter(q(''))).toBeNull();
    expect(genreFilter(q('genre=House'))).toEqual(['house']);
    expect(genreFilter(q('genres=house,Techno&genres=jazz&genres[]=Hip%20Hop&genre=HOUSE'))).toEqual(['house', 'techno', 'jazz', 'hip hop']);
  });
  it('refuses an empty filter and more than 20', () => {
    expect(() => genreFilter(q('genre=%20,%20'))).toThrow(GenreParamError);
    const many = Array.from({ length: 21 }, (_, i) => `g${i}`).join(',');
    expect(() => genreFilter(q(`genres=${many}`))).toThrow(/at most 20/);
  });
});

describe('public discovery', () => {
  it('passes genres to events.list as keys', () => {
    expect(publicReadArgs('public-discovery-events', q('genre=House&genres=techno'))).toEqual({ genres: ['house', 'techno'] });
    expect(() => publicReadArgs('public-discovery-events', q('genre=,'))).toThrow(PublicParamError);
  });
  it('lists genres, optionally for one organizer', () => {
    expect(PUBLIC_READS['public-discovery-genres']).toEqual({ action: 'genres.list' });
    expect(publicReadArgs('public-discovery-genres', q(''))).toEqual({});
    expect(publicReadArgs('public-discovery-genres', q('venue_id=blue-room'))).toEqual({ venue: 'blue-room' });
    expect(() => publicReadArgs('public-discovery-genres', q('venue_id=Not%20A%20Slug'))).toThrow(PublicParamError);
  });
});

describe('routes', () => {
  it('match with the existing scopes', () => {
    expect(matchRoute('GET', '/events/3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14/buyer-locations')?.route)
      .toMatchObject({ id: 'get-event-buyer-locations', scope: 'orders:read', auth: 'api_key' });
    expect(matchRoute('GET', '/buyer-locations')?.route).toMatchObject({ id: 'get-buyer-locations', scope: 'orders:read' });
    expect(matchRoute('GET', '/genres')?.route).toMatchObject({ id: 'list-genres', scope: 'events:read' });
    expect(matchRoute('GET', '/public/discovery/genres')?.route).toMatchObject({ id: 'public-discovery-genres', auth: 'public', scope: null });
    // The discovery event route still answers its own path.
    expect(matchRoute('GET', '/public/discovery/events/genres')?.route.id).toBe('public-discovery-event');
  });
});

describe('report parameters', () => {
  it('limit 1-100, default 10', () => {
    expect(reportLimit(q(''))).toBe(10);
    expect(reportLimit(q('limit=100'))).toBe(100);
    for (const bad of ['0', '101', '-1', '5.5', 'x']) expect(() => reportLimit(q(`limit=${bad}`))).toThrow(GeoGenreError);
  });
  it('since is an ISO date or time', () => {
    expect(reportSince(q(''))).toBeNull();
    expect(reportSince(q('since=2026-10-01'))).toBe('2026-10-01T00:00:00.000Z');
    expect(() => reportSince(q('since=last%20week'))).toThrow(/ISO 8601/);
  });
});
