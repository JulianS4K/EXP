// Ported from Terminal-2 tests/test_exos_link_preview.py (same cases, same expectations).
import { describe, it, expect } from 'vitest';
import {
  buildPreview,
  buildSitemap,
  dateLabel,
  effectivePrice,
  eventSummary,
  eventTags,
  fromPriceCents,
  inject,
  money,
  orgTags,
  previewTarget,
  type PublicReader,
} from './seo';
import { isLinkCrawler } from './crawler';

const EV = '11111111-1111-4111-8111-111111111111';
const TIER = '22222222-2222-4222-8222-222222222222';

describe('previewTarget', () => {
  it.each([
    [`event/${EV}`, '', ['event', EV]],
    [`event/${EV.toUpperCase()}/`, '', ['event', EV]],
    ['e/fall-party', '', ['event_slug', 'fall-party']],
    ['o/brooklyn-nights', '', ['org', 'brooklyn-nights']],
    ['l/brooklyn-nights/dj-kay', '', ['org', 'brooklyn-nights']],
    ['l/brooklyn-nights/bad code', '', null],
    [`promoter/${EV}/dj-kay`, '', ['promoter', EV]],
    ['checkout', `event=${EV}&products=${TIER}:2`, ['checkout_event', EV]],
    ['checkout', `products=${TIER}%3A2%2C${EV}%3A1`, ['checkout_tier', TIER]],
    ['checkout', 'products=junk', null],
    ['my-tickets', '', null],
    ['event/not-a-uuid', '', null],
    ['o/../../etc', '', null],
  ])('%s ?%s', (page, query, expected) => {
    expect(previewTarget(page, query)).toEqual(expected);
  });
});

describe('prices', () => {
  const now = new Date(Date.UTC(2026, 9, 1));

  it('is all-in and follows the schedule', () => {
    const tiers = [
      { price: 30, price_schedule: [{ startsAt: '2026-09-01T00:00:00Z', price: 20 }], exclusive_tax_percent: 8.875 },
      { price: 50, price_schedule: null, exclusive_tax_percent: 0 },
    ];
    // $20 early-bird is live; + 8.875% tax = 2000 + Math.round(177.5) = 2178.
    expect(fromPriceCents(tiers, now)).toBe(2178);
    expect(fromPriceCents([{ price: 17.65, exclusive_tax_percent: 10 }], now)).toBe(1765 + 177);
    expect(fromPriceCents([], now)).toBeNull();
    expect(fromPriceCents([{ price: 0 }], now)).toBe(0);
  });

  it('ignores malformed and future schedule steps; naive times are UTC', () => {
    const schedule = [
      'not-a-step',
      { price: -1, startsAt: '2026-01-01T00:00:00Z' },
      { price: 5, startsAt: 123 },
      { price: 6, startsAt: 'garbage' },
      { price: 7, startsAt: '2026-02-01T00:00:00' },
      { price: 9, startsAt: '2027-01-01T00:00:00Z' },
    ];
    expect(effectivePrice(10, schedule, now)).toBe(7);
    expect(effectivePrice(10, null, now)).toBe(10);
  });

  it('skips unparseable prices', () => {
    expect(fromPriceCents([{ price: 'abc' }, { price: 12 }])).toBe(1200);
  });

  it('labels money', () => {
    expect(money(0, 'USD')).toBe('Free');
    expect(money(2500, 'USD')).toBe('$25');
    expect(money(2550, 'EUR')).toBe('€25.50');
    expect(money(1000, 'MXN')).toBe('10 MXN');
    expect(money(123456, 'USD')).toBe('$1,234.56');
  });
});

describe('dateLabel', () => {
  it('uses the wall-clock time as written', () => {
    expect(dateLabel('2026-10-03T02:00:00Z', '2026-10-02T22:00:00')).toBe('Fri Oct 2 · 10 PM');
    expect(dateLabel('2026-10-03T02:30:00Z', null)).toBe('Sat Oct 3 · 2:30 AM');
    expect(dateLabel('2026-10-03', null)).toBe('Sat Oct 3 · 12 AM');
  });
  it('handles edges', () => {
    expect(dateLabel(null, null)).toBeNull();
    expect(dateLabel('not a date', null)).toBeNull();
    expect(dateLabel('2026-13-40T00:00:00Z', null)).toBeNull();
  });
});

