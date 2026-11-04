// Event and fan recommendations (mig 20261102140000): the score and its
// explanation. The database ranks (_exos_rec_score / _exos_rec_fan_score,
// which must use these same numbers: test_order_edits_recs.sql R1 and
// src/lib/recommendations.test.ts pin both); this file explains a row and
// lets the dashboard re-sort a page without asking again. Deterministic:
// integers only, ties broken by date then id.
// Pure, no imports.

export const REC_WEIGHTS = {
  artist: 50,
  venue: 40,
  series: 30,
  genre: 15,
  tag: 10,
  coBuyer: 5,
  /** At most, for an event on the same day; falls off over the window. */
  proximity: 20,
} as const;

export const REC_CAPS = { artist: 3, genre: 4, tag: 5, coBuyer: 10 } as const;

/** Days over which date proximity falls to 0: similar events / a fan's events. */
export const REC_WINDOW_DAYS = { similar: 30, fan: 60 } as const;

/** A fan for an event: past events matched each way count up to this many. */
export const FAN_REC_CAP = 3;

export interface RecSignals {
  shared_artists: number;
  same_venue: boolean;
  same_series: boolean;
  shared_genres: number;
  shared_tags: number;
  co_buyers: number;
  days_apart?: number | null;
}

export interface FanRecSignals {
  artist_events: number;
  venue_events: number;
  series_events: number;
  genre_events: number;
  tag_events: number;
}

const clamp = (n: unknown, max: number) => Math.min(Math.max(Math.trunc(Number(n) || 0), 0), max);

/** The points before date proximity; 0 means nothing in common. */
export function recBase(s: RecSignals): number {
  return REC_WEIGHTS.artist * clamp(s.shared_artists, REC_CAPS.artist)
    + (s.same_venue ? REC_WEIGHTS.venue : 0)
    + (s.same_series ? REC_WEIGHTS.series : 0)
    + REC_WEIGHTS.genre * clamp(s.shared_genres, REC_CAPS.genre)
    + REC_WEIGHTS.tag * clamp(s.shared_tags, REC_CAPS.tag)
    + REC_WEIGHTS.coBuyer * clamp(s.co_buyers, REC_CAPS.coBuyer);
}

/** Date proximity: full points on the same day, none past the window. */
export function proximityPoints(days: number | null | undefined, windowDays: number): number {
  if (days == null || !Number.isFinite(days) || windowDays <= 0) return 0;
  return Math.max(0, REC_WEIGHTS.proximity - Math.floor((Math.abs(days) * REC_WEIGHTS.proximity) / windowDays));
}

/** The whole score, as _exos_rec_score computes it. Proximity only counts with another signal. */
export function recScore(s: RecSignals, days: number | null | undefined, windowDays: number): number {
  const base = recBase(s);
  return base === 0 ? 0 : base + proximityPoints(days, windowDays);
}

/** A fan's score for an event, as _exos_rec_fan_score computes it. */
export function fanRecScore(s: FanRecSignals): number {
  return REC_WEIGHTS.artist * clamp(s.artist_events, FAN_REC_CAP)
    + REC_WEIGHTS.venue * clamp(s.venue_events, FAN_REC_CAP)
    + REC_WEIGHTS.series * clamp(s.series_events, FAN_REC_CAP)
    + REC_WEIGHTS.genre * clamp(s.genre_events, FAN_REC_CAP)
    + REC_WEIGHTS.tag * clamp(s.tag_events, FAN_REC_CAP);
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** Why an event was recommended, strongest first. */
export function recReasons(s: RecSignals): string[] {
  const out: string[] = [];
  if (s.shared_artists > 0) out.push(`${plural(s.shared_artists, 'shared artist')}`);
  if (s.same_venue) out.push('same venue');
  if (s.same_series) out.push('same series');
  if (s.shared_genres > 0) out.push(`${plural(s.shared_genres, 'shared genre')}`);
  if (s.shared_tags > 0) out.push(`${plural(s.shared_tags, 'shared tag')}`);
  if (s.co_buyers > 0) out.push(`${plural(s.co_buyers, 'buyer')} of both`);
  if (s.days_apart != null && out.length > 0) out.push(s.days_apart === 0 ? 'same day' : `${plural(s.days_apart, 'day')} apart`);
  return out;
}

/** Why a fan was recommended for an event. */
export function fanRecReasons(s: FanRecSignals): string[] {
  const out: string[] = [];
  if (s.artist_events > 0) out.push(`saw the artist at ${plural(s.artist_events, 'show')}`);
  if (s.venue_events > 0) out.push(`${plural(s.venue_events, 'show')} at this venue`);
  if (s.series_events > 0) out.push(`${plural(s.series_events, 'date')} of the series`);
  if (s.genre_events > 0) out.push(`${plural(s.genre_events, 'show')} in the genre`);
  if (s.tag_events > 0) out.push(`${plural(s.tag_events, 'show')} with a shared tag`);
  return out;
}

/** ?scope=org (default for similars) | all (other organizations' public events too). */
export function parseRecScope(v: string | null, fallback: 'org' | 'all'): 'org' | 'all' {
  if (v === null || v === '') return fallback;
  if (v === 'org' || v === 'all') return v;
  throw new Error('scope must be org or all.');
}

export interface RankedEvent {
  id: string;
  score: number;
  starts_at: string;
}

/** The database's order: score high to low, then the sooner event, then id. */
export function compareRanked(a: RankedEvent, b: RankedEvent): number {
  return b.score - a.score || a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id);
}
