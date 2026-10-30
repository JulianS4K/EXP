import { describe, expect, it } from 'vitest';
import {
  DEFAULT_GEN, bestAvailable, capacityByTier, countSeats, fromStoredMap, generateSection, levelsError,
  pickerData, regenerateSection, rowLabels, seatLabel, seatNumbers, starterMap, toStoredMap, toggleSeat,
  validateMap, type PublicLayout, type PublicSeatRow, type SeatMap,
} from './seating';

const small = (): SeatMap => ({
  width: 1000,
  height: 700,
  stage: { x: 300, y: 20, w: 400, h: 60, label: 'Stage' },
  sections: [
    generateSection('s1', 'Orchestra', 440, 140, { ...DEFAULT_GEN, rows: 3, seatsPerRow: 6 }),
    { id: 'g1', name: 'Floor', kind: 'ga', x: 50, y: 400, w: 200, h: 100, capacity: 50, rows: [] },
  ],
});

describe('numbering', () => {
  it('sequential, reverse, odd, even and their reverses', () => {
    expect(seatNumbers(4, 'sequential')).toEqual(['1', '2', '3', '4']);
    expect(seatNumbers(4, 'reverse')).toEqual(['4', '3', '2', '1']);
    expect(seatNumbers(3, 'odd')).toEqual(['1', '3', '5']);
    expect(seatNumbers(3, 'even')).toEqual(['2', '4', '6']);
    expect(seatNumbers(3, 'odd-reverse')).toEqual(['5', '3', '1']);
    expect(seatNumbers(3, 'even', 101)).toEqual(['102', '104', '106']);
  });
  it('row letters roll over spreadsheet style; numbers start where asked', () => {
    expect(rowLabels(3, 'letters', 'Y')).toEqual(['Y', 'Z', 'AA']);
    expect(rowLabels(3, 'numbers', '5')).toEqual(['5', '6', '7']);
  });
  it('labels print like the database', () => {
    expect(seatLabel('Orchestra', 'C', '12')).toBe('Orchestra · Row C · Seat 12');
  });
});

describe('generation', () => {
  it('a grid section with stable ids', () => {
    const s = generateSection('s1', 'Orchestra', 0, 0, { ...DEFAULT_GEN, rows: 2, seatsPerRow: 3 });
    expect(s.rows.map((r) => r.label)).toEqual(['A', 'B']);
    expect(s.rows[1].seats.map((x) => x.id)).toEqual(['s1-r2-1', 's1-r2-2', 's1-r2-3']);
    expect(s.rows[1].seats[2]).toMatchObject({ x: 48, y: 28, label: '3' });
  });
  it('regenerating keeps seat marks whose row + key survive', () => {
    const s = generateSection('s1', 'O', 0, 0, { ...DEFAULT_GEN, rows: 2, seatsPerRow: 3 });
    s.rows[0].seats[1].accessible = true;
    const next = regenerateSection(s, { ...DEFAULT_GEN, rows: 2, seatsPerRow: 5, scheme: 'reverse' });
    expect(next.rows[0].seats[1]).toMatchObject({ id: 's1-r1-2', accessible: true, label: '4' });
    expect(countSeats({ ...small(), sections: [next] })).toBe(10);
  });
  it('the starter map is valid', () => {
    expect(validateMap(starterMap())).toBeNull();
  });
});

describe('validation', () => {
  it('accepts a good map and round-trips through the stored form', () => {
    const m = small();
    expect(validateMap(m)).toBeNull();
    const back = fromStoredMap(JSON.parse(JSON.stringify(toStoredMap(m))));
    expect(back.sections[0].rows[2].seats[5].id).toBe('s1-r3-6');
    expect(validateMap(back)).toBeNull();
    expect(toStoredMap(m).sections).toHaveLength(2);
    // The stored form carries no seat ids (the database rebuilds them).
    expect(JSON.stringify(toStoredMap(m))).not.toContain('s1-r1-1');
  });
  it('refuses duplicate keys, empty rows, bad names, missing capacity, too many seats', () => {
    const dupe = small();
    dupe.sections[0].rows[0].seats[1].key = '1';
    expect(validateMap(dupe)).toMatch(/two seats share the key 1/);
    const empty = small();
    empty.sections[0].rows[0].seats = [];
    expect(validateMap(empty)).toMatch(/has no seats/);
    const named = small();
    named.sections[0].name = 'A|B';
    expect(validateMap(named)).toMatch(/Section names/);
    const ga = small();
    ga.sections[1].capacity = 0;
    expect(validateMap(ga)).toMatch(/capacity/);
    const huge = small();
    huge.sections = Array.from({ length: 2 }, (_, i) =>
      generateSection(`s${i}`, `S${i}`, 0, 0, { ...DEFAULT_GEN, rows: 200, seatsPerRow: 30 }));
    expect(validateMap(huge)).toMatch(/at most 10,000 seats/);
    expect(validateMap({ ...small(), sections: [] })).toMatch(/at least one section/);
  });
});

