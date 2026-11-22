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

// The organizer dashboard's genre filter (claude/exos-dice-leftovers): the
// genres of the organizer's own loaded events, no remote list.
describe('dashboard genre filter', () => {
  const events = [
    { genres: ['Hip Hop', 'Jazz'] }, { genres: ['hip  hop'] }, { genres: [], category: 'Comedy' }, { genres: null, category: null },
  ];
  it('offers each genre once, by key, the first spelling as the label', () => {
    const opts = genreChips([], events, 50);
    expect(opts.map((g) => [g.key, g.label])).toEqual([['hip hop', 'Hip Hop'], ['jazz', 'Jazz'], ['comedy', 'Comedy']]);
  });
  it('filters the list the same way', () => {
    expect(events.filter((e) => matchesGenre(e, 'hip hop'))).toHaveLength(2);
    expect(events.filter((e) => matchesGenre(e, 'comedy'))).toHaveLength(1);
    expect(events.filter((e) => matchesGenre(e, null))).toHaveLength(4);
  });
});
