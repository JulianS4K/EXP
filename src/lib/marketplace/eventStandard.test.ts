import { describe, expect, it } from 'vitest';
import { ageLimit, eventReadiness, marketCategory, marketSection, marketTitle } from '../../../supabase/functions/_shared/marketplace/eventStandard.ts';

describe('marketTitle', () => {
  it('strips emoji, dates, sales words and the venue; un-shouts all caps', () => {
    expect(marketTitle({ name: 'LATE NIGHT JAZZ 🎷 11/6 SOLD OUT!!', venue_name: 'Blue Room' })).toBe('Late Night Jazz');
    expect(marketTitle({ name: 'Techno Tuesdays @ Blue Room', venue_name: 'Blue Room' })).toBe('Techno Tuesdays');
    expect(marketTitle({ name: 'Nina Kraviz - Friday, November 6th 2026 (21+)' })).toBe('Nina Kraviz');
    expect(marketTitle({ name: 'Comedy Cellar Late Show — Tickets on sale now' })).toBe('Comedy Cellar Late Show');
  });
  it('leaves a normal title alone, keeps mixed case and "the" in names', () => {
    expect(marketTitle({ name: 'The xx with Special Guests' })).toBe('The xx with Special Guests');
    expect(marketTitle({ name: 'DJ Snake' })).toBe('DJ Snake');
  });
  it('falls back to the performer, else empty', () => {
    expect(marketTitle({ name: '🔥🔥 11/6 🔥🔥', primary_performer_name: 'Peggy Gou' })).toBe('Peggy Gou');
    expect(marketTitle({ name: 'SOLD OUT' })).toBe('');
    expect(marketTitle({ name: 'x'.repeat(150) })).toHaveLength(100);
  });
  it('reads the age limit for the listing notes', () => {
    expect(ageLimit('Warehouse Rave (21+)')).toBe('21+');
    expect(ageLimit('All Ages Matinee')).toBeNull();
  });
});

describe('marketSection', () => {
  it('price phases of the same entry are General Admission', () => {
    for (const n of ['GA', 'General Admission', 'Early Bird', 'Phase 2', 'Tier 1', 'Presale', 'Door', 'Last Chance Tickets', 'Regular']) {
      expect(marketSection({ name: n })).toBe('General Admission');
    }
  });
  it('VIP, tables, named areas and the organizer label', () => {
    expect(marketSection({ name: 'VIP Early Bird' })).toBe('VIP');
    expect(marketSection({ name: 'V.I.P. Meet & Greet' })).toBe('VIP Meet & Greet');
    expect(marketSection({ name: 'Bottle Service Booth' })).toBe('Table');
    expect(marketSection({ name: 'Anything', is_table: true })).toBe('Table');
    expect(marketSection({ name: 'BALCONY' })).toBe('Balcony');
    expect(marketSection({ name: 'Early Bird', section_label: 'Mezzanine' })).toBe('Mezzanine');
    expect(marketSection({ name: 'Artist Lounge' })).toBe('Artist Lounge');
  });
});

describe('marketCategory', () => {
  it('maps Exos categories and genres to the marketplaces\' categories', () => {
    expect(marketCategory({ category: 'Music', genres: ['Jazz'] })).toBe('concerts');
    expect(marketCategory({ category: 'Nightlife', genres: ['Club'] })).toBe('nightlife');
    expect(marketCategory({ category: 'Arts', genres: ['Theatre'] })).toBe('theater');
    expect(marketCategory({ category: 'Nightlife', genres: ['Festival'] })).toBe('festivals');
    expect(marketCategory({ category: 'Comedy' })).toBe('comedy');
    expect(marketCategory({ category: 'Sports', genres: ['Basketball'] })).toBe('sports');
    expect(marketCategory({ category: 'Tech', genres: ['Conference'] })).toBe('other');
    expect(marketCategory({ name: 'Tuesday Stand-Up Showcase' })).toBe('comedy');
  });
});

describe('eventReadiness', () => {
  const ev = {
    name: 'Late Night Jazz', primary_performer_name: 'Trio', category: 'Music', starts_at: '2026-11-07T02:00:00Z',
    timezone: 'America/New_York', venue_name: 'Blue Room',
    venue_address: { city: 'Brooklyn', region: 'NY', country: 'US' }, currency: 'USD',
  };
  it('a complete event is ready everywhere (TEvo still needs staff to link it)', () => {
    const r = eventReadiness(ev, [{ name: 'GA' }], ['stubhub', 'seatgeek', 'vivid', 'evo']);
    expect(r.every((x) => x.ready)).toBe(true);
    expect(r.find((x) => x.channel === 'evo')!.warnings.join()).toMatch(/staff to link/);
    expect(r.find((x) => x.channel === 'stubhub')!.warnings).toEqual([]);
  });
  it('says what blocks which marketplace and what hurts matching', () => {
    const r = eventReadiness({ ...ev, timezone: null, venue_address: {}, currency: 'EUR', primary_performer_name: null },
      [{ name: 'Early Bird' }], ['stubhub', 'vivid', 'seatgeek']);
    const by = Object.fromEntries(r.map((x) => [x.channel, x]));
    expect(by.stubhub.blocking.join()).toMatch(/venue city/);
    expect(by.vivid.blocking.join()).toMatch(/time zone/);
    expect(by.vivid.blocking.join()).toMatch(/USD only/);
    expect(by.seatgeek.ready).toBe(true);
    expect(by.seatgeek.warnings.join('|')).toMatch(/headliner/);
    expect(by.seatgeek.warnings.join('|')).toMatch(/Early Bird → General Admission/);
  });
  it('blocks without a title, start or venue', () => {
    const r = eventReadiness({ name: 'SOLD OUT 🔥' }, [], ['gametime'])[0];
    expect(r.ready).toBe(false);
    expect(r.blocking).toHaveLength(3);
  });
});
