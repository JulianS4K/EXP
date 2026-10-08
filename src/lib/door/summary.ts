// End-of-night door summary (exos_event_door_summary, mig 20261008090000):
// the answer parsed into a typed shape, plus the plain-text and CSV forms the
// organizer copies or downloads. Pure, unit-tested.

import { conflictText } from './health';

export interface Count {
  key: string;
  count: number;
}

export interface DoorSummary {
  eventName: string;
  timezone: string;
  generatedAt: string | null;
  sold: number;
  voided: number;
  checkedIn: number;
  noShows: number;
  /** Voided tickets that still got in (offline, recorded as forced). */
  voidedEntered: number;
  entries: {
    total: number;
    first: number;
    reentries: number;
    exits: number;
    forced: number;
    offline: number;
    byVerification: Count[];
  };
  firstEntryAt: string | null;
  lastEntryAt: string | null;
  peak: { start: string; entries: number } | null;
  /** Local hour in the event's zone ("2026-10-02T19:00"). */
  byHour: { hour: string; entries: number }[];
  byTier: { tier: string; sold: number; checkedIn: number }[];
  byList: { list: string; entries: number; exits: number }[];
  byStaff: { staff: string; entries: number; refused: number }[];
  overrides: Count[];
  conflicts: Count[];
  refusedTotal: number;
  refused: Count[];
  /** Inside right now (only when the event has a re-entry list). */
  insideNow: number | null;
}

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string => (typeof v === 'string' ? v : '');
const strOrNull = (v: unknown): string | null => (typeof v === 'string' && v ? v : null);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const arr = (v: unknown): Record<string, unknown>[] => (Array.isArray(v) ? v.map(obj) : []);
const counts = (v: unknown, keyField: string): Count[] =>
  arr(v).map((r) => ({ key: str(r[keyField]), count: num(r.count) })).filter((c) => c.key);

export function parseDoorSummary(raw: unknown): DoorSummary | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const ev = obj(r.event);
  const t = obj(r.tickets);
  const e = obj(r.entries);
  const peak = obj(r.peak);
  const refused = obj(r.refused);
  return {
    eventName: str(ev.name),
    timezone: str(ev.timezone) || 'UTC',
    generatedAt: strOrNull(r.generated_at),
    sold: num(t.sold),
    voided: num(t.voided),
    checkedIn: num(t.checked_in),
    noShows: num(t.no_shows),
    voidedEntered: num(t.voided_entered),
    entries: {
      total: num(e.total),
      first: num(e.first),
      reentries: num(e.reentries),
      exits: num(e.exits),
      forced: num(e.forced),
      offline: num(e.offline),
      byVerification: Object.entries(obj(e.by_verification))
        .map(([key, v]) => ({ key, count: num(v) }))
        .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key)),
    },
    firstEntryAt: strOrNull(r.first_entry_at),
    lastEntryAt: strOrNull(r.last_entry_at),
    peak: strOrNull(peak.start) ? { start: str(peak.start), entries: num(peak.entries) } : null,
    byHour: arr(r.by_hour).map((h) => ({ hour: str(h.hour), entries: num(h.entries) })),
    byTier: arr(r.by_tier).map((x) => ({ tier: str(x.tier), sold: num(x.sold), checkedIn: num(x.checked_in) })),
    byList: arr(r.by_list).map((x) => ({ list: str(x.list), entries: num(x.entries), exits: num(x.exits) })),
    byStaff: arr(r.by_staff).map((x) => ({ staff: str(x.staff), entries: num(x.entries), refused: num(x.refused) })),
    overrides: counts(r.overrides, 'reason'),
    conflicts: counts(r.conflicts, 'reason'),
    refusedTotal: num(refused.total),
    refused: counts(refused.by_reason, 'reason'),
    insideNow: r.inside_now == null ? null : num(r.inside_now),
  };
}

/** Share of sold tickets that came in, as a whole percent (null when none sold). */
export function showRate(s: Pick<DoorSummary, 'sold' | 'checkedIn'>): number | null {
  return s.sold > 0 ? Math.round((s.checkedIn / s.sold) * 100) : null;
}

const VERIFICATION_TEXT: Record<string, string> = {
  verified: 'QR code',
  manual: 'manual override',
  name: 'by name',
  legacy: 'old code',
  unknown: 'other',
};
export const verificationText = (k: string): string => VERIFICATION_TEXT[k] ?? k;

/** Wording for an exos_scan_rejects reason (the scanner's refusal). */
const REFUSAL_TEXT: Record<string, string> = {
  'invalid-barcode': 'unreadable or forged code',
  'not-found': 'ticket not found',
  'expired-code': 'code outside its time window',
};
export const refusalText = (reason: string): string => REFUSAL_TEXT[reason] ?? conflictText({ reason, forced: false });

