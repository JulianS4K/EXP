import { describe, expect, it, vi } from 'vitest';

vi.mock('../supabase', () => ({ supabase: {} }));

import {
  blockLine, blockUnits, defaultReleaseAt, fromLocalInput, parseBlockInput, parseFixedBlockStatus, toLocalInput,
} from './fixedBlock';
import { parseLastCallStatus, parsePublicSale, sellsElsewhere } from './lastCall';

const OPEN = {
  on: true, primary_source: 'external', platform: 'DICE', platform_url: 'https://dice.fm/event/x',
  release_at: '2026-11-07T23:00:00+00:00', release_at_set: null, release_at_default: '2026-11-07T23:00:00+00:00',
  released_at: null, release: null,
  tiers: [
    { tier_id: 't1', name: 'GA', kind: 'standard', party_size: null, block: 120, sold: 23, left: 97, returned: null, unsold_now: null, more_to_return: null },
    { tier_id: 't2', name: 'Booth', kind: 'table', party_size: 6, block: 4, sold: 1, left: 3, returned: null, unsold_now: null, more_to_return: null },
  ],
  totals: { block: 124, sold: 24, left: 100, more_to_return: null }, total_tickets: 0, cancelled: false, can_manage: true,
};

describe('fixed block (mig 20261029160000)', () => {
  it('parses the status before the release', () => {
    const s = parseFixedBlockStatus(OPEN)!;
    expect(s.on).toBe(true);
    expect(s.platform).toBe('DICE');
    expect(s.platformUrl).toBe('https://dice.fm/event/x');
    expect(s.releaseAt?.toISOString()).toBe('2026-11-07T23:00:00.000Z');
    expect(s.releaseAtSet).toBeNull();
    expect(s.release).toBeNull();
    expect(s.tiers[1]).toMatchObject({ table: true, partySize: 6, block: 4, left: 3, returned: null });
    expect(blockLine(s)).toBe('Selling a block of 124 for DICE: 24 sold, 100 left.');
    expect(parseFixedBlockStatus(null)).toBeNull();
    expect(parseFixedBlockStatus({ ...OPEN, platform_url: 'http://x.y' })!.platformUrl).toBeNull();
  });

  it('parses the release and what came back since', () => {
    const s = parseFixedBlockStatus({
      ...OPEN, released_at: '2026-11-07T23:00:05+00:00',
      release: { released_at: '2026-11-07T23:00:05+00:00', reason: 'manual', platform: 'DICE', total_returned: 98, total_pending: 2, mailed: 2 },
      totals: { block: 124, sold: 24, left: 100, more_to_return: 2 },
    })!;
    expect(s.release).toMatchObject({ reason: 'manual', totalReturned: 98, totalPending: 2, mailed: 2 });
    expect(blockLine(s)).toBe('Block released to DICE: put 98 back on sale there, and 2 more that came back since. Exos sold 24 of 124.');
    expect(blockLine({ ...s, totals: { ...s.totals, moreToReturn: 0 } })).toBe('Block released to DICE: put 98 back on sale there. Exos sold 24 of 124.');
  });

  it('reads a block from the editor: 1-100000, not below sold', () => {
    expect(parseBlockInput(' 120 ')).toBe(120);
    expect(parseBlockInput('0')).toBeUndefined();
    expect(parseBlockInput('100001')).toBeUndefined();
    expect(parseBlockInput('12.5')).toBeUndefined();
    expect(parseBlockInput('')).toBeUndefined();
    expect(parseBlockInput('20', 23)).toBeUndefined();
    expect(parseBlockInput('23', 23)).toBe(23);
  });

  it('words units', () => {
    expect(blockUnits(1, { table: false, partySize: null })).toBe('1 ticket');
    expect(blockUnits(95, { table: false, partySize: null })).toBe('95 tickets');
    expect(blockUnits(1, { table: true, partySize: 6 })).toBe('1 table of 6');
    expect(blockUnits(2, { table: true, partySize: null })).toBe('2 tables');
  });

  it('the default release time and the datetime input', () => {
    const doors = new Date('2026-11-08T23:00:00Z');
    expect(defaultReleaseAt(doors, new Date('2026-11-09T00:00:00Z'))?.toISOString()).toBe('2026-11-07T23:00:00.000Z');
    expect(defaultReleaseAt(null, doors)?.toISOString()).toBe('2026-11-07T23:00:00.000Z');
    expect(defaultReleaseAt(null, null)).toBeNull();
    const d = new Date(2026, 10, 7, 18, 5);
    expect(toLocalInput(d)).toBe('2026-11-07T18:05');
    expect(fromLocalInput('2026-11-07T18:05')?.getTime()).toBe(d.getTime());
    expect(toLocalInput(null)).toBe('');
    expect(fromLocalInput('')).toBeNull();
    expect(fromLocalInput('tomorrow')).toBeUndefined();
  });

  it('last call on a block event: Exos is the seller, the storefront stays on Exos', () => {
    expect(parseLastCallStatus({ active: true, remaining: 8, threshold: 10, primary_source: 'external' })!.primary).toBe('exos');
    const sale = parsePublicSale({ last_call: true, sells_on: 'exos', sells_on_url: null });
    expect(sellsElsewhere(sale)).toBe(false);
  });
});
