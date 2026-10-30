import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  DISCOVERY_CHANNELS,
  FREE_TIER_MANUAL_CAP,
  FREE_TIER_MAX_CAPACITY_DEFAULT,
  MANUAL_CHANNELS,
  hasManualSlot,
  parseMinutes,
  takesSlot,
  NEXT_STATUSES,
  PUBLICATION_STATUSES,
  canQueue,
  discoveryChannel,
  feedStatus,
} from '../../../supabase/functions/_shared/discovery/channels.ts';
import { discoveryRows } from './channels';

const MIGRATION = readFileSync(
  new URL('../../../supabase/migrations/20261029130000_exos_discovery_publishing.sql', import.meta.url), 'utf8');

// The seed rows: ('id', 'name', 'kind', 'region', url|NULL, verified, sort)
function seeded(): Map<string, { kind: string; region: string; url: string | null; verified: boolean }> {
  const out = new Map();
  const re = /\('([a-z0-9_]+)',\s*'[^']*',\s*'(feed|api|manual)',\s*'([^']+)',\s*(NULL|'[^']*'),\s*(true|false),\s*\d+\)/g;
  for (const m of MIGRATION.matchAll(re)) {
    out.set(m[1], { kind: m[2], region: m[3], url: m[4] === 'NULL' ? null : m[4].slice(1, -1), verified: m[5] === 'true' });
  }
  return out;
}

describe('discovery channel catalog', () => {
  it('matches the migration seed (ids, kinds, regions, URLs, verified)', () => {
    const sql = seeded();
    expect([...sql.keys()].sort()).toEqual(DISCOVERY_CHANNELS.map((c) => c.id).sort());
    for (const c of DISCOVERY_CHANNELS) {
      expect(sql.get(c.id), c.id).toEqual({ kind: c.kind, region: c.region, url: c.submissionUrl, verified: c.verified });
    }
  });

  it('has unique ids that fit the SQL check and utm tags', () => {
    const ids = DISCOVERY_CHANNELS.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const id of ids) expect(id).toMatch(/^[a-z0-9_]{2,40}$/);
  });

  it('gives every manual channel an https submission URL and a submitter', () => {
    for (const c of MANUAL_CHANNELS) {
      expect(c.submissionUrl, c.id).toMatch(/^https:\/\//);
      expect(c.submitter, c.id).toBeDefined();
      expect(c.notes.length, c.id).toBeGreaterThan(20);
    }
  });

  it('covers the NYC calendars and models Edmtrain and Meetup as manual (no write API in scope)', () => {
    for (const id of ['donyc', 'timeout_nyc', 'cityspark', 'resident_advisor', 'oh_my_rockness']) {
      expect(discoveryChannel(id)?.kind, id).toBe('manual');
    }
    expect(discoveryChannel('edmtrain')?.kind).toBe('manual');
    expect(discoveryChannel('meetup')?.kind).toBe('manual');
    expect(DISCOVERY_CHANNELS.some((c) => c.kind === 'api')).toBe(false);
    expect(discoveryChannel('google_events')?.kind).toBe('feed');
  });

  it('never lists a resale marketplace as a discovery channel', () => {
    for (const id of ['stubhub', 'seatgeek', 'vivid', 'gametime', 'tickpick', 'gotickets', 'tixel']) {
      expect(discoveryChannel(id)).toBeUndefined();
    }
  });
});

describe('statuses', () => {
  it('mirror the SQL check', () => {
    const check = MIGRATION.match(/CHECK \(status IN \(([^)]+)\)\)/)?.[1] ?? '';
    expect(check.split(',').map((s) => s.trim().replace(/'/g, ''))).toEqual([...PUBLICATION_STATUSES]);
  });

  it('allow the moves exos_discovery_set_status accepts', () => {
    expect(NEXT_STATUSES.queued).toEqual(['submitted', 'live', 'rejected']);
    expect(NEXT_STATUSES.submitted).toEqual(['live', 'rejected']);
    expect(NEXT_STATUSES.live).toEqual(['removed']);
    expect(NEXT_STATUSES.rejected).toEqual([]);
  });

  it('requeue only from not submitted / rejected / removed', () => {
    expect([null, 'not_submitted', 'rejected', 'removed'].every((s) => canQueue(s as never))).toBe(true);
    expect(['queued', 'submitted', 'live'].some((s) => canQueue(s as never))).toBe(false);
  });

  it('turn a feed blocker into live / not eligible', () => {
    expect(feedStatus(null)).toEqual({ status: 'live', reason: null });
    expect(feedStatus('no time zone')).toEqual({ status: 'not_eligible', reason: 'no time zone' });
  });
});

describe('free-tier cap and minutes', () => {
  it('match the migration (5 manual channels, cutoff default 150)', () => {
    expect(MIGRATION).toMatch(new RegExp(`<= public\\._exos_discovery_free_tier_max\\(\\)\\s+THEN ${FREE_TIER_MANUAL_CAP} END`));
    expect(MIGRATION).toMatch(new RegExp(`WHERE key = 'free_tier_max_capacity'\\), ${FREE_TIER_MAX_CAPACITY_DEFAULT}\\)`));
  });

  it('needs a slot only for a channel the event is not using', () => {
    expect(takesSlot(null)).toBe(true);
    expect(takesSlot('not_submitted')).toBe(true);
    expect(takesSlot('rejected')).toBe(false);
    expect(takesSlot('removed')).toBe(false);
    expect(hasManualSlot(5, 4)).toBe(true);
    expect(hasManualSlot(5, 5)).toBe(false);
    expect(hasManualSlot(null, 99)).toBe(true);
  });

  it('parses minutes like the RPC accepts them', () => {
    expect(parseMinutes('')).toBeNull();
    expect(parseMinutes(null)).toBeNull();
    expect(parseMinutes(' 15 ')).toBe(15);
    expect(parseMinutes('0')).toBe(0);
    expect(parseMinutes('600')).toBe(600);
    expect(parseMinutes('601')).toBe('invalid');
    expect(parseMinutes('-3')).toBe('invalid');
    expect(parseMinutes('2.5')).toBe('invalid');
  });
});

describe('discoveryRows (organizer screen)', () => {
  const NOW = new Date('2026-10-01T12:00:00Z');
  const event = {
    id: 'e1', slug: 'late', org_id: 'o1', name: 'Late Night Jazz', status: 'published',
    starts_at: '2026-11-07T02:00:00Z', timezone: 'America/New_York', currency: 'USD',
    venue_name: 'Elsewhere', venue_address: { city: 'Brooklyn', country: 'US' },
    image_url: null, tickets_sold: 0, noindex: false,
    tiers: [{ id: 't1', event_id: 'e1', name: 'GA', price: 20, capacity: 100, sold: 0, sales_start: null, sales_end: null, price_schedule: null, exclusive_tax_percent: 0 }],
  };
  const channels = DISCOVERY_CHANNELS.map((c) => ({
    id: c.id, name: c.name, kind: c.kind, region: c.region, submission_url: c.submissionUrl, verified: c.verified,
    publication: c.id === 'donyc' ? { id: 'p1', status: 'live', live_url: 'https://donyc.com/x' } : null,
  }));

  it('computes Google from feedBlocker, the catalog from catalogBlocker and the calendar from the RPC', () => {
    const rows = discoveryRows({ event, calendar: { status: 'live', reason: null }, can_edit: true, channels } as never, NOW);
    const by = new Map(rows.map((r) => [r.id, r]));
    expect(by.get('google_events')?.status).toBe('live');
    expect(by.get('calendar_ics')?.status).toBe('live');
    expect(by.get('ad_catalog')).toMatchObject({ status: 'not_eligible', reason: expect.stringContaining('image') });
    expect(by.get('donyc')).toMatchObject({ status: 'live', liveUrl: 'https://donyc.com/x' });
    expect(by.get('timeout_nyc')?.status).toBe('not_submitted');
  });

  it('marks Google not eligible when the organizer hid the event', () => {
    const rows = discoveryRows({ event: { ...event, noindex: true }, calendar: { status: 'not_eligible', reason: 'hidden' }, can_edit: true, channels } as never, NOW);
    expect(rows.find((r) => r.id === 'google_events')).toMatchObject({ status: 'not_eligible', reason: 'hidden from search by the organizer' });
  });
});
