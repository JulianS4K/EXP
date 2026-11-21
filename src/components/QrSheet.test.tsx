// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import QrSheet from './QrSheet';
import PromoPlaybookPanel from './PromoPlaybookPanel';
import { placementSheet, type PrintPlacement } from '../lib/printPlacements';
import { MARKET_CATEGORIES } from '../../supabase/functions/_shared/marketplace/eventStandard.ts';
import { PLAYBOOK, playbookFor } from '../lib/promoPlaybook';
import { cityById } from '../../supabase/functions/_shared/discovery/cities.ts';

afterEach(cleanup);

const placements: PrintPlacement[] = [
  { id: 'a', event_id: 'e', name: 'Poster - Bedford Ave', slug: 'poster-bedford-ave', created_at: '2026-11-21T10:00:00Z' },
  { id: 'b', event_id: 'e', name: 'Flyer - Bar X', slug: 'flyer-bar-x', created_at: '2026-11-21T10:05:00Z' },
];

describe('QrSheet', () => {
  it('prints one labelled QR per placement, in order, never split across pages', () => {
    render(<QrSheet title="Late Jazz" items={placementSheet('https://exos.example/e/late-jazz', placements)} />);
    expect(screen.getByRole('heading', { level: 1, name: 'Late Jazz' })).toBeTruthy();
    const items = within(screen.getByRole('list')).getAllByRole('listitem');
    expect(items.map((li) => li.querySelector('p')?.textContent)).toEqual(['Poster - Bedford Ave', 'Flyer - Bar X']);
    for (const li of items) {
      expect(li.className).toContain('break-inside-avoid');
      expect(li.querySelector('svg')).not.toBeNull();
    }
    expect(screen.getByTitle('QR code for Flyer - Bar X')).toBeTruthy();
    expect(screen.getByRole('list').className).toContain('print:grid-cols-2');
  });

  it('says so when there is nothing to print', () => {
    render(<QrSheet title="Late Jazz" items={[]} />);
    expect(screen.getByText(/No placements yet/)).toBeTruthy();
  });
});

describe('PromoPlaybookPanel', () => {
  it('has a playbook for every category, Meta first, with the ad rules', () => {
    for (const c of MARKET_CATEGORIES) {
      expect(PLAYBOOK[c].platforms[0].name, c).toMatch(/^Meta/);
      // The flyer rule is NYC's: it comes with the city, not the category.
      expect(PLAYBOOK[c].policy.some((p) => p.includes('§ 10-119')), c).toBe(false);
      expect(playbookFor(c, cityById('nyc')).policy.some((p) => p.includes('§ 10-119')), c).toBe(true);
    }
    expect(playbookFor('concerts').geo).toBeNull();
    expect(playbookFor('concerts', cityById('nyc')).geo).toBe('Ads in New York City: target about 10 miles around the venue (DMA New York (501)).');
    expect(PLAYBOOK.nightlife.policy.join(' ')).toMatch(/21\+.*under 25/);
    expect(PLAYBOOK.nightlife.policy.join(' ')).toMatch(/Snap bans/);
    expect(PLAYBOOK.community.policy.join(' ')).toMatch(/dating-ad rules/);
    expect(PLAYBOOK.concerts.policy.join(' ')).toMatch(/Event ticket sales/);
    render(<PromoPlaybookPanel category="food_drink" city={cityById('nyc')} />);
    expect(screen.getByRole('heading', { level: 2, name: /Playbook: Food & Drink/ })).toBeTruthy();
    expect(screen.getByText(/events in New York City/)).toBeTruthy();
    expect(screen.getByText(/Admin Code § 10-119/)).toBeTruthy();
    expect(screen.getByText(/target 21\+/)).toBeTruthy();
  });
});
