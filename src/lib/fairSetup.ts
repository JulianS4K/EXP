// "Fair / multi-day setup" in the event editor (mig 20261113110000): a preset
// generator for county fairs, rodeos and state fairs. From a few answers (the
// days and their hours, prices, re-entry, parking and camping) it builds one
// plan that exos_fair_setup writes in a single transaction as ordinary rows
// the organizer edits afterwards:
//
//   * a day pass per day: a ticket type on that day's check-in list only;
//   * a multi-day pass on every day's list (every day, or "any N days" with
//     max_entry_days = N) and an any-day pass (max_entry_days = 1);
//   * one check-in list per day: valid_from / valid_until = that day's hours,
//     entry_day = the date (once a day per ticket, whichever gate), and the
//     re-entry preset (same-day re-entry on, or none);
//   * parking and camping as ADD-ONS with their own entry codes
//     (separate_access_barcode), on one lot list that scans add-on codes only.
//
// Why add-ons and not ticket types for parking and camping: an add-on is
// bought with the admission order (a car comes with people), has its own
// capacity (spaces, campsites) without counting toward the event's tickets
// sold or attendance, and the door already keeps them apart both ways: a
// list that admits add-ons only refuses every ticket ('addon-only-list'),
// and an add-on code is refused at a ticket list ('tickets-only-list'). A
// ticket type would count as attendance, need its own day rules and could be
// let in at a pedestrian gate.
//
// Money is integer cents here; the SQL writes the price columns.
// Pure (no network), unit-tested in fairSetup.test.ts.

import { zonedWallClockToUtc } from './datetime';

export type ReentryPreset = 'same-day' | 'none';

export interface FairDayInput {
  /** YYYY-MM-DD, the fair day. */
  date: string;
  /** HH:MM local (the event's time zone). */
  opens: string;
  /** HH:MM; at or before `opens` = after midnight (a rodeo till 1 am). */
  closes: string;
}

export interface FairProductInput {
  enabled: boolean;
  priceCents: number;
  capacity: number;
}

export interface FairSetupInput {
  timezone: string;
  days: FairDayInput[];
  reentry: ReentryPreset;
  dayPass: { priceCents: number; capacity: number };
  /** `days` null / absent = every day of the fair; N < days = any N days. */
  multiDay: FairProductInput & { days?: number | null };
  anyDay: FairProductInput;
  parking: FairProductInput;
  camping: FairProductInput;
}

export interface PlanTier {
  key: string;
  name: string;
  description: string;
  price_cents: number;
  capacity: number;
  max_entry_days?: number;
}

export interface PlanAddon {
  key: string;
  name: string;
  description: string;
  price_cents: number;
  capacity: number;
}

export type PlanList =
  | { name: string; admits: 'tickets'; tier_keys: string[]; allow_reentry: boolean;
      valid_from: string; valid_until: string; entry_day: string }
  | { name: string; admits: 'addons'; addon_keys: string[]; allow_reentry: boolean;
      valid_from: string; valid_until: string };

export interface FairPlan {
  tiers: PlanTier[];
  addons: PlanAddon[];
  lists: PlanList[];
}

export const MAX_FAIR_DAYS = 14;
export const MAX_PRICE_CENTS = 10_000_000;
export const MAX_CAPACITY = 1_000_000;

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

/** "Fri, Aug 21" for a YYYY-MM-DD (the date itself, no time zone shift). */
export function dayLabel(date: string): string {
  const [y, m, d] = date.split('-').map(Number);
  return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(y, m - 1, d)));
}

/** The next calendar date after a YYYY-MM-DD. */
export function nextDate(date: string): string {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
}

/** A day's opening and closing instants (closing after midnight rolls over). */
export function dayWindow(day: FairDayInput, timezone: string): { from: Date; until: Date } | null {
  if (!DATE_RE.test(day.date) || !TIME_RE.test(day.opens) || !TIME_RE.test(day.closes)) return null;
  const from = zonedWallClockToUtc(`${day.date}T${day.opens}`, timezone);
  const closeDate = day.closes <= day.opens ? nextDate(day.date) : day.date;
  const until = zonedWallClockToUtc(`${closeDate}T${day.closes}`, timezone);
  if (!from || !until || !(until.getTime() > from.getTime())) return null;
  return { from, until };
}

