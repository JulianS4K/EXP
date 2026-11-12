// Door network reads that aren't ticket operations (those live in lib/tickets).

import { supabase } from '../supabase';
import { DOOR_REQUEST_TIMEOUT_MS, isMissingRpc, withDeadline } from './net';
import { parseDoorSummary, type DoorSummary } from './summary';
import { parseThroughput, type DoorThroughput } from './throughput';
import type { ImportRow } from './imports';
import { buildAddonRoster, mapDoorEventRow, type DoorEvent, type DoorRoster } from './roster';
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
  // Fair days (mig 20261113110000): the ticket types' day limits, saved with
  // the header so the device applies them offline. Only read for an event
  // with fair-day lists; a failed read keeps the ones the page had.
  if (ev.checkinLists?.some((l) => l.entryDay)) {
    try {
      ev.dayLimits = await fetchDayLimits(eventId, signal);
    } catch (err) {
      console.warn('ticket type day limits unavailable', err);
    }
  }
  return ev;
}

/** Ticket type id → max_entry_days for the event's types that have one. Door
 *  staff read the event's types (staff RLS); {} before the column exists. */
export async function fetchDayLimits(eventId: string, signal?: AbortSignal): Promise<Record<string, number>> {
  let q = supabase.from('exos_ticket_tiers').select('id, max_entry_days').eq('event_id', eventId).not('max_entry_days', 'is', null);
  if (signal) q = q.abortSignal(signal);
  const { data, error } = await q;
  if (error) {
    const code = (error as { code?: string }).code;
    if (code === '42703' || code === 'PGRST204') return {};
    throw error;
  }
  const out: Record<string, number> = {};
  for (const r of (data ?? []) as { id: string; max_entry_days: unknown }[]) {
    const n = Number(r.max_entry_days);
    if (typeof r.id === 'string' && Number.isInteger(n) && n > 0) out[r.id] = n;
  }
  return out;
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

/** Per-gate throughput (exos_door_throughput, mig 20261113110000). null when
 *  this database doesn't have it yet, or the caller may not see it. */
export async function fetchDoorThroughput(
  eventId: string, from: string | null, until: string | null, bucketMinutes: number,
): Promise<DoorThroughput | null> {
  const { data, error } = await supabase.rpc('exos_door_throughput', {
    p_event_id: eventId, p_from: from, p_until: until, p_bucket_minutes: bucketMinutes,
  });
  if (error) {
    if (isMissingRpc(error) || (error as { code?: string }).code === '42501') return null;
    throw error;
  }
  return parseThroughput(data);
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

/** The event's add-on entry codes for the saved list (mig 20261107110000):
 *  door keys only. {} when the database doesn't have them yet. */
export async function fetchAddonRoster(eventId: string): Promise<DoorRoster> {
  try {
    const data = await withDeadline(async (signal) => {
      const { data: d, error } = await supabase.rpc('exos_event_addon_passes', { p_event_id: eventId }).abortSignal(signal);
      if (error) throw error;
      return d;
    }, DOOR_REQUEST_TIMEOUT_MS);
    return buildAddonRoster(data);
  } catch (err) {
    if (isMissingRpc(err)) return {};
    throw err;
  }
}
