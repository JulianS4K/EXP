// /map — every published event with a venue pin, on one map (docs/maps.md).
// Pins come from exos_public_event_geo (server-geocoded, under 30 days old).
// Without VITE_GOOGLE_MAPS_API_KEY the page lists events with directions.

import { lazy, Suspense, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { MapPin } from 'lucide-react';
import type { Event } from '../types';
import { listPublicEvents } from '../lib/events';
import { listEventGeo } from '../lib/geo';
import { directionsUrl, mapsJsKey, venueQuery } from '../lib/maps';
import { formatInTz } from '../lib/datetime';
import { applyMeta } from '../lib/meta';
import { publicUrl } from '../lib/utils';
import type { EventPin } from '../components/EventsMapCanvas';

const EventsMapCanvas = lazy(() => import('../components/EventsMapCanvas'));

export default function EventsMap() {
  const [events, setEvents] = useState<Event[]>([]);
  const [pins, setPins] = useState<EventPin[]>([]);
  const [loading, setLoading] = useState(true);
  const key = mapsJsKey();

  useEffect(() => {
    try { applyMeta({ title: 'Events map', description: 'Live events near you, on a map.', canonicalUrl: publicUrl('map') }); } catch { /* non-fatal */ }
    let alive = true;
    (async () => {
      const evs = await listPublicEvents(200);
      const geo = await listEventGeo(evs.map((e) => e.id));
      if (!alive) return;
      setEvents(evs);
      setPins(evs.flatMap((e) => {
        const g = geo.get(e.id);
        if (!g) return [];
        return [{
          id: e.id, title: e.title, venue: e.location, lat: g.lat, lng: g.lng,
          when: e.date ? formatInTz(e.date.toDate(), e.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : undefined,
        }];
      }));
    })()
      .catch((e) => console.error('Events map load failed:', e))
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, []);

  return (
    <div className="max-w-6xl mx-auto px-4 py-10">
      <div className="flex items-center gap-3 mb-6">
        <MapPin className="w-6 h-6 text-brand-primary" />
        <h1 className="disp text-4xl uppercase tracking-wide text-white">Events map</h1>
      </div>
      {loading ? (
        <div style={{ height: '70vh' }} className="w-full bg-black border border-white/10" />
      ) : key && pins.length > 0 ? (
        <Suspense fallback={<div style={{ height: '70vh' }} className="w-full bg-black border border-white/10" />}>
          <EventsMapCanvas apiKey={key} pins={pins} />
        </Suspense>
      ) : (
        <ul className="space-y-2">
          {events.length === 0 && <li className="type text-[11px] uppercase tracking-widest text-white/40">No events on sale right now.</li>}
          {events.map((e) => {
            const q = venueQuery(e.location, e.address);
            return (
              <li key={e.id} className="flex items-center justify-between gap-4 bg-[#111] border border-white/10 px-4 py-3">
                <Link to={`/event/${e.id}`} className="font-bold text-white hover:text-brand-primary truncate">{e.title}</Link>
                {q && (
                  <a href={directionsUrl(q)} target="_blank" rel="noopener noreferrer" className="type text-[11px] uppercase tracking-widest text-brand-primary shrink-0">
                    Directions
                  </a>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
