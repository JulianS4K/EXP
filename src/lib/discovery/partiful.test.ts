import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { PARTIFUL_CHANNEL, partifulKit, partifulTicketLink } from './partiful';
import { centerSquare } from '../coverImages';
import { playbookFor } from '../promoPlaybook';
import { summarizeSources } from '../sourceReport';
import { readAttribution } from '../../../supabase/functions/_shared/attribution.ts';

const MIG = readFileSync(new URL('../../../supabase/migrations/20261121153700_exos_promotion.sql', import.meta.url), 'utf8');
const BASE = 'https://exos.example/bridge';
const EV = {
  id: 'e1', slug: 'warehouse-night', name: 'Warehouse Night', starts_at: '2026-11-28T03:00:00Z', timezone: 'America/New_York',
  venue_name: 'Elsewhere', venue_address: { street: '599 Johnson Ave', city: 'Brooklyn', region: 'NY', postal: '11237', country: 'US' },
  image_url: 'https://img.example.com/cover.jpg', summary: 'Techno till late.', description: null, description_md: null, currency: 'USD',
};

describe('Partiful kit', () => {
  it('tags the Exos ticket link partiful / referral / discovery, and the sanitizer keeps it', () => {
    const link = partifulTicketLink(BASE, EV);
    expect(link).toBe(`${BASE}/e/warehouse-night?utm_source=partiful&utm_medium=referral&utm_campaign=discovery`);
    const u = new URL(link);
    expect(readAttribution((k) => u.searchParams.get(k) ?? undefined))
      .toEqual({ utm_source: 'partiful', utm_medium: 'referral', utm_campaign: 'discovery' });
    expect(PARTIFUL_CHANNEL).toBe('partiful');
  });

  it('gives copy-ready title, when, venue, description with the ticket link, and the cover', () => {
    const kit = partifulKit(EV, [{ price: 20 }], BASE, new Date('2026-11-21T12:00:00Z'));
    const f = Object.fromEntries(kit.fields.map((x) => [x.key, x.value]));
    expect(f.title).toBe('Warehouse Night');
    expect(f.when).toBe('Fri, Nov 27, 2026, 10:00 PM');
    expect(f.where).toBe('Elsewhere, 599 Johnson Ave, Brooklyn, NY 11237, US');
    expect(f.description).toBe(`Techno till late.\n\nTickets ($20.00 all-in): ${kit.ticketLink}`);
    expect(f.image).toBe('https://img.example.com/cover.jpg');
    expect(kit.text.split('\n')[0]).toBe('Warehouse Night');
    expect(kit.text).toContain(kit.ticketLink);
    // No https image: no cover field.
    expect(partifulKit({ ...EV, image_url: 'http://x/y.jpg' }, [], BASE).fields.some((x) => x.key === 'image')).toBe(false);
  });

  it('crops covers to a centered square', () => {
    expect(centerSquare(1920, 1080)).toEqual({ sx: 420, sy: 0, size: 1080 });
    expect(centerSquare(800, 1200)).toEqual({ sx: 0, sy: 200, size: 800 });
  });

  it('is in the playbook for party crowds, and a recognised source', () => {
    expect(playbookFor('nightlife').creative.join(' ')).toMatch(/Partiful as the invite \/ RSVP page/);
    expect(playbookFor('community').creative.join(' ')).toMatch(/Partiful/);
    expect(playbookFor('concerts').creative.join(' ')).not.toMatch(/Partiful/);
    const s = summarizeSources([{ session_id: 's1', status: 'fulfilled', quantity: 1, amount_cents: 2000, currency: 'usd',
      attribution: { utm_source: 'partiful', utm_medium: 'referral', utm_campaign: 'discovery' } }], 'source');
    expect(s.rows[0].label).toBe('partiful / referral');
    // The channel report names it (not "Other").
    expect(MIG).toContain("WHEN 'partiful' THEN 'Partiful'");
    expect(MIG).toContain("WHEN v = 'partiful' THEN 'partiful'");
  });
});
