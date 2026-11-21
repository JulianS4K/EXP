import { describe, expect, it } from 'vitest';
import {
  buildFairPlan, dayLabel, dayWindow, defaultFairInput, fairSetupErrors, nextDate, planSummary, type FairSetupInput,
} from './fairSetup';

const base = (over: Partial<FairSetupInput> = {}): FairSetupInput => ({
  ...defaultFairInput('2027-08-20', 'America/Phoenix'),
  ...over,
});

describe('fair setup preset generator', () => {
  it('labels and steps dates without a time zone shift', () => {
    expect(dayLabel('2027-08-20')).toBe('Fri, Aug 20');
    expect(nextDate('2027-08-31')).toBe('2027-09-01');
    expect(nextDate('2028-02-28')).toBe('2028-02-29');
  });

  it("works out a day's hours in the event's time zone, rolling over midnight", () => {
    const w = dayWindow({ date: '2027-08-20', opens: '09:00', closes: '22:00' }, 'America/Phoenix');
    expect(w?.from.toISOString()).toBe('2027-08-20T16:00:00.000Z');
    expect(w?.until.toISOString()).toBe('2027-08-21T05:00:00.000Z');
    const late = dayWindow({ date: '2027-08-20', opens: '18:00', closes: '01:00' }, 'America/Phoenix');
    expect(late?.until.toISOString()).toBe('2027-08-21T08:00:00.000Z');
    expect(dayWindow({ date: '2027-08-20', opens: '9am', closes: '22:00' }, 'UTC')).toBeNull();
  });

  it('builds a day pass and a day list per day, the multi-day and any-day passes on every day', () => {
    const plan = buildFairPlan(base());
    expect(plan.tiers.map((t) => t.key)).toEqual(['day-1', 'day-2', 'day-3', 'multi', 'any']);
    expect(plan.tiers[0]).toMatchObject({ name: 'Day pass · Fri, Aug 20', price_cents: 1500, capacity: 5000 });
    expect(plan.tiers[0].max_entry_days).toBeUndefined();
    expect(plan.tiers[3]).toMatchObject({ name: '3-day pass', price_cents: 3500 });
    expect(plan.tiers[3].max_entry_days).toBeUndefined();
    expect(plan.tiers[4]).toMatchObject({ name: 'Any-day pass', max_entry_days: 1 });
    const days = plan.lists.filter((l) => l.admits === 'tickets');
    expect(days).toHaveLength(3);
    expect(days[1]).toEqual({
      name: 'Sat, Aug 21', admits: 'tickets', tier_keys: ['day-2', 'multi', 'any'], allow_reentry: true,
      valid_from: '2027-08-21T16:00:00.000Z', valid_until: '2027-08-22T05:00:00.000Z', entry_day: '2027-08-21',
    });
  });

  it('applies the re-entry preset to every day list, never to the lot', () => {
    const plan = buildFairPlan(base({ reentry: 'none' }));
    const days = plan.lists.filter((l) => l.admits === 'tickets');
    expect(days.every((l) => !l.allow_reentry)).toBe(true);
    expect(plan.tiers[0].description).toContain('One entry a day.');
    const lot = plan.lists.find((l) => l.admits === 'addons');
    expect(lot?.allow_reentry).toBe(true);
  });

  it('makes parking and camping add-ons with their own lot list spanning the fair', () => {
    const plan = buildFairPlan(base({ camping: { enabled: true, priceCents: 4500, capacity: 40 } }));
    expect(plan.addons.map((a) => a.key)).toEqual(['parking', 'camping']);
    const lot = plan.lists.find((l) => l.admits === 'addons');
    expect(lot).toEqual({
      name: 'Parking & camping', admits: 'addons', addon_keys: ['parking', 'camping'], allow_reentry: true,
      valid_from: '2027-08-20T16:00:00.000Z', valid_until: '2027-08-23T05:00:00.000Z',
    });
    // Lot staff scan only lot products: no ticket type is on the lot list, and
    // no add-on is on a day list.
    expect('tier_keys' in (lot as object)).toBe(false);
    expect(plan.lists.filter((l) => l.admits === 'tickets').every((l) => !('addon_keys' in l))).toBe(true);
  });

  it('names the lot after what it holds, and has none without lot products', () => {
    expect(buildFairPlan(base()).lists.at(-1)?.name).toBe('Parking lot');
    const campOnly = buildFairPlan(base({ parking: { enabled: false, priceCents: 0, capacity: 1 },
      camping: { enabled: true, priceCents: 4500, capacity: 40 } }));
    expect(campOnly.lists.at(-1)?.name).toBe('Campground');
    const none = buildFairPlan(base({ parking: { enabled: false, priceCents: 0, capacity: 1 } }));
    expect(none.addons).toEqual([]);
    expect(none.lists.every((l) => l.admits === 'tickets')).toBe(true);
  });

  it('makes an "any N days" flex pass when fewer days than the fair', () => {
    const plan = buildFairPlan(base({ multiDay: { enabled: true, priceCents: 2800, capacity: 100, days: 2 } }));
    expect(plan.tiers.find((t) => t.key === 'multi')).toMatchObject({ name: 'Any 2 days', max_entry_days: 2 });
  });

  it('sorts days and leaves off the passes that are turned off', () => {
    const plan = buildFairPlan(base({
      days: [{ date: '2027-08-22', opens: '10:00', closes: '20:00' }, { date: '2027-08-21', opens: '10:00', closes: '20:00' }],
      anyDay: { enabled: false, priceCents: 0, capacity: 1 },
    }));
    expect(plan.lists.map((l) => l.name)).toEqual(['Sat, Aug 21', 'Sun, Aug 22', 'Parking lot']);
    expect(plan.tiers.map((t) => t.key)).toEqual(['day-1', 'day-2', 'multi']);
    expect(plan.tiers.find((t) => t.key === 'multi')?.name).toBe('2-day pass');
  });

  it('says what is wrong in plain words', () => {
    expect(fairSetupErrors(base({ days: [] }))).toContain('Add at least one fair day.');
    expect(fairSetupErrors(base({ days: [{ date: '2027-08-20', opens: '09:00', closes: '22:00' },
      { date: '2027-08-20', opens: '09:00', closes: '22:00' }] }))).toContain('Fri, Aug 20 is listed twice.');
    expect(fairSetupErrors(base({ days: [{ date: '2027-08-20', opens: '09:00', closes: '03:00' },
      { date: '2027-08-21', opens: '01:00', closes: '22:00' }] }))).toContain('Fri, Aug 20 and Sat, Aug 21 overlap.');
    expect(fairSetupErrors(base({ dayPass: { priceCents: 12.5, capacity: 10 } }))).toContain('Day pass: set a price.');
    expect(fairSetupErrors(base({ dayPass: { priceCents: 100, capacity: 0 } }))).toContain('Day pass: set how many per day.');
    expect(fairSetupErrors(base({ days: [{ date: '2027-08-20', opens: '09:00', closes: '22:00' }] })))
      .toContain('A multi-day pass needs at least two days.');
    expect(fairSetupErrors(base({ multiDay: { enabled: true, priceCents: 1, capacity: 1, days: 4 } })))
      .toContain('Multi-day pass: pick 2 to 3 days.');
    expect(fairSetupErrors(base({ days: [{ date: '2027-08-20', opens: '09:00', closes: '09:00' }],
      multiDay: { enabled: false, priceCents: 0, capacity: 1 } }))).toContain('Fri, Aug 20: the gates have to close after they open.');
    expect(fairSetupErrors(base())).toEqual([]);
    expect(() => buildFairPlan(base({ days: [] }))).toThrow('Add at least one fair day.');
  });

  it('stays inside what exos_fair_setup accepts', () => {
    const plan = buildFairPlan(base({ camping: { enabled: true, priceCents: 0, capacity: 1 },
      days: Array.from({ length: 14 }, (_, i) => ({ date: `2027-08-${String(10 + i).padStart(2, '0')}`, opens: '09:00', closes: '22:00' })) }));
    expect(plan.tiers.length).toBeLessThanOrEqual(30);
    expect(plan.lists.length).toBeLessThanOrEqual(40);
    for (const t of plan.tiers) {
      expect(t.key).toMatch(/^[a-z0-9-]{1,40}$/);
      expect(t.name.length).toBeLessThanOrEqual(80);
      expect(Number.isInteger(t.price_cents)).toBe(true);
    }
    for (const l of plan.lists) {
      expect(l.name.length).toBeLessThanOrEqual(60);
      expect(Date.parse(l.valid_until) - Date.parse(l.valid_from)).toBeLessThanOrEqual(31 * 864e5);
    }
    expect(JSON.stringify(plan).length).toBeLessThan(65536);
  });

  it('summarizes what it will create', () => {
    const lines = planSummary(buildFairPlan(base({ reentry: 'none' })));
    expect(lines).toContain('Any-day pass: $18.00, 2,000 available, one day');
    expect(lines).toContain('Parking (own entry code): $10.00, 500 available');
    expect(lines).toContain('Check-in list "Fri, Aug 20": 3 ticket types, one entry');
    expect(lines).toContain('Check-in list "Parking lot": parking codes only, in and out');
  });
});
