import { describe, expect, it } from 'vitest';
import { describeSplit, parseChannelSplit } from './channelSplitModel';

describe('channel split', () => {
  it('parses the preview', () => {
    const s = parseChannelSplit({
      mode: 'auto', reserve_pct: 10, taper_hours: 48, tapered: false, last_run_at: '2026-10-14T09:00:00Z',
      tiers: [{ tier_id: 't1', unsold: 100, reserve: 10, shares: { stubhub: 45, seatgeek: '45' } }],
    });
    expect(s).toEqual({
      mode: 'auto', reservePct: 10, taperHours: 48, tapered: false, lastRunAt: '2026-10-14T09:00:00Z',
      tiers: [{ tierId: 't1', unsold: 100, reserve: 10, shares: { stubhub: 45, seatgeek: 45 } }],
    });
    expect(parseChannelSplit(null)).toMatchObject({ mode: 'manual', reservePct: 10, taperHours: 48, tiers: [] });
  });
  it('describes before and inside the taper', () => {
    expect(describeSplit({ reservePct: 10, taperHours: 48, tapered: false }))
      .toBe('Exos keeps 10% (at least one pack); the rest is shared evenly. 48 hours before the show it drops to one pack.');
    expect(describeSplit({ reservePct: 10, taperHours: 24, tapered: true }))
      .toBe('Inside the last 24 hours: Exos keeps one pack (your max per order) and the marketplaces share the rest.');
  });
});