const isCents = (n: unknown) => Number.isInteger(n) && (n as number) >= 0 && (n as number) <= MAX_PRICE_CENTS;
const isCapacity = (n: unknown) => Number.isInteger(n) && (n as number) >= 1 && (n as number) <= MAX_CAPACITY;

/** What's wrong with the answers, in plain words; [] when the plan can be built. */
export function fairSetupErrors(input: FairSetupInput): string[] {
  const errs: string[] = [];
  const n = input.days.length;
  if (n === 0) errs.push('Add at least one fair day.');
  if (n > MAX_FAIR_DAYS) errs.push(`At most ${MAX_FAIR_DAYS} days at a time.`);
  const seen = new Set<string>();
  const windows: { label: string; from: number; until: number }[] = [];
  input.days.forEach((d, i) => {
    const label = DATE_RE.test(d.date) ? dayLabel(d.date) : `Day ${i + 1}`;
    if (!DATE_RE.test(d.date)) errs.push(`Day ${i + 1}: pick a date.`);
    else if (seen.has(d.date)) errs.push(`${label} is listed twice.`);
    seen.add(d.date);
    if (!TIME_RE.test(d.opens) || !TIME_RE.test(d.closes)) {
      errs.push(`${label}: set the gate hours.`);
      return;
    }
    if (d.opens === d.closes) errs.push(`${label}: the gates have to close after they open.`);
    const w = DATE_RE.test(d.date) ? dayWindow(d, input.timezone) : null;
    if (w) windows.push({ label, from: w.from.getTime(), until: w.until.getTime() });
  });
  windows.sort((a, b) => a.from - b.from);
  for (let i = 1; i < windows.length; i++) {
    if (windows[i].from < windows[i - 1].until) errs.push(`${windows[i - 1].label} and ${windows[i].label} overlap.`);
  }
  if (!isCents(input.dayPass.priceCents)) errs.push('Day pass: set a price.');
  if (!isCapacity(input.dayPass.capacity)) errs.push('Day pass: set how many per day.');
  const product = (p: FairProductInput, label: string) => {
    if (!p.enabled) return;
    if (!isCents(p.priceCents)) errs.push(`${label}: set a price.`);
    if (!isCapacity(p.capacity)) errs.push(`${label}: set how many.`);
  };
  product(input.multiDay, 'Multi-day pass');
  product(input.anyDay, 'Any-day pass');
  product(input.parking, 'Parking');
  product(input.camping, 'Camping');
  if (input.multiDay.enabled) {
    if (n < 2) errs.push('A multi-day pass needs at least two days.');
    const k = input.multiDay.days;
    if (k != null && (!Number.isInteger(k) || k < 2 || k > n)) errs.push(`Multi-day pass: pick 2 to ${n} days.`);
  }
  return errs;
}

