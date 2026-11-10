// Read for the attendance report panel (mig 20261113120000). The RPC checks
// the caller is the org's owner, manager or finance (or a platform admin)
// and allows 20 reads a minute per user.

import { supabase } from './supabase';
import { parseAttendanceReport, type AttendanceReport } from './attendanceReport';

export type AttendanceRead =
  | { report: AttendanceReport }
  | { error: 'rate_limited' | 'not_found' | 'unavailable' };

/** One event's report, optionally paced against another event of the org. */
export async function getEventAttendance(eventId: string, compareEventId: string | null = null): Promise<AttendanceRead> {
  const { data, error } = await supabase.rpc('exos_event_attendance', {
    p_event_id: eventId, p_compare_event_id: compareEventId,
  });
  if (error) {
    // 54000: over 20 a minute; P0002: the comparison event is gone. Anything
    // else (role, or the migration not applied yet) hides the panel.
    if (error.code === '54000') return { error: 'rate_limited' };
    if (error.code === 'P0002') return { error: 'not_found' };
    console.warn('attendance report unavailable (non-fatal):', error.message);
    return { error: 'unavailable' };
  }
  const report = parseAttendanceReport(data);
  return report ? { report } : { error: 'unavailable' };
}