const summary = (over: Record<string, unknown> = {}) =>
  eventSummary(
    {
      id: EV,
      name: 'DJ "Kay" <live>',
      starts_at: '2026-10-03T02:00:00Z',
      occurs_at_local: '2026-10-02T22:00:00',
      venue_name: 'Elsewhere',
      venue_address: { city: 'Brooklyn', region: 'NY' },
      image_url: 'https://img.example/p.jpg',
      currency: 'USD',
      ...over,
    },
    [{ price: 25, exclusive_tax_percent: 0 }],
    { name: 'Brooklyn Nights' },
  )!;

describe('tags', () => {
  it('escape and describe an event', () => {
    const tags = eventTags(summary(), `https://x.example/bridge/event/${EV}`, 'https://x.example/bridge/icon-512.png');
    expect(tags.split('application/ld+json')[0]).not.toContain('<live>');
    expect(tags).toContain('DJ &quot;Kay&quot; &lt;live&gt;');
    expect(tags).toContain('Fri Oct 2 · 10 PM · Elsewhere · from $25 all-in');
    expect(tags).toContain('og:image" content="https://img.example/p.jpg"');
    expect(tags).toContain('"@type":"Event"');
    expect(tags).toContain('\\u003clive>');
    expect(tags).toContain('index, follow');
    expect(tags).toContain('"addressLocality":"Brooklyn"');
  });

  it('keeps promoter previews out of the index, without JSON-LD', () => {
    const tags = eventTags(summary(), 'https://x.example/e', 'https://x.example/i.png', true);
    expect(tags).toContain('noindex, nofollow');
    expect(tags).not.toContain('application/ld+json');
  });

  it('handles bare and free events', () => {
    const s = eventSummary({ id: EV, name: 'Open Mic', description: 'Bring a song.' }, [])!;
    const tags = eventTags(s, 'https://x.example/e', 'https://x.example/i.png');
    expect(tags).toContain('content="Bring a song."');
    for (const k of ['"startDate"', '"location"', '"offers"', '"organizer"']) expect(tags).not.toContain(k);
    const free = eventSummary({ id: EV, name: 'Free Show', venue_name: 'Park' }, [{ price: 0 }])!;
    expect(eventTags(free, 'https://x.example/e', 'https://x.example/i.png')).toContain('Park · Free');
    const noAddr = eventSummary({ id: EV, name: 'Show', venue_name: 'Room' }, [])!;
    expect(eventTags(noAddr, 'https://x.example/e', 'https://x.example/i.png')).not.toContain('"address"');
  });

  it('needs a name', () => {
    expect(eventSummary({}, [])).toBeNull();
    expect(eventSummary(null, [])).toBeNull();
    expect(orgTags({}, 'https://x.example/o', 'https://x.example/i.png')).toBeNull();
  });

  it('org tags fall back to defaults', () => {
    const tags = orgTags({ name: 'Nights', theme: 'bad', marketing: null }, 'https://x.example/o', 'https://x.example/i.png')!;
    expect(tags).toContain('Upcoming events from Nights.');
    expect(tags).toContain('og:image" content="https://x.example/i.png"');
  });
});

describe('inject', () => {
  it('needs both markers', () => {
    const shell = '<head><!-- SSR_META_START --><title>x</title><!-- SSR_META_END --></head>';
    expect(inject(shell, '<title>y</title>')).toBe('<head><title>y</title></head>');
    expect(inject('<head></head>', '<title>y</title>')).toBe('<head></head>');
    expect(inject(shell, null)).toBe(shell);
  });
});

/** Fake reader: equality filter on one column, like the supabase query the server runs. */
function fake(data: Record<string, Array<Record<string, unknown>>>): PublicReader {
  return async (table, _cols, filter, limit) =>
    (data[table] ?? []).filter((r) => !filter || r[filter.col] === filter.val).slice(0, limit);
}

