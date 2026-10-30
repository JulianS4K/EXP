import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import {
  addSlot, artistDraftError, draftFromLineup, jsonLdPerformers, lineupLine, lineupPayload, listingFeedUrl, moveSlot,
  parseLineup, parseSpotifyArtist, performerNames, rpcMessage, sameLineup, searchArtists, spotifyLinks, toArtist,
  type Artist, type DraftSlot,
} from './artists';

const ID = '4Z8W4fKeB5YxbusRsdQVPb';

describe('parseSpotifyArtist (same rules as _exos_spotify_artist_id)', () => {
  it('URL, URI and bare id give one id', () => {
    for (const s of [ID, `spotify:artist:${ID}`, `https://open.spotify.com/artist/${ID}`,
      `https://open.spotify.com/artist/${ID}?si=abc123`, `https://open.spotify.com/intl-de/artist/${ID}`,
      `open.spotify.com/artist/${ID}/`, `  ${ID}  `, `https://open.spotify.com/embed/artist/${ID}`]) {
      expect(parseSpotifyArtist(s), s).toEqual({ ok: true, id: ID });
    }
  });

  it('empty is no id; album / track / other hosts are refused', () => {
    expect(parseSpotifyArtist('')).toEqual({ ok: true, id: null });
    expect(parseSpotifyArtist(null)).toEqual({ ok: true, id: null });
    for (const s of [`https://open.spotify.com/album/${ID}`, `spotify:track:${ID}`, 'abc', `https://evil.example/artist/${ID}`, 42]) {
      expect(parseSpotifyArtist(s), String(s)).toEqual({ ok: false });
    }
  });

  it('derives URI and URL together, or neither', () => {
    expect(spotifyLinks(ID)).toEqual({ spotify_id: ID, spotify_uri: `spotify:artist:${ID}`, spotify_url: `https://open.spotify.com/artist/${ID}` });
    expect(spotifyLinks('nope')).toEqual({ spotify_id: null, spotify_uri: null, spotify_url: null });
  });
});

const artist = (id: string, name: string, extra: Partial<Artist> = {}): Artist =>
  toArtist({ id, name, permalink: name.toLowerCase(), ...extra });

describe('lineups', () => {
  const a = artist('a', 'Lumen', { spotify_id: ID } as never);
  const b = artist('b', 'Nova Echo');

  it('adds with headliner first, refuses duplicates and slot 21', () => {
    const one = addSlot([], a) as DraftSlot[];
    expect(one[0].actType).toBe('headline');
    const two = addSlot(one, b) as DraftSlot[];
    expect(two.map((s) => [s.artist.name, s.actType])).toEqual([['Lumen', 'headline'], ['Nova Echo', 'support']]);
    expect(addSlot(two, a)).toBe('Lumen is already on the bill.');
    const full = Array.from({ length: 20 }, (_, i) => ({ artist: artist(`x${i}`, `X${i}`), actType: 'support' as const, setTime: null }));
    expect(addSlot(full, b)).toMatch(/at most 20/);
  });

  it('moves, compares and serializes', () => {
    const slots = addSlot(addSlot([], a) as DraftSlot[], b) as DraftSlot[];
    const moved = moveSlot(slots, 1, -1);
    expect(moved.map((s) => s.artist.id)).toEqual(['b', 'a']);
    expect(moveSlot(slots, 0, -1).map((s) => s.artist.id)).toEqual(['a', 'b']);
    expect(sameLineup(slots, moved)).toBe(false);
    expect(sameLineup(slots, [...slots])).toBe(true);
    expect(lineupPayload(slots)).toEqual([
      { artist_id: 'a', act_type: 'headline', set_time: null }, { artist_id: 'b', act_type: 'support', set_time: null },
    ]);
  });

  const raw = [
    { id: 's2', artist_id: 'b', act_type: 'dj', position: 2, artist: { id: 'b', name: 'Nova Echo', permalink: 'nova-echo' } },
    { id: 's1', artist_id: 'a', act_type: 'headline', position: 1, set_time: '2026-12-05T04:30:00Z',
      artist: { id: 'a', name: 'Lumen', permalink: 'lumen', spotify_id: ID } },
    { id: 'bad' },
  ];

  it('parses RPC answers in running order and drops junk', () => {
    const l = parseLineup(raw);
    expect(l.map((s) => s.id)).toEqual(['s1', 's2']);
    expect(l[0].artist.spotify_url).toBe(`https://open.spotify.com/artist/${ID}`);
    expect(draftFromLineup(l).map((s) => [s.artist.id, s.actType, s.setTime])).toEqual([
      ['a', 'headline', '2026-12-05T04:30:00Z'], ['b', 'dj', null],
    ]);
    expect(performerNames(l)).toEqual(['Lumen', 'Nova Echo']);
    expect(lineupLine(l)).toBe('Lumen, Nova Echo');
    expect(lineupLine(l, 1)).toBe('Lumen +1');
  });

  it('JSON-LD performers: lineup with Spotify sameAs, else the free-text names', () => {
    expect(jsonLdPerformers(parseLineup(raw))).toEqual([
      { '@type': 'PerformingGroup', name: 'Lumen', sameAs: `https://open.spotify.com/artist/${ID}` },
      { '@type': 'PerformingGroup', name: 'Nova Echo' },
    ]);
    expect(jsonLdPerformers([], ['X', ' ', 'Y'])).toEqual([{ '@type': 'PerformingGroup', name: 'X' }, { '@type': 'PerformingGroup', name: 'Y' }]);
    expect(jsonLdPerformers(null, null)).toEqual([]);
  });
});

