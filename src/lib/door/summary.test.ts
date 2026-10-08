import { describe, it, expect } from 'vitest';
import { hourLabel, parseDoorSummary, refusalText, showRate, summaryCsvRows, summaryText, timeIn } from './summary';

// The shape exos_event_door_summary returns (tests/exos/test_door_delta_summary.sql S1-S4).
const RAW = {
  event: { id: 'e3', name: 'Summary Night', status: 'published', timezone: 'America/New_York' },
  generated_at: '2026-10-03T05:00:00+00:00',
  tickets: { sold: 6, voided: 1, checked_in: 4, no_shows: 2, voided_entered: 1 },
  entries: { total: 6, first: 5, reentries: 1, exits: 1, forced: 1, offline: 2, by_verification: { verified: 3, manual: 1, name: 1 } },
  first_entry_at: '2026-10-02T23:10:00+00:00',
  last_entry_at: '2026-10-03T00:45:00+00:00',
  peak: { start: '2026-10-02T23:15:00+00:00', entries: 4 },
  by_hour: [{ hour: '2026-10-02T19:00', entries: 5 }, { hour: '2026-10-02T20:00', entries: 1 }],
  by_tier: [{ tier: 'GA', sold: 4, checked_in: 3 }, { tier: 'VIP', sold: 2, checked_in: 1 }],
  by_list: [{ list: 'Main door', entries: 4, exits: 0 }, { list: 'Smoking deck', entries: 2, exits: 1 }],
  by_staff: [{ staff: 'Sam Scanner', entries: 5, refused: 2 }, { staff: 'd***@x.com', entries: 1, refused: 1 }],
  overrides: [{ reason: 'Phone died', count: 1 }],
  conflicts: [{ reason: 'voided', count: 1 }],
  refused: { total: 3, by_reason: [{ reason: 'used', count: 2 }, { reason: 'invalid-barcode', count: 1 }] },
  inside_now: 1,
};

describe('parseDoorSummary', () => {
  it('maps the RPC answer', () => {
    const s = parseDoorSummary(RAW)!;
    expect(s.eventName).toBe('Summary Night');
    expect(s.timezone).toBe('America/New_York');
    expect([s.sold, s.checkedIn, s.noShows, s.voided, s.voidedEntered]).toEqual([6, 4, 2, 1, 1]);
    expect(s.entries.byVerification).toEqual([
      { key: 'verified', count: 3 }, { key: 'manual', count: 1 }, { key: 'name', count: 1 },
    ]);
    expect(s.peak).toEqual({ start: '2026-10-02T23:15:00+00:00', entries: 4 });
    expect(s.byTier[0]).toEqual({ tier: 'GA', sold: 4, checkedIn: 3 });
    expect(s.overrides).toEqual([{ key: 'Phone died', count: 1 }]);
    expect(s.refused).toEqual([{ key: 'used', count: 2 }, { key: 'invalid-barcode', count: 1 }]);
    expect(s.insideNow).toBe(1);
  });

  it('an empty night and junk', () => {
    const s = parseDoorSummary({ event: {}, tickets: {}, entries: {}, peak: null, by_hour: [], inside_now: null })!;
    expect(s.sold).toBe(0);
    expect(s.timezone).toBe('UTC');
    expect(s.peak).toBeNull();
    expect(s.insideNow).toBeNull();
    expect(s.byStaff).toEqual([]);
    expect(parseDoorSummary(null)).toBeNull();
    expect(parseDoorSummary('x')).toBeNull();
    expect(parseDoorSummary({ by_tier: 'x', overrides: [{ count: 2 }] })!.overrides).toEqual([]);
  });
});

describe('formatting', () => {
  it('show rate', () => {
    expect(showRate({ sold: 6, checkedIn: 4 })).toBe(67);
    expect(showRate({ sold: 0, checkedIn: 0 })).toBeNull();
  });

  it('times in the event zone', () => {
    expect(timeIn('2026-10-02T23:10:00Z', 'America/New_York')).toBe('7:10 PM');
    expect(timeIn('2026-10-02T23:10:00Z', 'Not/AZone')).toBe('11:10 PM');
    expect(timeIn(null, 'UTC')).toBe('—');
    expect(hourLabel('2026-10-02T19:00')).toBe('7 PM');
    expect(hourLabel('2026-10-02T00:00')).toBe('12 AM');
    expect(hourLabel('2026-10-02T12:00')).toBe('12 PM');
  });

  it('refusal wording', () => {
    expect(refusalText('used')).toBe('already checked in');
    expect(refusalText('invalid-barcode')).toBe('unreadable or forged code');
    expect(refusalText('mystery')).toBe('mystery');
  });

  it('plain text for pasting', () => {
    const t = summaryText(parseDoorSummary(RAW)!);
    expect(t).toContain('Door summary: Summary Night');
    expect(t).toContain('4 of 6 checked in (67%) · 2 no-shows');
    expect(t).toContain('first in 7:10 PM, last in 8:45 PM');
    expect(t).toContain('Busiest 15 min: 4 entries from 7:15 PM');
    expect(t).toContain('1 re-entry · 1 exit · 2 scanned offline · 1 inside now');
    expect(t).toContain('  GA: 3 / 4');
    expect(t).toContain('  Sam Scanner: 5 in, 2 refused');
    expect(t).toContain('  Manual override (Phone died): 1');
    expect(t).toContain('  Offline admission, refunded / voided: 1');
    expect(t).toContain('  Refused, already checked in: 2');
  });

  it('a quiet night has no door lines', () => {
    const t = summaryText(parseDoorSummary({ event: { name: 'Quiet' }, tickets: { sold: 3, no_shows: 3 } })!);
    expect(t).toBe('Door summary: Quiet\n0 of 3 checked in (0%) · 3 no-shows');
  });

  it('CSV rows', () => {
    const rows = summaryCsvRows(parseDoorSummary(RAW)!);
    expect(rows).toContainEqual(['tickets', 'sold', 6, '']);
    expect(rows).toContainEqual(['doors', 'peak_15min_start', '2026-10-02T23:15:00+00:00', 4]);
    expect(rows).toContainEqual(['ticket_type', 'VIP', 1, 2]);
    expect(rows).toContainEqual(['staff', 'Sam Scanner', 5, 2]);
    expect(rows).toContainEqual(['refused', 'invalid-barcode', 1, '']);
    expect(rows.every((r) => r.length === 4)).toBe(true);
  });
});
