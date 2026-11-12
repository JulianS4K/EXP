// Per-gate throughput on the door report (exos_door_throughput, mig
// 20261113110000): scans per bucket (15 minutes by default) per gate and
// list, gate totals, the current in-park count where direction is tracked
// (re-entry lists), and refusals by reason. Pure parsing and shaping; the
// panel is components/DoorThroughputPanel.tsx.

import { refusalText, timeIn } from './summary';

export type ScanKind = 'ticket' | 'addon';

export interface ThroughputBucket {
  at: string;
  kind: ScanKind;
  listId: string | null;
  gate: string;
  entries: number;
  exits: number;
  forced: number;
}

export interface ThroughputGate {
  kind: ScanKind;
  listId: string | null;
  gate: string;
  entries: number;
  exits: number;
  forced: number;
  devices: number;
  firstAt: string | null;
  lastAt: string | null;
  peakEntries: number;
}

export interface InsideList {
  listId: string;
  name: string;
  admits: string;
  entryDay: string | null;
  openNow: boolean;
  ticketsInside: number;
  addonsInside: number;
}

export interface DoorThroughput {
  timezone: string;
  from: string;
  until: string;
  bucketMinutes: number;
  buckets: ThroughputBucket[];
  gates: ThroughputGate[];
  inside: InsideList[];
  inParkNow: number;
  lotNow: number;
  tracksDirection: boolean;
  refusals: { reason: string; count: number }[];
}

export const BUCKET_MINUTES = [5, 10, 15, 30, 60] as const;

const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : Number(v) || 0);
const str = (v: unknown) => (typeof v === 'string' ? v : null);
const kind = (v: unknown): ScanKind => (v === 'addon' ? 'addon' : 'ticket');
const arr = (v: unknown) => (Array.isArray(v) ? (v as Record<string, unknown>[]).filter((x) => x && typeof x === 'object') : []);

export function parseThroughput(raw: unknown): DoorThroughput | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  return {
    timezone: str(r.timezone) ?? 'UTC',
    from: str(r.from) ?? '',
    until: str(r.until) ?? '',
    bucketMinutes: num(r.bucket_minutes) || 15,
    buckets: arr(r.buckets).map((b) => ({
      at: String(b.at ?? ''), kind: kind(b.kind), listId: str(b.list_id), gate: String(b.gate ?? ''),
      entries: num(b.entries), exits: num(b.exits), forced: num(b.forced),
    })),
    gates: arr(r.gates).map((g) => ({
      kind: kind(g.kind), listId: str(g.list_id), gate: String(g.gate ?? ''), entries: num(g.entries),
      exits: num(g.exits), forced: num(g.forced), devices: num(g.devices), firstAt: str(g.first_at), lastAt: str(g.last_at),
      peakEntries: num(g.peak_entries),
    })),
    inside: arr(r.inside).map((i) => ({
      listId: String(i.list_id ?? ''), name: String(i.name ?? ''), admits: String(i.admits ?? 'tickets'),
      entryDay: str(i.entry_day), openNow: i.open_now === true, ticketsInside: num(i.tickets_inside),
      addonsInside: num(i.addons_inside),
    })),
    inParkNow: num(r.in_park_now),
    lotNow: num(r.lot_now),
    tracksDirection: r.tracks_direction === true,
    refusals: arr(r.refusals).map((x) => ({ reason: String(x.reason ?? ''), count: num(x.count) })),
  };
}

/** One gate's identity: its list (or, for a deleted list, its name) and kind. */
export const gateKey = (g: { kind: ScanKind; listId: string | null; gate: string }) => `${g.kind}:${g.listId ?? ''}:${g.gate}`;

export interface ThroughputGrid {
  columns: { key: string; label: string; kind: ScanKind }[];
  /** One row per bucket with any scan, oldest first: entries per column. */
  rows: { at: string; cells: number[]; total: number }[];
}

/** The table: a column per gate (busiest first, lot last), a row per bucket. */
export function throughputGrid(t: DoorThroughput): ThroughputGrid {
  const gates = [...t.gates].sort((a, b) =>
    (a.kind === b.kind ? 0 : a.kind === 'ticket' ? -1 : 1) || b.entries - a.entries || a.gate.localeCompare(b.gate));
  const columns = gates.map((g) => ({ key: gateKey(g), label: g.gate, kind: g.kind }));
  const idx = new Map(columns.map((c, i) => [c.key, i]));
  const byTime = new Map<string, number[]>();
  for (const b of t.buckets) {
    const i = idx.get(gateKey(b));
    if (i == null) continue;
    const t0 = new Date(b.at).toISOString();
    const row = byTime.get(t0) ?? new Array(columns.length).fill(0);
    row[i] += b.entries;
    byTime.set(t0, row);
  }
  const rows = [...byTime.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([at, cells]) => ({ at, cells, total: cells.reduce((s, n) => s + n, 0) }));
  return { columns, rows };
}

/** "9:15 AM – 9:30 AM" in the event's zone. */
export function bucketLabel(at: string, minutes: number, timezone: string): string {
  const end = new Date(Date.parse(at) + minutes * 60_000).toISOString();
  return `${timeIn(at, timezone)} – ${timeIn(end, timezone)}`;
}

/** Entries per minute at the busiest bucket of a gate. */
export const peakPerMinute = (g: ThroughputGate, minutes: number) => (minutes > 0 ? g.peakEntries / minutes : 0);

/** A refusal reason in words (the door's reasons, then the scanner's codes). */
export const throughputRefusalText = (reason: string): string => refusalText(reason);

/** The window for "today" in the event's zone, as ISO from / until (now). */
export function todayWindow(now: number, timezone: string): { from: string; until: string } {
  let parts: Record<string, string> = {};
  try {
    parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
      timeZone: timezone, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    }).formatToParts(new Date(now)).map((p) => [p.type, p.value]));
  } catch {
    parts = {};
  }
  const h = Number(parts.hour) % 24, m = Number(parts.minute), s = Number(parts.second);
  const since = Number.isFinite(h + m + s) ? ((h * 60 + m) * 60 + s) * 1000 : 0;
  return { from: new Date(now - since).toISOString(), until: new Date(now).toISOString() };
}
