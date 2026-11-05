// Event location modes (mig 20261105130000, docs/promoter-events.md): pure
// rules shared by the app (src/lib/eventLocation.ts) and the edge functions.
// No imports, so Deno and Node both load it.
//
//   venue_record     today's behaviour: a venue record and/or free-text labels.
//   unlisted_venue   a venue not on Exos: free-text name and address (public).
//   secret_location  the public sees the area (venue_location) only; ticket
//                    holders get the exact address at the reveal time (never
//                    later than the start). The address is never in the event
//                    row: the SQL keeps it in exos_event_secret_locations.
//   tba              the location is to be announced; the organizer chooses
//                    whether tickets sell before then (tba_allow_sales).
//
// The SQL is the authority (blockers, the reveal, who reads what); these
// mirror it for the editor, the event page and the feeds.

export const LOCATION_MODES = ["venue_record", "unlisted_venue", "secret_location", "tba"] as const;
export type LocationMode = (typeof LOCATION_MODES)[number];

export const ORG_TYPES = ["organizer", "promoter", "collective"] as const;
export type OrgType = (typeof ORG_TYPES)[number];

/** A stored mode, or venue_record (the column's default) for anything else. */
export function parseLocationMode(v: unknown): LocationMode {
  return typeof v === "string" && (LOCATION_MODES as readonly string[]).includes(v) ? (v as LocationMode) : "venue_record";
}

export function parseOrgType(v: unknown): OrgType {
  return typeof v === "string" && (ORG_TYPES as readonly string[]).includes(v) ? (v as OrgType) : "organizer";
}

/** The three modes with no venue organization on Exos (capacity required). */
export function isPromoterMode(mode: LocationMode): boolean {
  return mode !== "venue_record";
}

/** Whose location the public can't see in full (no pin, no address). */
export function isPrivateMode(mode: LocationMode): boolean {
  return mode === "secret_location" || mode === "tba";
}

export interface OrgTypeDefaults {
  /** The location mode a new event starts in. */
  defaultLocationMode: LocationMode;
  /** Hide the screens for running a venue (booking calendar, received venue requests). */
  hideVenueManagement: boolean;
}

/** Org type → UI defaults. A label: nothing here grants or removes a permission. */
export function orgTypeDefaults(t: OrgType): OrgTypeDefaults {
  return t === "organizer"
    ? { defaultLocationMode: "venue_record", hideVenueManagement: false }
    : { defaultLocationMode: "unlisted_venue", hideVenueManagement: true };
}

const ms = (iso: string | null | undefined): number | null => {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
};

/** When holders get a secret address: the reveal time, never later than the start (ISO, or null). */
export function effectiveRevealAt(revealAt: string | null | undefined, startsAt: string | null | undefined): string | null {
  const r = ms(revealAt);
  const s = ms(startsAt);
  if (r === null && s === null) return null;
  const t = r === null ? s! : s === null ? r : Math.min(r, s);
  return new Date(t).toISOString();
}

/** Has a secret_location event's address reached its holders yet? */
export function isRevealed(revealAt: string | null | undefined, startsAt: string | null | undefined, now: Date = new Date()): boolean {
  const at = effectiveRevealAt(revealAt, startsAt);
  return at !== null && now.getTime() >= Date.parse(at);
}

/** "24 hours before the start" as a timestamp. Null without a start or for a bad number. */
export function revealAtFromHours(startsAt: string | null | undefined, hoursBefore: number): string | null {
  const s = ms(startsAt);
  if (s === null || !Number.isFinite(hoursBefore) || hoursBefore < 0 || hoursBefore > 720) return null;
  return new Date(s - hoursBefore * 3600_000).toISOString();
}

/** The organizer's reveal presets (hours before the start). */
export const REVEAL_PRESETS: ReadonlyArray<{ hours: number; label: string }> = [
  { hours: 72, label: "3 days before" },
  { hours: 48, label: "2 days before" },
  { hours: 24, label: "24 hours before" },
  { hours: 12, label: "12 hours before" },
  { hours: 6, label: "6 hours before" },
  { hours: 2, label: "2 hours before" },
];

