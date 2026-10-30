import { describe, expect, it } from 'vitest';
import {
  activityProblem, buildCalendar, holdFromRow, lineFor, localDate, monthGrid, monthRange, placeLabel, previewMove,
  shiftMonth, slotKey, slugify, withImpliedDoors, type CalendarEvent, type Hold, type HoldPosition, type ShowActivity,
} from './booking';

const pos = (id: string, date: string, level: number, over: Partial<HoldPosition> = {}): HoldPosition => ({
  id, holdId: '', date, venueId: 'v1', roomId: 'main', startTime: null, isTarget: false, level, status: 'active', eventId: null, ...over,
});
const hold = (id: string, title: string, positions: HoldPosition[]): Hold => ({
  id, title, notes: '', status: 'active', announceAt: null, ticketForecast: null, ageRestriction: null, rental: null,
  firstDate: null, lastDate: null, positions: positions.map((p) => ({ ...p, holdId: id })),
});
const ev = (id: string, date: string, over: Partial<CalendarEvent> = {}): CalendarEvent => ({
  id, name: id, status: 'draft', date, venueId: 'v1', roomId: 'main', holdId: null, ...over,
});

describe('calendar grid', () => {
  it('pads a month into Sunday-first weeks', () => {
    const weeks = monthGrid(2026, 10); // November 2026 starts on a Sunday
    expect(weeks[0][0]).toBe('2026-11-01');
    expect(weeks.flat().filter(Boolean)).toHaveLength(30);
    expect(weeks.every((w) => w.length === 7)).toBe(true);
    const feb = monthGrid(2027, 1); // 1 Feb 2027 is a Monday
    expect(feb[0][0]).toBeNull();
    expect(feb[0][1]).toBe('2027-02-01');
  });

  it('month range and shifting across years', () => {
    expect(monthRange(2028, 1)).toEqual({ from: '2028-02-01', to: '2028-02-29' });
    expect(shiftMonth({ y: 2026, m: 11 }, 1)).toEqual({ y: 2027, m: 0 });
    expect(shiftMonth({ y: 2026, m: 0 }, -1)).toEqual({ y: 2025, m: 11 });
  });

  it('local date of an instant in the venue zone', () => {
    expect(localDate(new Date('2026-11-15T02:00:00Z'), 'America/Chicago')).toBe('2026-11-14');
    expect(localDate(new Date('2026-11-15T02:00:00Z'), 'Europe/Berlin')).toBe('2026-11-15');
  });
});

describe('challenged nights', () => {
  const a = hold('A', 'Band A', [pos('a1', '2026-11-14', 1), pos('a2', '2026-11-15', 1)]);
  const b = hold('B', 'Band B', [pos('b1', '2026-11-14', 2)]);
  const loft = hold('L', 'Loft act', [pos('l1', '2026-11-15', 1, { roomId: 'loft' })]);
  const gone = hold('G', 'Gone', [pos('g1', '2026-11-16', 1, { status: 'cleared' })]);

  it('a line of two is challenged, a lone hold is not, cleared nights are hidden', () => {
    const days = buildCalendar([a, b, loft, gone], []);
    expect(days.get('2026-11-14')!.challenged).toBe(true);
    expect(days.get('2026-11-14')!.nights.map((n) => [n.hold.id, n.pos.level])).toEqual([['A', 1], ['B', 2]]);
    expect(days.get('2026-11-15')!.challenged).toBe(false);
    expect(days.has('2026-11-16')).toBe(false);
  });

  it('a hold against a booked show is challenged; a cancelled show or another room is not', () => {
    expect(buildCalendar([a], [ev('show', '2026-11-15')]).get('2026-11-15')!.challenged).toBe(true);
    expect(buildCalendar([a], [ev('show', '2026-11-15', { status: 'cancelled' })]).get('2026-11-15')!.challenged).toBe(false);
    expect(buildCalendar([loft], [ev('show', '2026-11-15')]).get('2026-11-15')!.challenged).toBe(false);
    // A whole-venue show clashes with every room.
    expect(buildCalendar([loft], [ev('show', '2026-11-15', { roomId: null })]).get('2026-11-15')!.challenged).toBe(true);
  });

  it('filters by venue and room; a line is still counted across the filter', () => {
    const days = buildCalendar([a, b, loft], [ev('show', '2026-11-20', { venueId: 'v2' })], { venueId: 'v1', roomId: 'loft' });
    expect([...days.keys()]).toEqual(['2026-11-15']);
  });

  it('the line of one slot, and a move preview that matches the database rule', () => {
    expect(lineFor([a, b], { venueId: 'v1', roomId: 'main', date: '2026-11-14' }).map((x) => x.hold.id)).toEqual(['A', 'B']);
    expect(previewMove(['a', 'b', 'c', 'd'], 'a', 3)).toEqual(['b', 'c', 'a', 'd']);
    expect(previewMove(['a', 'b', 'c'], 'c', 1)).toEqual(['c', 'a', 'b']);
    expect(previewMove(['a', 'b'], 'a', 9)).toEqual(['b', 'a']);
    expect(previewMove(['a', 'b'], 'x', 1)).toEqual(['a', 'b']);
    expect(slotKey({ venueId: 'v', roomId: null, date: 'd' })).toBe('v|-|d');
  });
});

