// Google Maps for event and venue pages (roadmap item 7b).
//
// "Get directions" uses the keyless Maps URLs API, so it always works. The
// embedded map uses the Maps Embed API and only renders when the build has
// VITE_GOOGLE_MAPS_EMBED_KEY: restrict that key to the Maps Embed API and to
// our HTTP referrers in Google Cloud, since it ships in the bundle. The page's
// CSP must also allow frame-src https://www.google.com (Terminal-2 server.py).

export interface VenueAddress {
  street?: string;
  city?: string;
  region?: string;
  country?: string;
  postal?: string;
}

// What to search for: the venue name plus whatever address parts exist, or
// null when there's nothing mappable (TBA, online, blank).
export function venueQuery(location: string | undefined | null, address?: VenueAddress | null): string | null {
  const name = (location ?? '').trim();
  const parts = [address?.street, address?.city, address?.region, address?.postal, address?.country]
    .map((p) => (p ?? '').trim())
    .filter(Boolean);
  if (parts.length === 0 && (!name || /^(tba|tbd|online|virtual|secret location)$/i.test(name))) return null;
  return [name, ...parts].filter(Boolean).join(', ').slice(0, 300);
}

export function directionsUrl(query: string): string {
  return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(query)}`;
}

export function embedUrl(query: string, key: string): string {
  return `https://www.google.com/maps/embed/v1/place?key=${encodeURIComponent(key)}&q=${encodeURIComponent(query)}`;
}

export function mapsEmbedKey(): string | null {
  const key = (import.meta as any).env?.VITE_GOOGLE_MAPS_EMBED_KEY as string | undefined;
  return key && key.trim() ? key.trim() : null;
}
