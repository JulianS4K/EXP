// Artists and lineups: the parts the browser, exos-api and the listing feed
// share (mig 20261030110000, docs/listing-feed.md).
//
// The database is the authority (exos_artist_save parses Spotify input and
// makes permalinks; exos_lineup_save orders and checks slots); these mirror it
// so the editor can say what is wrong before a round trip, and render the
// lineup and its JSON-LD the same way everywhere.
//
// Pure TypeScript with no Deno or Supabase imports, so vitest can import it.

/** Act types, in the order the lineup editor offers them. */
export const ACT_TYPES = ['headline', 'support', 'opener', 'dj', 'host', 'other'] as const;
export type ActType = (typeof ACT_TYPES)[number];

export function isActType(v: unknown): v is ActType {
  return typeof v === 'string' && (ACT_TYPES as readonly string[]).includes(v);
}

export const ACT_TYPE_LABELS: Record<ActType, string> = {
  headline: 'Headliner', support: 'Support', opener: 'Opener', dj: 'DJ', host: 'Host', other: 'Other',
};

/** At most this many slots per event; performer_names mirrors the first 10. */
export const LINEUP_MAX = 20;
export const PERFORMERS_MAX = 10;
export const ARTIST_NAME_MAX = 120;

/** Links an artist record may carry (exos_artists.links keys). */
export const ARTIST_LINK_KEYS = [
  'website', 'instagram', 'facebook', 'twitter', 'tiktok', 'youtube', 'soundcloud', 'bandcamp', 'apple_music',
] as const;
export type ArtistLinkKey = (typeof ARTIST_LINK_KEYS)[number];

/** Listing partners a shared key is minted for (exos_listing_keys.partner_type). */
export const PARTNER_TYPES = ['bandsintown', 'jambase', 'songkick', 'website', 'other'] as const;
export type PartnerType = (typeof PARTNER_TYPES)[number];

// -- Spotify ---------------------------------------------------------------