describe('artist drafts and search', () => {
  it('says what is wrong before saving', () => {
    expect(artistDraftError({ name: ' ' })).toMatch(/name/);
    expect(artistDraftError({ name: 'X', spotify: 'not a link' })).toMatch(/Spotify/);
    expect(artistDraftError({ name: 'X', permalink: 'Bad Link' })).toMatch(/Permalinks/);
    expect(artistDraftError({ name: 'X', links: { website: 'example.com' } })).toMatch(/website/);
    expect(artistDraftError({ name: 'X', spotify: `spotify:artist:${ID}`, links: { website: 'https://x.example' } })).toBeNull();
  });

  it('searches names ignoring case and accents, prefix matches first', () => {
    const list = [artist('1', 'DJ Lumière'), artist('2', 'Lumen'), artist('3', 'Nova')];
    expect(searchArtists(list, 'lum').map((x) => x.id)).toEqual(['2', '1']);
    expect(searchArtists(list, 'lumiere').map((x) => x.id)).toEqual(['1']);
    expect(searchArtists(list, '')).toEqual([]);
  });

  it('cleans RPC messages and builds feed URLs', () => {
    expect(rpcMessage({ message: 'lineup: at most 20 slots' }, 'x')).toBe('At most 20 slots');
    expect(rpcMessage({}, 'Fallback')).toBe('Fallback');
    expect(listingFeedUrl('sh_live_ab', 'https://p.supabase.co/')).toBe('https://p.supabase.co/functions/v1/exos-api/v1/public/events?shared_key=sh_live_ab');
    expect(listingFeedUrl('k', '')).toBe('');
  });
});

describe('event JSON-LD carries the performers', () => {
  it('client (meta.ts) and server-rendered (hosting/seo.ts)', async () => {
    const { buildEventJsonLd } = await import('./meta');
    const { eventSummary, eventTags } = await import('./hosting/seo');
    const performers = jsonLdPerformers(parseLineup([
      { id: 's1', artist_id: 'a', act_type: 'headline', position: 1, artist: { id: 'a', name: 'Lumen', permalink: 'lumen', spotify_id: ID } },
    ]));
    const ld = buildEventJsonLd({ name: 'Show', startDate: '2026-12-05T03:00:00Z', location: { name: 'Hall' }, performers });
    expect(ld.performer).toEqual([{ '@type': 'PerformingGroup', name: 'Lumen', sameAs: `https://open.spotify.com/artist/${ID}` }]);
    expect(buildEventJsonLd({ name: 'Show', startDate: '2026-12-05T03:00:00Z', location: { name: 'Hall' } }).performer).toBeUndefined();
    const s = eventSummary({ id: 'e', name: 'Show', starts_at: '2026-12-05T03:00:00Z', performer_names: ['Lumen', 'Nova Echo'] }, []);
    expect(eventTags(s!, 'https://x/event/e', 'https://x/i.png'))
      .toContain('"performer":[{"@type":"PerformingGroup","name":"Lumen"},{"@type":"PerformingGroup","name":"Nova Echo"}]');
  });
});