/** The plan exos_fair_setup writes. Throws when fairSetupErrors has anything. */
export function buildFairPlan(input: FairSetupInput): FairPlan {
  const errs = fairSetupErrors(input);
  if (errs.length) throw new Error(errs[0]);
  const days = [...input.days].sort((a, b) => a.date.localeCompare(b.date));
  const n = days.length;
  const reentry = input.reentry === 'same-day';
  const entryNote = reentry ? 'Leave and come back the same day.' : 'One entry a day.';
  const tiers: PlanTier[] = days.map((d, i) => ({
    key: `day-${i + 1}`,
    name: `Day pass · ${dayLabel(d.date)}`,
    description: `Valid ${dayLabel(d.date)} only. ${entryNote}`,
    price_cents: input.dayPass.priceCents,
    capacity: input.dayPass.capacity,
  }));
  const everyDay: string[] = [];
  if (input.multiDay.enabled) {
    const k = input.multiDay.days ?? n;
    const flex = k < n;
    tiers.push({
      key: 'multi',
      name: flex ? `Any ${k} days` : `${n}-day pass`,
      description: flex
        ? `Valid on any ${k} of the ${n} days. ${entryNote}`
        : `Valid every day, ${dayLabel(days[0].date)} to ${dayLabel(days[n - 1].date)}. ${entryNote}`,
      price_cents: input.multiDay.priceCents,
      capacity: input.multiDay.capacity,
      ...(flex ? { max_entry_days: k } : {}),
    });
    everyDay.push('multi');
  }
  if (input.anyDay.enabled) {
    tiers.push({
      key: 'any',
      name: 'Any-day pass',
      description: `Valid on one day of your choice. ${entryNote}`,
      price_cents: input.anyDay.priceCents,
      capacity: input.anyDay.capacity,
      max_entry_days: 1,
    });
    everyDay.push('any');
  }

  const windows = days.map((d) => dayWindow(d, input.timezone) as { from: Date; until: Date });
  const lists: PlanList[] = days.map((d, i) => ({
    name: dayLabel(d.date),
    admits: 'tickets' as const,
    tier_keys: [`day-${i + 1}`, ...everyDay],
    allow_reentry: reentry,
    valid_from: windows[i].from.toISOString(),
    valid_until: windows[i].until.toISOString(),
    entry_day: d.date,
  }));

  const addons: PlanAddon[] = [];
  if (input.parking.enabled) {
    addons.push({
      key: 'parking', name: 'Parking', description: 'One vehicle, every fair day. Show the parking code at the lot.',
      price_cents: input.parking.priceCents, capacity: input.parking.capacity,
    });
  }
  if (input.camping.enabled) {
    addons.push({
      key: 'camping', name: 'Camping', description: 'One campsite for the fair. Show the camping code at the lot.',
      price_cents: input.camping.priceCents, capacity: input.camping.capacity,
    });
  }
  if (addons.length) {
    // Vehicles and campers come and go: the lot always allows re-entry.
    lists.push({
      name: addons.length === 2 ? 'Parking & camping' : addons[0].key === 'parking' ? 'Parking lot' : 'Campground',
      admits: 'addons',
      addon_keys: addons.map((a) => a.key),
      allow_reentry: true,
      valid_from: windows[0].from.toISOString(),
      valid_until: windows.reduce((m, w) => (w.until > m ? w.until : m), windows[0].until).toISOString(),
    });
  }
  return { tiers, addons, lists };
}

/** Default answers: three days from the event's start date, 9 am to 10 pm. */
export function defaultFairInput(startDate: string | null, timezone: string): FairSetupInput {
  const first = startDate && DATE_RE.test(startDate) ? startDate : new Date().toISOString().slice(0, 10);
  const days: FairDayInput[] = [];
  let d = first;
  for (let i = 0; i < 3; i++) {
    days.push({ date: d, opens: '09:00', closes: '22:00' });
    d = nextDate(d);
  }
  return {
    timezone,
    days,
    reentry: 'same-day',
    dayPass: { priceCents: 1500, capacity: 5000 },
    multiDay: { enabled: true, priceCents: 3500, capacity: 2000, days: null },
    anyDay: { enabled: true, priceCents: 1800, capacity: 2000 },
    parking: { enabled: true, priceCents: 1000, capacity: 500 },
    camping: { enabled: false, priceCents: 4500, capacity: 50 },
  };
}

/** One line per thing the plan creates, for the preview. */
export function planSummary(plan: FairPlan): string[] {
  const money = (c: number) => (c === 0 ? 'free' : `$${(c / 100).toFixed(2)}`);
  const out = plan.tiers.map((t) =>
    `${t.name}: ${money(t.price_cents)}, ${t.capacity.toLocaleString('en-US')} available` +
    (t.max_entry_days ? `, ${t.max_entry_days === 1 ? 'one day' : `${t.max_entry_days} days`}` : ''));
  for (const a of plan.addons) out.push(`${a.name} (own entry code): ${money(a.price_cents)}, ${a.capacity.toLocaleString('en-US')} available`);
  for (const l of plan.lists) {
    out.push(l.admits === 'addons'
      ? `Check-in list "${l.name}": ${l.addon_keys.length === 2 ? 'parking and camping' : l.addon_keys[0]} codes only, in and out`
      : `Check-in list "${l.name}": ${l.tier_keys.length} ticket types, ${l.allow_reentry ? 're-entry the same day' : 'one entry'}`);
  }
  return out;
}
