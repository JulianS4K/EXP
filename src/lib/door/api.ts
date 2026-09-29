// Door network reads that aren't ticket operations (those live in lib/tickets).

import { supabase } from '../supabase';
import { DOOR_REQUEST_TIMEOUT_MS, withDeadline } from './net';
import { mapDoorEventRow, type DoorEvent } from './roster';

/** The event header for the scanner. Staff RLS on exos_events lets door staff
 *  read the event in any status. null when it doesn't exist or isn't visible. */
export async function fetchDoorEvent(eventId: string, signal?: AbortSignal): Promise<DoorEvent | null> {
  let q = supabase.from('exos_events').select('*').eq('id', eventId);
  if (signal) q = q.abortSignal(signal);
  const { data, error } = await q.maybeSingle();
  if (error) throw error;
  return data ? mapDoorEventRow(data as Record<string, unknown>) : null;
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
