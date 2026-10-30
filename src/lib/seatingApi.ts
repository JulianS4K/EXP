// Reserved seating (mig 20261030140000) — Supabase wrappers. Pure logic lives
// in ./seating; docs/seating.md has the model.
//
//   * Seat maps (exos_seat_maps): RLS, owner / manager write, staff read.
//   * An event's seating is set through exos_set_event_seating and read by
//     staff from exos_event_seating; seats are blocked / unblocked through
//     exos_set_seats_blocked.
//   * Buyers read the layout and seat availability of a published event
//     through two anon-callable functions; seats are held by exos-checkout
//     (with the cart hold), never from the browser.

import { supabase } from './supabase';
import {
  fromStoredMap, pickerData, toStoredMap, type Levels, type PickerData, type PublicLayout, type PublicSeatRow, type SeatMap,
} from './seating';

export interface SeatMapRecord {
  id: string;
  orgId: string;
  roomId: string | null;
  name: string;
  map: SeatMap;
  seatCount: number;
  version: number;
  updatedAt: string;
}

function mapRecord(r: any): SeatMapRecord {
  return {
    id: r.id,
    orgId: r.org_id,
    roomId: r.room_id ?? null,
    name: r.name,
    map: fromStoredMap(r.map),
    seatCount: r.seat_count ?? 0,
    version: r.version ?? 1,
    updatedAt: r.updated_at,
  };
}

export async function listSeatMaps(orgId: string): Promise<SeatMapRecord[]> {
  const { data, error } = await supabase.from('exos_seat_maps')
    .select('id, org_id, room_id, name, map, seat_count, version, updated_at')
    .eq('org_id', orgId).order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(mapRecord);
}

/** Create (no id) or update a seat map; returns the saved record. */
export async function saveSeatMap(orgId: string, input: { id?: string; name: string; map: SeatMap }): Promise<SeatMapRecord> {
  const row = { org_id: orgId, name: input.name.trim(), map: toStoredMap(input.map) };
  const q = input.id
    ? supabase.from('exos_seat_maps').update(row).eq('id', input.id)
    : supabase.from('exos_seat_maps').insert(row);
  const { data, error } = await q.select('id, org_id, room_id, name, map, seat_count, version, updated_at').single();
  if (error) throw error;
  return mapRecord(data);
}

export async function deleteSeatMap(id: string): Promise<void> {
  const { error } = await supabase.from('exos_seat_maps').delete().eq('id', id);
  if (error) throw error;
}

export interface EventSeatingAdmin {
  mapId: string | null;
  mapVersion: number | null;
  map: SeatMap;
  levels: Levels;
  seatCount: number;
}

/** Staff: the event's current seating, or null (general admission). */
export async function getEventSeating(eventId: string): Promise<EventSeatingAdmin | null> {
  const { data, error } = await supabase.from('exos_event_seating')
    .select('map_id, map_version, map, levels, seat_count').eq('event_id', eventId).maybeSingle();
  if (error) {
    // Before the migration the table doesn't exist: no seating.
    if (['42P01', 'PGRST205'].includes(String(error.code))) return null;
    throw error;
  }
  if (!data) return null;
  return {
    mapId: (data as any).map_id ?? null,
    mapVersion: (data as any).map_version ?? null,
    map: fromStoredMap((data as any).map),
    levels: ((data as any).levels ?? {}) as Levels,
    seatCount: (data as any).seat_count ?? 0,
  };
}

/** Owner / manager: assign a map and price levels (null map = general admission). */
export async function setEventSeating(eventId: string, mapId: string | null, levels: Levels): Promise<{ seatCount: number; tiers: Record<string, number> }> {
  const { data, error } = await supabase.rpc('exos_set_event_seating', { p_event_id: eventId, p_map_id: mapId, p_levels: levels });
  if (error) throw error;
  const d = (data ?? {}) as { seat_count?: number; tiers?: Record<string, number> };
  return { seatCount: d.seat_count ?? 0, tiers: d.tiers ?? {} };
}

export interface StaffSeat {
  seatId: string;
  label: string;
  tierId: string | null;
  status: 'available' | 'held' | 'sold' | 'blocked';
  ticketId: string | null;
  holdExpiresAt: string | null;
  reason: string | null;
}

export async function getSeatStatus(eventId: string): Promise<StaffSeat[]> {
  const { data, error } = await supabase.rpc('exos_event_seat_status', { p_event_id: eventId });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    seatId: r.seat_id, label: r.label, tierId: r.tier_id ?? null, status: r.status,
    ticketId: r.ticket_id ?? null, holdExpiresAt: r.hold_expires_at ?? null, reason: r.reason ?? null,
  }));
}

/** Owner / manager: block (kills, house seats) or unblock free seats. Returns the seats changed. */
export async function setSeatsBlocked(eventId: string, seatIds: string[], blocked: boolean, reason?: string): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_set_seats_blocked', {
    p_event_id: eventId, p_seat_ids: seatIds, p_blocked: blocked, p_reason: reason ?? null,
  });
  if (error) throw error;
  return (data ?? []) as string[];
}

/**
 * Buyer: the seat picker's data for a published event, or null when the
 * event has no seat map (general admission, or before the migration).
 */
export async function getPublicSeating(eventId: string): Promise<PickerData | null> {
  const { data: layout, error } = await supabase.rpc('exos_public_event_seating', { p_event_id: eventId });
  if (error || !layout) return null;
  const { data: seats, error: sErr } = await supabase.rpc('exos_public_event_seats', { p_event_id: eventId });
  if (sErr) throw sErr;
  return pickerData(layout as PublicLayout, (seats ?? []) as PublicSeatRow[]);
}

/** Which tiers of an event are seated (empty for general admission). */
export async function getSeatedTierIds(eventId: string): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_public_event_seating', { p_event_id: eventId });
  if (error || !data) return [];
  return ((data as PublicLayout).seated_tier_ids ?? []) as string[];
}

export interface TicketSeat {
  label: string;
  section: string | null;
  row: string | null;
  number: string | null;
}

/**
 * Seats of the caller's tickets (My Tickets, ticket page), by ticket id.
 * Best effort: before the migration (no columns) every ticket is GA.
 */
export async function getTicketSeats(ticketIds: string[]): Promise<Map<string, TicketSeat>> {
  const out = new Map<string, TicketSeat>();
  const ids = [...new Set(ticketIds.filter(Boolean))];
  if (ids.length === 0) return out;
  for (let i = 0; i < ids.length; i += 200) {
    const { data, error } = await supabase.from('exos_tickets')
      .select('id, seat_label, seat_section, seat_row, seat_number')
      .in('id', ids.slice(i, i + 200)).not('seat_label', 'is', null);
    if (error) return out;
    for (const r of (data ?? []) as any[]) {
      out.set(r.id, { label: r.seat_label, section: r.seat_section ?? null, row: r.seat_row ?? null, number: r.seat_number ?? null });
    }
  }
  return out;
}

/** Door: seat labels of an event's seated tickets (cached offline with the roster). */
export async function getSeatRoster(eventId: string): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const { data, error } = await supabase.rpc('exos_event_seat_roster', { p_event_id: eventId });
  if (error) return out;
  for (const r of (data ?? []) as any[]) if (r.seat_label) out.set(r.ticket_id, r.seat_label);
  return out;
}

/** Colours for price levels (by tier order). */
export const LEVEL_COLORS = ['#00FF00', '#38bdf8', '#f472b6', '#facc15', '#a78bfa', '#fb923c', '#34d399', '#f87171'];