describe('show schedule', () => {
  const row = (id: string, kind: ShowActivity['kind'], startsAt: string): ShowActivity => ({
    id, eventId: 'e', kind, name: id, startsAt, endsAt: null, notes: '', isSet: true, showInAdvance: true,
  });

  it('adds an implied doors row only when there is none', () => {
    const rows = [row('set', 'set', '2026-11-15T03:00:00Z'), row('load', 'load_in', '2026-11-14T20:00:00Z')];
    const shown = withImpliedDoors(rows, 'e', '2026-11-15T01:00:00Z');
    expect(shown.map((r) => r.id)).toEqual(['load', 'implied-doors', 'set']);
    expect(shown[1].implied).toBe(true);
    expect(withImpliedDoors([...rows, row('d', 'doors', '2026-11-15T01:00:00Z')], 'e', '2026-11-15T01:00:00Z')).toHaveLength(3);
    expect(withImpliedDoors(rows, 'e', null)).toHaveLength(2);
  });

  it('checks a row before saving', () => {
    const ctx = { eventStartsAt: '2026-11-15T02:00:00Z', hasOtherDoors: false };
    expect(activityProblem({ kind: 'set', startsAt: null, endsAt: null }, ctx)).toMatch(/time/);
    expect(activityProblem({ kind: 'set', startsAt: '2026-11-15T03:00:00Z', endsAt: '2026-11-15T02:00:00Z' }, ctx)).toMatch(/end/);
    expect(activityProblem({ kind: 'doors', startsAt: '2026-11-15T02:30:00Z', endsAt: null }, ctx)).toMatch(/after/);
    expect(activityProblem({ kind: 'doors', startsAt: '2026-11-15T01:00:00Z', endsAt: null }, { ...ctx, hasOtherDoors: true })).toMatch(/already/);
    expect(activityProblem({ kind: 'doors', startsAt: '2026-11-15T01:00:00Z', endsAt: null }, ctx)).toBeNull();
  });
});

describe('rows', () => {
  it('reads a hold from the table shape and from the JSON shape', () => {
    const table = holdFromRow({
      id: 'h', title: 'T', status: 'active', rental_status: 'confirmed', rental_fee: '2500.00', rental_currency: 'USD',
      exos_hold_positions: [{ id: 'p2', date: '2026-11-15', venue_id: 'v', room_id: null, level: 1, status: 'active', start_time: '20:00:00' },
                            { id: 'p1', date: '2026-11-14', venue_id: 'v', room_id: 'r', level: 2, status: 'active' }],
    });
    expect(table.rental).toEqual({ status: 'confirmed', fee: 2500, deposit: null, currency: 'USD', notes: '' });
    expect(table.positions.map((p) => p.id)).toEqual(['p1', 'p2']);
    expect(table.positions[1]).toMatchObject({ holdId: 'h', startTime: '20:00', roomId: null });
    const json = holdFromRow({ id: 'h', title: 'T', status: 'cleared', rental: null, positions: [] });
    expect(json.rental).toBeNull();
  });

  it('labels and slugs', () => {
    expect(placeLabel({ name: 'Lincoln Hall' }, { name: 'Main Room' })).toBe('Lincoln Hall — Main Room');
    expect(placeLabel({ name: 'Lincoln Hall' }, null)).toBe('Lincoln Hall');
    expect(slugify('Café Wha?')).toBe('cafe-wha');
  });
});
