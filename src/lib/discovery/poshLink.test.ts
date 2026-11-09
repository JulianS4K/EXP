import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  POSH_DESCRIPTION_MAX,
  POSH_TITLE_MAX,
  POSH_WEBHOOK_WARNING,
  formatRate,
  parseCount,
  poshFunnel,
  poshKit,
  poshLinkBlockedReason,
  poshLinkEligibility,
} from './poshLink';
import { discoveryChannel } from '../../../supabase/functions/_shared/discovery/channels.ts';
import { readAttribution } from '../../../supabase/functions/_shared/attribution.ts';

const MIGRATION = readFileSync(
  new URL('../../../supabase/migrations/20261104150000_exos_posh_link_channel.sql', import.meta.url), 'utf8');
const BASE = 'https://exos.example.com/bridge';

const event = {
  id: '11111111-1111-4111-8111-111111111111',
  slug: 'late-night-jazz',
  name: 'Late Night Jazz',
  starts_at: '2026-11-07T02:00:00Z', // Fri 9 PM New York
  ends_at: '2026-11-07T07:00:00Z', // Sat 2 AM
  timezone: 'America/New_York',
  venue_name: 'Elsewhere',
  venue_address: { street: '599 Johnson Ave', city: 'Brooklyn', region: 'NY', postal: '11237', country: 'US' },
  image_url: 'https://cdn.example.com/a.jpg',
  summary: 'Two sets.',
  description_md: '**Bar** opens early.',
};

describe('posh_link channel', () => {
  it('is a manual, global, organizer-account channel with steps and an unverified link', () => {
    const c = discoveryChannel('posh_link');
    expect(c).toMatchObject({ kind: 'manual', region: 'global', submitter: 'organizer', submissionUrl: 'https://posh.vip', verified: false });
    expect(c?.steps?.join(' ')).toMatch(/Create Event.*External tickets.*external ticket URL/);
    expect(c?.notes).toMatch(/never writes to Posh/);
  });
});

