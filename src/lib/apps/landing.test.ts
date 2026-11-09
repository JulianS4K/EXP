import { describe, expect, it } from 'vitest';
import { PRODUCT_FACTS, type ProductFact } from '../hosting/productFacts';
import { APP_LINKS } from './links';
import {
  APP_LANDINGS, PRICING_FACT_IDS, SIGNUP_PATH, appLanding, appLandingAt, eventsCopy, landingClaims,
} from './landing';

const byId = new Map(PRODUCT_FACTS.map((f) => [f.id, f]));

describe('app landing pages', () => {
  it('has the four apps at /apps/<id>', () => {
    expect(APP_LANDINGS.map((a) => a.path)).toEqual(['/apps/door', '/apps/events', '/apps/promote', '/apps/money']);
    for (const a of APP_LANDINGS) expect(a.path).toBe(`/apps/${a.id}`);
  });

  it('matches the footer links', () => {
    expect(APP_LANDINGS.map(({ id, path, name }) => ({ id, path, name }))).toEqual(APP_LINKS);
  });

  it('names only facts a page may claim (live or at launch)', () => {
    for (const a of APP_LANDINGS) {
      for (const id of [...a.factIds, ...PRICING_FACT_IDS]) {
        const f = byId.get(id);
        expect(f, `${a.id}: ${id} is not in the registry`).toBeDefined();
        expect(['live', 'at_launch'], `${a.id}: ${id} is ${f?.status}`).toContain(f!.status);
      }
      expect(new Set(a.factIds).size).toBe(a.factIds.length);
    }
  });

  it('only says "sell tickets" on the Events page once paid checkout is live', () => {
    const events = appLanding('events');
    const copy = [events.title, events.description, events.headline];
    if (byId.get('paid-checkout')!.status !== 'live') {
      for (const t of copy) expect(t.toLowerCase()).not.toContain('sell tickets');
    }
    // Both branches, whatever the registry says today.
    const withStatus = (status: ProductFact['status']) =>
      PRODUCT_FACTS.map((f) => (f.id === 'paid-checkout' ? { ...f, status } : f));
    for (const status of ['at_launch', 'off', 'not_shipped'] as const) {
      for (const t of Object.values(eventsCopy(withStatus(status)))) expect(t.toLowerCase()).not.toContain('sell tickets');
    }
    expect(eventsCopy(withStatus('live')).headline).toBe('Create an event page and sell tickets.');
  });

  it('shows the pricing facts on every page, labelled coming at launch while they are', () => {
    const pricing = landingClaims(PRICING_FACT_IDS);
    expect(pricing.map((c) => c.id)).toEqual([...PRICING_FACT_IDS]);
    for (const c of pricing) expect(c.atLaunch).toBe(byId.get(c.id)!.status === 'at_launch');
  });

  it('sends the door page to /door and the others to sign-up', () => {
    expect(appLanding('door').cta.to).toBe('/door');
    for (const id of ['events', 'promote', 'money'] as const) expect(appLanding(id).cta.to).toBe(SIGNUP_PATH);
  });

  it('finds a page by path', () => {
    expect(appLandingAt('apps/door')?.id).toBe('door');
    expect(appLandingAt('/apps/money/?utm_source=x')?.id).toBe('money');
    expect(appLandingAt('apps')).toBeNull();
    expect(appLandingAt('apps/box-office')).toBeNull();
  });

  it('drops a fact that is off, not shipped or unknown, and labels at-launch ones', () => {
    const facts: ProductFact[] = [
      { id: 'a', audience: 'organizer', claim: 'A works.', status: 'live', code: [] },
      { id: 'b', audience: 'organizer', claim: 'B soon.', status: 'at_launch', code: [] },
      { id: 'c', audience: 'organizer', claim: 'C is off.', status: 'off', code: [], note: 'x' },
      { id: 'd', audience: 'organizer', claim: 'D not built.', status: 'not_shipped', code: [], note: 'x' },
    ];
    expect(landingClaims(['d', 'b', 'zz', 'c', 'a'], facts)).toEqual([
      { id: 'b', claim: 'B soon.', atLaunch: true },
      { id: 'a', claim: 'A works.', atLaunch: false },
    ]);
  });

  it('renders every bullet it names (a status change drops it from the page, never the other way)', () => {
    for (const a of APP_LANDINGS) {
      expect(landingClaims(a.factIds).map((c) => c.id)).toEqual(a.factIds);
    }
  });
});
