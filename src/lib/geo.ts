// Venue coordinates. Reads come from exos_public_event_geo (published events,
// pins under 30 days old; mig 20260924230000). Geocoding itself only happens
// server-side in the exos-geocode edge function, which organizers trigger when
// they save an event.

import { supabase } from './supabase';

export interface EventGeo {
  eventId: string;
  lat: number;
  lng: number;
  placeId: string | null;
  formattedAddress: string | null;
}

function mapRow(r: any): EventGeo {
  return { eventId: r.event_id, lat: r.lat, lng: r.lng, placeId: r.place_id ?? null, formattedAddress: r.formatted_address ?? null };
}

export async function getEventGeo(eventId: string): Promise<EventGeo | null> {
  const { data, error } = await supabase
    .from('exos_public_event_geo')
    .select('event_id, lat, lng, place_id, formatted_address')
    .eq('event_id', eventId)
    .maybeSingle();
  if (error || !data) return null;
  return mapRow(data);
}

export async function listEventGeo(eventIds: string[]): Promise<Map<string, EventGeo>> {
  const out = new Map<string, EventGeo>();
  if (eventIds.length === 0) return out;
  const { data, error } = await supabase
    .from('exos_public_event_geo')
    .select('event_id, lat, lng, place_id, formatted_address')
    .in('event_id', eventIds.slice(0, 500));
  if (error || !data) return out;
  for (const r of data) out.set(r.event_id, mapRow(r));
  return out;
}

// Ask the server to (re)geocode an event's venue. Best-effort: the event is
// already saved, and a map without a pin falls back to the embed/directions.
export async function geocodeEvent(eventId: string): Promise<void> {
  try {
    const { error } = await supabase.functions.invoke('exos-geocode', { body: { event_id: eventId } });
    if (error) console.warn('Venue geocode failed (map will fall back):', error);
  } catch (e) {
    console.warn('Venue geocode failed (map will fall back):', e);
  }
}
