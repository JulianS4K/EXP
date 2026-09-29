// Organizer CRUD for check-in lists (mig 20260929140000). Writes go through
// the table's RLS (owner / manager of the event's org); a trigger sets the
// org from the event and checks the ticket types are the event's. Door staff
// of the event read them (the scanner's list picker).

import { supabase } from './supabase';
import { checkinListInputError, mapCheckinListRow, sortLists, type CheckinListInput, type DoorCheckinList } from './door/lists';

/** The event's lists, or null when the database has no lists table yet
 *  (mig 20260929140000 not applied): the door then uses the old RPCs. */
export async function listCheckinLists(eventId: string, signal?: AbortSignal): Promise<DoorCheckinList[] | null> {
  let q = supabase.from('exos_checkin_lists').select('*').eq('event_id', eventId).order('sort_order', { ascending: true });
  if (signal) q = q.abortSignal(signal);
  const { data, error } = await q;
  if (error) {
    // 42P01 (Postgres) / PGRST205 (PostgREST schema cache): no such table.
    const code = (error as { code?: string }).code;
    if (code === '42P01' || code === 'PGRST205' || code === 'PGRST204') return null;
    throw error;
  }
  return sortLists(((data ?? []) as Record<string, unknown>[]).map(mapCheckinListRow));
}

/** Create (no id) or update a list. Returns its id. */
export async function saveCheckinList(eventId: string, input: CheckinListInput, id?: string, sortOrder?: number): Promise<string> {
  const err = checkinListInputError(input);
  if (err) throw new Error(err);
  const row = {
    event_id: eventId,
    name: input.name.trim(),
    tier_ids: input.tierIds && input.tierIds.length > 0 ? input.tierIds : null,
    allow_reentry: input.allowReentry === true,
    valid_from: input.validFrom || null,
    valid_until: input.validUntil || null,
    ...(sortOrder != null ? { sort_order: sortOrder } : {}),
  };
  if (id) {
    const { error } = await supabase.from('exos_checkin_lists').update(row).eq('id', id);
    if (error) throw error;
    return id;
  }
  // org_id is set from the event by a trigger; the value sent is overwritten.
  const { data: ev, error: evErr } = await supabase.from('exos_events').select('org_id').eq('id', eventId).single();
  if (evErr) throw evErr;
  const { data, error } = await supabase
    .from('exos_checkin_lists')
    .insert({ ...row, org_id: (ev as { org_id: string }).org_id })
    .select('id')
    .single();
  if (error) throw error;
  return (data as { id: string }).id;
}

export async function deleteCheckinList(id: string): Promise<void> {
  const { error } = await supabase.from('exos_checkin_lists').delete().eq('id', id);
  if (error) throw error;
}
