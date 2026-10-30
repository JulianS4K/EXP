// ---------------------------------------------------------------------------
// Reserved seating: the seat-map model shared by the seat-map editor, the
// buyer's seat picker and the event editor (docs/seating.md). Pure
// TypeScript, no React or Supabase, so vitest covers it directly.
//
// A seat map is a list of sections. A section is either
//   * 'seated': rows of seats, each seat positioned relative to the section's
//     origin (so moving a section moves its seats), or
//   * 'ga': a standing / general-admission area with a capacity and a box.
// The stage is a box too; "best available" ranks seats by their distance to
// its centre.
//
// Stored form (exos_seat_maps.map, jsonb): the same shape without seat ids;
// the database rebuilds a seat's id as `${sectionId}-${rowId}-${key}` and
// checks the map again on save (_exos_seat_map_error, mig 20261030140000).
// validateMap here mirrors that check so the editor can say what's wrong
// before saving.
// ---------------------------------------------------------------------------

export const MAX_SEATS_PER_MAP = 10_000;
export const MAX_SECTIONS_PER_MAP = 100;
export const MAX_ROWS_PER_SECTION = 200;
export const MAX_SEATS_PER_ROW = 200;
export const MAX_GA_CAPACITY = 100_000;
export const MAX_CANVAS = 10_000;
/** Seats one order can hold (the cart hold's quantity cap). */
export const MAX_SEATS_PER_ORDER = 10;

const SHORT_ID_RE = /^[A-Za-z0-9]{1,12}$/;
const KEY_RE = /^[A-Za-z0-9]{1,6}$/;
const LABEL_RE = /^[^|;]{1,24}$/;

export type SectionKind = 'seated' | 'ga';

export interface Seat {
  /** Full seat id: `${sectionId}-${rowId}-${key}`. */
  id: string;
  /** Per-row key the id is built from. */
  key: string;
  /** Seat number as printed ("12", "12A"). */
  label: string;
  x: number;
  y: number;
  accessible?: boolean;
  companion?: boolean;
  obstructed?: boolean;
}

export interface Row {
  id: string;
  label: string;
  seats: Seat[];
}

export type NumberingScheme = 'sequential' | 'reverse' | 'odd' | 'even' | 'odd-reverse' | 'even-reverse';
export const NUMBERING_SCHEMES: NumberingScheme[] = ['sequential', 'reverse', 'odd', 'even', 'odd-reverse', 'even-reverse'];
export type RowStyle = 'letters' | 'numbers';

/** How a section was generated, kept so the editor can regenerate it. */
export interface SectionGen {
  rows: number;
  seatsPerRow: number;
  scheme: NumberingScheme;
  startNumber: number;
  rowStyle: RowStyle;
  rowStart: string;
  spacing: number;
  rowSpacing: number;
  /** 0 (straight) … 1 (strong curve towards the stage). */
  curve: number;
  /** Shift every other row by half a seat. */
  stagger: boolean;
}

export interface Section {
  id: string;
  name: string;
  kind: SectionKind;
  x: number;
  y: number;
  /** Standing areas: box size and capacity. */
  w?: number;
  h?: number;
  capacity?: number;
  labelX?: number;
  labelY?: number;
  rows: Row[];
  gen?: SectionGen;
}

export interface Stage {
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
}

export interface SeatMap {
  width: number;
  height: number;
  stage: Stage;
  sections: Section[];
}

/**
 * Price levels: which ticket tier a section, row or seat sells as. Keys are a
 * section id, `${sectionId}-${rowId}` or a seat id; the most specific wins
 * (seat > row > section).
 */
export type Levels = Record<string, string>;

const round1 = (n: number) => Math.round(n * 10) / 10;

export function countSeats(map: SeatMap): number {
  let n = 0;
  for (const sec of map.sections) for (const r of sec.rows) n += r.seats.length;
  return n;
}

// -- Stored form ---------------------------------------------------------------

