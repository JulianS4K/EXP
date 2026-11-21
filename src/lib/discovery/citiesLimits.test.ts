import { describe, expect, it } from 'vitest';
import { CITIES, cityById, cityOf, inUS, regionApplies } from '../../../supabase/functions/_shared/discovery/cities.ts';
import { CHANNEL_LIMITS, RESALE_MARKETPLACES, channelLimits, hiddenByLimit, limitFacts } from '../../../supabase/functions/_shared/discovery/limits.ts';
import { DISCOVERY_CHANNELS, MANUAL_CHANNELS, rankChannels } from '../../../supabase/functions/_shared/discovery/channels.ts';

const NYC = cityById('nyc');

describe('cities', () => {
  it('ships NYC only, as data', () => {
    expect(CITIES.map((c) => c.id)).toEqual(['nyc']);
    expect(NYC).toMatchObject({ name: 'New York City', regions: ['NYC'], country: 'US', neighborhoodsPath: '/nyc' });
    expect(NYC!.boroughs).toHaveLength(5);
    expect(Object.keys(NYC!.adGeo.zipsByBorough)).toEqual([...NYC!.boroughs]);
    expect(NYC!.adGeo.radiusMiles).toBeGreaterThan(0);
    // Every city region code is one some channel can carry; channel regions are city codes or wider.
    for (const c of DISCOVERY_CHANNELS) expect(['global', 'US', ...CITIES.flatMap((x) => x.regions)], c.id).toContain(c.region);
  });

  it('finds the city from a venue address', () => {
    expect(cityOf({ city: 'Brooklyn', region: 'NY', country: 'US' })?.id).toBe('nyc');
    expect(cityOf({ city: 'New York', region: 'NY' })?.id).toBe('nyc');
    expect(cityOf({ city: 'Buffalo', region: 'New York' })).toBeNull();
    expect(cityOf({ city: 'Chicago' })).toBeNull();
    expect(cityOf(null)).toBeNull();
    expect(inUS({ country: 'US' })).toBe(true);
    expect(inUS({})).toBe(true);
    expect(inUS({ country: 'Canada' })).toBe(false);
  });

  it('applies city regions in their city only', () => {
    expect(regionApplies('NYC', NYC)).toBe(true);
    expect(regionApplies('NYC', null)).toBe(false);
    expect(regionApplies('global', null)).toBe(true);
    expect(regionApplies('US', null, true)).toBe(true);
    expect(regionApplies('US', null, false)).toBe(false);
  });

  it('ranks city channels for events there and falls back to wider ones elsewhere', () => {
    const rows = MANUAL_CHANNELS.map((c) => ({ id: c.id }));
    expect(rankChannels(rows, 'comedy', { city: NYC }).map((r) => r.id)).toEqual(['timeout_nyc', 'the_skint', 'donyc', 'cityspark', 'posh_link']);
    expect(rankChannels(rows, 'comedy', { city: null }).map((r) => r.id)).toEqual(['cityspark', 'posh_link']);
    expect(rankChannels(rows, 'concerts', { city: null }).map((r) => r.id))
      .toEqual(['bandsintown', 'spotify', 'songkick', 'cityspark', 'posh_link']);
    // Outside the US, a US-only channel (CitySpark) doesn't fit either.
    expect(rankChannels(rows, 'concerts', { city: null, us: false }).map((r) => r.id)).toEqual(['bandsintown', 'spotify', 'songkick', 'posh_link']);
    const all = rankChannels(rows, 'comedy', { city: null, showAll: true });
    expect(all.find((r) => r.id === 'donyc')?.fits).toBe(false);
  });
});

describe('channel limits', () => {
  const free = limitFacts({ tiers: [{ price: 0 }, { price: '0.00' }] });
  const paid = limitFacts({ tiers: [{ price: 0 }, { price: 25 }] });
  it('works out the facts', () => {
    expect(free).toEqual({ free: true, inviteOnly: false, hidden: false });
    expect(paid.free).toBe(false);
    expect(limitFacts({ tiers: [], noindex: true })).toEqual({ free: true, inviteOnly: true, hidden: true });
  });

  it('hides Shotgun and the resale marketplaces for free events only', () => {
    expect(hiddenByLimit('shotgun', free)).toBe(true);
    expect(hiddenByLimit('shotgun', paid)).toBe(false);
    for (const m of RESALE_MARKETPLACES) {
      expect(hiddenByLimit(m, free), m).toBe(true);
      expect(hiddenByLimit(m, paid), m).toBe(false);
    }
    expect(channelLimits('stubhub', free)[0].reason).toMatch(/nothing to resell/);
  });

  it('warns on the Meetup and AllEvents plan caps, always', () => {
    expect(channelLimits('meetup', paid)).toMatchObject([{ id: 'meetup_starter_cap', action: 'warn' }]);
    expect(channelLimits('meetup', paid)[0].reason).toMatch(/10 attendees.*Standard or Pro/);
    expect(channelLimits('allevents', free)[0].reason).toMatch(/5 active upcoming events/);
  });

  it('warns that Google needs a free event to be publicly bookable', () => {
    expect(channelLimits('google_events', free)).toEqual([]);
    expect(channelLimits('google_events', { ...free, hidden: true })[0].reason).toMatch(/invite-only or hidden/);
    expect(channelLimits('google_events', limitFacts({ tiers: [] }))).toHaveLength(1);
    expect(channelLimits('google_events', { ...paid, hidden: true })).toEqual([]);
  });

  it('is one table with a reason per row', () => {
    for (const l of CHANNEL_LIMITS) {
      expect(l.id).toMatch(/^[a-z0-9_]+$/);
      expect(l.channels.length).toBeGreaterThan(0);
      expect(['warn', 'block']).toContain(l.action);
      expect(l.reason.length).toBeGreaterThan(20);
      expect(l.source.length).toBeGreaterThan(5);
    }
    expect(new Set(CHANNEL_LIMITS.map((l) => l.id)).size).toBe(CHANNEL_LIMITS.length);
    expect(channelLimits('donyc', free)).toEqual([]);
  });
});
