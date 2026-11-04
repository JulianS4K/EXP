// Booking calendar: the pure pieces (docs/booking.md). No Supabase here, so
// vitest covers it (booking.test.ts); the data layer is bookingApi.ts.
//
// The database (mig 20261030100000) owns the rules: hold levels per org +
// venue + room + date, promotion, convert, the doors row ↔ doors_at. This
// file only shapes what it returns for the calendar and the panels, and
// previews a level change before it is sent.

export type VenueRelationship = 'owned' | 'rented' | 'partner';
export type HoldStatus = 'active' | 'cleared' | 'converted';
export type RentalStatus = 'requested' | 'confirmed' | 'declined';

export const SHOW_ACTIVITY_KINDS = [
  'announce', 'load_in', 'soundcheck', 'doors', 'set', 'changeover', 'curfew', 'load_out', 'other',
] as const;
export type ShowActivityKind = (typeof SHOW_ACTIVITY_KINDS)[number];

export const KIND_LABELS: Record<ShowActivityKind, string> = {
  announce: 'Announce',
  load_in: 'Load in',
  soundcheck: 'Soundcheck',
  doors: 'Doors',
  set: 'Set',
  changeover: 'Changeover',
  curfew: 'Curfew',
  load_out: 'Load out',
  other: 'Other',
};

export const CONTACT_ROLES = ['promoter', 'agent', 'production', 'settlement', 'other'] as const;
export type ContactRole = (typeof CONTACT_ROLES)[number];

export const RELATIONSHIP_LABELS: Record<VenueRelationship, string> = { owned: 'Owned', rented: 'Rented', partner: 'Partner' };

export interface VenueAddress {
  street?: string;
  city?: string;
  region?: string;
  country?: string;
  postal?: string;
}

export interface Venue {
  id: string;
  orgId: string;
  name: string;
  address: VenueAddress | null;
  timezone: string | null;
  capacity: number | null;
  website: string | null;
  permalink: string | null;
  relationship: VenueRelationship;
  contactName: string | null;
  contactEmail: string | null;
  contactPhone: string | null;
  notes: string | null;
}

export interface Room {
  id: string;
  venueId: string;
  name: string;
  capacity: number | null;
  color: string | null;
  notes: string | null;
  sortOrder: number;
}

export interface HoldPosition {
  id: string;
  holdId: string;
  date: string; // YYYY-MM-DD, the venue's local date
  venueId: string;
  roomId: string | null; // null = the whole venue
  startTime: string | null; // HH:MM
  isTarget: boolean;
  level: number;
  status: HoldStatus;
  eventId: string | null;
}

export interface HoldRental {
  status: RentalStatus;
  fee: number | null;
  deposit: number | null;
  currency: string;
  notes: string;
}

export interface Hold {
  id: string;
  title: string;
  notes: string;
  status: HoldStatus;
  announceAt: string | null;
  ticketForecast: number | null;
  ageRestriction: string | null;
  rental: HoldRental | null;
  firstDate: string | null;
  lastDate: string | null;
  positions: HoldPosition[];
}

/** An event as the calendar shows it: on its local date. */
export interface CalendarEvent {
  id: string;
  name: string;
  status: string;
  date: string;
  venueId: string | null;
  roomId: string | null;
  holdId: string | null;
}

export interface ShowActivity {
  id: string;
  eventId: string;
  kind: ShowActivityKind;
  name: string;
  startsAt: string; // ISO
  endsAt: string | null;
  notes: string;
  isSet: boolean;
  showInAdvance: boolean;
  /** The row implied by the event's doors_at when there is no doors row. */
  implied?: boolean;
}

export interface EventNote {
  id: string;
  body: string;
  authorId: string | null;
  authorName: string;
  createdAt: string;
}

export interface EventContact {
  id: string;
  role: ContactRole;
  title: string | null;
  name: string;
  email: string | null;
  phone: string | null;
  company: string | null;
  notes: string;
}

// ---- Dates ------------------------------------------------------------------

const pad = (n: number) => String(n).padStart(2, '0');
export const ymd = (y: number, m: number, d: number) => `${y}-${pad(m + 1)}-${pad(d)}`;

