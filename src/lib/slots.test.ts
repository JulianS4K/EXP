import { describe, expect, it } from 'vitest';
import { parseRule } from './recurrence';
import {
  GENERATE_BATCH, entryWindowAnswer, entryWindowMessage, fillRatio, generateBatches, groupReport, hoursText, monthGrid,
  monthRange, parseHoursText,
  shiftMonth, slotIdLabel, slotLabel, slotLeftFor, slugify, summarizeDays, type EntryWindowAnswer, type PublicSlot,
  type SlotReportRow,
} from './slots';

const slot = (p: Partial<PublicSlot>): PublicSlot => ({
  slotId: '20261114T1000', date: '2026-11-14', time: '10:00', startsAt: '', endsAt: '', entryUntil: '',
  capacity: 10, remaining: 10, tierRemaining: {}, closed: false, ended: false, ...p,
});

describe('slot picker', () => {
  it('counts what is left for a tier', () => {
    expect(slotLeftFor(slot({ remaining: 6, tierRemaining: { child: 2 } }), 'child')).toBe(2);
    expect(slotLeftFor(slot({ remaining: 6, tierRemaining: { child: 2 } }), 'adult')).toBe(6);
    expect(slotLeftFor(slot({ closed: true }), null)).toBe(0);
    expect(slotLeftFor(slot({ ended: true }), null)).toBe(0);
  });

  it('summarizes days for the calendar', () => {
    const days = summarizeDays([
      slot({ date: '2026-11-15', remaining: 1 }),
      slot({ date: '2026-11-14', remaining: 0 }),
      slot({ date: '2026-11-14', remaining: 3 }),
    ], null, 2);
    expect(days).toEqual([
      { date: '2026-11-14', slots: 2, open: 1, left: 3 },
      { date: '2026-11-15', slots: 1, open: 0, left: 1 },
    ]);
  });

  it('builds month grids starting on Sunday', () => {
    const g = monthGrid(2026, 11); // 1 Nov 2026 is a Sunday
    expect(g[0][0]).toBe('2026-11-01');
    expect(g.flat().filter(Boolean)).toHaveLength(30);
    expect(g.every((w) => w.length === 7)).toBe(true);
    expect(monthGrid(2026, 10)[0].slice(0, 4)).toEqual([null, null, null, null]);
    expect(monthRange(2026, 11, '2026-11-10', '2027-01-01')).toEqual({ from: '2026-11-10', to: '2026-11-30' });
    expect(monthRange(2026, 9, '2026-11-10', '2027-01-01')).toBeNull();
    expect(shiftMonth(2026, 12, 1)).toEqual({ year: 2027, month: 1 });
    expect(shiftMonth(2026, 1, -1)).toEqual({ year: 2025, month: 12 });
  });

  it('labels slots', () => {
    expect(slotLabel('10:30', 30)).toBe('10:30 – 11:00');
    expect(slotLabel('23:30', 60)).toBe('23:30 – 00:30');
    expect(slotIdLabel('20261114T1030')).toBe('2026-11-14 10:30');
  });
});

describe('slot report', () => {
  const row = (p: Partial<SlotReportRow>): SlotReportRow => ({
    slotId: 'x', date: '2026-11-14', time: '10:00', capacity: 10, custom: false, closed: false, sold: 0, held: 0,
    checkedIn: 0, gross: 0, tierSold: {}, ...p,
  });
  it('groups by day with totals', () => {
    const g = groupReport([
      row({ date: '2026-11-15', time: '10:00', sold: 2, gross: 30 }),
      row({ time: '11:00', sold: 5, checkedIn: 3, gross: 75.1 }),
      row({ time: '10:00', sold: 1, gross: 15.2, closed: true }),
    ]);
    expect(g.map((d) => d.date)).toEqual(['2026-11-14', '2026-11-15']);
    expect(g[0].rows.map((r) => r.time)).toEqual(['10:00', '11:00']);
    expect([g[0].sold, g[0].capacity, g[0].checkedIn, g[0].gross]).toEqual([6, 10, 3, 90.3]);
    expect(fillRatio({ sold: 5, capacity: 10 })).toBe(0.5);
    expect(fillRatio({ sold: 1, capacity: 0 })).toBe(1);
  });
});

describe('the door', () => {
  const t = { entryFrom: '2026-11-14T15:20:00Z', entryUntil: '2026-11-14T15:45:00Z' };
  const at = (s: string) => Date.parse(`2026-11-14T${s}:00Z`);
  it('decides like the server', () => {
    expect(entryWindowAnswer(t, at('15:30'))).toEqual({ ok: true });
    expect(entryWindowAnswer(t, at('15:00'))).toMatchObject({ ok: false, window: 'early' });
    expect(entryWindowAnswer(t, at('16:00'))).toMatchObject({ ok: false, window: 'late' });
    expect(entryWindowAnswer({ ...t, override: true }, at('16:00'))).toEqual({ ok: true });
    expect(entryWindowAnswer({ entryFrom: null, entryUntil: null }, at('16:00'))).toEqual({ ok: true });
  });
  it('says how far off', () => {
    type Refusal = Extract<EntryWindowAnswer, { ok: false }>;
    const early = entryWindowAnswer(t, at('14:55')) as Refusal;
    const late = entryWindowAnswer(t, at('16:50')) as Refusal;
    expect([early.ok, late.ok]).toEqual([false, false]);
    expect(entryWindowMessage(early, at('14:55'))).toBe('Too early: entry opens in 25 min');
    expect(entryWindowMessage(late, at('16:50'))).toBe('Too late: entry closed 1 h 5 min ago');
  });
});

describe('series editor', () => {
  it('batches only new, future dates', () => {
    const rule = parseRule({ freq: 'daily', startDate: '2026-01-01', count: 300, time: '20:00' });
    const batches = generateBatches(rule, 'UTC', { from: '2026-01-01', to: '2026-12-31' }, new Set(['2026-01-05']),
      Date.parse('2026-01-03T00:00:00Z'));
    const flat = batches.flat();
    expect(batches[0]).toHaveLength(GENERATE_BATCH);
    expect(flat[0]).toEqual({ date: '2026-01-03', time: '20:00' });
    expect(flat.some((d) => d.date === '2026-01-05')).toBe(false);
    expect(flat).toHaveLength(300 - 2 - 1);
  });
  it('reads and writes opening hours text', () => {
    expect(parseHoursText('9:00-13:00, 14:00 – 18:30')).toEqual([{ open: '09:00', close: '13:00' }, { open: '14:00', close: '18:30' }]);
    expect(parseHoursText('  ')).toEqual([]);
    expect(() => parseHoursText('morning')).toThrow();
    expect(hoursText([{ open: '09:00', close: '13:00' }])).toBe('09:00-13:00');
  });
  it('slugifies names', () => {
    expect(slugify('Winter Season — 2026!')).toBe('winter-season-2026');
    expect(slugify('Café Nights')).toBe('cafe-nights');
  });
});
