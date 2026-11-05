import { describe, expect, it } from 'vitest';
import { eventGenreKeys, genreChips, matchesGenre, parseGenreList } from './genres';

describe('genre chips', () => {
  it('keys an event by its genres, else its category', () => {
    expect(eventGenreKeys({ genres: ['House', ' house ', 'Hip  Hop'] })).toEqual(['house', 'hip hop']);
    expect(eventGenreKeys({ genres: [], category: 'Comedy' })).toEqual(['comedy']);
    expect(eventGenreKeys({})).toEqual([]);
  });
  it('matches any case; null is everything', () => {
    expect(matchesGenre({ genres: ['TECHNO'] }, 'techno')).toBe(true);
    expect(matchesGenre({ genres: ['Jazz'] }, 'techno')).toBe(false);
    expect(matchesGenre({}, null)).toBe(true);
  });
  it('reads genres.list and drops junk', () => {
    expect(parseGenreList([
      { genre: 'house', name: 'House', events: 3, variants: ['House', 'house'] },
      { genre: '  ', name: 'x' }, null, { genre: 'jazz' },
    ])).toEqual([
      { key: 'house', label: 'House', events: 3, variants: ['House', 'house'] },
      { key: 'jazz', label: 'jazz', events: 0, variants: ['jazz'] },
    ]);
    expect(parseGenreList({ rows: [] })).toEqual([]);
  });
  it('merges remote genres with the loaded events, remote first, capped', () => {
    const remote = parseGenreList([{ genre: 'house', name: 'House', events: 3, variants: ['House'] }]);
    const chips = genreChips(remote, [{ genres: ['house', 'Disco'] }, { category: 'Comedy' }]);
    expect(chips.map((c) => c.key)).toEqual(['house', 'disco', 'comedy']);
    expect(chips[0].variants).toEqual(['House', 'house']);
    expect(remote[0].variants).toEqual(['House']); // not mutated
    expect(genreChips(remote, [{ genres: ['a', 'b', 'c'] }], 2)).toHaveLength(2);
  });
});
