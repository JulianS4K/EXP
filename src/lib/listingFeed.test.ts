// The public listing feed's pure half (supabase/functions/_shared/listingFeed/feed.ts):
// Opendate paging rules, filters, sort, entry shape, secret / online venues,
// all-in prices, utm-tagged ticket links, ETags. The SQL half (what is
// listable, venue redaction) is tests/exos/test_artists_feed.sql.

import { describe, expect, it } from 'vitest';
import {
  buildFeedPage, etagMatches, feedEntry, FeedParamError, parseFeedQuery, PER_PAGE_MAX, selectFeed, SHARED_KEY_RE,
  type SourceEvent,
} from '../../supabase/functions/_shared/listingFeed/feed.ts';

const NOW = new Date('2026-11-01T12:00:00Z');
const q = (s: string) => parseFeedQuery(new URLSearchParams(s), NOW);
const SP = '4Z8W4fKeB5YxbusRsdQVPb';
const LUMEN = '7a1c9e2b-4d6f-4a8b-9c0d-2e3f4a5b6c7d';
const ALIAS = '9c3e1a4d-6f8b-4cad-9e2f-4a5b6c7d8e9f';

function ev(id: string, startsAt: string, extra: Partial<SourceEvent> = {}): SourceEvent {
  return {
    id, slug: null, name: id, status: 'published', starts_at: startsAt, ends_at: null, doors_at: null,
    timezone: 'America/New_York', currency: 'usd', image_url: null, genres: [], subgenres: [], performer_names: [],
    format: 'in_person', tickets_sold: 0, total_tickets: 100, created_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-02T00:00:00Z', published_at: '2026-10-01T00:00:00Z',
    venue: { secret: false, online: false, venue_id: null, name: 'The Loft', permalink: 'the-loft', city: 'Brooklyn', region: 'NY', country: 'US' },
    tiers: [{ id: 't1', price: 20, capacity: 100, sold: 0, sales_start: null, sales_end: null, exclusive_tax_percent: 0 }],
    lineup: [],
    ...extra,
  };
}

const slot = (id: string, artistId: string, pos: number, name: string, extra: Record<string, unknown> = {}) => ({
  id, artist_id: artistId, act_type: pos === 1 ? 'headline' : 'support', position: pos, set_time: null,
  updated_at: '2026-10-22T18:05:00Z',
  artist: { id: artistId, name, permalink: name.toLowerCase(), updated_at: '2026-10-20T00:00:00Z', image_url: null,
    image_thumb_url: null, spotify_id: null, canonical_artist_id: null, ...extra },
});

describe('parseFeedQuery (Opendate paging rules)', () => {
  it('defaults: page 1 of 30, from now, start_time asc', () => {
    expect(q('')).toMatchObject({ page: 1, perPage: 30, sort: 'start_time asc', startGte: NOW, startLte: null });
  });

  it('caps per_page at 250 and refuses non-positive integers', () => {
    expect(q('per_page=999').perPage).toBe(PER_PAGE_MAX);
    for (const bad of ['page=0', 'page=-1', 'page=1.5', 'per_page=0', 'per_page=x', 'page=99999']) {
      expect(() => q(bad), bad).toThrow(FeedParamError);
    }
  });

  it('reads q[…] and plain forms, lists comma-separated or repeated', () => {
    expect(q('q[start_time_gteq]=2026-12-01').startGte.toISOString()).toBe('2026-12-01T00:00:00.000Z');
    expect(q('start_time_lteq=2027-01-01T00:00:00Z').startLte?.toISOString()).toBe('2027-01-01T00:00:00.000Z');
    expect(q('genre=Rock,Jazz&genre=house&genre[]=techno').genres).toEqual(['rock', 'jazz', 'house', 'techno']);
    expect(q(`q[s]=${encodeURIComponent('published_at desc')}`).sort).toBe('published_at desc');
    expect(q('q[s]=start_time').sort).toBe('start_time asc');
    expect(q(`artist_id=${LUMEN.toUpperCase()}`).artistId).toBe(LUMEN);
  });

  it('refuses tag_id, unknown sorts and bad dates / ids', () => {
    for (const bad of ['tag_id=3', 'q[tag_id]=3', 'q[s]=title+asc', 'start_time_gteq=soon', 'artist_id=lumen', 'venue_id=a%20b']) {
      expect(() => q(bad), bad).toThrow(FeedParamError);
    }
  });
});

