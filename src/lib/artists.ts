// Artists, lineups and listing-feed keys (mig 20261030110000,
// docs/listing-feed.md): the dashboard's data layer and the editor's pure
// helpers. The shared rules (Spotify parsing, act types, JSON-LD performers)
// live in supabase/functions/_shared/artists.ts so exos-api and the feed use
// the same ones.
//
// Writes go through the SECURITY DEFINER RPCs (exos_artist_save,
// exos_artist_merge, exos_lineup_save, exos_listing_key_create / _revoke);
// staff read the tables under RLS. Buyers read lineups through
// exos_public_lineups (published events only).

import { supabase } from './supabase';
import { uploadEventImage } from './storage';
import {
  ARTIST_NAME_MAX, LINEUP_MAX, parseLineup, parseSpotifyArtist, spotifyLinks,
  type ActType, type LineupSlot, type PartnerType,
} from '../../supabase/functions/_shared/artists.ts';

export {
  ACT_TYPES, ACT_TYPE_LABELS, ARTIST_LINK_KEYS, LINEUP_MAX, PARTNER_TYPES, isActType, jsonLdPerformers, lineupLine,
  orderedLineup, parseLineup, parseSpotifyArtist, performerNames, spotifyLinks,
} from '../../supabase/functions/_shared/artists.ts';
export type { ActType, ArtistLinkKey, JsonLdPerformer, LineupSlot, PartnerType, SlotArtist } from '../../supabase/functions/_shared/artists.ts';

export interface Artist {
  id: string;
  name: string;
  permalink: string;
  bio: string | null;
  genres: string[];
  links: Record<string, string>;
  image_url: string | null;
  image_thumb_url: string | null;
  spotify_id: string | null;
  spotify_uri: string | null;
  spotify_url: string | null;
  canonical_artist_id: string | null;
  updated_at?: string | null;
}

const ARTIST_COLS =
  'id, name, permalink, bio, genres, links, image_url, image_thumb_url, spotify_id, canonical_artist_id, updated_at';

/** A row (table or RPC answer) as an Artist, with the derived Spotify fields. */
export function toArtist(row: Record<string, unknown>): Artist {
  return {
    id: String(row.id),
    name: String(row.name ?? ''),
    permalink: String(row.permalink ?? ''),
    bio: typeof row.bio === 'string' ? row.bio : null,
    genres: Array.isArray(row.genres) ? row.genres.filter((g): g is string => typeof g === 'string') : [],
    links: row.links && typeof row.links === 'object' && !Array.isArray(row.links) ? (row.links as Record<string, string>) : {},
    image_url: typeof row.image_url === 'string' ? row.image_url : null,
    image_thumb_url: typeof row.image_thumb_url === 'string' ? row.image_thumb_url : (typeof row.image_url === 'string' ? row.image_url : null),
    ...spotifyLinks(row.spotify_id),
    canonical_artist_id: typeof row.canonical_artist_id === 'string' ? row.canonical_artist_id : null,
    updated_at: typeof row.updated_at === 'string' ? row.updated_at : null,
  };
}

/** The message a refused RPC carries, without the function-name prefix. */
export function rpcMessage(err: unknown, fallback: string): string {
  const m = String((err as { message?: unknown })?.message ?? '').replace(/^[a-z_ ]+: /i, '');
  return m ? m.charAt(0).toUpperCase() + m.slice(1) : fallback;
}

async function call<T>(fn: string, args: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(rpcMessage(error, fallback));
  return data as T;
}

// --- Artists --------------------------------------------------------------------

/** The org's artists by name (merged aliases only when asked for). */
export async function listOrgArtists(orgId: string, opts: { includeMerged?: boolean } = {}): Promise<Artist[]> {
  let q = supabase.from('exos_artists').select(ARTIST_COLS).eq('org_id', orgId);
  if (!opts.includeMerged) q = q.is('canonical_artist_id', null);
  const { data, error } = await q.order('name', { ascending: true }).limit(1000);
  if (error) throw error;
  return ((data ?? []) as unknown as Record<string, unknown>[]).map(toArtist);
}

