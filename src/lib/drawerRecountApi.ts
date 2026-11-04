// The POS drawer report on the event report (mig 20261104200000): drawers
// (RLS: door staff and finance of the org read them), their recounts (owner /
// manager / finance) and the recount RPC (owner / manager).

import { supabase } from './supabase';
import type { DrawerRow, RecountRow } from './drawerRecount';

/** The event's drawers, their recounts and whether the settlement is final; null when unreadable. */
export async function getEventDrawers(eventId: string): Promise<{ drawers: DrawerRow[]; recounts: RecountRow[]; settled: boolean } | null> {
  try {
    const d = await supabase.from('exos_pos_drawer_sessions')
      .select('id, status, open_float_cents, expected_cents, counted_cents, variance_cents, closed_at, note')
      .eq('event_id', eventId).order('opened_at', { ascending: true });
    if (d.error) throw d.error;
    const r = await supabase.from('exos_pos_drawer_recounts')
      .select('id, session_id, recount_no, previous_counted_cents, previous_variance_cents, counted_cents, variance_cents, reason, created_at')
      .eq('event_id', eventId);
    const s = await supabase.from('exos_pos_settlements').select('id').eq('event_id', eventId).eq('status', 'final').limit(1);
    return {
      drawers: (d.data ?? []) as DrawerRow[],
      recounts: r.error ? [] : (r.data ?? []) as RecountRow[],
      settled: !s.error && (s.data ?? []).length > 0,
    };
  } catch (e) {
    console.warn('drawer report unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
}

export async function recountDrawer(sessionId: string, countedCents: number, reason: string) {
  const { data, error } = await supabase.rpc('exos_pos_recount_drawer', {
    p_session_id: sessionId, p_counted_cents: countedCents, p_reason: reason, p_counts: null,
  });
  if (error) throw error;
  return data as { recount_no: number; variance_cents: number; previous_counted_cents: number; replay: boolean };
}