describe('selectFeed', () => {
  const events = [
    ev('b', '2026-11-03T00:00:00Z', { genres: ['Rock'], venue: { ...ev('x', '').venue, venue_id: 'v1' }, published_at: '2026-10-05T00:00:00Z' }),
    ev('a', '2026-11-02T00:00:00Z', { genres: ['Jazz'], subgenres: ['Bebop'], published_at: '2026-10-09T00:00:00Z' }),
    ev('c', '2026-11-10T00:00:00Z', { genres: ['Techno'], lineup: [slot('s1', LUMEN, 1, 'Lumen')] }),
    ev('old', '2026-10-20T00:00:00Z'),
  ];
  const ids = (s: string) => selectFeed(events, q(s)).rows.map((e) => e.id);

  it('upcoming only by default, start order, exact totals', () => {
    expect(ids('')).toEqual(['a', 'b', 'c']);
    expect(selectFeed(events, q('per_page=2&page=2'))).toMatchObject({ total: 3, totalPages: 2 });
    expect(ids('per_page=2&page=2')).toEqual(['c']);
    expect(ids('page=9')).toEqual([]);
    expect(ids('start_time_gteq=2026-10-01')).toEqual(['old', 'a', 'b', 'c']);
    expect(ids('start_time_lteq=2026-11-05')).toEqual(['a', 'b']);
  });

  it('filters by genre (subgenres count), exclusion, venue and artist (aliases count)', () => {
    expect(ids('genre=rock')).toEqual(['b']);
    expect(ids('genre=bebop')).toEqual(['a']);
    expect(ids('exclude_genre=techno,jazz')).toEqual(['b']);
    expect(ids('venue_id=v1')).toEqual(['b']);
    expect(ids(`artist_id=${LUMEN}`)).toEqual(['c']);
    const merged = [ev('m', '2026-11-04T00:00:00Z', { lineup: [slot('s9', LUMEN, 1, 'Lumen', { canonical_artist_id: ALIAS })] })];
    expect(selectFeed(merged, q(`artist_id=${ALIAS}`)).rows.map((e) => e.id)).toEqual(['m']);
  });

  it('sorts by start or publish time, either way', () => {
    expect(ids(`q[s]=${encodeURIComponent('start_time desc')}`)).toEqual(['c', 'b', 'a']);
    expect(ids(`q[s]=${encodeURIComponent('published_at desc')}`)).toEqual(['a', 'b', 'c']);
  });
});