export interface ArtistDraft {
  name: string;
  permalink?: string;
  spotify?: string;
  bio?: string;
  genres?: string[];
  links?: Record<string, string>;
  image_url?: string | null;
}

/** What is wrong with a draft before it goes to the server, or null. */
export function artistDraftError(d: ArtistDraft): string | null {
  const name = d.name.trim();
  if (!name) return 'Give the artist a name.';
  if (name.length > ARTIST_NAME_MAX) return `Names are at most ${ARTIST_NAME_MAX} characters.`;
  if (d.spotify !== undefined && !parseSpotifyArtist(d.spotify).ok) {
    return 'That Spotify link is not an artist page. Paste the artist link (open.spotify.com/artist/…), a spotify:artist: URI or the id.';
  }
  if (d.permalink && !/^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$/.test(d.permalink)) {
    return 'Permalinks are lowercase letters, digits and dashes.';
  }
  for (const [k, v] of Object.entries(d.links ?? {})) {
    if (v.trim() && !/^https?:\/\/\S+\.\S+$/i.test(v.trim())) return `The ${k} link must start with http:// or https://.`;
  }
  return null;
}

/** Create (id null) or update an artist. Only the fields given change. */
export async function saveArtist(orgId: string, id: string | null, fields: Partial<ArtistDraft>): Promise<Artist> {
  const row = await call<Record<string, unknown>>('exos_artist_save', { p_org_id: orgId, p_artist_id: id, p_fields: fields },
    'Could not save the artist.');
  return toArtist(row);
}

/** Merge `sourceId` into `targetId` (owner / manager). */
export async function mergeArtist(sourceId: string, targetId: string): Promise<{ artist: Artist; eventsUpdated: number }> {
  const r = await call<{ artist: Record<string, unknown>; events_updated: number }>('exos_artist_merge',
    { p_source: sourceId, p_target: targetId }, 'Could not merge the artists.');
  return { artist: toArtist(r.artist), eventsUpdated: r.events_updated };
}

const IMAGE_TYPES = /^image\/(png|jpe?g|webp)$/;
const IMAGE_MAX = 2 * 1024 * 1024;

/** Upload an artist photo (the uploader's own media folder) and return its public URL. */
export async function uploadArtistImage(uid: string, file: File): Promise<string> {
  if (!IMAGE_TYPES.test(file.type)) throw new Error('Photos must be PNG, JPG or WebP.');
  if (file.size > IMAGE_MAX) throw new Error('Photos must be under 2 MB.');
  return (await uploadEventImage(uid, file)).url;
}

/** Case- and accent-insensitive "contains" search over names, best matches first. */
export function searchArtists(artists: readonly Artist[], query: string, limit = 8): Artist[] {
  const fold = (s: string) => s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  const q = fold(query);
  if (!q) return [];
  return artists
    .map((a) => ({ a, at: fold(a.name).indexOf(q) }))
    .filter((x) => x.at >= 0)
    .sort((x, y) => (x.at === 0 ? 0 : 1) - (y.at === 0 ? 0 : 1) || x.a.name.localeCompare(y.a.name))
    .slice(0, limit)
    .map((x) => x.a);
}

// --- Lineups ----------------------------------------------------------------------

/** A slot in the editor: an artist, an act type and an optional set time. */
export interface DraftSlot {
  artist: Artist;
  actType: ActType;
  setTime: string | null;
}

/** An event's lineup as staff see it (RLS). */
export async function getEventLineup(eventId: string): Promise<LineupSlot[]> {
  const { data, error } = await supabase
    .from('exos_event_lineup')
    .select('id, artist_id, act_type, position, set_time, updated_at, artist:exos_artists(id, name, permalink, updated_at, image_url, image_thumb_url, spotify_id, canonical_artist_id)')
    .eq('event_id', eventId)
    .order('position', { ascending: true });
  if (error) throw error;
  return parseLineup(data ?? []);
}

