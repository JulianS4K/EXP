// Internal seat numbers for marketplace allocations (mig 20260927030000).
//
// General admission has no seats, but SeatGeek needs seat_from / seat_thru on
// every listing with a row. Each allocated seat has an internal number, per
// ticket type, never shared between marketplaces; the allocation row holds
// the unsold ones as a Postgres int4multirange (internal_seats), which
// supabase-js returns as text: "{[1,5),[11,13)}". Staff and the marketplace
// see these numbers; customers never do.

/** An inclusive run of seat numbers. */
export interface SeatRun {
  from: number;
  thru: number;
}

/** "{[1,5),[11,13)}" (or already-parsed runs) -> [{1,4},{11,12}], sorted and merged. */
export function parseSeatRanges(v: string | SeatRun[] | null | undefined): SeatRun[] {
  if (v == null) return [];
  let runs: SeatRun[];
  if (Array.isArray(v)) {
    runs = v.map((r) => ({ from: r.from, thru: r.thru }));
  } else {
    const s = v.trim();
    if (!/^\{.*\}$/.test(s)) throw new Error(`not a seat range set: ${v}`);
    runs = [];
    const re = /([[(])\s*(-?\d+)\s*,\s*(-?\d+)\s*([\])])/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(s))) {
      const from = Number(m[2]) + (m[1] === '(' ? 1 : 0);
      const thru = Number(m[3]) - (m[4] === ')' ? 1 : 0);
      if (thru >= from) runs.push({ from, thru });
    }
  }
  for (const r of runs) {
    if (!Number.isInteger(r.from) || !Number.isInteger(r.thru) || r.from < 1 || r.thru < r.from) {
      throw new Error(`bad seat run ${r.from}-${r.thru}`);
    }
  }
  runs.sort((a, b) => a.from - b.from);
  const out: SeatRun[] = [];
  for (const r of runs) {
    const last = out[out.length - 1];
    if (last && r.from <= last.thru + 1) last.thru = Math.max(last.thru, r.thru);
    else out.push({ ...r });
  }
  return out;
}

export function seatCount(runs: SeatRun[]): number {
  return runs.reduce((n, r) => n + r.thru - r.from + 1, 0);
}

/** Contiguous blocks of at most `max` seats each (null: no limit), in order. */
export function seatBlocks(runs: SeatRun[], max: number | null): SeatRun[] {
  const out: SeatRun[] = [];
  for (const r of runs) {
    if (!max) {
      out.push({ ...r });
      continue;
    }
    for (let s = r.from; s <= r.thru; s += max) out.push({ from: s, thru: Math.min(s + max - 1, r.thru) });
  }
  return out;
}

/** The lowest `n` seats (a live listing waiting to shrink lists these; the highest go back to Exos). */
export function lowestSeats(runs: SeatRun[], n: number): SeatRun[] {
  const out: SeatRun[] = [];
  let left = Math.max(0, Math.floor(n));
  for (const r of runs) {
    if (left <= 0) break;
    const len = r.thru - r.from + 1;
    out.push(len <= left ? { ...r } : { from: r.from, thru: r.from + left - 1 });
    left -= Math.min(len, left);
  }
  return out;
}

/** "1-4, 11-12" for staff screens. */
export function formatSeatRanges(runs: SeatRun[]): string {
  return runs.map((r) => (r.from === r.thru ? `${r.from}` : `${r.from}-${r.thru}`)).join(', ');
}