describe('feedEntry', () => {
  const opts = { appBase: 'https://tickets.example.com/bridge', partnerType: 'bandsintown', now: NOW };

  it('times carry the event zone offset; ticket_url is utm-tagged per partner', () => {
    const e = feedEntry(ev('e1', '2026-12-05T03:00:00Z', { slug: 'warehouse', doors_at: '2026-12-05T02:30:00Z' }), opts);
    expect(e.start_time).toBe('2026-12-04T22:00:00-05:00');
    expect(e.doors_time).toBe('2026-12-04T21:30:00-05:00');
    expect(e.end_time).toBeNull();
    expect(e.ticket_url).toBe('https://tickets.example.com/bridge/e/warehouse?utm_source=bandsintown&utm_medium=listing&utm_campaign=listing_feed');
    expect(feedEntry(ev('e2', '2026-12-05T03:00:00Z'), { ...opts, partnerType: 'other' }).ticket_url)
      .toBe('https://tickets.example.com/bridge/event/e2?utm_source=listing&utm_medium=listing&utm_campaign=listing_feed');
    expect(e).toMatchObject({ currency: 'USD', venue_name: 'The Loft', venue_permalink: 'the-loft', city: 'Brooklyn', online: false });
  });

  it('prices are all-in over the public tiers; on_sale and sold_out', () => {
    const e = feedEntry(ev('p', '2026-12-05T03:00:00Z', {
      tiers: [
        { id: 'free', price: 0, capacity: 10, sold: 0, sales_start: null, sales_end: null },
        { id: 'ga', price: 25, capacity: 100, sold: 0, sales_start: null, sales_end: null, exclusive_tax_percent: 8.875,
          passed_on_fees: [{ name: 'Facility', calc: 'fixed', amount_cents: 200, taxable: true }] },
      ],
    }), opts);
    expect(e.price_min).toBe(0);
    expect(e.price_max).toBeCloseTo(29.4, 2); // (25 + 2) * 1.08875 = 29.396 -> 29.40
    expect(e).toMatchObject({ on_sale: true, sold_out: false });
    const soldOut = feedEntry(ev('s', '2026-12-05T03:00:00Z', { tickets_sold: 100 }), opts);
    expect(soldOut).toMatchObject({ on_sale: false, sold_out: true });
    const later = feedEntry(ev('l', '2026-12-05T03:00:00Z', {
      tiers: [{ id: 't', price: 10, capacity: 5, sold: 0, sales_start: '2026-11-20T00:00:00Z', sales_end: null }],
    }), opts);
    expect(later).toMatchObject({ on_sale: false, sold_out: false });
    expect(feedEntry(ev('n', '2026-12-05T03:00:00Z', { tiers: [] }), opts)).toMatchObject({ price_min: null, on_sale: false });
  });

  it('a secret venue carries only its area; an online event no venue', () => {
    const sec = feedEntry(ev('sec', '2026-12-05T03:00:00Z', {
      venue: { secret: true, online: false, venue_id: null, name: 'Williamsburg, Brooklyn', permalink: null, city: null, region: null, country: null },
    }), opts);
    expect(sec).toMatchObject({ venue_name: 'Williamsburg, Brooklyn', venue_id: null, venue_permalink: null, city: null, region: null, country: null });
    const online = feedEntry(ev('on', '2026-12-05T03:00:00Z', {
      venue: { secret: false, online: true, venue_id: null, name: null, permalink: null, city: null, region: null, country: null },
    }), opts);
    expect(online).toMatchObject({ online: true, venue_name: null });
  });

  it('performers: slot vs artist ids, derived Spotify, deprecated flat copies', () => {
    const e = feedEntry(ev('lu', '2026-12-05T03:00:00Z', {
      lineup: [slot('s2', 'n1', 2, 'Nova Echo'), slot('s1', LUMEN, 1, 'Lumen', { spotify_id: SP, image_url: 'https://x/p.jpg' })],
    }), opts);
    expect(e.performers.map((p) => [p.performer_id, p.artist_id, p.position, p.act_type])).toEqual([
      ['s1', LUMEN, 1, 'headline'], ['s2', 'n1', 2, 'support'],
    ]);
    expect(e.performers[0].artist).toMatchObject({
      id: LUMEN, spotify_id: SP, spotify_uri: `spotify:artist:${SP}`, spotify_url: `https://open.spotify.com/artist/${SP}`,
      image_thumb_url: 'https://x/p.jpg', canonical_artist_id: null,
    });
    expect(e.performers[1].artist).toMatchObject({ spotify_id: null, spotify_uri: null, spotify_url: null });
    expect(e.performers[0]).toMatchObject({ id: 's1', name: 'Lumen', permalink: 'lumen', image_url: 'https://x/p.jpg', image_thumb_url_for_json: 'https://x/p.jpg' });
  });

  it('free-text performer names list without artist records', () => {
    const e = feedEntry(ev('ft', '2026-12-05T03:00:00Z', { performer_names: ['Headliner', ' ', 'Support'] }), opts);
    expect(e.performers.map((p) => [p.performer_id, p.artist_id, p.act_type, p.name])).toEqual([
      ['ft-p1', null, 'headline', 'Headliner'], ['ft-p2', null, 'support', 'Support'],
    ]);
    expect(e.performers[0].artist.id).toBeNull();
  });
});

describe('buildFeedPage, etags, keys', () => {
  it('builds Opendate\'s envelope', () => {
    const page = buildFeedPage([ev('a', '2026-11-02T00:00:00Z'), ev('b', '2026-11-03T00:00:00Z')], q('per_page=1'),
      { appBase: '', partnerType: 'website', now: NOW });
    expect(Object.keys(page)).toEqual(['current_page', 'per_page', 'total_entries', 'total_pages', 'collection']);
    expect(page).toMatchObject({ current_page: 1, per_page: 1, total_entries: 2, total_pages: 2 });
    expect(page.collection[0].ticket_url).toBeNull();
  });

  it('matches If-None-Match lists, weak forms and *', () => {
    expect(etagMatches('"abc"', '"abc"')).toBe(true);
    expect(etagMatches('W/"abc", "def"', '"abc"')).toBe(true);
    expect(etagMatches('*', '"abc"')).toBe(true);
    expect(etagMatches('"nope"', '"abc"')).toBe(false);
    expect(etagMatches(null, '"abc"')).toBe(false);
  });

  it('knows a shared key from an API key', () => {
    expect(SHARED_KEY_RE.test(`sh_live_${'a1'.repeat(24)}`)).toBe(true);
    expect(SHARED_KEY_RE.test(`sk_live_${'a1'.repeat(24)}`)).toBe(false);
  });
});