/** Replace the lineup; the answer is the lineup as saved. */
export async function saveLineup(eventId: string, slots: readonly DraftSlot[]): Promise<LineupSlot[]> {
  const raw = await call<unknown>('exos_lineup_save', { p_event_id: eventId, p_slots: lineupPayload(slots) },
    'Could not save the lineup.');
  return parseLineup(raw);
}

/** The RPC's slot list, in running order. */
export function lineupPayload(slots: readonly DraftSlot[]): { artist_id: string; act_type: ActType; set_time: string | null }[] {
  return slots.map((s) => ({ artist_id: s.artist.id, act_type: s.actType, set_time: s.setTime }));
}

/** Saved slots as editor slots. */
export function draftFromLineup(lineup: readonly LineupSlot[]): DraftSlot[] {
  return lineup.map((s) => ({
    artist: toArtist({ ...s.artist, id: s.artist_id }),
    actType: s.act_type,
    setTime: s.set_time ?? null,
  }));
}

/** Add an artist at the end (the first slot is the headliner); refuses duplicates and slot 21. */
export function addSlot(slots: readonly DraftSlot[], artist: Artist): DraftSlot[] | string {
  if (slots.some((s) => s.artist.id === artist.id)) return `${artist.name} is already on the bill.`;
  if (slots.length >= LINEUP_MAX) return `A lineup has at most ${LINEUP_MAX} acts.`;
  return [...slots, { artist, actType: slots.length === 0 ? 'headline' : 'support', setTime: null }];
}

/** Move slot `i` by `by` (-1 up, +1 down); out of range is a no-op. */
export function moveSlot<T>(slots: readonly T[], i: number, by: number): T[] {
  const j = i + by;
  if (i < 0 || i >= slots.length || j < 0 || j >= slots.length) return [...slots];
  const next = [...slots];
  [next[i], next[j]] = [next[j], next[i]];
  return next;
}

/** Same lineup (artists, order, act types, set times)? */
export function sameLineup(a: readonly DraftSlot[], b: readonly DraftSlot[]): boolean {
  return JSON.stringify(lineupPayload(a)) === JSON.stringify(lineupPayload(b));
}

/** Published events' lineups for the event page and the widget. Never throws. */
export async function getPublicLineups(eventIds: string[]): Promise<Record<string, LineupSlot[]>> {
  const ids = [...new Set(eventIds.filter(Boolean))].slice(0, 100);
  if (!ids.length) return {};
  try {
    const { data, error } = await supabase.rpc('exos_public_lineups', { p_event_ids: ids });
    if (error) throw error;
    const out: Record<string, LineupSlot[]> = {};
    for (const [id, raw] of Object.entries((data ?? {}) as Record<string, unknown>)) out[id] = parseLineup(raw);
    return out;
  } catch (e) {
    // Before the migration (or on a read error) pages fall back to performer names.
    console.warn('lineups: not loaded', e);
    return {};
  }
}

// --- Listing-feed shared keys ------------------------------------------------------

export interface ListingKey {
  id: string;
  label: string;
  partner_type: PartnerType;
  key_prefix: string;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
}

export async function listListingKeys(orgId: string): Promise<ListingKey[]> {
  const { data, error } = await supabase
    .from('exos_listing_keys')
    .select('id, label, partner_type, key_prefix, created_at, last_used_at, revoked_at')
    .eq('org_id', orgId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []) as ListingKey[];
}

/** Mint a key; the plaintext comes back this once. */
export async function createListingKey(orgId: string, partnerType: PartnerType, label: string): Promise<ListingKey & { key: string }> {
  return call('exos_listing_key_create', { p_org_id: orgId, p_label: label, p_partner_type: partnerType },
    'Could not create the key.');
}

export async function revokeListingKey(keyId: string): Promise<void> {
  await call('exos_listing_key_revoke', { p_key_id: keyId }, 'Could not revoke the key.');
}

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

/** The feed URL a partner is given for a key ('' when this build has no Supabase URL). */
export function listingFeedUrl(key: string, base = env.VITE_SUPABASE_URL ?? ''): string {
  const b = base.replace(/\/+$/, '');
  return b ? `${b}/functions/v1/exos-api/v1/public/events?shared_key=${encodeURIComponent(key)}` : '';
}
