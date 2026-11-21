// Cities for promotion (operator 2026-11-21: NYC first, city as data). Each
// city is one entry here: what it's called, its boroughs, the discovery
// channel regions that apply there, the ad geo defaults and its community
// list. Adding a city means adding an entry (and, for a city-only listing
// site, a channel whose `region` is the city's region code); no code changes.
//
// A channel's `region` (channels.ts) is either a city region code ('NYC') or
// a wider one ('US', 'global'). A city region applies only to events in that
// city; a wider one applies to every event (US: events in the US).
//
// Pure: no Deno or Supabase imports.

export interface CityConfig {
  /** Stable id: lower case, a-z 0-9 and '-'. */
  id: string;
  name: string;
  /** Channel region codes that apply only here (channels.ts `region`). */
  regions: readonly string[];
  country: string;
  /** Lower-case names a venue address's city or region may carry for this city. */
  matches: readonly string[];
  boroughs: readonly string[];
  /** Neighborhood pages, when the city has them (the circles live in SQL, mig 20261111110000). */
  neighborhoodsPath: string | null;
  adGeo: {
    /** Default targeting radius around the venue, in miles. */
    radiusMiles: number;
    /** Nielsen DMA, for platforms that target by it. */
    dma: string | null;
    /** ZIP codes to target by borough (placeholder: empty until filled in). */
    zipsByBorough: Readonly<Record<string, readonly string[]>>;
  };
  /** Local communities to post in (subreddits, groups). Placeholder: filled in later. */
  communities: readonly string[];
  /** City rules for posters and flyers, shown in the playbook. */
  printRules: readonly string[];
}

export const CITIES: readonly CityConfig[] = [
  {
    id: 'nyc',
    name: 'New York City',
    regions: ['NYC'],
    country: 'US',
    matches: ['new york', 'new york city', 'nyc', 'manhattan', 'brooklyn', 'queens', 'bronx', 'the bronx', 'staten island', 'long island city', 'astoria', 'flushing', 'williamsburg', 'bushwick', 'harlem'],
    boroughs: ['Manhattan', 'Brooklyn', 'Queens', 'The Bronx', 'Staten Island'],
    neighborhoodsPath: '/nyc',
    adGeo: {
      radiusMiles: 10,
      dma: 'New York (501)',
      zipsByBorough: { Manhattan: [], Brooklyn: [], Queens: [], 'The Bronx': [], 'Staten Island': [] },
    },
    communities: [],
    printRules: [
      'NYC: no flyers on lamp posts, poles or trees (Admin Code § 10-119, fined). Use licensed poster walls, community boards and venues that say yes.',
    ],
  },
];

const US = new Set(['us', 'usa', 'united states', 'united states of america']);

export function cityById(id: string | null | undefined): CityConfig | null {
  return CITIES.find((c) => c.id === id) ?? null;
}

/** The configured city a venue address is in, or null. */
export function cityOf(address: unknown): CityConfig | null {
  const a = (address && typeof address === 'object' ? address : {}) as Record<string, unknown>;
  const s = (v: unknown) => (typeof v === 'string' ? v.trim().toLowerCase() : '');
  const city = s(a.city);
  const region = s(a.region);
  return CITIES.find((c) => (city && c.matches.includes(city)) || (region && c.matches.includes(region) && region !== 'new york')) ?? null;
}

/** Is a venue address in the US (no country = assumed US, Exos's market today)? */
export function inUS(address: unknown): boolean {
  const a = (address && typeof address === 'object' ? address : {}) as Record<string, unknown>;
  const country = typeof a.country === 'string' ? a.country.trim().toLowerCase() : '';
  return !country || US.has(country);
}

/** Every region code that belongs to some city. */
export const CITY_REGIONS: ReadonlySet<string> = new Set(CITIES.flatMap((c) => c.regions));

/**
 * Does a channel's region apply to an event in this city? City regions only
 * in their city; 'US' in the US; anything else (global) everywhere.
 */
export function regionApplies(region: string, city: CityConfig | null, us = true): boolean {
  if (CITY_REGIONS.has(region)) return !!city && city.regions.includes(region);
  if (region === 'US') return us;
  return true;
}
