import { lazy, Suspense, useEffect, useState } from 'react';
import { Navigation } from 'lucide-react';
import {
  directionsUrl, directionsUrlForPlace, embedUrl, mapsEmbedKey, mapsJsKey, venueQuery, type VenueAddress,
} from '../lib/maps';
import { getEventGeo, type EventGeo } from '../lib/geo';

const InteractiveVenueMap = lazy(() => import('./InteractiveVenueMap'));

// Map + directions for an event's venue (lib/maps.ts has the fallback order).
// Renders nothing when the venue isn't mappable.
export default function VenueMap({
  eventId, location, address,
}: { eventId?: string; location?: string; address?: VenueAddress }) {
  const q = venueQuery(location, address);
  const jsKey = mapsJsKey();
  const embedKey = mapsEmbedKey();
  const [geo, setGeo] = useState<EventGeo | null>(null);

  useEffect(() => {
    if (!eventId || !jsKey || !q) return undefined;
    let alive = true;
    getEventGeo(eventId).then((g) => { if (alive) setGeo(g); }).catch(() => { /* fall back */ });
    return () => { alive = false; };
  }, [eventId, jsKey, q]);

  if (!q) return null;
  const directions = geo?.placeId ? directionsUrlForPlace(q, geo.placeId) : directionsUrl(q);

  return (
    <div className="bg-[#111] sm:col-span-2">
      {jsKey && geo ? (
        <Suspense fallback={<div style={{ height: 256 }} className="w-full bg-black" />}>
          <InteractiveVenueMap apiKey={jsKey} lat={geo.lat} lng={geo.lng} title={q} />
        </Suspense>
      ) : embedKey ? (
        <iframe
          title={`Map of ${q}`}
          src={embedUrl(q, embedKey)}
          className="block h-56 w-full border-0 grayscale invert-[.9]"
          loading="lazy"
          referrerPolicy="strict-origin-when-cross-origin"
          allowFullScreen
        />
      ) : null}
      <div className="flex items-center justify-between gap-4 p-5">
        <p className="type text-[11px] uppercase tracking-widest text-white/50 truncate">{geo?.formattedAddress || q}</p>
        <a
          href={directions}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex shrink-0 items-center gap-2 type text-[11px] uppercase tracking-widest text-brand-primary hover:underline"
        >
          <Navigation className="h-3 w-3" /> Directions
        </a>
      </div>
    </div>
  );
}
