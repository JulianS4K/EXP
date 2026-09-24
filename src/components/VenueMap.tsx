import { Navigation } from 'lucide-react';
import { directionsUrl, embedUrl, mapsEmbedKey, venueQuery, type VenueAddress } from '../lib/maps';

// Map + directions for an event's venue. Renders nothing when the venue
// isn't mappable; renders directions only when no embed key is configured.
export default function VenueMap({ location, address }: { location?: string; address?: VenueAddress }) {
  const q = venueQuery(location, address);
  if (!q) return null;
  const key = mapsEmbedKey();
  return (
    <div className="bg-[#111] sm:col-span-2">
      {key && (
        <iframe
          title={`Map of ${q}`}
          src={embedUrl(q, key)}
          className="block h-56 w-full border-0 grayscale invert-[.9]"
          loading="lazy"
          referrerPolicy="strict-origin-when-cross-origin"
          allowFullScreen
        />
      )}
      <div className="flex items-center justify-between gap-4 p-5">
        <p className="type text-[11px] uppercase tracking-widest text-white/50 truncate">{q}</p>
        <a
          href={directionsUrl(q)}
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
