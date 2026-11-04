import { describe, expect, it } from 'vitest';
import {
  RuleError, describeRule, expandRule, nthWeekdayOfMonth, parseRule, planGeneration, ruleDates, utcToZoned, zonedToUtcMs,
  type SeriesRule,
} from './recurrence';

const iso = (ms: number) => new Date(ms).toISOString().replace('.000Z', 'Z');
const rule = (r: Partial<SeriesRule> & Record<string, unknown>): SeriesRule => parseRule({ interval: 1, time: '20:00', ...r });
const NY = 'America/New_York';

describe('time zones', () => {
  it('a weekly 20:00 show keeps its wall clock across the spring change', () => {
    const occ = expandRule(rule({ freq: 'weekly', weekdays: [6], startDate: '2026-02-28', endDate: '2026-03-14' }), NY);
    expect(occ.map((o) => o.date)).toEqual(['2026-02-28', '2026-03-07', '2026-03-14']);
    expect(occ.map((o) => iso(o.startMs))).toEqual(['2026-03-01T01:00:00Z', '2026-03-08T01:00:00Z', '2026-03-15T00:00:00Z']);
    expect(occ.map((o) => utcToZoned(o.startMs, NY).time)).toEqual(['20:00', '20:00', '20:00']);
  });

  it('and across the fall change', () => {
    const fall = expandRule(rule({ freq: 'weekly', weekdays: [6], startDate: '2026-10-24', endDate: '2026-11-07' }), NY);
    expect(fall.map((o) => iso(o.startMs))).toEqual(['2026-10-25T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-08T01:00:00Z']);
  });

  it('moves a time in the gap forward and takes the first of a repeated time (as _exos_zoned_ts)', () => {
    expect(iso(zonedToUtcMs('2026-03-08', '02:30', NY))).toBe('2026-03-08T07:30:00Z');
    expect(iso(zonedToUtcMs('2026-11-01', '01:30', NY))).toBe('2026-11-01T05:30:00Z');
    expect([iso(zonedToUtcMs('2026-03-28', '19:30', 'Europe/London')), iso(zonedToUtcMs('2026-03-29', '19:30', 'Europe/London'))])
      .toEqual(['2026-03-28T19:30:00Z', '2026-03-29T18:30:00Z']);
    expect(iso(zonedToUtcMs('2026-07-01', '10:00', 'Asia/Tokyo'))).toBe('2026-07-01T01:00:00Z');
  });

  it('a daily 02:30 series keeps one date a day through the gap', () => {
    const occ = expandRule(rule({ freq: 'daily', startDate: '2026-03-07', count: 3, time: '02:30' }), NY);
    expect(occ.map((o) => utcToZoned(o.startMs, NY))).toEqual([
      { date: '2026-03-07', time: '02:30' }, { date: '2026-03-08', time: '03:30' }, { date: '2026-03-09', time: '02:30' },
    ]);
  });
});

describe('monthly rules', () => {
  it('skip months without the day', () => {
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'date', day: 31 }, startDate: '2026-01-31', endDate: '2026-08-31' })))
      .toEqual(['2026-01-31', '2026-03-31', '2026-05-31', '2026-07-31', '2026-08-31']);
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'date', day: 29 }, startDate: '2027-01-29', endDate: '2028-03-29' }))
      .filter((d) => d.slice(5, 7) === '02')).toEqual(['2028-02-29']);
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'date', day: 31 }, startDate: '2026-01-15', count: 3 })))
      .toEqual(['2026-01-31', '2026-03-31', '2026-05-31']);
    expect(ruleDates(rule({ freq: 'monthly', interval: 2, monthly: { mode: 'date', day: 10 }, startDate: '2026-01-10', count: 4 })))
      .toEqual(['2026-01-10', '2026-03-10', '2026-05-10', '2026-07-10']);
  });

  it('nth weekdays', () => {
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'nth', nth: 2, weekday: 2 }, startDate: '2026-01-01', count: 4 })))
      .toEqual(['2026-01-13', '2026-02-10', '2026-03-10', '2026-04-14']);
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'nth', nth: -1, weekday: 5 }, startDate: '2026-01-01', count: 3 })))
      .toEqual(['2026-01-30', '2026-02-27', '2026-03-27']);
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'nth', nth: 5, weekday: 1 }, startDate: '2026-01-01', endDate: '2026-12-31' })))
      .toEqual(['2026-03-30', '2026-06-29', '2026-08-31', '2026-11-30']);
    expect(nthWeekdayOfMonth(2026, 2, 5, 0)).toBeNull();
    expect(ruleDates(rule({ freq: 'monthly', monthly: { mode: 'nth', nth: 1, weekday: 1 }, startDate: '2026-01-10', count: 2 })))
      .toEqual(['2026-02-02', '2026-03-02']);
  });
});

