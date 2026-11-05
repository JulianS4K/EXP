// Genre chips on the public browse page (Home) (mig 20261106140000).
// A genre is the organizer's free text on an event (exos_events.genres);
// chips compare keys (genreKey: any case and spacing), the same as the API
// filters and public.exos_genre_key. The chip list is the genres of upcoming
// published, listed events (exos_api_public 'genres.list', the existing
// anon discovery RPC), merged with the genres of the events already loaded.

import { genreKey } from '../../supabase/functions/_shared/api/genres.ts';

export { genreKey };

export interface GenreChip {
  /** The comparison key. */
  key: string;
  /** What the chip says (the spelling used most). */
  label: string;
  /** Upcoming events with it (0 when only seen in the loaded set). */
  events: number;
  /** The spellings in use, for an exact-overlap read of the events view. */
  variants: string[];
}

interface WithGenres {
  genres?: string[] | null;
  category?: string | null;
}

/** An event's genre keys; an event without genres falls back to its category. */
export function eventGenreKeys(e: WithGenres): string[] {
  const raw = e.genres && e.genres.length ? e.genres : e.category ? [e.category] : [];
  return [...new Set(raw.map((g) => genreKey(g)).filter((k): k is string => !!k))];
}

/** Does the event carry this genre (a key, or null for "all")? */
export function matchesGenre(e: WithGenres, key: string | null): boolean {
  return key === null || eventGenreKeys(e).includes(key);
}

/** The genres.list answer as chips (anything malformed dropped). */
export function parseGenreList(raw: unknown): GenreChip[] {
  if (!Array.isArray(raw)) return [];
  const out: GenreChip[] = [];
  for (const r of raw) {
    const o = (r ?? {}) as Record<string, unknown>;
    const key = typeof o.genre === 'string' ? genreKey(o.genre) : null;
    if (!key) continue;
    const label = typeof o.name === 'string' && o.name.trim() ? o.name.trim() : key;
    const variants = Array.isArray(o.variants) ? o.variants.filter((v): v is string => typeof v === 'string') : [];
    out.push({ key, label, events: Number(o.events) || 0, variants: variants.length ? variants : [label] });
  }
  return out;
}

/**
 * The chips to show: the remote list (most events first), then genres only
 * the loaded events carry, at most `max`. Labels keep the spelling seen first.
 */
export function genreChips(remote: GenreChip[], loaded: WithGenres[], max = 12): GenreChip[] {
  const byKey = new Map<string, GenreChip>();
  for (const c of remote) if (!byKey.has(c.key)) byKey.set(c.key, { ...c, variants: [...c.variants] });
  for (const e of loaded) {
    const raw = e.genres && e.genres.length ? e.genres : e.category ? [e.category] : [];
    for (const g of raw) {
      const key = genreKey(g);
      if (!key) continue;
      const chip = byKey.get(key);
      const spelled = g.trim();
      if (!chip) byKey.set(key, { key, label: spelled, events: 0, variants: [spelled] });
      else if (!chip.variants.includes(spelled)) chip.variants.push(spelled);
    }
  }
  return [...byKey.values()].slice(0, Math.max(0, max));
}
