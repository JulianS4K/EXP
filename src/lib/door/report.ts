// Door totals for the scan report (ScanReport), from exos_event_checkins rows.
// Since mig 20260929140000 a ticket can have several rows: re-entries and
// exits on a re-entry list, and "forced" rows for offline admissions the
// server refused (recorded so attendance is true). Checked in counts
// tickets, not rows. Pure, unit-tested.

export interface DoorScanRow {
  ticketId: string;
  direction: 'entry' | 'exit';
  forced: boolean;
  conflict: string | null;
  verification: string | null;
}

export interface DoorTotals {
  /** Tickets with at least one entry (forced ones included: they came in). */
  checkedIn: number;
  /** Entries after a ticket's first (re-entry lists). */
  reentries: number;
  exits: number;
  /** Offline admissions the server refused but recorded. */
  forced: number;
  byName: number;
  conflicts: { reason: string; count: number }[];
}

export function doorTotals(rows: DoorScanRow[]): DoorTotals {
  const entered = new Set<string>();
  const firstEntries = new Set<string>();
  let normalEntries = 0;
  let exits = 0;
  let forced = 0;
  let byName = 0;
  const reasons = new Map<string, number>();
  for (const r of rows) {
    if (r.direction === 'exit') {
      exits += 1;
      continue;
    }
    entered.add(r.ticketId);
    if (r.forced) {
      forced += 1;
      const k = r.conflict || 'unknown';
      reasons.set(k, (reasons.get(k) ?? 0) + 1);
      continue;
    }
    normalEntries += 1;
    firstEntries.add(r.ticketId);
    if (r.verification === 'name') byName += 1;
  }
  return {
    checkedIn: entered.size,
    reentries: normalEntries - firstEntries.size,
    exits,
    forced,
    byName,
    conflicts: [...reasons.entries()].map(([reason, count]) => ({ reason, count })).sort((a, b) => b.count - a.count),
  };
}
