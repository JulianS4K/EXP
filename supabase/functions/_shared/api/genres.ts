// Genre filters for exos-api (mig 20261106140000): GET /v1/events?genre= /
// ?genres=, GET /v1/public/discovery/events?genre= / ?genres=. A genre is the
// free text on exos_events.genres; filters compare keys (NFKC, lower case,
// single spaces, 40 characters), the same as public.exos_genre_key, so
// "Hip Hop", "hip  hop" and "HIP HOP" are one genre.
//
// Pure TypeScript, imported by vitest (src/lib/apiGenres.test.ts).

export const MAX_GENRES = 20;
export const GENRE_MAX_LEN = 40;

export class GenreParamError extends Error {}

/** The comparison key of a genre, or null for an empty one. Mirrors public.exos_genre_key. */
export function genreKey(raw: string | null | undefined): string | null {
  const s = [...(raw ?? '').normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim()].slice(0, GENRE_MAX_LEN).join('').trim();
  return s ? s : null;
}

/**
 * The genres a request filters on, as keys, or null for no filter. Accepts
 * ?genre=House, ?genres=house,techno, repeated ?genres= / ?genres[]= and any
 * mix; matches events with at least one of them. More than 20 is a 400.
 */
export function genreFilter(q: URLSearchParams): string[] | null {
  const raw = [...q.getAll('genre'), ...q.getAll('genres'), ...q.getAll('genres[]')];
  if (raw.length === 0) return null;
  const keys = new Set<string>();
  for (const v of raw) {
    for (const part of v.split(',')) {
      const k = genreKey(part);
      if (k) keys.add(k);
    }
  }
  if (keys.size === 0) throw new GenreParamError('genre must name at least one genre');
  if (keys.size > MAX_GENRES) throw new GenreParamError(`at most ${MAX_GENRES} genres`);
  return [...keys];
}