describe('price levels', () => {
  it('seat > row > section; capacity per tier, blocked seats excluded', () => {
    const m = small();
    const levels = { s1: 'T1', 's1-r3': 'T2', 's1-r3-6': 'T1', g1: 'GA' };
    const caps = capacityByTier(m, levels, new Set(['s1-r1-1']));
    expect(caps).toEqual({ T1: { seats: 12, ga: 0 }, T2: { seats: 5, ga: 0 }, GA: { seats: 0, ga: 50 } });
    expect(levelsError(m, levels, ['T1', 'T2', 'GA'])).toBeNull();
  });
  it('refuses unknown keys, foreign tiers, and a tier both seated and standing', () => {
    const m = small();
    expect(levelsError(m, { nope: 'T1' }, ['T1'])).toMatch(/no such section/);
    expect(levelsError(m, { s1: 'X' }, ['T1'])).toMatch(/not a ticket type/);
    expect(levelsError(m, { s1: 'T1', g1: 'T1' }, ['T1'])).toMatch(/not both/);
    expect(levelsError(m, {}, ['T1'])).toMatch(/at least one/);
  });
});

describe('best available', () => {
  const m = small();
  const levels = { s1: 'T1' };
  it('the most central block in the front row', () => {
    expect(bestAvailable(m, levels, new Set(), 'T1', 2)).toEqual({ seatIds: ['s1-r1-3', 's1-r1-4'], together: true });
  });
  it('a taken seat breaks the run', () => {
    const r = bestAvailable(m, levels, new Set(['s1-r1-3', 's1-r1-4']), 'T1', 2);
    expect(r?.together).toBe(true);
    expect(r?.seatIds).not.toContain('s1-r1-3');
  });
  it('accessible seats are left out unless asked; obstructed seats rank last', () => {
    const acc = small();
    acc.sections[0].rows[0].seats.forEach((s) => { s.accessible = true; });
    expect(bestAvailable(acc, levels, new Set(), 'T1', 1)?.seatIds[0]).toMatch(/^s1-r2-/);
    expect(bestAvailable(acc, levels, new Set(), 'T1', 1, { includeAccessible: true })?.seatIds[0]).toMatch(/^s1-r1-/);
    const obs = small();
    obs.sections[0].rows[0].seats.forEach((s) => { s.obstructed = true; });
    expect(bestAvailable(obs, levels, new Set(), 'T1', 1)?.seatIds[0]).toMatch(/^s1-r2-/);
  });
  it('splits when no block fits, unless told not to; null when sold out', () => {
    const taken = new Set<string>();
    for (const r of m.sections[0].rows) r.seats.forEach((s, i) => { if (i % 2 === 1) taken.add(s.id); });
    expect(bestAvailable(m, levels, taken, 'T1', 2)?.together).toBe(false);
    expect(bestAvailable(m, levels, taken, 'T1', 2, { allowSplit: false })).toBeNull();
    expect(bestAvailable(m, levels, new Set(), 'T1', 19)).toBeNull();
    expect(bestAvailable(m, levels, new Set(), 'T1', 0)).toBeNull();
  });
});

describe('picker data from the public reads', () => {
  const layout: PublicLayout = {
    map: {
      width: 1000, height: 700, stage: { x: 300, y: 20, w: 400, h: 60, label: 'Stage' },
      sections: [{ id: 's1', name: 'Orchestra', kind: 'seated', x: 400, y: 140 }, { id: 'g1', name: 'Floor', kind: 'ga', x: 0, y: 0, w: 100, h: 50, tier_id: 'GA' }],
    },
    seated_tier_ids: ['T1'],
    seat_count: 2,
  };
  const rows: PublicSeatRow[] = [
    { seat_id: 's1-r1-1', section_id: 's1', section: 'Orchestra', row_label: 'A', number: '1', label: 'Orchestra · Row A · Seat 1', tier_id: 'T1', x: '400', y: 140, accessible: false, companion: false, obstructed: false, available: true },
    { seat_id: 's1-r1-2', section_id: 's1', section: 'Orchestra', row_label: 'A', number: '2', label: 'Orchestra · Row A · Seat 2', tier_id: 'T1', x: 424, y: 140, accessible: true, companion: false, obstructed: false, available: false },
  ];
  it('rebuilds relative positions, levels, availability', () => {
    const d = pickerData(layout, rows);
    expect(d.map.sections[0].rows[0].seats.map((s) => [s.id, s.x, s.y])).toEqual([['s1-r1-1', 0, 0], ['s1-r1-2', 24, 0]]);
    expect(d.levels).toEqual({ g1: 'GA', 's1-r1-1': 'T1', 's1-r1-2': 'T1' });
    expect([...d.unavailable]).toEqual(['s1-r1-2']);
    expect(d.labels.get('s1-r1-1')).toBe('Orchestra · Row A · Seat 1');
  });
  it('toggle: one tier per order, cap, taken seats refused', () => {
    const d = pickerData(layout, rows);
    expect(toggleSeat([], 's1-r1-1', d, 2)).toEqual({ selection: ['s1-r1-1'] });
    expect(toggleSeat(['s1-r1-1'], 's1-r1-1', d, 2)).toEqual({ selection: [] });
    expect(toggleSeat([], 's1-r1-2', d, 2).error).toMatch(/taken/);
    expect(toggleSeat(['s1-r1-1'], 'x', { levels: { ...d.levels, x: 'T2' }, unavailable: new Set() }, 2).error).toMatch(/one ticket type/);
    expect(toggleSeat(['s1-r1-1'], 's1-r1-9', { levels: { ...d.levels, 's1-r1-9': 'T1' }, unavailable: new Set() }, 1).error).toMatch(/Up to 1/);
  });
});
