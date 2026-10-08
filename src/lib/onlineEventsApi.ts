// RPC wrappers for online / hybrid events (mig 20261005090000). The join
// link never travels with the event row: staff read and write it through
// exos_event_online_staff / exos_set_event_online, holders through
// exos_event_online_access.

import { supabase } from './supabase';

// Whether the migration is on this database: one cheap probe per page load.
let columns: Promise<boolean> | null = null;
export function hasOnlineColumns(): Promise<boolean> {
  if (!columns) {
    columns = Promise.resolve(
      supabase.from('exos_public_events').select('what_to_bring').limit(1),
    ).then(({ error }) => !error, () => false);
  }
  return columns;
}

export interface JoinLink {
  joinUrl: string;
  joinNote: string | null;
  revealMinutes: number | null;
}

export async function getEventJoinLinkForStaff(eventId: string): Promise<JoinLink | null> {
  const { data, error } = await supabase.rpc('exos_event_online_staff', { p_event_id: eventId });
  if (error) throw error;
  const r = Array.isArray(data) ? data[0] : data;
  if (!r?.join_url) return null;
  return { joinUrl: r.join_url, joinNote: r.join_note ?? null, revealMinutes: r.reveal_minutes ?? null };
}

export async function setEventJoinLink(
  eventId: string,
  link: { url: string; note: string | null; revealMinutes: number | null },
): Promise<void> {
  const { error } = await supabase.rpc('exos_set_event_online', {
    p_event_id: eventId,
    p_join_url: link.url,
    p_join_note: link.note,
    p_reveal_minutes: link.revealMinutes,
  });
  if (error) throw error;
}

export type OnlineAccessState = 'none' | 'not_holder' | 'cancelled' | 'later' | 'ready';

export interface OnlineAccess {
  state: OnlineAccessState;
  joinUrl: string | null;
  joinNote: string | null;
  availableAt: number | null; // ms
}

export async function getOnlineAccess(eventId: string): Promise<OnlineAccess> {
  const { data, error } = await supabase.rpc('exos_event_online_access', { p_event_id: eventId });
  if (error) throw error;
  const r = Array.isArray(data) ? data[0] : data;
  return {
    state: (r?.state ?? 'none') as OnlineAccessState,
    joinUrl: r?.join_url ?? null,
    joinNote: r?.join_note ?? null,
    availableAt: r?.available_at ? new Date(r.available_at).getTime() : null,
  };
}