/** The jsonb the database stores: no seat ids, unknown fields dropped. */
export function toStoredMap(map: SeatMap): Record<string, unknown> {
  return {
    width: map.width,
    height: map.height,
    stage: { ...map.stage },
    sections: map.sections.map((sec) => ({
      id: sec.id,
      name: sec.name,
      kind: sec.kind,
      x: sec.x,
      y: sec.y,
      ...(sec.kind === 'ga' ? { w: sec.w ?? 200, h: sec.h ?? 120, capacity: sec.capacity ?? 0 } : {}),
      ...(sec.labelX !== undefined ? { labelX: sec.labelX } : {}),
      ...(sec.labelY !== undefined ? { labelY: sec.labelY } : {}),
      ...(sec.gen ? { gen: { ...sec.gen } } : {}),
      rows: sec.kind === 'ga' ? [] : sec.rows.map((r) => ({
        id: r.id,
        label: r.label,
        seats: r.seats.map((s) => ({
          key: s.key,
          label: s.label,
          x: round1(s.x),
          y: round1(s.y),
          ...(s.accessible ? { accessible: true } : {}),
          ...(s.companion ? { companion: true } : {}),
          ...(s.obstructed ? { obstructed: true } : {}),
        })),
      })),
    })),
  };
}

/** Untrusted / stored JSON → SeatMap, rebuilding every seat id. */
export function fromStoredMap(raw: unknown): SeatMap {
  const m = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
  const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  const stage = (m.stage && typeof m.stage === 'object' ? m.stage : {}) as Record<string, unknown>;
  const sections = Array.isArray(m.sections) ? m.sections : [];
  return {
    width: num(m.width, 1000),
    height: num(m.height, 700),
    stage: { x: num(stage.x, 300), y: num(stage.y, 20), w: num(stage.w, 400), h: num(stage.h, 60), label: str(stage.label) || 'Stage' },
    sections: sections.map((rawSec): Section => {
      const s = (rawSec && typeof rawSec === 'object' ? rawSec : {}) as Record<string, unknown>;
      const id = str(s.id);
      const kind: SectionKind = s.kind === 'ga' ? 'ga' : 'seated';
      const rows = Array.isArray(s.rows) ? s.rows : [];
      return {
        id,
        name: str(s.name),
        kind,
        x: num(s.x, 0),
        y: num(s.y, 0),
        ...(kind === 'ga' ? { w: num(s.w, 200), h: num(s.h, 120), capacity: num(s.capacity, 0) } : {}),
        ...(typeof s.labelX === 'number' ? { labelX: s.labelX } : {}),
        ...(typeof s.labelY === 'number' ? { labelY: s.labelY } : {}),
        ...(s.gen && typeof s.gen === 'object' ? { gen: parseGen(s.gen as Record<string, unknown>) } : {}),
        rows: kind === 'ga' ? [] : rows.map((rawRow): Row => {
          const r = (rawRow && typeof rawRow === 'object' ? rawRow : {}) as Record<string, unknown>;
          const rowId = str(r.id);
          const seats = Array.isArray(r.seats) ? r.seats : [];
          return {
            id: rowId,
            label: str(r.label),
            seats: seats.map((rawSeat): Seat => {
              const q = (rawSeat && typeof rawSeat === 'object' ? rawSeat : {}) as Record<string, unknown>;
              const key = str(q.key);
              return {
                id: `${id}-${rowId}-${key}`,
                key,
                label: str(q.label) || key,
                x: num(q.x, NaN),
                y: num(q.y, NaN),
                ...(q.accessible === true ? { accessible: true } : {}),
                ...(q.companion === true ? { companion: true } : {}),
                ...(q.obstructed === true ? { obstructed: true } : {}),
              };
            }),
          };
        }),
      };
    }),
  };
}

function parseGen(g: Record<string, unknown>): SectionGen {
  const n = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
  const rowStyle: RowStyle = g.rowStyle === 'numbers' ? 'numbers' : 'letters';
  return {
    rows: clampInt(n(g.rows, 1), 1, MAX_ROWS_PER_SECTION),
    seatsPerRow: clampInt(n(g.seatsPerRow, 1), 1, MAX_SEATS_PER_ROW),
    scheme: NUMBERING_SCHEMES.includes(g.scheme as NumberingScheme) ? (g.scheme as NumberingScheme) : 'sequential',
    startNumber: clampInt(n(g.startNumber, 1), 0, 9999),
    rowStyle,
    rowStart: typeof g.rowStart === 'string' ? g.rowStart.slice(0, 3) : (rowStyle === 'letters' ? 'A' : '1'),
    spacing: Math.max(4, Math.min(200, n(g.spacing, 24))),
    rowSpacing: Math.max(4, Math.min(200, n(g.rowSpacing, 28))),
    curve: Math.max(0, Math.min(1, n(g.curve, 0))),
    stagger: g.stagger === true,
  };
}

