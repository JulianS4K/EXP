import { describe, expect, it } from 'vitest';
import { timingProblem } from './eventTiming';

const NOW = Date.UTC(2026, 9, 20, 12);
const H = 3600_000;

describe('timingProblem (Create + Edit event)', () => {
  it('accepts doors ≤ start < end in the future', () => {
    expect(timingProblem({ startMs: NOW + 24 * H, doorsMs: NOW + 23 * H, endMs: NOW + 27 * H }, NOW)).toBeNull();
    expect(timingProblem({ startMs: NOW + 24 * H, doorsMs: NOW + 24 * H }, NOW)).toBeNull();
    expect(timingProblem({ startMs: NOW + 24 * H }, NOW)).toBeNull();
  });

  it('needs a start', () => {
    expect(timingProblem({ startMs: null }, NOW)).toBe('Please set the show start time.');
    expect(timingProblem({ startMs: NaN }, NOW)).toBe('Please set the show start time.');
  });

  it('refuses doors after the start and an end at or before it', () => {
    expect(timingProblem({ startMs: NOW + 24 * H, doorsMs: NOW + 25 * H }, NOW)).toBe('Doors must open before the show starts.');
    expect(timingProblem({ startMs: NOW + 24 * H, endMs: NOW + 23 * H }, NOW)).toBe('Show end must be after the show start.');
    expect(timingProblem({ startMs: NOW + 24 * H, endMs: NOW + 24 * H }, NOW)).toBe('Show end must be after the show start.');
  });

  it('refuses a start in the past', () => {
    expect(timingProblem({ startMs: NOW - H }, NOW)).toBe('Show start time must be in the future.');
  });

  it('Edit: an event already past still saves while its start is unchanged', () => {
    expect(timingProblem({ startMs: NOW - 48 * H, savedStartMs: NOW - 48 * H, endMs: NOW - 45 * H }, NOW)).toBeNull();
    // ...but moving it to another past time is refused, and ordering still applies.
    expect(timingProblem({ startMs: NOW - 24 * H, savedStartMs: NOW - 48 * H }, NOW)).toBe('Show start time must be in the future.');
    expect(timingProblem({ startMs: NOW - 48 * H, savedStartMs: NOW - 48 * H, endMs: NOW - 50 * H }, NOW))
      .toBe('Show end must be after the show start.');
  });
});
