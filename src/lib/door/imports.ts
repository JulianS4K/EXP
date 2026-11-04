// Exos Door: attendee exports from other ticketing platforms (mig
// 20261013090000). Parse the CSV, guess which column is which (Eventbrite,
// Posh, DICE, Shotgun, RA, or any spreadsheet with a name column), turn rows
// into exos_import_guests rows, and match a scanned barcode against the
// imported codes. Pure, unit-tested.

// The column detection and the import plan live in
// supabase/functions/_shared/guestImport.ts (shared with exos-api).
export * from '../../../supabase/functions/_shared/guestImport.ts';
import { normalizeDoorCode } from '../../../supabase/functions/_shared/guestImport.ts';

// The CSV reader is shared with the sales-count import (src/lib/salesCounts.ts)
// and exos-api, so it lives in supabase/functions/_shared/csvParse.ts.
export { parseCsv } from '../../../supabase/functions/_shared/csvParse.ts';

/** Candidate codes in what the camera read: the whole text, and for a link
 *  its last path segment and its query values (some platforms put the
 *  ticket id in a URL). */
export function scanCandidates(scanned: string): string[] {
  const out: string[] = [];
  const add = (s: string | null | undefined) => {
    const c = normalizeDoorCode(s ?? '');
    if (c && !out.includes(c)) out.push(c);
  };
  add(scanned);
  const t = scanned.trim();
  if (/^https?:\/\//i.test(t)) {
    try {
      const u = new URL(t);
      const segs = u.pathname.split('/').filter(Boolean);
      add(segs[segs.length - 1]);
      for (const v of u.searchParams.values()) add(v);
    } catch {
      /* not a URL after all */
    }
  }
  return out;
}

/** Index imported guests by code. */
export function codeIndex<T extends { code?: string | null }>(guests: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const g of guests) {
    const c = normalizeDoorCode(g.code ?? '');
    if (c) m.set(c, g);
  }
  return m;
}

/** The imported guest a scan belongs to, or null. */
export function matchImported<T>(scanned: string, index: Map<string, T>): T | null {
  if (index.size === 0) return null;
  for (const c of scanCandidates(scanned)) {
    const g = index.get(c);
    if (g) return g;
  }
  return null;
}

/** Exos's own signed codes (rotating T- / wallet W-): never looked up among
 *  imported codes. A bare uuid is not on this list: another platform may use
 *  uuids as ticket ids, so it is matched against the imported codes first. */
export const isExosCode = (scanned: string): boolean => /^(T-|W-)/.test(scanned.trim());
