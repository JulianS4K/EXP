// Interactive venue map with an AdvancedMarker (docs/maps.md). Lazy-loaded
// by VenueMap so the Maps JS loader only ships to pages that show a map.
// AdvancedMarker requires a Map ID; the container has an explicit height so
// the canvas can't collapse to 0px.

import { APIProvider, AdvancedMarker, Map, Pin } from '@vis.gl/react-google-maps';
import { mapsMapId } from '../lib/maps';

export default function InteractiveVenueMap({
  apiKey, lat, lng, title,
}: { apiKey: string; lat: number; lng: number; title: string }) {
  return (
    <APIProvider apiKey={apiKey}>
      <div style={{ height: 256 }} className="w-full">
        <Map
          mapId={mapsMapId()}
          defaultCenter={{ lat, lng }}
          defaultZoom={15}
          gestureHandling="cooperative"
          disableDefaultUI
          zoomControl
          colorScheme="DARK"
          style={{ width: '100%', height: '100%' }}
        >
          <AdvancedMarker position={{ lat, lng }} title={title}>
            <Pin background="#00FF00" borderColor="#000000" glyphColor="#000000" />
          </AdvancedMarker>
        </Map>
      </div>
    </APIProvider>
  );
}