describe('weekly, exceptions and overrides', () => {
  it('every 2 weeks on Friday and Saturday from a Saturday', () => {
    expect(ruleDates(rule({ freq: 'weekly', interval: 2, weekdays: [5, 6], startDate: '2026-01-03', count: 5 })))
      .toEqual(['2026-01-03', '2026-01-16', '2026-01-17', '2026-01-30', '2026-01-31']);
  });

  it('an exception removes a date without extending the count; an override moves one time', () => {
    const occ = expandRule(rule({
      freq: 'daily', startDate: '2026-06-01', count: 5, exceptions: ['2026-06-03'], overrides: { '2026-06-04': '18:00' },
    }), 'UTC');
    expect(occ.map((o) => o.date)).toEqual(['2026-06-01', '2026-06-02', '2026-06-04', '2026-06-05']);
    expect(occ.map((o) => `${o.time}${o.overridden ? '*' : ''}`)).toEqual(['20:00', '20:00', '18:00*', '20:00']);
  });
});

describe('parseRule', () => {
  it('refuses incomplete or impossible rules', () => {
    const bad: unknown[] = [
      { freq: 'daily', startDate: '2026-01-01', time: '20:00' },
      { freq: 'weekly', weekdays: [], startDate: '2026-01-01', count: 3, time: '20:00' },
      { freq: 'daily', startDate: '2026-01-01', count: 3, time: '25:00' },
      { freq: 'daily', startDate: '2026-02-30', count: 3, time: '20:00' },
      { freq: 'daily', startDate: '2026-02-03', endDate: '2026-02-01', time: '20:00' },
      { freq: 'monthly', monthly: { mode: 'nth', nth: 0, weekday: 1 }, startDate: '2026-01-01', count: 3, time: '20:00' },
      { freq: 'yearly', startDate: '2026-01-01', count: 3, time: '20:00' },
    ];
    for (const r of bad) expect(() => parseRule(r)).toThrow(RuleError);
  });

  it('describes a rule', () => {
    expect(describeRule(rule({ freq: 'weekly', weekdays: [5, 6], startDate: '2026-01-02', count: 2 })))
      .toBe('Every week on Friday, Saturday at 20:00');
  });
});

describe('planGeneration', () => {
  const r = rule({ freq: 'weekly', weekdays: [4, 5], startDate: '2026-01-01', endDate: '2026-12-31' });
  const now = Date.parse('2026-01-01T00:00:00Z');

  it('is idempotent against the recorded dates, and windows only add new dates', () => {
    const existing = new Set<string>();
    const first = planGeneration(r, 'America/Chicago', { from: '2026-01-01', to: '2026-01-31' }, existing, now);
    expect(first).toHaveLength(10);
    for (const o of first) existing.add(o.date);
    expect(planGeneration(r, 'America/Chicago', { from: '2026-01-01', to: '2026-01-31' }, existing, now)).toHaveLength(0);
    expect(planGeneration(r, 'America/Chicago', { from: '2026-01-15', to: '2026-02-14' }, existing, now).map((o) => o.date))
      .toEqual(['2026-02-05', '2026-02-06', '2026-02-12', '2026-02-13']);
  });

  it('never plans a past start', () => {
    const late = planGeneration(r, 'America/Chicago', { from: '2026-01-01', to: '2026-01-31' }, new Set(), Date.parse('2026-01-20T12:00:00Z'));
    expect(late.map((o) => o.date)).toEqual(['2026-01-22', '2026-01-23', '2026-01-29', '2026-01-30']);
  });
});