/** YYYY-MM-DD of an instant as seen in `tz` (the event's local date). */
export function localDate(d: Date, tz?: string | null): string {
  try {
    const parts = new Intl.DateTimeFormat('en-CA', { timeZone: tz || undefined, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(d);
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
    return `${get('year')}-${get('month')}-${get('day')}`;
  } catch {
    return d.toISOString().slice(0, 10);
  }
}

/** Weeks (Sunday first) covering a month (0-based), as YYYY-MM-DD or null padding. */
export function monthGrid(year: number, month: number): (string | null)[][] {
  const first = new Date(Date.UTC(year, month, 1)).getUTCDay();
  const days = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const cells: (string | null)[] = [...Array(first).fill(null), ...Array.from({ length: days }, (_, i) => ymd(year, month, i + 1))];
  while (cells.length % 7) cells.push(null);
  const weeks: (string | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

/** First and last date of a month (0-based), YYYY-MM-DD. */
export function monthRange(year: number, month: number): { from: string; to: string } {
  return { from: ymd(year, month, 1), to: ymd(year, month, new Date(Date.UTC(year, month + 1, 0)).getUTCDate()) };
}

export function shiftMonth(c: { y: number; m: number }, delta: number): { y: number; m: number } {
  const d = new Date(Date.UTC(c.y, c.m + delta, 1));
  return { y: d.getUTCFullYear(), m: d.getUTCMonth() };
}

// ---- Slots, levels, challenges -------------------------------------------------

export function slotKey(p: { venueId: string; roomId?: string | null; date: string }): string {
  return `${p.venueId}|${p.roomId || '-'}|${p.date}`;
}

export interface CalendarDay {
  events: CalendarEvent[];
  nights: { hold: Hold; pos: HoldPosition; challenged: boolean }[];
  challenged: boolean;
}

/**
 * The calendar by date: every active night (by level) and every event, with
 * the database's rule for a challenged night: its line has more than one
 * hold, or a show that isn't cancelled is in the same room (or the whole
 * venue, either way) that date.
 */
export function buildCalendar(
  holds: Hold[],
  events: CalendarEvent[],
  filter: { venueId?: string; roomId?: string } = {},
): Map<string, CalendarDay> {
  const nights = holds.flatMap((hold) => hold.positions.filter((p) => p.status === 'active').map((pos) => ({ hold, pos })));
  const lineLength = new Map<string, number>();
  for (const n of nights) lineLength.set(slotKey(n.pos), (lineLength.get(slotKey(n.pos)) ?? 0) + 1);
  const live = events.filter((e) => e.status !== 'cancelled');
  const clashesWithShow = (p: HoldPosition) =>
    live.some((e) => e.venueId === p.venueId && e.date === p.date && (!p.roomId || !e.roomId || e.roomId === p.roomId));
  const matches = (venueId: string | null, roomId: string | null) =>
    (!filter.venueId || venueId === filter.venueId) && (!filter.roomId || roomId === filter.roomId);

  const days = new Map<string, CalendarDay>();
  const day = (d: string) => {
    let x = days.get(d);
    if (!x) days.set(d, (x = { events: [], nights: [], challenged: false }));
    return x;
  };
  for (const e of events) if (matches(e.venueId, e.roomId)) day(e.date).events.push(e);
  for (const n of nights) {
    if (!matches(n.pos.venueId, n.pos.roomId)) continue;
    const challenged = (lineLength.get(slotKey(n.pos)) ?? 0) > 1 || clashesWithShow(n.pos);
    const d = day(n.pos.date);
    d.nights.push({ ...n, challenged });
    if (challenged) d.challenged = true;
  }
  for (const d of days.values()) {
    d.nights.sort((a, b) => a.pos.level - b.pos.level || a.hold.title.localeCompare(b.hold.title));
    d.events.sort((a, b) => a.name.localeCompare(b.name));
  }
  return days;
}

/** The holds in one slot's line, level 1 first. */
export function lineFor(holds: Hold[], slot: { venueId: string; roomId: string | null; date: string }): { hold: Hold; pos: HoldPosition }[] {
  const key = slotKey(slot);
  return holds
    .flatMap((hold) => hold.positions.filter((p) => p.status === 'active' && slotKey(p) === key).map((pos) => ({ hold, pos })))
    .sort((a, b) => a.pos.level - b.pos.level);
}

/**
 * Preview of a line after moving one position to `level` (same rule as the
 * database: take it out, re-insert at level, renumber 1..N). Returns the
 * position ids in their new order.
 */
export function previewMove(lineIds: string[], id: string, level: number): string[] {
  const rest = lineIds.filter((x) => x !== id);
  if (rest.length === lineIds.length) return lineIds;
  const at = Math.min(Math.max(level - 1, 0), rest.length);
  return [...rest.slice(0, at), id, ...rest.slice(at)];
}

// ---- Places ------------------------------------------------------------------

export function placeLabel(venue: Pick<Venue, 'name'> | undefined, room: Pick<Room, 'name'> | undefined | null): string {
  if (!venue) return '';
  return room ? `${venue.name} — ${room.name}` : venue.name;
}

export function slugify(s: string): string {
  return s.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60).replace(/-+$/, '');
}

// ---- Show schedule -------------------------------------------------------------

/**
 * The schedule as shown: rows by time plus, when there is no doors row, an
 * implied one from the event's doors_at (the database keeps a real doors row
 * and doors_at equal).
 */
export function withImpliedDoors(rows: ShowActivity[], eventId: string, doorsAt: string | null | undefined): ShowActivity[] {
  const all = [...rows];
  if (doorsAt && !rows.some((r) => r.kind === 'doors')) {
    all.push({
      id: 'implied-doors', eventId, kind: 'doors', name: 'Doors', startsAt: doorsAt, endsAt: null, notes: '',
      isSet: true, showInAdvance: true, implied: true,
    });
  }
  return all.sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.name.localeCompare(b.name));
}

/** What's wrong with a schedule row before it is saved, or null. */
export function activityProblem(
  input: { kind: ShowActivityKind; startsAt: string | null; endsAt: string | null },
  ctx: { eventStartsAt: string | null; hasOtherDoors: boolean },
): string | null {
  if (!input.startsAt) return 'Give the row a time.';
  if (input.endsAt && Date.parse(input.endsAt) < Date.parse(input.startsAt)) return 'The end can’t be before the start.';
  if (input.kind === 'doors') {
    if (ctx.hasOtherDoors) return 'This show already has a doors row. Edit that one.';
    if (ctx.eventStartsAt && Date.parse(input.startsAt) > Date.parse(ctx.eventStartsAt)) return 'Doors can’t be after the show starts.';
  }
  return null;
}

// ---- Row mapping (database snake_case → app camelCase) ------------------------------

/* eslint-disable @typescript-eslint/no-explicit-any */
export function venueFromRow(r: any): Venue {
  return {
    id: r.id, orgId: r.org_id, name: r.name, address: r.address ?? null, timezone: r.timezone ?? null,
    capacity: r.capacity ?? null, website: r.website ?? null, permalink: r.permalink ?? null,
    relationship: (r.relationship ?? 'owned') as VenueRelationship, contactName: r.contact_name ?? null,
    contactEmail: r.contact_email ?? null, contactPhone: r.contact_phone ?? null, notes: r.notes ?? null,
  };
}

export function roomFromRow(r: any): Room {
  return {
    id: r.id, venueId: r.venue_id, name: r.name, capacity: r.capacity ?? null, color: r.color ?? null,
    notes: r.notes ?? null, sortOrder: r.sort_order ?? 0,
  };
}

export function positionFromRow(r: any, holdId?: string): HoldPosition {
  return {
    id: r.id, holdId: r.hold_id ?? holdId ?? '', date: r.date, venueId: r.venue_id, roomId: r.room_id ?? null,
    startTime: typeof r.start_time === 'string' ? r.start_time.slice(0, 5) : null, isTarget: !!r.is_target,
    level: r.level, status: r.status, eventId: r.event_id ?? null,
  };
}

/** A hold row with its positions (a table row with embedded positions, or _exos_hold_json). */
export function holdFromRow(r: any): Hold {
  const rental: HoldRental | null = r.rental !== undefined
    ? (r.rental ? { status: r.rental.status, fee: r.rental.fee ?? null, deposit: r.rental.deposit ?? null, currency: r.rental.currency ?? 'USD', notes: r.rental.notes ?? '' } : null)
    : (r.rental_status
      ? { status: r.rental_status, fee: r.rental_fee == null ? null : Number(r.rental_fee), deposit: r.rental_deposit == null ? null : Number(r.rental_deposit), currency: r.rental_currency ?? 'USD', notes: r.rental_notes ?? '' }
      : null);
  return {
    id: r.id, title: r.title, notes: r.notes ?? '', status: r.status, announceAt: r.announce_at ?? null,
    ticketForecast: r.ticket_forecast ?? null, ageRestriction: r.age_restriction ?? null, rental,
    firstDate: r.first_date ?? null, lastDate: r.last_date ?? null,
    positions: ((r.positions ?? r.exos_hold_positions ?? []) as any[]).map((p) => positionFromRow(p, r.id))
      .sort((a, b) => a.date.localeCompare(b.date) || a.level - b.level),
  };
}

export function activityFromRow(r: any): ShowActivity {
  return {
    id: r.id, eventId: r.event_id, kind: r.kind, name: r.name, startsAt: r.starts_at, endsAt: r.ends_at ?? null,
    notes: r.notes ?? '', isSet: r.is_set !== false, showInAdvance: r.show_in_advance !== false,
  };
}

export function noteFromRow(r: any): EventNote {
  return { id: r.id, body: r.body, authorId: r.author_id ?? null, authorName: r.author_name ?? '', createdAt: r.created_at };
}

export function contactFromRow(r: any): EventContact {
  return {
    id: r.id, role: r.role, title: r.title ?? null, name: r.name, email: r.email ?? null, phone: r.phone ?? null,
    company: r.company ?? null, notes: r.notes ?? '',
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */
