// Door network reads that aren't ticket operations (those live in lib/tickets).

import { supabase } from '../supabase';
import { DOOR_REQUEST_TIMEOUT_MS, isMissingRpc, withDeadline } from './net';
import { parseDoorSummary, type DoorSummary } from './summary';
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