/** Can Exos sell this event now, as far as its location goes? (tba waits for an explicit yes.) */
export function salesOpen(mode: LocationMode, tbaAllowSales: boolean | null | undefined): boolean {
  return mode !== "tba" || tbaAllowSales === true;
}

export interface Address {
  street?: string | null;
  city?: string | null;
  region?: string | null;
  postal?: string | null;
  country?: string | null;
}

/** "Name, 1 Street, City, Region Postal, Country" without the empty parts. */
export function addressLine(name: string | null | undefined, a: Address | null | undefined): string {
  const region = [a?.region, a?.postal].map((x) => (x ?? "").trim()).filter(Boolean).join(" ");
  return [name, a?.street, a?.city, region, a?.country].map((x) => (x ?? "").trim()).filter(Boolean).join(", ");
}

export interface LocationRow {
  location_mode?: unknown;
  venue_name?: string | null;
  venue_location?: string | null;
  venue_address?: Address | null;
  location_reveal_at?: string | null;
  tba_allow_sales?: boolean | null;
  starts_at?: string | null;
  format?: string | null;
}

export interface Blocker {
  code: string;
  field: string;
  message: string;
}

/**
 * The location blockers for an event as the editor has it (mirror of SQL
 * _exos_location_blockers_row). `hasSecret`: a secret address is saved (or
 * typed); `capacities`: each ticket type's capacity (0 = unlimited).
 */
export function locationBlockers(e: LocationRow, hasSecret: boolean, capacities: number[] = []): Blocker[] {
  const out: Blocker[] = [];
  const mode = parseLocationMode(e.location_mode);
  const blank = (s: string | null | undefined) => !(s ?? "").trim();
  if ((e.format ?? "in_person") !== "online") {
    if (mode === "unlisted_venue" && blank(e.venue_address?.street) && blank(e.venue_address?.city)) {
      out.push({ code: "missing_venue_address", field: "venue_address", message: "Add the venue's address (street and city)." });
    }
    if (mode === "secret_location") {
      if (blank(e.venue_location)) {
        out.push({ code: "missing_location_area", field: "venue_location",
          message: "Add the area or neighbourhood shown on the event page (the exact address stays private)." });
      }
      if (!hasSecret) {
        out.push({ code: "missing_secret_address", field: "secret_location", message: "Add the exact address ticket holders get at the reveal." });
      }
      const r = ms(e.location_reveal_at);
      const s = ms(e.starts_at);
      if (r === null) {
        out.push({ code: "missing_reveal_time", field: "location_reveal_at", message: "Pick when ticket holders get the address." });
      } else if (s !== null && r >= s) {
        out.push({ code: "reveal_after_start", field: "location_reveal_at", message: "The address has to be revealed before the event starts." });
      }
    }
    if (mode === "tba" && (e.tba_allow_sales === null || e.tba_allow_sales === undefined)) {
      out.push({ code: "tba_sales_choice", field: "tba_allow_sales",
        message: "Choose whether tickets go on sale before the location is announced." });
    }
  }
  if (isPromoterMode(mode) && capacities.some((c) => !(c > 0))) {
    out.push({ code: "capacity_required", field: "ticket_types",
      message: "Give every ticket type a capacity (events without a venue on Exos can't be unlimited)." });
  }
  return out;
}

export interface PublicLocation {
  mode: LocationMode;
  /** The headline: a venue name, the area, "Secret location", "Location to be announced". */
  title: string;
  /** A second line: the public address or area. */
  detail: string | null;
  /** A note for buyers: when the address comes, that sales wait. */
  note: string | null;
  /** May a map / directions / venue calendar be shown? */
  mappable: boolean;
  /** The public street address (venue_record / unlisted_venue only). */
  address: Address | null;
}