const clampInt = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, Math.round(v)));

// -- Validation --------------------------------------------------------------

const finite = (v: unknown, min: number, max: number): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;

/** Error message for a map, or null when it is valid (same rules as the DB). */
export function validateMap(map: SeatMap): string | null {
  if (!map || typeof map !== 'object') return 'The seat map is missing.';
  if (!finite(map.width, 100, MAX_CANVAS) || !finite(map.height, 100, MAX_CANVAS)) {
    return `The canvas must be between 100 and ${MAX_CANVAS} units wide and high.`;
  }
  const st = map.stage;
  if (!st || !finite(st.x, -MAX_CANVAS, MAX_CANVAS) || !finite(st.y, -MAX_CANVAS, MAX_CANVAS) || !finite(st.w, 0, MAX_CANVAS) || !finite(st.h, 0, MAX_CANVAS)) {
    return 'The stage position is invalid.';
  }
  if (!Array.isArray(map.sections) || map.sections.length === 0) return 'Add at least one section.';
  if (map.sections.length > MAX_SECTIONS_PER_MAP) return `A map can have at most ${MAX_SECTIONS_PER_MAP} sections.`;
  const sectionIds = new Set<string>();
  let seats = 0;
  for (const sec of map.sections) {
    if (!SHORT_ID_RE.test(sec.id ?? '')) return 'Section ids are 1-12 letters or digits.';
    if (sectionIds.has(sec.id)) return `Two sections share the id ${sec.id}.`;
    sectionIds.add(sec.id);
    if (typeof sec.name !== 'string' || !sec.name.trim() || sec.name.trim().length > 40 || /[|;]/.test(sec.name)) {
      return 'Section names are 1-40 characters, without | or ;.';
    }
    if (!finite(sec.x, -MAX_CANVAS, MAX_CANVAS) || !finite(sec.y, -MAX_CANVAS, MAX_CANVAS)) return `Section ${sec.name}: position is invalid.`;
    if (sec.kind === 'ga') {
      if (!Number.isInteger(sec.capacity) || (sec.capacity as number) < 1 || (sec.capacity as number) > MAX_GA_CAPACITY) {
        return `Standing area ${sec.name}: capacity must be 1-${MAX_GA_CAPACITY}.`;
      }
      if (sec.rows && sec.rows.length > 0) return `Standing area ${sec.name} can't have rows.`;
      continue;
    }
    if (sec.kind !== 'seated') return `Section ${sec.name}: kind must be seated or ga.`;
    if (!Array.isArray(sec.rows) || sec.rows.length === 0) return `Section ${sec.name} has no rows.`;
    if (sec.rows.length > MAX_ROWS_PER_SECTION) return `Section ${sec.name}: at most ${MAX_ROWS_PER_SECTION} rows.`;
    const rowIds = new Set<string>();
    for (const row of sec.rows) {
      if (!SHORT_ID_RE.test(row.id ?? '')) return `Section ${sec.name}: row ids are 1-12 letters or digits.`;
      if (rowIds.has(row.id)) return `Section ${sec.name}: two rows share the id ${row.id}.`;
      rowIds.add(row.id);
      if (typeof row.label !== 'string' || !LABEL_RE.test(row.label)) return `Section ${sec.name}: row labels are 1-24 characters, without | or ;.`;
      if (!Array.isArray(row.seats) || row.seats.length === 0) return `Section ${sec.name}, row ${row.label} has no seats.`;
      if (row.seats.length > MAX_SEATS_PER_ROW) return `Section ${sec.name}, row ${row.label}: at most ${MAX_SEATS_PER_ROW} seats.`;
      const keys = new Set<string>();
      for (const seat of row.seats) {
        if (!KEY_RE.test(seat.key ?? '')) return `Section ${sec.name}, row ${row.label}: seat keys are 1-6 letters or digits.`;
        if (keys.has(seat.key)) return `Section ${sec.name}, row ${row.label}: two seats share the key ${seat.key}.`;
        keys.add(seat.key);
        if (typeof seat.label !== 'string' || !LABEL_RE.test(seat.label)) return `Section ${sec.name}, row ${row.label}: seat numbers are 1-24 characters, without | or ;.`;
        if (!finite(seat.x, -MAX_CANVAS, MAX_CANVAS) || !finite(seat.y, -MAX_CANVAS, MAX_CANVAS)) return `Section ${sec.name}, row ${row.label}: a seat position is invalid.`;
        seats++;
      }
    }
  }
  if (seats > MAX_SEATS_PER_MAP) return `A map can have at most ${MAX_SEATS_PER_MAP.toLocaleString('en-US')} seats (this one has ${seats.toLocaleString('en-US')}).`;
  return null;
}

