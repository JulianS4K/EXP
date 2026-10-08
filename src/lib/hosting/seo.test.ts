// Ported from Terminal-2 tests/test_exos_link_preview.py (same cases, same expectations).
import { describe, it, expect } from 'vitest';
import {
  buildLlmsTxt,
  buildPreview,
  buildPreviewPage,
  faqJsonLd,
  injectBody,
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

describe('online events + noindex (mig 20261005090000)', () => {
  const base = 'https://x.example';
  it('marks online and hybrid events in the JSON-LD with the public page as the virtual location', async () => {
    const online = await buildPreview(fake({
      exos_public_events: [{ id: EV, name: 'Stream', format: 'online', venue_name: 'Online' }],
    }), ['event', EV], base);
    expect(online).toContain('OnlineEventAttendanceMode');
    expect(online).toContain(`"VirtualLocation","url":"${base}/bridge/event/${EV}"`);
    expect(online).not.toContain('"Place"');
    const hybrid = await buildPreview(fake({
      exos_public_events: [{ id: EV, name: 'Both', format: 'hybrid', venue_name: 'Elsewhere' }],
    }), ['event', EV], base);
    expect(hybrid).toContain('MixedEventAttendanceMode');
    expect(hybrid).toContain('"Place"');
    expect(hybrid).toContain('VirtualLocation');
  });

  it('keeps noindex events out of previews and the sitemap', async () => {
    const hidden = await buildPreview(fake({
      exos_public_events: [{ id: EV, name: 'Private', noindex: true }],
    }), ['event', EV], base);
    expect(hidden).toContain('noindex, nofollow');
    expect(hidden).not.toContain('application/ld+json');
    const xml = await buildSitemap(fake({
      exos_public_events: [{ id: 'e-shown', starts_at: null }, { id: 'e-hidden', starts_at: null, noindex: true }],
    }), base);
    expect(xml).toContain('e-shown');
    expect(xml).not.toContain('e-hidden');
  });

  it('falls back to the old columns on a database without the migration', async () => {
    const old: PublicReader = async (table, cols, filter, limit) => {
      if (cols.includes('noindex')) throw new Error('column exos_public_events.noindex does not exist');
      return fake({
        exos_public_events: [{ id: EV, name: 'Old DB', starts_at: null }],
      })(table, cols, filter, limit);
    };
    expect(await buildPreview(old, ['event', EV], base)).toContain('OfflineEventAttendanceMode');
    expect(await buildSitemap(old, base)).toContain(`/bridge/event/${EV}`);
  });
});

describe('AI discovery (EXOS_AI_DISCOVERY, off until launch)', () => {
  const base = 'https://x.example';
  const UA_GPT = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot';
  const full = () => fake({
    exos_public_events: [{
      id: EV, org_id: 'o1', name: 'Fall Party', starts_at: '2026-10-03T02:00:00Z', venue_name: 'Elsewhere', currency: 'USD',
      venue_address: { city: 'Brooklyn' }, description: 'Four rooms <b>of</b> house.', summary: 'House till late.',
      lineup: [{ name: 'DJ Kay', role: 'headliner', set_at: '23:30' }], faq: [{ q: 'Coat check?', a: 'Yes, $3.' }],
      min_age: 21, refund_policy: 'until_7d', what_to_bring: 'Photo ID', policy_notes: 'No re-entry.', format: 'hybrid', noindex: false,
    }],
    exos_public_tiers: [
      { id: TIER, event_id: EV, name: 'GA', price: 25, exclusive_tax_percent: 0, capacity: 100, sold: 10, sort_order: 0 },
      { id: 'vip', event_id: EV, name: 'VIP', price: 60, exclusive_tax_percent: 0, capacity: 5, sold: 5, sort_order: 1 },
    ],
    exos_public_orgs: [{ id: 'o1', name: 'Brooklyn Nights', slug: 'bk-nights' }],
  });

  it('leaves AI fetchers out of the crawler list unless asked', () => {
    expect(isLinkCrawler(UA_GPT)).toBe(false);
    expect(isLinkCrawler(UA_GPT, { ai: true })).toBe(true);
    expect(isLinkCrawler('Mozilla/5.0 (compatible; Googlebot/2.1)', { ai: false })).toBe(true);
  });

  it('adds no body without content mode', async () => {
    const page = await buildPreviewPage(full(), ['event', EV], base);
    expect(page?.body).toBeNull();
    expect(page?.tags).not.toContain('FAQPage');
  });

  it('renders the event page as escaped HTML with tickets, FAQ and policies', async () => {
    const page = (await buildPreviewPage(full(), ['event', EV], base, { content: true }))!;
    const b = page.body!;
    expect(b).toContain('<h1>Fall Party</h1>');
    expect(b).toContain('House till late.');
    expect(b).toContain('Four rooms &lt;b&gt;of&lt;/b&gt; house.');
    expect(b).toContain('Elsewhere, Brooklyn · also online');
    expect(b).toContain('Ages:</strong> 21+');
    expect(b).toContain('DJ Kay (headliner, 23:30)');
    expect(b).toContain('GA: $25 (on sale)');
    expect(b).toContain('VIP: $60 (sold out)');
    expect(b).toContain(`href="${base}/bridge/event/${EV}"`);
    expect(b).toContain('<dt>Coat check?</dt><dd>Yes, $3.</dd>');
    expect(b).toContain('What to bring:</strong> Photo ID');
    expect(b).toContain('Refunds available up to 7 days before the event.');
    expect(page.tags).toContain('"@type":"FAQPage"');
  });

  it('keeps hidden events bare', async () => {
    const hidden = fake({ exos_public_events: [{ id: EV, name: 'Private', noindex: true, faq: [{ q: 'q', a: 'a' }] }] });
    const page = (await buildPreviewPage(hidden, ['event', EV], base, { content: true }))!;
    expect(page.body).toBeNull();
    expect(page.tags).not.toContain('FAQPage');
  });

  it('falls back to the plain preview on an older schema', async () => {
    const old: PublicReader = async (table, cols, filter, limit) => {
      if (/summary|noindex|capacity/.test(cols)) throw new Error('column does not exist');
      return fake({ exos_public_events: [{ id: EV, name: 'Old DB' }], exos_public_tiers: [{ event_id: EV, price: 10 }] })(table, cols, filter, limit);
    };
    const page = (await buildPreviewPage(old, ['event', EV], base, { content: true }))!;
    expect(page.tags).toContain('Old DB');
    expect(page.body).toContain('<h1>Old DB</h1>');
  });

  it('FAQ JSON-LD skips incomplete entries and escapes <', () => {
    expect(faqJsonLd([{ q: 'only a question' }])).toBeNull();
    expect(faqJsonLd(null)).toBeNull();
    expect(faqJsonLd([{ q: '</script>', a: 'x' }])).not.toContain('</script>"');
  });

  it('puts the body inside #root', () => {
    expect(injectBody('<body><div id="root"><div id="boot"></div></div></body>', '<main>x</main>'))
      .toBe('<body><div id="root">\n<main>x</main><div id="boot"></div></div></body>');
    expect(injectBody('<body></body>', '<main>x</main>')).toBe('<body></body>');
    expect(injectBody('<div id="root"></div>', null)).toBe('<div id="root"></div>');
  });

  it('builds llms.txt with upcoming public events and the MCP endpoint', async () => {
    const now = new Date(Date.UTC(2026, 9, 1));
    const txt = await buildLlmsTxt(fake({
      exos_public_events: [
        { id: 'e-soon', name: 'Fall Party', starts_at: '2026-10-03T02:00:00Z', venue_name: 'Elsewhere', venue_address: { city: 'Brooklyn' } },
        { id: 'e-hidden', name: 'Private', starts_at: '2026-10-04T02:00:00Z', noindex: true },
        { id: 'e-past', name: 'Old', starts_at: '2026-09-01T02:00:00Z' },
        { id: 'e-weird', name: 'A [b]\nc', starts_at: '2026-10-05T02:00:00Z' },
      ],
    }), base, { mcpUrl: 'https://p.supabase.co/functions/v1/exos-mcp', now });
    expect(txt.startsWith('# Exos\n')).toBe(true);
    expect(txt).toContain('all-in');
    expect(txt).toContain('MCP server (search events, prices, checkout links; read-only, no key needed): https://p.supabase.co/functions/v1/exos-mcp');
    expect(txt).toContain(`- [Fall Party](${base}/bridge/event/e-soon): Sat Oct 3 · 2 AM · Elsewhere · Brooklyn`);
    expect(txt).not.toContain('e-hidden');
    expect(txt).not.toContain('e-past');
    expect(txt).toContain('[A b c]');
    expect(await buildLlmsTxt(fake({}), base)).not.toContain('Upcoming events');
  });
});