/** "8:15 PM" in the event's zone. */
export function timeIn(iso: string | null, timezone: string): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  try {
    return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: timezone });
  } catch {
    return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' });
  }
}

/** "7 PM" from a local "YYYY-MM-DDTHH:00" hour. */
export function hourLabel(hour: string): string {
  const m = /T(\d{2}):/.exec(hour);
  if (!m) return hour;
  const h = Number(m[1]);
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12} ${h < 12 ? 'AM' : 'PM'}`;
}

/** The summary as plain text, to paste into a message or email. */
export function summaryText(s: DoorSummary): string {
  const rate = showRate(s);
  const lines: string[] = [];
  lines.push(`Door summary: ${s.eventName}`);
  lines.push(`${s.checkedIn} of ${s.sold} checked in${rate === null ? '' : ` (${rate}%)`} · ${s.noShows} no-show${s.noShows === 1 ? '' : 's'}`);
  if (s.entries.total > 0) {
    lines.push(`Doors: first in ${timeIn(s.firstEntryAt, s.timezone)}, last in ${timeIn(s.lastEntryAt, s.timezone)}`);
    if (s.peak) lines.push(`Busiest 15 min: ${s.peak.entries} entries from ${timeIn(s.peak.start, s.timezone)}`);
  }
  const extra: string[] = [];
  if (s.entries.reentries) extra.push(`${s.entries.reentries} re-entr${s.entries.reentries === 1 ? 'y' : 'ies'}`);
  if (s.entries.exits) extra.push(`${s.entries.exits} exit${s.entries.exits === 1 ? '' : 's'}`);
  if (s.entries.offline) extra.push(`${s.entries.offline} scanned offline`);
  if (s.insideNow !== null) extra.push(`${s.insideNow} inside now`);
  if (extra.length) lines.push(extra.join(' · '));
  if (s.byTier.length) {
    lines.push('');
    lines.push('By ticket type:');
    for (const t of s.byTier) lines.push(`  ${t.tier}: ${t.checkedIn} / ${t.sold}`);
  }
  if (s.byStaff.length) {
    lines.push('');
    lines.push('By staff:');
    for (const t of s.byStaff) lines.push(`  ${t.staff}: ${t.entries} in${t.refused ? `, ${t.refused} refused` : ''}`);
  }
  const issues: string[] = [];
  for (const o of s.overrides) issues.push(`  Manual override (${o.key}): ${o.count}`);
  for (const c of s.conflicts) issues.push(`  Offline admission, ${conflictText({ reason: c.key, forced: false })}: ${c.count}`);
  for (const r of s.refused) issues.push(`  Refused, ${refusalText(r.key)}: ${r.count}`);
  if (issues.length) {
    lines.push('');
    lines.push('Needs a look:');
    lines.push(...issues);
  }
  return lines.join('\n');
}

/** Rows for the summary CSV: section, item, value (and a second value). */
export function summaryCsvRows(s: DoorSummary): (string | number)[][] {
  const rows: (string | number)[][] = [
    ['tickets', 'sold', s.sold, ''],
    ['tickets', 'checked_in', s.checkedIn, ''],
    ['tickets', 'no_shows', s.noShows, ''],
    ['tickets', 'voided', s.voided, ''],
    ['tickets', 'voided_entered', s.voidedEntered, ''],
    ['entries', 'total', s.entries.total, ''],
    ['entries', 'first', s.entries.first, ''],
    ['entries', 'reentries', s.entries.reentries, ''],
    ['entries', 'exits', s.entries.exits, ''],
    ['entries', 'forced', s.entries.forced, ''],
    ['entries', 'offline', s.entries.offline, ''],
  ];
  for (const v of s.entries.byVerification) rows.push(['verification', v.key, v.count, '']);
  rows.push(['doors', 'first_entry_at', s.firstEntryAt ?? '', ''], ['doors', 'last_entry_at', s.lastEntryAt ?? '', '']);
  if (s.peak) rows.push(['doors', 'peak_15min_start', s.peak.start, s.peak.entries]);
  if (s.insideNow !== null) rows.push(['doors', 'inside_now', s.insideNow, '']);
  for (const h of s.byHour) rows.push(['hour', h.hour, h.entries, '']);
  for (const t of s.byTier) rows.push(['ticket_type', t.tier, t.checkedIn, t.sold]);
  for (const l of s.byList) rows.push(['list', l.list, l.entries, l.exits]);
  for (const t of s.byStaff) rows.push(['staff', t.staff, t.entries, t.refused]);
  for (const o of s.overrides) rows.push(['override', o.key, o.count, '']);
  for (const c of s.conflicts) rows.push(['offline_conflict', c.key, c.count, '']);
  for (const r of s.refused) rows.push(['refused', r.key, r.count, '']);
  return rows;
}

export const SUMMARY_CSV_HEADER = ['section', 'item', 'value', 'value_2'];