/**
 * What the public event page (and anything public) shows. Only reads the
 * public columns; a secret address can't get here because the row never has it.
 */
export function publicLocation(e: LocationRow, formatWhen: (iso: string) => string = (iso) => iso): PublicLocation {
  const mode = parseLocationMode(e.location_mode);
  const area = (e.venue_location ?? "").trim() || null;
  if (mode === "secret_location") {
    const at = effectiveRevealAt(e.location_reveal_at, e.starts_at);
    return {
      mode, title: "Secret location", detail: area, address: null, mappable: false,
      note: at ? `Ticket holders get the address ${formatWhen(at)}.` : "Ticket holders get the address before the event.",
    };
  }
  if (mode === "tba") {
    return {
      mode, title: "Location to be announced", detail: area, address: null, mappable: false,
      note: salesOpen(mode, e.tba_allow_sales)
        ? "Ticket holders hear as soon as it's set."
        : "Tickets go on sale once the location is announced.",
    };
  }
  const name = (e.venue_name ?? "").trim() || area || "";
  const addr = e.venue_address ?? null;
  const line = addressLine(null, addr) || (area && area !== name ? area : null);
  return { mode, title: name, detail: line || null, note: null, mappable: !!name || !!line, address: addr };
}

export interface HolderLocationView {
  location_mode?: unknown;
  venue_name?: string | null;
  venue_location?: string | null;
  venue_address?: Address | null;
  reveal_at?: string | null;
  revealed?: boolean;
  secret_location?: { venue_name?: string | null; address?: Address | null; directions?: string | null } | null;
}

export interface HolderLocation extends PublicLocation {
  revealed: boolean;
  directions: string | null;
}

/** What a ticket holder sees (the answer of exos_event_location / exos_ticket_link_location). */
export function holderLocation(v: HolderLocationView, formatWhen: (iso: string) => string = (iso) => iso): HolderLocation {
  const mode = parseLocationMode(v.location_mode);
  const s = v.secret_location;
  if (mode === "secret_location" && s && s.address) {
    return {
      mode, title: (s.venue_name ?? "").trim() || "The location", detail: addressLine(null, s.address) || null,
      note: (v.venue_location ?? "").trim() ? `In ${v.venue_location!.trim()}. Please keep it to ticket holders.` : "Please keep it to ticket holders.",
      mappable: true, address: s.address, revealed: true, directions: (s.directions ?? "").trim() || null,
    };
  }
  const pub = publicLocation({
    location_mode: mode, venue_name: v.venue_name, venue_location: v.venue_location, venue_address: v.venue_address,
    location_reveal_at: v.reveal_at,
  }, formatWhen);
  if (mode === "secret_location") {
    pub.note = v.reveal_at ? `You'll get the address ${formatWhen(v.reveal_at)}, here and by email.` : pub.note;
  }
  return { ...pub, revealed: false, directions: null };
}

/**
 * The location fields a public feed (listing feed, Google, calendar,
 * catalog) may publish for an event. A private mode publishes the area as
 * the place name and nothing else: no street, no coordinates.
 */
export function feedLocation(e: LocationRow): { name: string | null; address: Address | null; geo: boolean } {
  const mode = parseLocationMode(e.location_mode);
  if (isPrivateMode(mode)) return { name: (e.venue_location ?? "").trim() || null, address: null, geo: false };
  return {
    name: (e.venue_name ?? "").trim() || (e.venue_location ?? "").trim() || null,
    address: e.venue_address ?? null,
    geo: true,
  };
}

/** Same name and city as an owned venue on Exos (case and spaces aside): the SQL's match key. */
export function venueMatchKey(name: string | null | undefined, city: string | null | undefined): string | null {
  const n = (name ?? "").trim().toLowerCase();
  const c = (city ?? "").trim().toLowerCase();
  return n && c ? `${n}|${c}` : null;
}
