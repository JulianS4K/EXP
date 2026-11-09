import { describe, expect, it } from 'vitest';
import {
  compareRanked, fanRecReasons, fanRecScore, parseRecEvent, parseRecFan, parseRecScope, proximityPoints, recBase,
  recReasons, recScore, REC_CAPS, REC_WEIGHTS, viewRecEvents, viewRecFans, type RecSignals,
} from './recommendations';

const none: RecSignals = { shared_artists: 0, same_venue: false, same_series: false, shared_genres: 0, shared_tags: 0, co_buyers: 0 };

describe('recommendation score (same numbers as _exos_rec_score, test_order_edits_recs.sql R1)', () => {
  it('pins the weights and caps', () => {
    expect(REC_WEIGHTS).toEqual({ artist: 50, venue: 40, series: 30, genre: 15, tag: 10, coBuyer: 5, proximity: 20 });
    expect(REC_CAPS).toEqual({ artist: 3, genre: 4, tag: 5, coBuyer: 10 });
  });

  it('matches the SQL cases', () => {
    expect(recScore({ ...none, shared_artists: 1, same_venue: true, shared_genres: 1 }, 0, 30)).toBe(125);
    expect(recScore({ shared_artists: 5, same_venue: true, same_series: true, shared_genres: 9, shared_tags: 9, co_buyers: 99 }, 0, 30))
      .toBe(150 + 40 + 30 + 60 + 50 + 50 + 20);
    expect(recScore(none, 0, 30)).toBe(0);
    expect(recScore({ ...none, shared_tags: 1 }, 15, 30)).toBe(20);
    expect(recScore({ ...none, shared_tags: 1 }, 45, 30)).toBe(10);
    expect(recScore({ ...none, shared_artists: 1 }, null, 30)).toBe(50);
    expect(fanRecScore({ artist_events: 1, venue_events: 2, series_events: 0, genre_events: 4, tag_events: 1 })).toBe(50 + 80 + 45 + 10);
  });

  it('the harness fixture: 1 artist, venue, 1 genre, 1 co-buyer, 5 days apart = 127', () => {
    expect(recScore({ ...none, shared_artists: 1, same_venue: true, shared_genres: 1, co_buyers: 1 }, 5.04, 30)).toBe(127);
  });

  it('date proximity alone never recommends, and falls off symmetrically', () => {
    expect(recScore(none, 0, 30)).toBe(0);
    expect(proximityPoints(-7, 30)).toBe(proximityPoints(7, 30));
    expect(proximityPoints(30, 30)).toBe(0);
    expect(proximityPoints(NaN, 30)).toBe(0);
    expect(proximityPoints(1, 0)).toBe(0);
  });

  it('ignores junk counts (negative, fractional, non-numbers)', () => {
    expect(recBase({ ...none, shared_artists: -2, shared_tags: 1.9, co_buyers: Number('x') })).toBe(10);
  });

  it('is deterministic: ties go to the sooner event, then the id', () => {
    const rows = [
      { id: 'b', score: 50, starts_at: '2026-11-10' },
      { id: 'a', score: 50, starts_at: '2026-11-10' },
      { id: 'c', score: 50, starts_at: '2026-11-09' },
      { id: 'd', score: 90, starts_at: '2026-12-01' },
    ];
    expect([...rows].sort(compareRanked).map((r) => r.id)).toEqual(['d', 'c', 'a', 'b']);
    expect([...rows].reverse().sort(compareRanked).map((r) => r.id)).toEqual(['d', 'c', 'a', 'b']);
  });
});

describe('explanations', () => {
  it('names each signal, strongest first, and the date only with another signal', () => {
    expect(recReasons({ ...none, shared_artists: 2, same_venue: true, co_buyers: 1, days_apart: 5 }))
      .toEqual(['2 shared artists', 'same venue', '1 buyer of both', '5 days apart']);
    expect(recReasons({ ...none, days_apart: 0 })).toEqual([]);
    expect(recReasons({ ...none, shared_tags: 1, days_apart: 0 })).toEqual(['1 shared tag', 'same day']);
    expect(fanRecReasons({ artist_events: 2, venue_events: 0, series_events: 1, genre_events: 0, tag_events: 0 }))
      .toEqual(['saw the artist at 2 shows', '1 date of the series']);
  });

  it('scope is org or all', () => {
    expect(parseRecScope(null, 'org')).toBe('org');
    expect(parseRecScope('', 'all')).toBe('all');
    expect(parseRecScope('all', 'org')).toBe('all');
    expect(() => parseRecScope('everyone', 'org')).toThrow(/org or all/);
  });
});

describe('dashboard tables', () => {
  const ev = (id: string, score: number, startsAt: string, sameOrg: boolean, name = id) =>
    parseRecEvent({ id, name, starts_at: startsAt, score, same_org: sameOrg, org: { name: 'O' }, signals: { shared_artists: 1 } });

  it('parses an API / RPC row and explains it', () => {
    const e = parseRecEvent({ id: 'x', name: 'N', starts_at: '2026-11-07', score: '127', same_org: true, org: { name: 'Org', slug: 'org' },
      signals: { shared_artists: 1, same_venue: true, days_apart: 5 } });
    expect(e.score).toBe(127);
    expect(e.reasons).toEqual(['1 shared artist', 'same venue', '5 days apart']);
    expect(parseRecFan({ id: 'f', email: 'a@x.com', first_name: 'A', signals: { artist_events: 1 } }))
      .toMatchObject({ name: 'A', score: 50, reasons: ['saw the artist at 1 show'] });
  });

  it('filters by org and sorts by score, date or name', () => {
    const rows = [ev('a', 50, '2026-11-12', true, 'Zed'), ev('b', 90, '2026-11-20', false, 'Amy'), ev('c', 50, '2026-11-10', true, 'Max')];
    expect(viewRecEvents(rows, 'all', 'score').map((r) => r.id)).toEqual(['b', 'c', 'a']);
    expect(viewRecEvents(rows, 'org', 'score').map((r) => r.id)).toEqual(['c', 'a']);
    expect(viewRecEvents(rows, 'other', 'date').map((r) => r.id)).toEqual(['b']);
    expect(viewRecEvents(rows, 'all', 'name').map((r) => r.id)).toEqual(['b', 'c', 'a']);
  });

  it('searches and sorts fans', () => {
    const fans = [
      parseRecFan({ id: '1', email: 'zoe@x.com', score: 50, last_order_at: '2026-01-01' }),
      parseRecFan({ id: '2', email: 'amy@x.com', first_name: 'Amy', score: 90, last_order_at: '2025-01-01' }),
      parseRecFan({ id: '3', email: 'bo@x.com', score: 50, last_order_at: '2026-06-01' }),
    ];
    expect(viewRecFans(fans, '', 'score').map((f) => f.id)).toEqual(['2', '3', '1']);
    expect(viewRecFans(fans, '', 'recent').map((f) => f.id)).toEqual(['3', '1', '2']);
    expect(viewRecFans(fans, 'AMY', 'email').map((f) => f.id)).toEqual(['2']);
  });
});
