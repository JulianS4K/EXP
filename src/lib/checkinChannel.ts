// Shared-lock convergence for multi-lane door check-in (D4-OPS-10).
//
// Problem: two offline / intermittently-connected lanes can each hold a ticket
// as unused in their local registry and both admit it before syncing — the
// server's atomic status flip only catches the second on reconnect, after both
// holders already walked in.
//
// Fix: every lane subscribes (over Supabase Realtime) to INSERTs on
// exos_event_checkins for THIS event. Whenever ANY lane successfully checks a
// ticket in — online, or via a reconnect replay of an offline admit — the audit
// row is written and Realtime pushes it to every other connected lane within
// ~seconds, so a near-simultaneous scan elsewhere is refused.
//
// Why postgres_changes rather than a raw broadcast channel: it is AUTHORITATIVE
// (driven by the real status flip, not a client's claim) and RLS-gated — only
// org staff (who can SELECT exos_event_checkins) receive it, so a random authed
// user cannot spoof a "used" event to deny entry. A true simultaneous double
// scan on two FULLY-offline lanes is physically unpreventable client-side; the
// server atomic flip + scan-reject audit remain the backstop, and the reconnect
// registry re-pull (see OrganizerCheckIn) closes the gap once links return.
//
// Requires exos_event_checkins in the `supabase_realtime` publication
// (migration 20260523120000_exos_realtime_checkins.sql; A1 applies).

import type { RealtimeChannel } from '@supabase/supabase-js';
import { supabase } from './supabase';

export interface CheckinChannel {
  leave: () => void;
}

/** One inserted check-in row. list / direction / forced come from mig
 *  20260929140000 (absent before it: a plain entry). */
export interface RemoteCheckin {
  ticketId: string;
  listId: string | null;
  direction: 'entry' | 'exit';
  forced: boolean;
}

/**
 * Subscribe to other lanes' check-ins for an event. `onRemoteCheckIn` fires
 * each time a check-in audit row is inserted for this event (including this
 * lane's own — callers already mark those, so a redundant mark is a no-op).
 * An exit on a re-entry list is a row too (direction 'exit').
 */
export function joinCheckinChannel(
  eventId: string,
  onRemoteCheckIn: (row: RemoteCheckin) => void,
): CheckinChannel {
  const channel: RealtimeChannel = supabase
    .channel(`exos-checkin:${eventId}`)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'exos_event_checkins',
        filter: `event_id=eq.${eventId}`,
      },
      (payload) => {
        const row = (payload.new ?? null) as
          | { ticket_id?: string; list_id?: string | null; direction?: string; forced?: boolean }
          | null;
        if (!row?.ticket_id) return;
        onRemoteCheckIn({
          ticketId: row.ticket_id,
          listId: row.list_id ?? null,
          direction: row.direction === 'exit' ? 'exit' : 'entry',
          forced: row.forced === true,
        });
      },
    )
    .subscribe();

  return {
    leave: () => {
      void supabase.removeChannel(channel);
    },
  };
}
