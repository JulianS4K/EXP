// Door network reads that aren't ticket operations (those live in lib/tickets).

import { supabase } from '../supabase';
import { DOOR_REQUEST_TIMEOUT_MS, isMissingRpc, withDeadline } from './net';
import { parseDoorSummary, type DoorSummary } from './summary';
import type { ImportRow } from './imports';
import { mapDoorEventRow, type DoorEvent } from './roster';
import { listCheckinLists } from '../checkinLists';

/** The event header for the scanner. Staff RLS on exos_events lets door staff
 *  read the event in any status. null when it doesn't exist or isn't visible. */
export async function fetchDoorEvent(eventId: string, signal?: AbortSignal): Promise<DoorEvent | null> {
  let q = supabase.from('exos_events').select('*').eq('id', eventId);
  if (signal) q = q.abortSignal(signal);
  const { data, error } = await q.maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const ev = mapDoorEventRow(data as Record<string, unknown>);
  // Check-in lists (mig 20260929140000), saved with the header for offline.
  // A failed read leaves it undefined: the page keeps the lists it had.
  try {
    ev.checkinLists = await listCheckinLists(eventId, signal);
  } catch (err) {
    console.warn('check-in lists unavailable', err);
    ev.checkinLists = undefined;
  }
  return ev;
}

/** Is the server answering? A cheap call used to leave "unreachable" mode. */
export async function pingServer(): Promise<boolean> {
  try {
    await withDeadline(async (signal) => {
      const { error } = await supabase.rpc('exos_server_time').abortSignal(signal);
      if (error) throw error;
    }, DOOR_REQUEST_TIMEOUT_MS);
    return true;
  } catch {
    return false;
  }
}

/** The end-of-night door summary (exos_event_door_summary, mig 20261008090000).
 *  null when this database doesn't have it yet, or the caller may not see it. */
export async function fetchDoorSummary(eventId: string): Promise<DoorSummary | null> {
  const { data, error } = await supabase.rpc('exos_event_door_summary', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error) || (error as { code?: string }).code === '42501') return null;
    throw error;
  }
  return parseDoorSummary(data);
}

export interface ImportResult {
  inserted: number;
  duplicates: number;
  invalid: number;
  errors: { row: number; reason: string }[];
}

/** Add an attendee export to a guest list (exos_import_guests, mig
 *  20261013090000; owners / managers). Rows over the limit are refused. */
export async function importGuests(listId: string, rows: ImportRow[]): Promise<ImportResult> {
  const { data, error } = await supabase.rpc('exos_import_guests', { p_list_id: listId, p_rows: rows });
  if (error) throw error;
  const d = (data ?? {}) as Record<string, unknown>;
  return {
    inserted: Number(d.inserted) || 0,
    duplicates: Number(d.duplicates) || 0,
    invalid: Number(d.invalid) || 0,
    errors: Array.isArray(d.errors) ? (d.errors as ImportResult['errors']) : [],
  };
}

/** The event's guest list with this exact name, if any (so a re-import goes
 *  into the same list instead of a new one). */
export async function findGuestListId(eventId: string, name: string): Promise<string | null> {
  const { data, error } = await supabase
    .from('exos_guest_lists')
    .select('id')
    .eq('event_id', eventId)
    .eq('name', name)
    .order('created_at', { ascending: true })
    .limit(1);
  if (error) throw error;
  return (data?.[0]?.id as string | undefined) ?? null;
}