const sb = () =>
  fake({
    exos_public_events: [
      { id: EV, org_id: 'o1', name: 'Fall Party', slug: 'fall-party', starts_at: '2026-10-03T02:00:00Z', venue_name: 'Elsewhere', currency: 'USD' },
    ],
    exos_public_tiers: [{ id: TIER, event_id: EV, price: 25, exclusive_tax_percent: 0 }],
    exos_public_orgs: [{ id: 'o1', name: 'Brooklyn Nights', slug: 'bk-nights', description: 'Parties.' }],
  });

describe('buildPreview', () => {
  const base = 'https://x.example';

  it('resolves every target kind', async () => {
    expect(await buildPreview(sb(), ['event', EV], base)).toContain('Fall Party');
    expect(await buildPreview(sb(), ['event_slug', 'fall-party'], base)).toContain('Fall Party');
    const checkout = await buildPreview(sb(), ['checkout_tier', TIER], base);
    expect(checkout).toContain(`canonical" href="${base}/bridge/event/${EV}"`);
    expect(await buildPreview(sb(), ['promoter', EV], base)).toContain('noindex');
    expect(await buildPreview(sb(), ['org', 'bk-nights'], base)).toContain('Brooklyn Nights');
    expect(await buildPreview(sb(), ['event', '33333333-3333-4333-8333-333333333333'], base)).toBeNull();
  });

  it('returns null on misses', async () => {
    expect(await buildPreview(fake({}), ['org', 'nope'], base)).toBeNull();
    expect(await buildPreview(fake({}), ['checkout_tier', TIER], base)).toBeNull();
    expect(await buildPreview(fake({ exos_public_events: [{ id: EV, name: '' }] }), ['event', EV], base)).toBeNull();
    expect(await buildPreview(fake({ exos_public_events: [{ id: EV, name: 'Solo' }] }), ['event', EV], base)).toContain('Solo');
  });
});

describe('buildSitemap', () => {
  it('lists upcoming events and orgs', async () => {
    const now = new Date(Date.UTC(2026, 9, 1));
    const xml = await buildSitemap(
      fake({
        exos_public_events: [
          { id: 'e-future', starts_at: '2026-10-03T02:00:00Z', ends_at: null },
          { id: 'e-running', starts_at: '2026-09-20T02:00:00Z', ends_at: '2026-10-02T00:00:00Z' },
          { id: 'e-yesterday', starts_at: '2026-09-30T12:00:00Z', ends_at: null },
          { id: 'e-past', starts_at: '2026-09-01T02:00:00Z', ends_at: '2026-09-01T06:00:00Z' },
          { id: 'e-undated', starts_at: null },
          { id: 'e-bad-date', starts_at: 'not a date' },
        ],
        exos_public_orgs: [{ slug: 'bk-nights' }, { slug: null }, { slug: 'a&b' }],
      }),
      'https://x.example',
      now,
    );
    expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
    for (const keep of ['e-future', 'e-running', 'e-yesterday', 'e-undated', 'e-bad-date']) {
      expect(xml).toContain(`https://x.example/bridge/event/${keep}</loc>`);
    }
    expect(xml).not.toContain('e-past');
    expect(xml).toContain('https://x.example/bridge/o/bk-nights</loc>');
    expect(xml).toContain('/bridge/o/a&amp;b</loc>');
    expect(xml.split('/bridge/o/').length - 1).toBe(2);
    expect((await buildSitemap(fake({}), 'https://x.example')).endsWith('</urlset>\n')).toBe(true);
  });
});

describe('isLinkCrawler', () => {
  it('matches unfurl bots, not browsers', () => {
    expect(isLinkCrawler('facebookexternalhit/1.1')).toBe(true);
    expect(isLinkCrawler('WhatsApp/2.23')).toBe(true);
    expect(isLinkCrawler('Mozilla/5.0 (iPhone) Safari/604.1')).toBe(false);
    expect(isLinkCrawler(null)).toBe(false);
  });
});
