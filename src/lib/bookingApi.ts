// Booking data layer (mig 20261030100000, docs/booking.md). Pure shaping lives
// in ./booking.ts.
//
// Venues, rooms, the show schedule, notes and contacts are rows the signed-in
// user writes directly (RLS: owner / manager for venues and rooms, owner /
// manager / content for the per-event tables). Holds are read here but
// written only through the exos_hold_* functions, because a hold's level
// depends on every other hold in the same room that night.

import { supabase } from './supabase';
import {
  activityFromRow, contactFromRow, holdFromRow, localDate, noteFromRow, roomFromRow, venueFromRow,
  type CalendarEvent, type ContactRole, type EventContact, type EventNote, type Hold, type HoldRental, type Room,
  type ShowActivity, type ShowActivityKind, type Venue, type VenueAddress, type VenueRelationship,
} from './booking';

/** The database's message without its function prefix, first letter up. */
function clean(error: { message?: string }): Error {
  const msg = String(error.message ?? 'Request failed').replace(/^exos_[a-z_]+:\s*/, '');
  if (/duplicate key value/.test(msg)) {
    if (/permalink/.test(msg)) return new Error('Another venue already uses that permalink.');
    if (/one_doors/.test(msg)) return new Error('This show already has a doors row. Edit that one.');
    if (/one_per_slot/.test(msg)) return new Error('This hold already has that room on that date.');
    return new Error('That clashes with an existing record.');
  }
  if (/violates foreign key constraint/.test(msg)) return new Error('Still in use: hold nights point at it.');
  return new Error(msg.charAt(0).toUpperCase() + msg.slice(1));
}