const SPOTIFY_ID_RE = /^[0-9A-Za-z]{22}$/;
const SPOTIFY_URI_RE = /^spotify:artist:([0-9A-Za-z]{22})$/i;
// open.spotify.com/artist/<id>, optional locale segment (/intl-de/), play.,
// embed paths, any query or hash.
const SPOTIFY_URL_RE =
  /^(?:https?:\/\/)?(?:open|play)\.spotify\.com\/(?:intl-[a-z]{2}(?:-[a-z]{2})?\/)?(?:embed\/)?artist\/([0-9A-Za-z]{22})(?:[/?#].*)?$/i;

export type SpotifyParse = { ok: true; id: string | null } | { ok: false };

/**
 * The canonical 22-character Spotify artist id from an artist URL, a
 * `spotify:artist:` URI or a bare id. Empty input is `{ ok: true, id: null }`;
 * album / track / playlist links and anything else are `{ ok: false }`.
 * Same rules as _exos_spotify_artist_id in SQL. No call to Spotify is made.
 */
export function parseSpotifyArtist(input: unknown): SpotifyParse {
  if (input === undefined || input === null) return { ok: true, id: null };
  if (typeof input !== 'string') return { ok: false };
  const s = input.trim();
  if (!s) return { ok: true, id: null };
  if (s.length > 300) return { ok: false };
  if (SPOTIFY_ID_RE.test(s)) return { ok: true, id: s };
  const uri = SPOTIFY_URI_RE.exec(s);
  if (uri) return { ok: true, id: uri[1] };
  const url = SPOTIFY_URL_RE.exec(s);
  if (url) return { ok: true, id: url[1] };
  return { ok: false };
}

export interface SpotifyLinks {
  spotify_id: string | null;
  spotify_uri: string | null;
  spotify_url: string | null;
}

/** The three Spotify fields from the one stored id: all set or all null. */
export function spotifyLinks(id: unknown): SpotifyLinks {
  if (typeof id !== 'string' || !SPOTIFY_ID_RE.test(id)) return { spotify_id: null, spotify_uri: null, spotify_url: null };
  return { spotify_id: id, spotify_uri: `spotify:artist:${id}`, spotify_url: `https://open.spotify.com/artist/${id}` };
}

// -- Lineups ------------------------------------------------------------------

/** An artist as a lineup slot carries it (_exos_lineup_json). */
export interface SlotArtist {
  id: string;
  name: string;
  permalink: string;
  updated_at?: string | null;
  image_url?: string | null;
  image_thumb_url?: string | null;
  spotify_id?: string | null;
  spotify_uri?: string | null;
  spotify_url?: string | null;
  canonical_artist_id?: string | null;
}

/** One lineup slot (_exos_lineup_json / exos_public_lineups). */
export interface LineupSlot {
  id: string;
  artist_id: string;
  act_type: ActType;
  position: number;
  set_time?: string | null;
  updated_at?: string | null;
  artist: SlotArtist;
}

/** Slots by position (ties keep their order). */
export function orderedLineup<T extends { position?: number }>(slots: readonly T[] | null | undefined): T[] {
  if (!Array.isArray(slots)) return [];
  return slots
    .map((s, i) => ({ s, i }))
    .sort((a, b) => (a.s.position ?? a.i + 1) - (b.s.position ?? b.i + 1) || a.i - b.i)
    .map(({ s }) => s);
}

/** Parse untrusted JSON (an RPC answer) into slots, dropping malformed ones. */
export function parseLineup(raw: unknown): LineupSlot[] {
  if (!Array.isArray(raw)) return [];
  const out: LineupSlot[] = [];
  for (const x of raw) {
    const s = x as Partial<LineupSlot> | null;
    const a = s?.artist as Partial<SlotArtist> | undefined;
    if (!s || typeof s.id !== 'string' || typeof s.artist_id !== 'string' || !a || typeof a.name !== 'string') continue;
    out.push({
      id: s.id,
      artist_id: s.artist_id,
      act_type: isActType(s.act_type) ? s.act_type : 'other',
      position: typeof s.position === 'number' ? s.position : out.length + 1,
      set_time: typeof s.set_time === 'string' ? s.set_time : null,
      updated_at: typeof s.updated_at === 'string' ? s.updated_at : null,
      artist: {
        id: typeof a.id === 'string' ? a.id : s.artist_id,
        name: a.name,
        permalink: typeof a.permalink === 'string' ? a.permalink : '',
        updated_at: a.updated_at ?? null,
        image_url: a.image_url ?? null,
        image_thumb_url: a.image_thumb_url ?? a.image_url ?? null,
        ...spotifyLinks(a.spotify_id),
        canonical_artist_id: a.canonical_artist_id ?? null,
      },
    });
  }
  return orderedLineup(out);
}

/** The legacy performer names for a lineup: first 10, 80 characters each. */
export function performerNames(slots: readonly LineupSlot[]): string[] {
  return orderedLineup(slots)
    .map((s) => s.artist.name.trim().slice(0, 80))
    .filter(Boolean)
    .slice(0, PERFORMERS_MAX);
}

export interface JsonLdPerformer {
  '@type': 'PerformingGroup';
  name: string;
  sameAs?: string;
}

/**
 * schema.org performers for an event: the structured lineup (with the Spotify
 * URL as sameAs) when there is one, else the free-text names.
 */
export function jsonLdPerformers(lineup: readonly LineupSlot[] | null | undefined, names?: readonly unknown[] | null): JsonLdPerformer[] {
  const slots = orderedLineup(lineup ?? []);
  if (slots.length) {
    return slots
      .filter((s) => s.artist.name.trim())
      .map((s) => {
        const url = spotifyLinks(s.artist.spotify_id).spotify_url;
        return url
          ? { '@type': 'PerformingGroup' as const, name: s.artist.name.trim(), sameAs: url }
          : { '@type': 'PerformingGroup' as const, name: s.artist.name.trim() };
      });
  }
  return (names ?? [])
    .filter((n): n is string => typeof n === 'string' && !!n.trim())
    .slice(0, 20)
    .map((name) => ({ '@type': 'PerformingGroup' as const, name: name.trim() }));
}

/** "Lumen, Nova Echo" for one-line lists (the events widget). */
export function lineupLine(lineup: readonly LineupSlot[], max = 4): string {
  const names = orderedLineup(lineup).map((s) => s.artist.name.trim()).filter(Boolean);
  return names.length > max ? `${names.slice(0, max).join(', ')} +${names.length - max}` : names.join(', ');
}
