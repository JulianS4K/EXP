// Map canvas with one AdvancedMarker per event (docs/maps.md). Lazy-loaded
// by the /map page. Explicit container height; Map ID required for
// AdvancedMarker. Clicking a pin opens a card linking to the event.

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { APIProvider, AdvancedMarker, InfoWindow, Map, Pin } from '@vis.gl/react-google-maps';
import { mapsMapId, NYC_CENTER } from '../lib/maps';

export interface EventPin {
  id: string;
  title: string;
  when?: string;
  venue?: string;
  lat: number;
  lng: number;
}

export default function EventsMapCanvas({ apiKey, pins }: { apiKey: string; pins: EventPin[] }) {
  const [open, setOpen] = useState<string | null>(null);
  const active = pins.find((p) => p.id === open) ?? null;
  return (
    <APIProvider apiKey={apiKey}>
      <div style={{ height: '70vh' }} className="w-full border border-white/10">
        <Map
          mapId={mapsMapId()}
          defaultCenter={pins[0] ? { lat: pins[0].lat, lng: pins[0].lng } : NYC_CENTER}
          defaultZoom={12}
          gestureHandling="greedy"
          colorScheme="DARK"
          style={{ width: '100%', height: '100%' }}
        >
          {pins.map((p) => (
            <AdvancedMarker key={p.id} position={{ lat: p.lat, lng: p.lng }} title={p.title} onClick={() => setOpen(p.id)}>
              <Pin background="#00FF00" borderColor="#000000" glyphColor="#000000" />
            </AdvancedMarker>
          ))}
          {active && (
            <InfoWindow position={{ lat: active.lat, lng: active.lng }} onCloseClick={() => setOpen(null)} headerDisabled>
              <div style={{ color: '#000', maxWidth: 220 }}>
                <p style={{ fontWeight: 800, marginBottom: 4 }}>{active.title}</p>
                {active.when && <p style={{ fontSize: 12 }}>{active.when}</p>}
                {active.venue && <p style={{ fontSize: 12, marginBottom: 6 }}>{active.venue}</p>}
                <Link to={`/event/${active.id}`} style={{ fontSize: 12, fontWeight: 700, textDecoration: 'underline' }}>Tickets</Link>
              </div>
            </InfoWindow>
          )}
        </Map>
      </div>
    </APIProvider>
  );
}