async function run<T>(p: PromiseLike<{ data: T; error: { message?: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw clean(error);
  return data;
}

// ---- Venues and rooms -------------------------------------------------------------

export async function listVenues(orgId: string): Promise<Venue[]> {
  const rows = await run(supabase.from('exos_venues').select('*').eq('org_id', orgId).order('name'));
  return (rows ?? []).map(venueFromRow);
}

export async function listRooms(orgId: string): Promise<Room[]> {
  const rows = await run(supabase.from('exos_venue_rooms').select('*').eq('org_id', orgId).order('sort_order').order('name'));
  return (rows ?? []).map(roomFromRow);
}

export interface VenueInput {
  name: string;
  address: VenueAddress | null;
  timezone: string;
  capacity: number | null;
  website: string;
  permalink: string;
  relationship: VenueRelationship;
  contactName: string;
  contactEmail: string;
  contactPhone: string;
  notes: string;
}

function venueRow(v: VenueInput) {
  const nul = (s: string) => (s.trim() ? s.trim() : null);
  return {
    name: v.name.trim(), address: v.address, timezone: nul(v.timezone), capacity: v.capacity, website: nul(v.website),
    permalink: nul(v.permalink.toLowerCase()), relationship: v.relationship, contact_name: nul(v.contactName),
    contact_email: nul(v.contactEmail), contact_phone: nul(v.contactPhone), notes: nul(v.notes),
  };
}

export async function saveVenue(orgId: string, input: VenueInput, venueId?: string): Promise<Venue> {
  const row = venueRow(input);
  const data = venueId
    ? await run(supabase.from('exos_venues').update(row).eq('id', venueId).select('*').single())
    : await run(supabase.from('exos_venues').insert({ ...row, org_id: orgId }).select('*').single());
  return venueFromRow(data);
}

export async function deleteVenue(venueId: string): Promise<void> {
  await run(supabase.from('exos_venues').delete().eq('id', venueId));
}

export interface RoomInput {
  name: string;
  capacity: number | null;
  color: string;
  notes: string;
}

export async function saveRoom(orgId: string, venueId: string, input: RoomInput, roomId?: string): Promise<Room> {
  const row = { name: input.name.trim(), capacity: input.capacity, color: input.color.trim() || null, notes: input.notes.trim() || null };
  const data = roomId
    ? await run(supabase.from('exos_venue_rooms').update(row).eq('id', roomId).select('*').single())
    : await run(supabase.from('exos_venue_rooms').insert({ ...row, venue_id: venueId, org_id: orgId }).select('*').single());
  return roomFromRow(data);
}

export async function deleteRoom(roomId: string): Promise<void> {
  await run(supabase.from('exos_venue_rooms').delete().eq('id', roomId));
}

// ---- Holds (read here, written by the functions) ----------------------------------------

const HOLD_SELECT =
  'id, title, notes, status, announce_at, ticket_forecast, age_restriction, rental_status, rental_fee, rental_deposit, ' +
  'rental_currency, rental_notes, first_date, last_date, ' +
  'exos_hold_positions(id, hold_id, date, venue_id, room_id, start_time, is_target, level, status, event_id)';

/** Holds with any night between from and to (every night of each is included). */
export async function listHolds(orgId: string, from: string, to: string): Promise<Hold[]> {
  const ids = await run(supabase.from('exos_hold_positions').select('hold_id').eq('org_id', orgId)
    .gte('date', from).lte('date', to).limit(2000));
  const unique = [...new Set((ids ?? []).map((r: { hold_id: string }) => r.hold_id))];
  if (unique.length === 0) return [];
  const out: Hold[] = [];
  for (let i = 0; i < unique.length; i += 100) {
    const rows = await run(supabase.from('exos_holds').select(HOLD_SELECT).in('id', unique.slice(i, i + 100)));
    out.push(...(rows ?? []).map(holdFromRow));
  }
  return out;
}

export async function getHold(holdId: string): Promise<Hold | null> {
  const row = await run(supabase.from('exos_holds').select(HOLD_SELECT).eq('id', holdId).maybeSingle());
  return row ? holdFromRow(row) : null;
}

export interface NewNight {
  date: string;
  venueId: string;
  roomId: string | null;
  level?: number | null;
  startTime?: string | null;
  isTarget?: boolean;
}

export interface HoldInput {
  title?: string;
  notes?: string;
  announceAt?: string | null;
  ticketForecast?: number | null;
  ageRestriction?: string | null;
  rental?: HoldRental | null;
}

function holdPayload(input: HoldInput): Record<string, unknown> {
  const p: Record<string, unknown> = {};
  if (input.title !== undefined) p.title = input.title;
  if (input.notes !== undefined) p.notes = input.notes;
  if (input.announceAt !== undefined) p.announce_at = input.announceAt;
  if (input.ticketForecast !== undefined) p.ticket_forecast = input.ticketForecast;
  if (input.ageRestriction !== undefined) p.age_restriction = input.ageRestriction;
  if (input.rental !== undefined) p.rental = input.rental;
  return p;
}

const nightPayload = (n: NewNight) => ({
  date: n.date, venue_id: n.venueId, room_id: n.roomId, level: n.level ?? null,
  start_time: n.startTime || null, is_target: !!n.isTarget,
});

export async function createHold(orgId: string, input: HoldInput & { title: string }, nights: NewNight[]): Promise<Hold> {
  const data = await run(supabase.rpc('exos_hold_create', {
    p_org_id: orgId, p_hold: { ...holdPayload(input), positions: nights.map(nightPayload) },
  }));
  return holdFromRow(data);
}

/** An existing night to keep: its id, and optionally a new level / time / target flag. */
export interface KeepNight {
  id: string;
  level?: number;
  startTime?: string | null;
  isTarget?: boolean;
}

/**
 * Update a hold. `nights`, when given, is the full list to keep (existing
 * ones by id, new ones as NewNight); active nights left out are cleared.
 */
export async function updateHold(holdId: string, input: HoldInput, nights?: (KeepNight | NewNight)[]): Promise<Hold> {
  const p = holdPayload(input);
  if (nights) {
    p.positions = nights.map((n) => ('id' in n
      ? {
          id: n.id,
          ...(n.level !== undefined ? { level: n.level } : {}),
          ...(n.startTime !== undefined ? { start_time: n.startTime || null } : {}),
          ...(n.isTarget !== undefined ? { is_target: n.isTarget } : {}),
        }
      : nightPayload(n)));
  }
  return holdFromRow(await run(supabase.rpc('exos_hold_update', { p_hold_id: holdId, p_patch: p })));
}

export async function clearHold(holdId: string, positionIds?: string[]): Promise<Hold> {
  return holdFromRow(await run(supabase.rpc('exos_hold_clear', { p_hold_id: holdId, p_position_ids: positionIds ?? null })));
}

export async function convertHold(
  holdId: string,
  positionId: string,
  opts: { time?: string; clearHoldsOnDay?: boolean } = {},
): Promise<{ hold: Hold; eventId: string }> {
  const data = await run(supabase.rpc('exos_hold_convert', {
    p_hold_id: holdId,
    p_args: { position_id: positionId, ...(opts.time ? { time: opts.time } : {}), ...(opts.clearHoldsOnDay ? { clear_holds_on_day: true } : {}) },
  })) as { hold: unknown; event_id: string };
  return { hold: holdFromRow(data.hold), eventId: data.event_id };
}

// ---- Events on the calendar --------------------------------------------------------------

/** The org's events starting around [from, to], each on its local date. */
export async function listCalendarEvents(orgId: string, from: string, to: string): Promise<CalendarEvent[]> {
  const lo = new Date(`${from}T00:00:00Z`);
  lo.setUTCDate(lo.getUTCDate() - 1);
  const hi = new Date(`${to}T00:00:00Z`);
  hi.setUTCDate(hi.getUTCDate() + 2);
  const rows = await run(supabase.from('exos_events')
    .select('id, name, status, starts_at, timezone, exos_venue_id, exos_room_id, hold_id')
    .eq('org_id', orgId).gte('starts_at', lo.toISOString()).lt('starts_at', hi.toISOString()));
  return (rows ?? [])
    .map((r: { id: string; name: string; status: string; starts_at: string; timezone: string | null; exos_venue_id: string | null; exos_room_id: string | null; hold_id: string | null }) => ({
      id: r.id, name: r.name, status: r.status, date: localDate(new Date(r.starts_at), r.timezone),
      venueId: r.exos_venue_id, roomId: r.exos_room_id, holdId: r.hold_id,
    }))
    .filter((e) => e.date >= from && e.date <= to);
}

/** Link (or unlink) an event to one of the org's venues and rooms. */
export async function setEventVenue(eventId: string, venueId: string | null, roomId: string | null): Promise<void> {
  await run(supabase.from('exos_events').update({ exos_venue_id: venueId, exos_room_id: venueId ? roomId : null }).eq('id', eventId));
}

// ---- Show schedule ----------------------------------------------------------------------

export async function listShowActivities(eventId: string): Promise<ShowActivity[]> {
  const rows = await run(supabase.from('exos_show_activities').select('*').eq('event_id', eventId).order('starts_at'));
  return (rows ?? []).map(activityFromRow);
}

export interface ShowActivityInput {
  kind: ShowActivityKind;
  name: string;
  startsAt: string;
  endsAt: string | null;
  notes: string;
  isSet: boolean;
  showInAdvance: boolean;
}

export async function saveShowActivity(eventId: string, orgId: string, input: ShowActivityInput, id?: string): Promise<void> {
  const row = {
    kind: input.kind, name: input.name.trim(), starts_at: input.startsAt, ends_at: input.endsAt, notes: input.notes.trim(),
    is_set: input.isSet, show_in_advance: input.showInAdvance,
  };
  if (id) await run(supabase.from('exos_show_activities').update(row).eq('id', id));
  else await run(supabase.from('exos_show_activities').insert({ ...row, event_id: eventId, org_id: orgId }));
}

/** Deleting the doors row clears the event's doors time (database trigger). */
export async function deleteShowActivity(id: string): Promise<void> {
  await run(supabase.from('exos_show_activities').delete().eq('id', id));
}

/** Clearing the implied doors row = clearing the event's doors time. */
export async function clearEventDoors(eventId: string): Promise<void> {
  await run(supabase.from('exos_events').update({ doors_at: null }).eq('id', eventId));
}

// ---- Notes and contacts -------------------------------------------------------------------

export async function listNotes(eventId: string): Promise<EventNote[]> {
  const rows = await run(supabase.from('exos_event_notes').select('*').eq('event_id', eventId).order('created_at'));
  return (rows ?? []).map(noteFromRow);
}

export async function addNote(eventId: string, orgId: string, body: string, authorName: string): Promise<void> {
  await run(supabase.from('exos_event_notes').insert({ event_id: eventId, org_id: orgId, body: body.trim(), author_name: authorName.slice(0, 100) }));
}

export async function deleteNote(id: string): Promise<void> {
  await run(supabase.from('exos_event_notes').delete().eq('id', id));
}

export async function listContacts(eventId: string): Promise<EventContact[]> {
  const rows = await run(supabase.from('exos_event_contacts').select('*').eq('event_id', eventId).order('role').order('name'));
  return (rows ?? []).map(contactFromRow);
}

export interface ContactInput {
  role: ContactRole;
  title: string;
  name: string;
  email: string;
  phone: string;
  company: string;
  notes: string;
}

export async function saveContact(eventId: string, orgId: string, input: ContactInput, id?: string): Promise<void> {
  const nul = (s: string) => (s.trim() ? s.trim() : null);
  const row = {
    role: input.role, title: nul(input.title), name: input.name.trim(), email: nul(input.email), phone: nul(input.phone),
    company: nul(input.company), notes: input.notes.trim(),
  };
  if (id) await run(supabase.from('exos_event_contacts').update(row).eq('id', id));
  else await run(supabase.from('exos_event_contacts').insert({ ...row, event_id: eventId, org_id: orgId }));
}

export async function deleteContact(id: string): Promise<void> {
  await run(supabase.from('exos_event_contacts').delete().eq('id', id));
}
