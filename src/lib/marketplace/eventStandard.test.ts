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
  it("prefers the organizer's age limit over the title", () => {
    expect(ageLimit('Warehouse Rave', 18)).toBe('18+');
    expect(ageLimit('Warehouse Rave (21+)', 18)).toBe('18+');
    expect(ageLimit('Warehouse Rave (21+)', 0)).toBeNull(); // all ages
    expect(ageLimit('Warehouse Rave (21+)', null)).toBe('21+');
    expect(ageLimit('Warehouse Rave (21+)', undefined)).toBe('21+');
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
    // A conference is a business event now (it was "other" before 2026-11-21).
    expect(marketCategory({ category: 'Tech', genres: ['Conference'] })).toBe('business');
    expect(marketCategory({ name: 'Tuesday Stand-Up Showcase' })).toBe('comedy');
  });

  // Every category and genre chip the event editor offers (lib/eventTaxonomy.ts),
  // with what it mapped to before the food_drink / community / business split.
  // Only the ones that were "other" may move, and only into a new category.
  it('keeps the older mappings for every editor category and genre', () => {
    const same: Array<[string, string[], string]> = [
      ['Music', ['Electronic'], 'concerts'], ['Music', ['Hip Hop'], 'concerts'], ['Music', ['Rock'], 'concerts'],
      ['Music', ['Jazz'], 'concerts'], ['Music', ['Classical'], 'concerts'], ['Music', ['Latin'], 'concerts'],
      ['Music', [], 'concerts'],
      ['Nightlife', ['Club'], 'nightlife'], ['Nightlife', ['Bar'], 'nightlife'], ['Nightlife', ['Lounge'], 'nightlife'],
      ['Nightlife', ['Festival'], 'festivals'], ['Nightlife', ['Underground'], 'nightlife'], ['Nightlife', ['House Party'], 'nightlife'],
      ['Nightlife', [], 'nightlife'],
      ['Sports', ['Basketball'], 'sports'], ['Sports', ['Esports'], 'sports'], ['Sports', ['Combat Sports'], 'sports'],
      ['Arts', ['Gallery'], 'theater'], ['Arts', ['Theatre'], 'theater'], ['Arts', ['Dance'], 'theater'],
      ['Arts', ['Performance Art'], 'theater'], ['Arts', ['Photography'], 'theater'], ['Arts', ['Fashion'], 'theater'],
      ['Food', ['Festival'], 'festivals'],
      ['Tech', ['AI'], 'other'], ['Tech', ['Web3'], 'other'], ['Tech', [], 'other'],
      ['Wellness', [], 'other'],
    ];
    for (const [category, genres, want] of same) expect(marketCategory({ category, genres }), `${category} ${genres}`).toBe(want);
    // No category: the title decides, a concert by default.
    expect(marketCategory({ name: 'Late Night Jazz' })).toBe('concerts');
    expect(marketCategory({ name: 'Lumen Live' })).toBe('concerts');
    expect(marketCategory({ name: 'Warehouse Rave' })).toBe('nightlife');
    expect(marketCategory({ name: 'Jazz Brunch' })).toBe('concerts');
    expect(marketCategory({ name: 'Swan Lake Ballet' })).toBe('theater');
    expect(marketCategory({ name: 'Drag Brunch' })).toBe('theater');
    expect(marketCategory({ category: 'Arts', genres: ['Drag'] })).toBe('theater');
  });

  it('puts food, community and business events in their own categories', () => {
    expect(marketCategory({ category: 'Food', genres: ['Tasting'] })).toBe('food_drink');
    expect(marketCategory({ category: 'Food', genres: ['Pop-up'] })).toBe('food_drink');
    expect(marketCategory({ category: 'Food', genres: ['Workshop'] })).toBe('food_drink');
    expect(marketCategory({ category: 'Food', genres: ['Dining Experience'] })).toBe('food_drink');
    expect(marketCategory({ category: 'Food' })).toBe('food_drink');
    expect(marketCategory({ category: 'Tech', genres: ['Meetup'] })).toBe('community');
    expect(marketCategory({ category: 'Tech', genres: ['Workshop'] })).toBe('community');
    expect(marketCategory({ category: 'Tech', genres: ['Hackathon'] })).toBe('community');
    expect(marketCategory({ category: 'Tech', name: 'Founders Networking Night' })).toBe('business');
    expect(marketCategory({ category: 'Games', genres: ['Dice'] })).toBe('community');
    expect(marketCategory({ category: 'Community' })).toBe('community');
    expect(marketCategory({ category: 'Business' })).toBe('business');
    // No category: a title that clearly names one, and no music.
    expect(marketCategory({ name: 'Dungeons & Dragons One-Shot' })).toBe('community');
    expect(marketCategory({ name: 'D&D Night' })).toBe('community');
    expect(marketCategory({ name: 'Board Game Night' })).toBe('community');
    expect(marketCategory({ name: 'Pub Trivia' })).toBe('community');
    expect(marketCategory({ name: 'Natural Wine Tasting' })).toBe('food_drink');
    expect(marketCategory({ name: 'Startup Networking Mixer' })).toBe('business');
    expect(marketCategory({ name: 'Book Club: Middlemarch' })).toBe('community');
    expect(marketCategory({ name: 'Supper Club' })).toBe('food_drink');
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