describe('poshLinkEligibility', () => {
  const exos = { link_out: false, link_out_platform: null, ticket_backend: 'exos', posh_webhooks: false };

  it('offers it for an event sold on Exos', () => {
    expect(poshLinkEligibility(exos)).toEqual({ offered: true, blocked: null, warning: null });
    expect(poshLinkEligibility(null).offered).toBe(true);
  });

  it('refuses link-out events, Posh-sold ones saying they already have a Posh page', () => {
    const posh = poshLinkEligibility({ ...exos, link_out: true, link_out_platform: 'posh', ticket_backend: 'posh' });
    expect(posh.offered).toBe(false);
    expect(posh.blocked).toBe('This event is sold on Posh, so it already has a Posh page. Posh (third-party link) is for events sold on Exos.');
    const eb = poshLinkEligibility({ ...exos, link_out: true, link_out_platform: 'eventbrite', ticket_backend: 'eventbrite' });
    expect(eb).toMatchObject({ offered: false, warning: null });
    expect(eb.blocked).toMatch(/^This event is sold on Eventbrite \(a link-out event\)/);
    expect(poshLinkEligibility({ ...exos, link_out: true, link_out_platform: 'luma' }).blocked).toMatch(/sold on Luma/);
  });

  it('words the refusal as the database does (_exos_posh_link_blocked)', () => {
    const sql = (m: string) => (m.charAt(0).toLowerCase() + m.slice(1)).replace(/'/g, "''");
    expect(MIGRATION).toContain(`'${sql(poshLinkBlockedReason('posh'))}'`);
    const eb = sql(poshLinkBlockedReason('eventbrite'));
    expect(eb.startsWith('this event is sold on Eventbrite')).toBe(true);
    expect(MIGRATION).toContain(`'${eb.slice('this event is sold on Eventbrite'.length)}'`);
    expect(MIGRATION).toContain("WHEN 'eventbrite' THEN 'Eventbrite' WHEN 'luma' THEN 'Luma'");
  });

  it('warns (but offers) when Posh webhooks are connected for the event', () => {
    expect(poshLinkEligibility({ ...exos, posh_webhooks: true })).toEqual({ offered: true, blocked: null, warning: POSH_WEBHOOK_WARNING });
    expect(POSH_WEBHOOK_WARNING).toMatch(/for events sold on Exos, not Posh/);
  });

  it('warns when the event sells on another platform without being link-out', () => {
    expect(poshLinkEligibility({ ...exos, ticket_backend: 'pretix' }).warning).toMatch(/sold on pretix.*won't show/);
  });
});

describe('poshKit', () => {
  it('gives the Posh form fields in the event time zone with the tracked link', () => {
    const k = poshKit(event, BASE);
    expect(k.title).toBe('Late Night Jazz');
    expect([k.startDate, k.startTime, k.endDate, k.endTime]).toEqual(['2026-11-06', '21:00', '2026-11-07', '02:00']);
    expect(k.timezone).toBe('America/New_York');
    expect(k.when).toBe('Fri, Nov 6, 2026, 9:00 PM - Sat, Nov 7, 2026, 2:00 AM (America/New_York)');
    expect(k.venue).toBe('Elsewhere');
    expect(k.address).toBe('599 Johnson Ave, Brooklyn, NY 11237, US');
    expect(k.description).toBe('Two sets. Bar opens early.');
    expect(k.image).toBe('https://cdn.example.com/a.jpg');
    expect(k.ticketLink).toBe(`${BASE}/e/late-night-jazz?utm_source=posh_link&utm_medium=listing&utm_campaign=discovery`);
    const q = new URL(k.ticketLink).searchParams;
    expect(readAttribution((x) => q.get(x))).toMatchObject({ utm_source: 'posh_link', utm_medium: 'listing', utm_campaign: 'discovery' });
    expect(k.fields.map((f) => f.key)).toEqual(['title', 'start', 'end', 'timezone', 'venue', 'address', 'description', 'image', 'ticketLink']);
    expect(k.fields.find((f) => f.key === 'start')?.value).toBe('2026-11-06 21:00');
  });

  it('shows a same-day end as a time only', () => {
    expect(poshKit({ ...event, ends_at: '2026-11-07T04:30:00Z' }, BASE).when)
      .toBe('Fri, Nov 6, 2026, 9:00 PM - 11:30 PM (America/New_York)');
  });

  it('trims the title and description to fit', () => {
    const k = poshKit({ ...event, name: 'x'.repeat(300), summary: null, description_md: 'y '.repeat(2000) }, BASE);
    expect(k.title.length).toBe(POSH_TITLE_MAX);
    expect(k.title.endsWith('…')).toBe(true);
    expect(k.description.length).toBeLessThanOrEqual(POSH_DESCRIPTION_MAX);
    expect(k.description.endsWith('…')).toBe(true);
  });

  it('drops empty fields: no end, no http image, online events', () => {
    const k = poshKit({ ...event, ends_at: null, image_url: 'http://x/a.jpg', format: 'online' }, BASE);
    expect(k.image).toBeNull();
    expect(k.venue).toBe('Online');
    expect(k.fields.map((f) => f.key)).toEqual(['title', 'start', 'timezone', 'venue', 'description', 'ticketLink']);
    const none = poshKit({ ...event, starts_at: null, ends_at: null }, BASE);
    expect(none.when).toBe('');
    expect(none.fields.some((f) => f.key === 'timezone')).toBe(false);
  });

  it('falls back to /event/<id> without a slug', () => {
    expect(poshKit({ ...event, slug: null }, BASE).ticketLink).toContain(`/event/${event.id}?utm_source=posh_link`);
  });
});

describe('poshFunnel', () => {
  const exos = { orders: 6, tickets: 9, gross_cents: 22500, currency: 'usd' };

  it('uses the latest reading and works out the rates', () => {
    const f = poshFunnel([
      { id: 'b', as_of: '2026-11-03', page_views: 400, link_clicks: 80 },
      { id: 'a', as_of: '2026-10-28', page_views: 120, link_clicks: 30 },
    ], exos);
    expect(f.latest?.id).toBe('b');
    expect([f.views, f.clicks, f.orders, f.tickets, f.grossCents]).toEqual([400, 80, 6, 9, 22500]);
    expect(f.clickRate).toBeCloseTo(0.2);
    expect(f.orderRate).toBeCloseTo(0.075);
    expect(f.viewToOrder).toBeCloseTo(0.015);
    expect(f.notes).toEqual([]);
  });

  it('has no rates without readings or with zeros', () => {
    const none = poshFunnel([], exos);
    expect([none.clickRate, none.orderRate, none.viewToOrder]).toEqual([null, null, null]);
    expect(none.orders).toBe(6);
    expect(none.notes[0]).toMatch(/No Posh numbers yet/);
    const zero = poshFunnel([{ id: 'z', as_of: '2026-11-01', page_views: 0, link_clicks: 0 }], { ...exos, orders: 0 });
    expect([zero.clickRate, zero.orderRate, zero.viewToOrder]).toEqual([null, null, null]);
    expect(poshFunnel([{ id: 'z', as_of: '2026-11-01', page_views: 10, link_clicks: 0 }], null).clickRate).toBe(0);
  });

  it('flags readings that look wrong', () => {
    const f = poshFunnel([
      { id: 'a', as_of: '2026-11-01', page_views: 500, link_clicks: 50 },
      { id: 'b', as_of: '2026-11-02', page_views: 40, link_clicks: 60 },
    ], { ...exos, orders: 70 });
    expect(f.notes.join(' ')).toMatch(/more clicks than views/);
    expect(f.notes.join(' ')).toMatch(/2026-11-02 reading is lower than 2026-11-01/);
    expect(f.notes.join(' ')).toMatch(/More Exos orders than Posh clicks/);
  });

  it('formats rates', () => {
    expect(formatRate(null)).toBe('–');
    expect(formatRate(0)).toBe('0%');
    expect(formatRate(0.2)).toBe('20%');
    expect(formatRate(0.075)).toBe('7.5%');
    expect(formatRate(Infinity)).toBe('–');
  });
});

describe('parseCount', () => {
  it('takes whole numbers from 0, like the RPC', () => {
    expect(parseCount('')).toBeNull();
    expect(parseCount(null)).toBeNull();
    expect(parseCount(' 1,234 ')).toBe(1234);
    expect(parseCount('0')).toBe(0);
    expect(parseCount('100000000')).toBe(100000000);
    expect(parseCount('100000001')).toBe('invalid');
    expect(parseCount('-1')).toBe('invalid');
    expect(parseCount('2.5')).toBe('invalid');
    expect(parseCount('abc')).toBe('invalid');
  });

  it('matches the table and RPC bounds', () => {
    expect(MIGRATION).toContain('page_views     integer NOT NULL CHECK (page_views BETWEEN 0 AND 100000000)');
    expect(MIGRATION).toContain('p_page_views > 100000000');
  });
});
