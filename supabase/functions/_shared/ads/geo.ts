// Ad geo targeting for "Boost this event" (ads phase, mig 20261121190500).
// Pure: no Deno or Supabase imports.
//
// A SMALL LOCAL CITY CONFIG. The promotion branch (claude/exos-promotion)
// carries the shared city config, _shared/discovery/cities.ts (CityConfig:
// boroughs, adGeo.radiusMiles / zipsByBorough, communities); it is not on
// this branch's base, so the ad planner keeps this subset of the same shape.
// When the branches merge, point adCityOf() at cities.ts's cityOf() and fill
// its zipsByBorough / communities from AD_CITIES, then delete this copy.
//
// Meta targets a radius around the venue when its pin is known (and public);
// otherwise the city's ZIPs. Reddit has no radius (operator brief 2026-11-21),
// so it always gets ZIP / borough lists. The ZIPs below are a starter list
// per borough (real USPS ZIPs; extend them in the config, not in code).

export interface AdCity {
  id: string;
  name: string;
  country: string;
  /** Lower-case names a venue address's city may carry. */
  matches: readonly string[];
  boroughs: readonly string[];
  radiusMiles: number;
  zipsByBorough: Readonly<Record<string, readonly string[]>>;
  /** Subreddits for Reddit's community targeting (names without r/). */
  communities: readonly string[];
}

export const AD_CITIES: readonly AdCity[] = [
  {
    id: "nyc",
    name: "New York City",
    country: "US",
    matches: ["new york", "new york city", "nyc", "manhattan", "brooklyn", "queens", "bronx", "the bronx", "staten island",
              "long island city", "astoria", "flushing", "williamsburg", "bushwick", "harlem"],
    boroughs: ["Manhattan", "Brooklyn", "Queens", "The Bronx", "Staten Island"],
    radiusMiles: 10,
    zipsByBorough: {
      Manhattan: ["10001", "10002", "10003", "10009", "10011", "10012", "10013", "10014", "10016", "10019", "10036"],
      Brooklyn: ["11201", "11205", "11206", "11211", "11215", "11216", "11217", "11221", "11222", "11237", "11238"],
      Queens: ["11101", "11102", "11103", "11104", "11105", "11106", "11354", "11372", "11375", "11377", "11385"],
      "The Bronx": ["10451", "10452", "10453", "10454", "10455", "10456", "10458", "10459", "10460"],
      "Staten Island": ["10301", "10302", "10303", "10304", "10305", "10306", "10310", "10314"],
    },
    communities: ["nyc", "AskNYC", "Brooklyn", "Queens", "bronx", "StatenIsland"],
  },
];

const s = (v: unknown) => (typeof v === "string" ? v.trim().toLowerCase() : "");

/** The configured city a venue address (or a free-text location) is in, or null. */
export function adCityOf(address: unknown, location?: unknown): AdCity | null {
  const a = (address && typeof address === "object" ? address : {}) as Record<string, unknown>;
  const city = s(a.city);
  const loc = s(location);
  return AD_CITIES.find((c) => (city && c.matches.includes(city)) || (loc && c.matches.some((m) => loc.includes(m)))) ?? null;
}

export type AdGeo =
  | { kind: "radius"; lat: number; lng: number; miles: number; city: string | null; zips: string[]; boroughs: string[] }
  | { kind: "zips"; zips: string[]; boroughs: string[]; city: string }
  | { kind: "none"; reason: string };

/** Every ZIP of the city (all boroughs), in config order. */
export function cityZips(c: AdCity): { zips: string[]; boroughs: string[] } {
  const zips: string[] = [];
  for (const b of c.boroughs) for (const z of c.zipsByBorough[b] ?? []) if (!zips.includes(z)) zips.push(z);
  return { zips, boroughs: [...c.boroughs] };
}

export interface GeoInput {
  lat?: number | null;
  lng?: number | null;
  venue_address?: unknown;
  venue_location?: unknown;
}

/** Where to target: the venue radius when its pin is public, else the city's ZIPs, else nothing (a warning). */
export function adGeo(ev: GeoInput): AdGeo {
  const city = adCityOf(ev.venue_address, ev.venue_location);
  const z = city ? cityZips(city) : { zips: [], boroughs: [] };
  if (typeof ev.lat === "number" && typeof ev.lng === "number" && Number.isFinite(ev.lat) && Number.isFinite(ev.lng)) {
    return { kind: "radius", lat: ev.lat, lng: ev.lng, miles: city?.radiusMiles ?? 10, city: city?.id ?? null, ...z };
  }
  if (city) return { kind: "zips", city: city.id, ...z };
  return { kind: "none", reason: "The venue isn't in a city Exos has ad targeting for, and has no map pin: add the venue address first." };
}

export function communitiesFor(cityId: string | null): string[] {
  return [...(AD_CITIES.find((c) => c.id === cityId)?.communities ?? [])];
}
