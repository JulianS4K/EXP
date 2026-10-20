// Reschedule timing (mig 20261021130000); the SQL side is tests/exos/test_festival_p1.sql F4.
import { describe, it, expect } from 'vitest';
import { shiftWithStart, timingProblem } from './rescheduleTiming';

const d = (s: string) => new Date(s);

describe('shiftWithStart', () => {
  it('moves doors and end a week with the start', () => {
    const oldStart = d('2026-11-07T00:00:00Z');
    const newStart = d('2026-11-14T00:00:00Z');
    expect(shiftWithStart(d('2026-11-06T23:00:00Z'), oldStart, newStart)?.toISOString()).toBe('2026-11-13T23:00:00.000Z');
    expect(shiftWithStart(d('2026-11-07T06:30:00Z'), oldStart, newStart)?.toISOString()).toBe('2026-11-14T06:30:00.000Z');
  });
  it('earlier moves too', () => {
    expect(shiftWithStart(d('2026-11-06T23:00:00Z'), d('2026-11-07T00:00:00Z'), d('2026-11-06T22:00:00Z'))?.toISOString())
      .toBe('2026-11-06T21:00:00.000Z');
  });
  it('leaves a missing time or start alone', () => {
    expect(shiftWithStart(null, d('2026-11-07T00:00:00Z'), d('2026-11-14T00:00:00Z'))).toBeNull();
    const doors = d('2026-11-06T23:00:00Z');
    expect(shiftWithStart(doors, null, d('2026-11-14T00:00:00Z'))).toBe(doors);
    expect(shiftWithStart(doors, d('2026-11-07T00:00:00Z'), null)).toBe(doors);
  });
});

describe('timingProblem', () => {
  const start = d('2026-11-14T00:00:00Z');
  it('accepts doors <= start <= end', () => {
    expect(timingProblem(start, d('2026-11-13T23:00:00Z'), d('2026-11-14T06:30:00Z'))).toBeNull();
    expect(timingProblem(start, start, start)).toBeNull();
    expect(timingProblem(start, null, null)).toBeNull();
  });
  it('refuses doors after the start', () => {
    expect(timingProblem(start, d('2026-11-14T00:01:00Z'), null)).toMatch(/Doors/);
  });
  it('refuses an end before the start (the old end left behind)', () => {
    expect(timingProblem(start, null, d('2026-11-07T06:30:00Z'))).toMatch(/end/);
  });
});