// -- Generation ----------------------------------------------------------------

/**
 * Seat numbers for one row, left to right (house view, stage at the top).
 * `sequential` 1..n, `reverse` n..1, `odd` 1,3,5…, `even` 2,4,6…, and the
 * `-reverse` variants count from the right. `start` replaces the first
 * number (an odd scheme starting at 1 stays odd).
 */
export function seatNumbers(count: number, scheme: NumberingScheme, start = 1): string[] {
  const n = Math.max(0, Math.floor(count));
  let nums: number[];
  switch (scheme) {
    case 'odd':
    case 'odd-reverse': {
      const first = start % 2 === 1 ? start : start + 1;
      nums = Array.from({ length: n }, (_, i) => first + 2 * i);
      break;
    }
    case 'even':
    case 'even-reverse': {
      const first = start % 2 === 0 ? Math.max(2, start) : start + 1;
      nums = Array.from({ length: n }, (_, i) => first + 2 * i);
      break;
    }
    default:
      nums = Array.from({ length: n }, (_, i) => start + i);
  }
  if (scheme === 'reverse' || scheme === 'odd-reverse' || scheme === 'even-reverse') nums.reverse();
  return nums.map(String);
}

/** Letters A, B, … Z, AA, AB … (spreadsheet style), from a 0-based index. */
function letters(i: number): string {
  let s = '';
  let n = i + 1;
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function lettersIndex(s: string): number {
  let n = 0;
  for (const ch of s.toUpperCase()) {
    const c = ch.charCodeAt(0) - 64;
    if (c < 1 || c > 26) return 0;
    n = n * 26 + c;
  }
  return Math.max(0, n - 1);
}

/** Row labels, front (nearest the stage) to back. */
export function rowLabels(count: number, style: RowStyle, start: string): string[] {
  if (style === 'numbers') {
    const first = Math.max(0, Number.parseInt(start, 10) || 1);
    return Array.from({ length: count }, (_, i) => String(first + i));
  }
  const first = lettersIndex(start || 'A');
  return Array.from({ length: count }, (_, i) => letters(first + i));
}

export const DEFAULT_GEN: SectionGen = {
  rows: 5,
  seatsPerRow: 10,
  scheme: 'sequential',
  startNumber: 1,
  rowStyle: 'letters',
  rowStart: 'A',
  spacing: 24,
  rowSpacing: 28,
  curve: 0,
  stagger: false,
};

/**
 * A grid of rows for a section. Seat keys are the 1-based position from the
 * left, so ids don't change when the numbering scheme does. With `curve` the
 * ends of each row bend towards the stage.
 */
export function generateRows(sectionId: string, gen: SectionGen): Row[] {
  const rows: Row[] = [];
  const labels = rowLabels(gen.rows, gen.rowStyle, gen.rowStart);
  const width = (gen.seatsPerRow - 1) * gen.spacing;
  const nums = seatNumbers(gen.seatsPerRow, gen.scheme, gen.startNumber);
  for (let r = 0; r < gen.rows; r++) {
    const offset = gen.stagger && r % 2 === 1 ? gen.spacing / 2 : 0;
    const rowId = `r${r + 1}`;
    const seats: Seat[] = [];
    for (let i = 0; i < gen.seatsPerRow; i++) {
      const x = i * gen.spacing + offset;
      const t = width > 0 ? (x - width / 2) / (width / 2) : 0;
      const bend = gen.curve * Math.min(width, 600) * 0.18 * t * t;
      const key = String(i + 1);
      seats.push({ id: `${sectionId}-${rowId}-${key}`, key, label: nums[i], x: round1(x), y: round1(r * gen.rowSpacing - bend) });
    }
    rows.push({ id: rowId, label: labels[r], seats });
  }
  return rows;
}

/** A seated section from generator settings. */
export function generateSection(id: string, name: string, x: number, y: number, gen: SectionGen): Section {
  return {
    id, name, kind: 'seated', x, y, gen,
    rows: generateRows(id, gen),
    labelX: ((gen.seatsPerRow - 1) * gen.spacing) / 2,
    labelY: -18,
  };
}

/** Regenerates a section, keeping the marks of seats whose row + key survive. */
export function regenerateSection(sec: Section, gen: SectionGen): Section {
  const marks = new Map<string, Pick<Seat, 'accessible' | 'companion' | 'obstructed'>>();
  for (const r of sec.rows) for (const s of r.seats) marks.set(`${r.id}-${s.key}`, { accessible: s.accessible, companion: s.companion, obstructed: s.obstructed });
  const next = generateSection(sec.id, sec.name, sec.x, sec.y, gen);
  next.rows = next.rows.map((r) => ({
    ...r,
    seats: r.seats.map((s) => {
      const m = marks.get(`${r.id}-${s.key}`);
      return {
        ...s,
        ...(m?.accessible ? { accessible: true } : {}),
        ...(m?.companion ? { companion: true } : {}),
        ...(m?.obstructed ? { obstructed: true } : {}),
      };
    }),
  }));
  return next;
}

/** A starter map: a stage and one 5 × 10 section. */
export function starterMap(): SeatMap {
  return {
    width: 1000,
    height: 700,
    stage: { x: 300, y: 20, w: 400, h: 60, label: 'Stage' },
    sections: [generateSection('s1', 'Orchestra', 390, 140, DEFAULT_GEN)],
  };
}

/** A fresh short id for a new section or row. */
export function newShortId(prefix: string, taken: Set<string>): string {
  for (let i = 1; i < 10_000; i++) {
    const id = `${prefix}${i}`;
    if (!taken.has(id)) return id;
  }
  return `${prefix}${Date.now().toString(36).slice(-6)}`;
}

// -- Lookup ------------------------------------------------------------------

export interface SeatEntry {
  section: Section;
  row: Row;
  seat: Seat;
  /** Position of the seat in its row (adjacency for best available). */
  index: number;
}

export function seatIndex(map: SeatMap): Map<string, SeatEntry> {
  const out = new Map<string, SeatEntry>();
  for (const section of map.sections) {
    for (const row of section.rows) row.seats.forEach((seat, index) => out.set(seat.id, { section, row, seat, index }));
  }
  return out;
}

/** The tier a seat sells as: seat, then row, then section level. '' = not on sale. */
export function tierForSeat(levels: Levels, sectionId: string, rowId: string, seatId: string): string {
  return levels[seatId] ?? levels[`${sectionId}-${rowId}`] ?? levels[sectionId] ?? '';
}

/** "Orchestra · Row C · Seat 12" (the label the database prints on tickets). */
export function seatLabel(section: string, row: string, number: string): string {
  return `${section} · Row ${row} · Seat ${number}`;
}

/**
 * Sellable inventory per tier: seated tiers count their seats minus blocked
 * ones; GA tiers add up their standing areas' capacity.
 */
export function capacityByTier(map: SeatMap, levels: Levels, blocked: Set<string> = new Set()): Record<string, { seats: number; ga: number }> {
  const out: Record<string, { seats: number; ga: number }> = {};
  const add = (tierId: string, k: 'seats' | 'ga', n: number) => {
    if (!tierId) return;
    out[tierId] = out[tierId] ?? { seats: 0, ga: 0 };
    out[tierId][k] += n;
  };
  for (const sec of map.sections) {
    if (sec.kind === 'ga') {
      add(levels[sec.id] ?? '', 'ga', sec.capacity ?? 0);
      continue;
    }
    for (const row of sec.rows) {
      for (const seat of row.seats) {
        if (!blocked.has(seat.id)) add(tierForSeat(levels, sec.id, row.id, seat.id), 'seats', 1);
      }
    }
  }
  return out;
}

/**
 * Checks price levels against the map and the event's tiers (same rules as
 * exos_set_event_seating): every key names a section, row or seat, every
 * value is a tier of the event, and no tier is both seated and standing.
 */
export function levelsError(map: SeatMap, levels: Levels, tierIds: string[]): string | null {
  if (!levels || typeof levels !== 'object') return 'Price levels are missing.';
  const keys = new Set<string>();
  for (const sec of map.sections) {
    keys.add(sec.id);
    for (const r of sec.rows) {
      keys.add(`${sec.id}-${r.id}`);
      for (const s of r.seats) keys.add(s.id);
    }
  }
  const tiers = new Set(tierIds);
  for (const [k, v] of Object.entries(levels)) {
    if (!keys.has(k)) return `Price level for ${k}: no such section, row or seat in this map.`;
    if (typeof v !== 'string' || !tiers.has(v)) return `Price level for ${k}: not a ticket type of this event.`;
  }
  const caps = capacityByTier(map, levels);
  for (const c of Object.values(caps)) {
    if (c.seats > 0 && c.ga > 0) return 'A ticket type can be sold as seats or as a standing area, not both.';
  }
  if (Object.keys(caps).length === 0) return 'Assign at least one section to a ticket type.';
  return null;
}

// -- Best available ----------------------------------------------------------

export interface BestOptions {
  /** Offer wheelchair / companion seats too (off by default: kept for those who need them). */
  includeAccessible?: boolean;
  /** When no block of `qty` adjacent seats exists, pick the best separate seats. */
  allowSplit?: boolean;
}

/**
 * The best `qty` available seats of a tier: a block of adjacent seats in one
 * row when there is one (adjacent = next to each other in the row, no taken
 * seat between), closest to the stage centre, obstructed-view seats ranked
 * last. `unavailable` holds every held, sold or blocked seat id. Null when
 * the tier doesn't have `qty` free seats.
 */
export function bestAvailable(
  map: SeatMap, levels: Levels, unavailable: Set<string>, tierId: string, qty: number, opts: BestOptions = {},
): { seatIds: string[]; together: boolean } | null {
  if (!Number.isInteger(qty) || qty < 1) return null;
  const sx = map.stage.x + map.stage.w / 2;
  const sy = map.stage.y + map.stage.h / 2;
  const maxD = Math.hypot(map.width, map.height) || 1;
  const eligible = (sec: Section, row: Row, seat: Seat) =>
    !unavailable.has(seat.id) &&
    tierForSeat(levels, sec.id, row.id, seat.id) === tierId &&
    (opts.includeAccessible || (!seat.accessible && !seat.companion));
  const score = (sec: Section, seat: Seat) =>
    Math.hypot(sec.x + seat.x - sx, sec.y + seat.y - sy) + (seat.obstructed ? maxD : 0);

  let best: { ids: string[]; s: number } | null = null;
  const singles: { id: string; s: number }[] = [];
  for (const sec of map.sections) {
    if (sec.kind !== 'seated') continue;
    for (const row of sec.rows) {
      let run: Seat[] = [];
      const flush = () => {
        for (let i = 0; i + qty <= run.length; i++) {
          const block = run.slice(i, i + qty);
          const s = block.reduce((sum, seat) => sum + score(sec, seat), 0) / qty;
          if (!best || s < best.s - 1e-9) best = { ids: block.map((b) => b.id), s };
        }
        run = [];
      };
      for (const seat of row.seats) {
        if (eligible(sec, row, seat)) {
          run.push(seat);
          singles.push({ id: seat.id, s: score(sec, seat) });
        } else {
          flush();
        }
      }
      flush();
    }
  }
  if (best) return { seatIds: (best as { ids: string[] }).ids, together: true };
  if (opts.allowSplit === false || singles.length < qty) return null;
  singles.sort((a, b) => a.s - b.s);
  return { seatIds: singles.slice(0, qty).map((s) => s.id), together: false };
}

// -- Public seating (exos_public_event_seating + exos_public_event_seats) -------

export interface PublicSeatRow {
  seat_id: string;
  section_id: string;
  section: string;
  row_label: string;
  number: string;
  label: string;
  tier_id: string | null;
  x: number | string;
  y: number | string;
  accessible: boolean;
  companion: boolean;
  obstructed: boolean;
  available: boolean;
}

export interface PublicLayoutSection {
  id: string;
  name: string;
  kind?: SectionKind;
  x: number;
  y: number;
  w?: number | null;
  h?: number | null;
  labelX?: number | null;
  labelY?: number | null;
  tier_id?: string | null;
}

export interface PublicLayout {
  map: { width: number; height: number; stage?: Stage | null; sections: PublicLayoutSection[] };
  seated_tier_ids: string[];
  seat_count: number;
}

export interface PickerData {
  map: SeatMap;
  levels: Levels;
  unavailable: Set<string>;
  seatedTierIds: string[];
  labels: Map<string, string>;
}

/**
 * Rebuilds a drawable map (seats relative to their section, rows in seat
 * order) plus seat-level price levels and the unavailable set from the two
 * public reads. Seat ids are `${section}-${row}-${key}`.
 */
export function pickerData(layout: PublicLayout, seats: PublicSeatRow[]): PickerData {
  const secs = new Map<string, Section>();
  for (const s of layout.map.sections) {
    secs.set(s.id, {
      id: s.id, name: s.name, kind: s.kind === 'ga' ? 'ga' : 'seated', x: Number(s.x) || 0, y: Number(s.y) || 0,
      ...(s.kind === 'ga' ? { w: Number(s.w) || 100, h: Number(s.h) || 60 } : {}),
      ...(typeof s.labelX === 'number' ? { labelX: s.labelX } : {}),
      ...(typeof s.labelY === 'number' ? { labelY: s.labelY } : {}),
      rows: [],
    });
  }
  const levels: Levels = {};
  const unavailable = new Set<string>();
  const labels = new Map<string, string>();
  for (const sec of layout.map.sections) if (sec.kind === 'ga' && sec.tier_id) levels[sec.id] = sec.tier_id;
  for (const r of seats) {
    const sec = secs.get(r.section_id);
    if (!sec) continue;
    const rest = r.seat_id.slice(r.section_id.length + 1);
    const cut = rest.lastIndexOf('-');
    const rowId = rest.slice(0, cut);
    const key = rest.slice(cut + 1);
    let row = sec.rows.find((x) => x.id === rowId);
    if (!row) {
      row = { id: rowId, label: r.row_label, seats: [] };
      sec.rows.push(row);
    }
    row.seats.push({
      id: r.seat_id, key, label: r.number, x: Number(r.x) - sec.x, y: Number(r.y) - sec.y,
      ...(r.accessible ? { accessible: true } : {}),
      ...(r.companion ? { companion: true } : {}),
      ...(r.obstructed ? { obstructed: true } : {}),
    });
    if (r.tier_id) levels[r.seat_id] = r.tier_id;
    if (!r.available) unavailable.add(r.seat_id);
    labels.set(r.seat_id, r.label);
  }
  return {
    map: {
      width: Number(layout.map.width) || 1000,
      height: Number(layout.map.height) || 700,
      stage: layout.map.stage ?? { x: 0, y: 0, w: 0, h: 0, label: '' },
      sections: [...secs.values()],
    },
    levels,
    unavailable,
    seatedTierIds: layout.seated_tier_ids ?? [],
    labels,
  };
}

/** Picking: toggle a seat, keeping one tier per order and the per-order cap. */
export function toggleSeat(
  selection: string[], seatId: string, data: Pick<PickerData, 'levels' | 'unavailable'>, max: number,
): { selection: string[]; error?: string } {
  if (selection.includes(seatId)) return { selection: selection.filter((x) => x !== seatId) };
  const tier = data.levels[seatId];
  if (!tier) return { selection, error: 'That seat is not on sale.' };
  if (data.unavailable.has(seatId)) return { selection, error: 'That seat is taken.' };
  if (selection.length > 0 && data.levels[selection[0]] !== tier) {
    return { selection, error: 'Pick seats of one ticket type per order.' };
  }
  if (selection.length >= max) return { selection, error: `Up to ${max} seats per order.` };
  return { selection: [...selection, seatId] };
}
