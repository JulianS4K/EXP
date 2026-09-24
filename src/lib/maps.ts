// Google Maps for event and venue pages (roadmap item 7b, docs/maps.md).
//
// Three levels, best available wins:
//   1. Interactive map with an AdvancedMarker (@vis.gl/react-google-maps):
//      needs VITE_GOOGLE_MAPS_API_KEY (browser key, restricted to the Maps
//      JavaScript API and our referrers) plus stored coordinates from the
//      exos-geocode proxy. AdvancedMarker needs a Map ID: VITE_GOOGLE_MAPS_MAP_ID,
//      falling back to Google's DEMO_MAP_ID.
//   2. Maps Embed iframe: VITE_GOOGLE_MAPS_EMBED_KEY, no coordinates needed.
//   3. "Directions" link (keyless Maps URLs API): always.
// The browser never calls a googleapis.com REST endpoint itself; geocoding
// goes through supabase/functions/exos-geocode.

export { venueQuery, type VenueAddress } from '../../supabase/functions/_shared/geocode.ts';

export function directionsUrl(query: string): string {
  return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(query)}`;
}

// Directions to an exact place when we have its Place ID.
export function directionsUrlForPlace(query: string, placeId: string): string {
  return `${directionsUrl(query)}&destination_place_id=${encodeURIComponent(placeId)}`;
}

export function embedUrl(query: string, key: string): string {
  return `https://www.google.com/maps/embed/v1/place?key=${encodeURIComponent(key)}&q=${encodeURIComponent(query)}`;
}

function env(name: string): string | null {
  const v = (import.meta as any).env?.[name] as string | undefined;
  return v && v.trim() ? v.trim() : null;
}

export const mapsEmbedKey = () => env('VITE_GOOGLE_MAPS_EMBED_KEY');
export const mapsJsKey = () => env('VITE_GOOGLE_MAPS_API_KEY');
export const mapsMapId = () => env('VITE_GOOGLE_MAPS_MAP_ID') ?? 'DEMO_MAP_ID';

// Default view for the events map: New York City (docs/gtm-nyc.md).
export const NYC_CENTER = { lat: 40.7128, lng: -73.9851 };
